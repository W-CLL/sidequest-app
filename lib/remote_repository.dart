import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'client_info.dart';
import 'domain.dart';
import 'media_normalizer.dart';
import 'offline_store.dart';
import 'repository.dart';
import 'silent_reporter.dart';
import 'sync_schedule.dart';
import 'sync_settings.dart';

const _uuid = Uuid();

/// io（安卓/桌面）平台实现工厂：离线优先 + 同步。
QuestRepository createPlatformRepository({required String apiBaseUrl}) =>
    apiBaseUrl.trim().isEmpty
    ? const ConfigurationRepository()
    : RemoteQuestRepository(apiBaseUrl: apiBaseUrl);

class PlatformSessionTokenStore implements SessionTokenStore {
  PlatformSessionTokenStore({
    this.scope = 'default',
    FlutterSecureStorage? secure,
  }) : _secure = secure ?? const FlutterSecureStorage();
  final String scope;
  final FlutterSecureStorage _secure;

  /// 读取失败（例如设备密钥失效导致无法解密）时回调一次，便于静默上报。
  void Function(Object error)? onCorruption;
  String get _key => 'sidequest.remote.token.$scope';
  @override
  Future<String?> read() async {
    if (kIsWeb) {
      return (await SharedPreferences.getInstance()).getString(_key);
    }
    try {
      return await _secure.read(key: _key);
    } catch (error) {
      // 存储损坏（无法解密）：按未登录处理并清掉坏数据，重新登录即可恢复。
      onCorruption?.call(error);
      try {
        await _secure.delete(key: _key);
      } catch (_) {
        // 清不掉也不影响本次降级。
      }
      return null;
    }
  }

  @override
  Future<void> write(String token) async {
    if (kIsWeb) {
      if (!await (await SharedPreferences.getInstance()).setString(
        _key,
        token,
      )) {
        throw const QuestException('无法保存登录状态。');
      }
      return;
    }
    try {
      await _secure.write(key: _key, value: token);
    } catch (_) {
      throw const QuestException('无法保存登录状态。');
    }
  }

  @override
  Future<void> clear() async {
    if (kIsWeb) {
      if (!await (await SharedPreferences.getInstance()).remove(_key)) {
        throw const QuestException('无法清除登录状态。');
      }
      return;
    }
    try {
      await _secure.delete(key: _key);
    } catch (_) {
      throw const QuestException('无法清除登录状态。');
    }
  }
}

class _ApiException extends QuestException {
  const _ApiException(super.message, this.statusCode);
  final int statusCode;
}

bool _isPermanentSyncRejection(int statusCode) =>
    statusCode >= 400 &&
    statusCode < 500 &&
    statusCode != 401 &&
    statusCode != 408 &&
    statusCode != 425 &&
    statusCode != 429;

class _UncertainNetworkException extends QuestException {
  const _UncertainNetworkException(super.message);
}

class _SyncAbortedException extends QuestException {
  const _SyncAbortedException(super.message);
}

class _ParsedSyncResponse {
  const _ParsedSyncResponse({
    required this.state,
    required this.branchMode,
    required this.receipts,
    required this.entries,
    required this.missingCommandIds,
  });

  final AppSnapshot state;
  final String branchMode;
  final List<Map<String, dynamic>> receipts;
  final List<JournalEntry> entries;
  final Set<String> missingCommandIds;
}

typedef WifiCheck = Future<bool> Function();

class RemoteQuestRepository implements QuestRepository {
  @override
  bool get isWebClient => false;

  RemoteQuestRepository({
    required String apiBaseUrl,
    http.Client? client,
    SessionTokenStore? tokenStore,
    SharedPreferences? preferences,
    OfflineStore? offlineStore,
    WifiCheck? wifiCheck,
    ImageNormalizer? imageNormalizer,
    bool autoSync = true,
    DateTime Function()? now,
  }) : _base = _normalizeBase(apiBaseUrl),
       _client = client ?? http.Client(),
       _ownsClient = client == null,
       _prefs = preferences,
       _syncSettings = SyncSettings(preferences: preferences),
       _wifiCheck = wifiCheck ?? _platformWifiCheck,
       _imageNormalizer = imageNormalizer ?? normalizeImageForUpload,
       // ignore: prefer_initializing_formals
       _autoSync = autoSync,
       _now = now ?? DateTime.now,
       _tokens =
           tokenStore ??
           PlatformSessionTokenStore(scope: _scopeFor(apiBaseUrl)),
       _offline =
           offlineStore ?? OfflineStore(namespace: _normalizeBase(apiBaseUrl)) {
    final tokens = _tokens;
    if (tokens is PlatformSessionTokenStore) {
      tokens.onCorruption = (error) => reportProblem(error, 'token.read');
    }
    final uri = Uri.parse(_base);
    if (uri.scheme != 'https' &&
        !(uri.scheme == 'http' &&
            ['localhost', '127.0.0.1', '10.0.2.2', '::1'].contains(uri.host))) {
      throw const QuestException('远程服务必须使用 HTTPS 安全连接。');
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const QuestException('服务地址格式不正确。');
    }
  }

  static String _normalizeBase(String value) {
    final uri = Uri.parse(value.trim().replaceFirst(RegExp(r'/+$'), ''));
    return uri
        .replace(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase())
        .toString();
  }

  static String _scopeFor(String value) =>
      Uri.encodeComponent(_normalizeBase(value)).replaceAll('%', '_');
  static Future<bool> _platformWifiCheck() async {
    try {
      final results = await Connectivity().checkConnectivity();
      return results.contains(ConnectivityResult.wifi) ||
          results.contains(ConnectivityResult.ethernet);
    } on MissingPluginException {
      return false;
    }
  }

  final String _base;
  final http.Client _client;
  final bool _ownsClient;
  SilentReporter? _silentReporter;

  /// 是否允许静默上报：只在真实运行且使用内置网络客户端时开启；
  /// 测试（flutter test / 注入的客户端）一律关闭。
  bool get _reportingEnabled {
    if (!_ownsClient) return false;
    try {
      return Platform.environment['FLUTTER_TEST'] != 'true';
    } on UnsupportedError {
      return false;
    }
  }

  /// 把错误细节静默送到后台（用户无感知）。界面文案请用 voice.userMessageFor。
  @override
  void reportProblem(Object error, String scope) {
    if (!_reportingEnabled) return;
    (_silentReporter ??= SilentReporter(
      _sendDiagnostic,
    )).report(error, scope, client: Platform.operatingSystem);
  }

  Future<void> _sendDiagnostic(Map<String, Object?> payload) async {
    String? token;
    try {
      token = await _tokens.read();
    } catch (_) {
      // 读不到令牌也要尽量送达：诊断走匿名通道，不取决于登录状态。
    }
    await _client
        .post(
          Uri.parse('$_base/api/diagnostics'),
          headers: _headers(token: token),
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 8));
  }

  final SessionTokenStore _tokens;
  final OfflineStore _offline;
  SharedPreferences? _prefs;
  final WifiCheck _wifiCheck;
  final SyncSettings _syncSettings;

  Future<bool> _canAutoSync() async =>
      await _wifiCheck() || await _syncSettings.getMobileDataSyncEnabled();
  final ImageNormalizer _imageNormalizer;
  final bool _autoSync;
  final DateTime Function() _now;
  final StreamController<SyncSummary> _syncController =
      StreamController<SyncSummary>.broadcast();
  final String _syncLeaseOwner = _uuid.v4();
  final String _sessionLeaseOwner = _uuid.v4();
  final Set<Future<void>> _backgroundTasks = {};
  Future<void> _tail = Future.value();
  Future<void>? _syncFuture;
  Future<void>? _protocolFuture;
  Future<void>? _disposeFuture;
  String? _lastEmittedSyncSignature;
  DateTime? _lastLoadAutoSyncAt;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _started = false;
  bool _disposed = false;

  @override
  bool get isRemote => true;
  @override
  bool get isConfigured => true;
  @override
  String get cacheScope => _base;
  @override
  Stream<SyncSummary> get syncUpdates => _syncController.stream;

  void _launchBackground(Future<void> Function() action) {
    if (_disposed) return;
    late final Future<void> task;
    task = Future<void>.sync(action)
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _backgroundTasks.remove(task));
    _backgroundTasks.add(task);
  }

  Future<void> _drainBackgroundTasks() async {
    while (_backgroundTasks.isNotEmpty) {
      await Future.wait(_backgroundTasks.toList(growable: false));
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_disposed) {
      return Future<T>.error(const QuestException('仓储已关闭，请重新打开应用。'));
    }
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<T> _withSessionLease<T>(Future<T> Function() action) async {
    await _ensureStarted();
    while (!_disposed) {
      if (await _offline.acquireLease(
        _sessionLeaseOwner,
        ttl: const Duration(seconds: 30),
      )) {
        Timer? heartbeat;
        Future<void>? renewalFuture;
        void renew() {
          if (renewalFuture != null) return;
          late final Future<void> current;
          current = _offline
              .renewLease(_sessionLeaseOwner, ttl: const Duration(seconds: 30))
              .then<void>((_) {}, onError: (Object _, StackTrace _) {})
              .whenComplete(() {
                if (identical(renewalFuture, current)) renewalFuture = null;
              });
          renewalFuture = current;
        }

        heartbeat = Timer.periodic(const Duration(seconds: 10), (_) => renew());
        try {
          return await action();
        } finally {
          heartbeat.cancel();
          final renewal = renewalFuture;
          if (renewal != null) await renewal;
          await _offline.releaseLease(_sessionLeaseOwner);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    throw const QuestException('仓储已关闭，请重新打开应用。');
  }

  Future<void> _ensureStarted() async {
    if (_started) return;
    _started = true;
    await _offline.database;
    if (!_autoSync) return;
    try {
      _connectivitySubscription = Connectivity().onConnectivityChanged.listen((
        results,
      ) {
        if (results.any((result) => result != ConnectivityResult.none)) {
          _launchBackground(() async {
            if (await _canAutoSync()) await _bestEffortSync();
          });
        }
      });
    } on MissingPluginException {
      // Tests and unsupported platforms use explicit sync calls.
    }
  }

  Map<String, String> _headers({
    String? token,
    bool json = true,
    String? contentType,
  }) => {
    'X-Sidequest-Protocol': '2',
    'X-Sidequest-Client': clientTagAndroid,
    if (json) 'Content-Type': 'application/json; charset=utf-8',
    'Content-Type': ?contentType,
    if (token != null) 'Authorization': 'Bearer $token',
  };

  Future<void> _probeProtocol() async {
    late http.Response response;
    try {
      response = await _client
          .get(Uri.parse('$_base/api/health'))
          .timeout(const Duration(seconds: 20));
    } on TimeoutException catch (error) {
      reportProblem(error, 'health');
      throw const QuestException('连接超时，请稍后重试。');
    } on http.ClientException catch (error) {
      reportProblem(error, 'health');
      throw const QuestException('暂时连接不到服务。');
    } on SocketException catch (error) {
      reportProblem(error, 'health');
      throw const QuestException('暂时连接不到服务。');
    }
    Map<String, dynamic> data;
    try {
      data = jsonMap(jsonDecode(utf8.decode(response.bodyBytes)));
    } catch (error) {
      reportProblem(error, 'health:probe');
      throw const QuestException('暂时无法连接，请更新应用后再试。');
    }
    if (response.statusCode < 200 ||
        response.statusCode >= 300 ||
        data['protocolVersion'] != 2) {
      throw const QuestException('暂时无法连接，请更新应用后再试。');
    }
  }

  Future<void> _ensureProtocol({Future<void> Function()? guard}) async {
    if (guard != null) await guard();
    var future = _protocolFuture;
    if (future == null) {
      future = _probeProtocol();
      _protocolFuture = future;
      try {
        await future;
      } catch (_) {
        if (identical(_protocolFuture, future)) _protocolFuture = null;
        rethrow;
      }
    } else {
      await future;
    }
    if (guard != null) await guard();
  }

  Future<Map<String, dynamic>> _request(
    String endpoint, {
    String method = 'GET',
    Map<String, dynamic>? body,
    Map<String, String>? query,
    bool authenticated = true,
    String? sessionToken,
    Future<void> Function()? guard,
    bool uncertainWrite = false,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    await _ensureProtocol(guard: guard);
    final token = authenticated ? (sessionToken ?? await _tokens.read()) : null;
    if (guard != null) await guard();
    final uri = Uri.parse('$_base/api/$endpoint')
        .replace(queryParameters: query);
    late http.Response response;
    try {
      response = switch (method) {
        'POST' =>
          await _client
              .post(
                uri,
                headers: _headers(token: token),
                body: jsonEncode(body ?? {}),
              )
              .timeout(timeout),
        'DELETE' =>
          await _client
              .delete(uri, headers: _headers(token: token))
              .timeout(timeout),
        _ =>
          await _client
              .get(uri, headers: _headers(token: token))
              .timeout(timeout),
      };
    } on TimeoutException catch (error) {
      reportProblem(error, 'request:$endpoint');
      if (uncertainWrite) {
        throw const _UncertainNetworkException('连接超时，将先确认服务是否已收到。');
      }
      throw const QuestException('连接超时，本机内容已保留，请稍后重试。');
    } on http.ClientException catch (error) {
      reportProblem(error, 'request:$endpoint');
      if (uncertainWrite) {
        throw const _UncertainNetworkException('同步连接中断，将先确认服务是否已收到。');
      }
      throw const QuestException('暂时连接不到服务，本机内容已保留。');
    } on SocketException catch (error) {
      reportProblem(error, 'request:$endpoint');
      if (uncertainWrite) {
        throw const _UncertainNetworkException('同步连接中断，将先确认服务是否已收到。');
      }
      throw const QuestException('暂时连接不到服务，本机内容已保留。');
    }
    if (guard != null) await guard();
    Map<String, dynamic> data;
    try {
      data = jsonMap(jsonDecode(utf8.decode(response.bodyBytes)));
    } catch (error) {
      reportProblem(error, 'request:$endpoint:decode');
      if (uncertainWrite &&
          response.statusCode >= 200 &&
          response.statusCode < 300) {
        throw const _UncertainNetworkException('同步响应无法识别，将先查询回执。');
      }
      throw const QuestException('服务返回了无法识别的数据，请稍后重试。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final failure = _ApiException(
        data['error'] is String ? data['error'] as String : '请求未成功，请稍后重试。',
        response.statusCode,
      );
      if (response.statusCode >= 500) {
        reportProblem(failure, 'request:$endpoint:${response.statusCode}');
      }
      throw failure;
    }
    return data;
  }

  Future<http.Response> _putFile(
    String endpoint,
    File file,
    String mimeType, {
    required String sessionToken,
    required Future<void> Function() guard,
  }) async {
    await _ensureProtocol(guard: guard);
    await guard();
    try {
      final request = http.StreamedRequest(
        'PUT',
        Uri.parse('$_base/api/$endpoint'),
      );
      request.headers.addAll(
        _headers(token: sessionToken, json: false, contentType: mimeType),
      );
      request.contentLength = await file.length();
      final response = await (() async {
        final sent = _client.send(request);
        await file.openRead().pipe(request.sink);
        return http.Response.fromStream(await sent);
      })().timeout(const Duration(minutes: 2));
      await guard();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        var message = '附件同步失败，请稍后重试。';
        try {
          final decoded = jsonMap(jsonDecode(utf8.decode(response.bodyBytes)));
          if (decoded['error'] is String) message = decoded['error'] as String;
        } catch (_) {}
        final failure = _ApiException(message, response.statusCode);
        if (response.statusCode >= 500) {
          reportProblem(failure, 'upload:${response.statusCode}');
        }
        throw failure;
      }
      return response;
    } on TimeoutException catch (error) {
      reportProblem(error, 'upload');
      throw const QuestException('附件同步超时，本机文件仍已保留。');
    } on http.ClientException catch (error) {
      reportProblem(error, 'upload');
      throw const QuestException('附件同步中断，本机文件仍已保留。');
    }
  }

  AppSnapshot _stateFrom(Map<String, dynamic> response) {
    try {
      return AppSnapshot.fromJson(jsonMap(response['state']));
    } catch (_) {
      throw const QuestException('服务状态暂时无法读取，请稍后重试。');
    }
  }

  Future<OfflineAccount> _requireAccount() async {
    await _ensureStarted();
    final account = await _offline.activeAccount();
    if (account == null || account.snapshot.profile == null) {
      throw const QuestException('请先登录，再开始探索。');
    }
    return account;
  }

  Future<OfflineAccount> _requireSyncedAccountForOnlineMutation() async {
    final before = await _requireAccount();
    await syncNow();
    final account = await _requireAccount();
    if (account.id != before.id) {
      throw const QuestException('账号已变更，请重试。');
    }
    if (await _offline.pendingCommandCount(account.id) != 0) {
      throw const QuestException('还有内容没同步，请先到“同步”里处理。');
    }
    return account;
  }

  Future<T> _withPinnedOnlineAccount<T>(
    OfflineAccount expected,
    Future<T> Function(String token, Future<void> Function() guard) action,
  ) => _withSessionLease(() async {
    final current = await _requireAccount();
    if (current.id != expected.id) {
      throw const QuestException('账号已变更，请重试。');
    }
    final token = await _tokens.read();
    if (token == null) {
      await _offline.markRequiresLogin(current.id, true);
      throw const QuestException('请重新登录后继续。');
    }
    Future<void> guard() => _assertPinnedSession(
      accountId: current.id,
      token: token,
      leaseOwner: _sessionLeaseOwner,
    );
    await guard();
    return action(token, guard);
  });

  Future<void> _emitSummary([String? message]) async {
    if (_disposed || _syncController.isClosed) return;
    final account = await _offline.activeAccount();
    if (_disposed || _syncController.isClosed) return;
    final summary = account == null
        ? SyncSummary(message: message)
        : await _offline.summary(account.id);
    if (_disposed || _syncController.isClosed) return;
    final emitted = SyncSummary(
      pending: summary.pending,
      uploading: summary.uploading,
      failed: summary.failed,
      queuedCommands: summary.queuedCommands,
      requiresLogin: summary.requiresLogin,
      message: message ?? summary.message,
    );
    final signature = jsonEncode({
      'account': account?.id,
      'snapshot': account?.snapshot.toJson(),
      'pending': emitted.pending,
      'uploading': emitted.uploading,
      'failed': emitted.failed,
      'queuedCommands': emitted.queuedCommands,
      'requiresLogin': emitted.requiresLogin,
      'message': emitted.message,
    });
    if (_lastEmittedSyncSignature == signature) return;
    if (_disposed || _syncController.isClosed) return;
    _lastEmittedSyncSignature = signature;
    _syncController.add(emitted);
  }

  Future<void> _autoSyncAfterLoad(OfflineAccount account) async {
    if (!_autoSync || account.requiresLogin) return;
    final now = DateTime.now();
    final last = _lastLoadAutoSyncAt;
    if (last != null && now.difference(last) < const Duration(seconds: 5)) {
      return;
    }
    _lastLoadAutoSyncAt = now;
    if (!await _canAutoSync()) return;
    if (!_disposed) await _bestEffortSync();
  }

  Future<AppSnapshot> _rollDay(OfflineAccount account) async {
    final state = account.snapshot;
    final today = localDay(_now());
    if (state.day == today) return state;
    // The server owns day rollover. In particular, never synthesize `next`
    // here: /api/sync rolls the day before checking a branch revision, so a
    // client-generated rollover command would immediately conflict with it.
    return state.copyWith(day: today);
  }

  Future<void> _afterLocalMutation() async {
    if (_disposed) return;
    await _emitSummary();
    if (_disposed) return;
    await scheduleSyncWork();
    if (_disposed) return;
    if (_autoSync && await _canAutoSync() && !_disposed) {
      await _bestEffortSync();
    }
  }

  Future<void> _bestEffortSync() async {
    try {
      await syncNow();
    } on QuestException catch (error) {
      if (!_disposed) await _emitSummary(error.message);
    } on Object {
      if (!_disposed) await _emitSummary('同步暂时中断，本机内容已保留。');
    }
  }

  @override
  Future<AppSnapshot> load() => _serial(() async {
    await _ensureStarted();
    var account = await _offline.activeAccount();
    if (account != null) {
      final state = await _rollDay(account);
      _launchBackground(() => _autoSyncAfterLoad(account!));
      return state;
    }
    if (await _tokens.read() != null) {
      try {
        final cloud = _stateFrom(await _request('state'));
        if (cloud.profile != null) {
          account = await _offline.activateFromCloud(cloud);
          _launchBackground(() => _autoSyncAfterLoad(account!));
          return account.snapshot;
        }
      } on _ApiException catch (error) {
        if (error.statusCode == 401) await _tokens.clear();
        if (error.statusCode != 401) rethrow;
      }
    }
    return AppSnapshot(day: localDay(_now()));
  });

  @override
  Future<AppSnapshot> savePreferences(String role, List<String> chosen) =>
      _serial(() async {
        validatePreferences(role, chosen);
        await _ensureStarted();
        final account = await _offline.activeAccount();
        if (account == null) {
          _prefs ??= await SharedPreferences.getInstance();
          if (!await _prefs!.setString(
            'sidequest.remote.pending.$cacheScope',
            jsonEncode({'role': role, 'preferences': chosen}),
          )) {
            throw const QuestException('偏好保存失败，请重试。');
          }
          return AppSnapshot(day: localDay(_now()));
        }
        final synced = await _requireSyncedAccountForOnlineMutation();
        return _withPinnedOnlineAccount(synced, (token, guard) async {
          final cloud = _stateFrom(
            await _request(
              'preferences',
              method: 'POST',
              body: {'role': role, 'preferences': chosen},
              sessionToken: token,
              guard: guard,
            ),
          );
          await guard();
          return _offline.adoptCloud(synced.id, cloud);
        });
      });

  Future<AppSnapshot> _authenticate(
    String endpoint,
    String nickname,
    String password,
  ) async {
    final display = validateNickname(nickname);
    validatePassword(password);
    final body = <String, dynamic>{'nickname': display, 'password': password};
    if (endpoint == 'register') {
      _prefs ??= await SharedPreferences.getInstance();
      final pending = _prefs!.getString('sidequest.remote.pending.$cacheScope');
      if (pending == null) {
        throw const QuestException('请先选择你的身份，再创建账号。');
      }
      body.addAll(jsonMap(jsonDecode(pending)));
    }
    final result = await _request(
      endpoint,
      method: 'POST',
      body: body,
      authenticated: false,
    );
    final cloud = _stateFrom(result);
    final token = result['token'];
    if (token is! String || cloud.profile == null) {
      throw const QuestException('登录响应无效，请稍后重试。');
    }
    await _tokens.write(token);
    try {
      final account = await _offline.activateFromCloud(cloud);
      if (endpoint == 'register') {
        await _prefs!.remove('sidequest.remote.pending.$cacheScope');
      }
      await _emitSummary();
      if (_autoSync && await _canAutoSync()) {
        _launchBackground(_bestEffortSync);
      }
      return account.snapshot;
    } catch (_) {
      await _tokens.clear();
      rethrow;
    }
  }

  @override
  Future<AppSnapshot> register(String nickname, String password) =>
      _serial(() async {
        await _ensureStarted();
        return _withSessionLease(
          () => _authenticate('register', nickname, password),
        );
      });
  @override
  Future<AppSnapshot> login(String nickname, String password) =>
      _serial(() async {
        await _ensureStarted();
        return _withSessionLease(
          () => _authenticate('login', nickname, password),
        );
      });

  @override
  Future<AppSnapshot> logout({bool discardPending = false}) => _serial(
    () => _withSessionLease(() async {
      final account = await _offline.activeAccount();
      if (account == null) return AppSnapshot(day: localDay(_now()));
      if (discardPending) {
        await _offline.purgeAccount(account.id);
        await _cleanupQueue();
      }
      try {
        if (await _tokens.read() != null) {
          await _request('logout', method: 'POST', body: const {});
        }
      } on QuestException {
        // Local logout is still safe; the remote token expires naturally.
      } finally {
        await _tokens.clear();
        await _offline.clearActiveAccount();
      }
      await _emitSummary();
      return AppSnapshot(day: localDay(_now()));
    }),
  );

  @override
  Future<AppSnapshot> claim() => _serial(() async {
    final account = await _requireAccount();
    final state = await _rollDay(account);
    if (state.activeQuestId != null) return state;
    if (state.canRequestNext) {
      throw const QuestException('这次已完成，可以从首页继续探索。');
    }
    final next = state.copyWith(activeQuestId: state.recommendedQuestId);
    await _offline.mutateWithCommand(
      accountId: account.id,
      snapshot: next,
      commandId: _uuid.v4(),
      type: 'claim',
      payload: {'questId': state.recommendedQuestId},
      expectedBranchId: account.activeBranchId,
    );
    _launchBackground(_afterLocalMutation);
    return next;
  });

  @override
  Future<AppSnapshot> replace() => _serial(() async {
    final account = await _requireSyncedAccountForOnlineMutation();
    final state = await _rollDay(account);
    if (state.canRequestNext) {
      throw const QuestException('这次已完成，可以从首页继续探索。');
    }
    if (!state.replacementAvailable) {
      throw const QuestException('今天已经更换过一次，也可以先放一放。');
    }
    return _withPinnedOnlineAccount(account, (token, guard) async {
      final cloud = _stateFrom(
        await _request(
          'replace',
          method: 'POST',
          body: const {},
          sessionToken: token,
          guard: guard,
        ),
      );
      await guard();
      return _offline.adoptCloud(account.id, cloud);
    });
  });

  @override
  Future<AppSnapshot> stop() => _serial(() async {
    final account = await _requireAccount();
    final state = await _rollDay(account);
    final next = state.copyWith(activeQuestId: null);
    await _offline.mutateWithCommand(
      accountId: account.id,
      snapshot: next,
      commandId: _uuid.v4(),
      type: 'stop',
      payload: const {},
      expectedBranchId: account.activeBranchId,
    );
    _launchBackground(_afterLocalMutation);
    return next;
  });

  @override
  Future<DraftEditorContext> openDraftEditor(String questId) => _serial(
    () async {
      questById(questId);
      final account = await _requireAccount();
      final state = await _rollDay(account);
      if (state.activeQuestId != questId) {
        throw const QuestException('这项活动的进度已变化，请从今日页重新打开。');
      }
      final current = await _offline.account(account.id);
      if (current == null || current.activeBranchId != account.activeBranchId) {
        throw const QuestException('探索进度已变化，请重新打开记录页。');
      }
      return DraftEditorContext(
        snapshot: current.snapshot,
        branchId: current.activeBranchId,
        questId: questId,
      );
    },
  );

  Future<Never> _moveStaleEditorToConflict({
    required OfflineAccount account,
    required String branchId,
    required String questId,
    required String text,
    required List<MediaAttachment> attachments,
  }) async {
    final snapshot = await _offline.saveStaleEditorDraft(
      accountId: account.id,
      branchId: branchId,
      questId: questId,
      text: text,
      attachments: attachments,
    );
    final draft = snapshot.conflictDrafts.lastWhere(
      (item) => item.branchId == branchId && item.questId == questId,
    );
    await _emitSummary('云端进度已变更，当前文字已保留为冲突草稿。');
    throw DraftEditorMovedException(
      snapshot: snapshot,
      conflictDraftId: draft.id,
    );
  }

  @override
  Future<AppSnapshot> saveDraft(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  }) => _serial(() async {
    validateText(text);
    final account = await _requireAccount();
    final state = await _rollDay(account);
    if ((expectedBranchId == null) != (expectedQuestId == null)) {
      throw const QuestException('草稿编辑上下文不完整，请重新打开记录页。');
    }
    final guardedMedia = attachments ?? state.draftAttachments;
    if (expectedBranchId != null &&
        (account.activeBranchId != expectedBranchId ||
            state.activeQuestId != expectedQuestId)) {
      return _moveStaleEditorToConflict(
        account: account,
        branchId: expectedBranchId,
        questId: expectedQuestId!,
        text: text,
        attachments: guardedMedia,
      );
    }
    if (state.activeQuestId == null) {
      throw const QuestException('请先开始活动，再写记录。');
    }
    final media = guardedMedia;
    validateMedia(media);
    await _offline.validateAttachments(account.id, media);
    final next = state.copyWith(draft: text, draftAttachments: media);
    try {
      await _offline.mutateWithCommand(
        accountId: account.id,
        snapshot: next,
        commandId: _uuid.v4(),
        type: 'draft',
        payload: {
          'questId': state.activeQuestId,
          'text': text,
          'mediaIds': media.map((item) => item.id).toList(),
        },
        coalesceDraft: true,
        expectedBranchId: expectedBranchId ?? account.activeBranchId,
      );
    } on OfflineBranchChangedException {
      if (expectedBranchId == null || expectedQuestId == null) rethrow;
      return _moveStaleEditorToConflict(
        account: account,
        branchId: expectedBranchId,
        questId: expectedQuestId,
        text: text,
        attachments: media,
      );
    }
    _launchBackground(_afterLocalMutation);
    return next;
  });

  @override
  Future<AppSnapshot> complete(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  }) => _serial(() async {
    validateText(text, required: true);
    final account = await _requireAccount();
    final state = await _rollDay(account);
    if ((expectedBranchId == null) != (expectedQuestId == null)) {
      throw const QuestException('草稿编辑上下文不完整，请重新打开记录页。');
    }
    final guardedMedia = attachments ?? state.draftAttachments;
    if (expectedBranchId != null &&
        (account.activeBranchId != expectedBranchId ||
            state.activeQuestId != expectedQuestId)) {
      return _moveStaleEditorToConflict(
        account: account,
        branchId: expectedBranchId,
        questId: expectedQuestId!,
        text: text,
        attachments: guardedMedia,
      );
    }
    if (state.activeQuestId == null) {
      throw const QuestException('请先开始活动，再写记录。');
    }
    final media = guardedMedia;
    validateMedia(media);
    await _offline.validateAttachments(account.id, media);
    final now = _now().toUtc();
    final entry = JournalEntry(
      id: _uuid.v4(),
      questId: state.activeQuestId!,
      questTitle: questById(state.activeQuestId!).title,
      text: text.trim(),
      createdAt: now,
      attachments: media,
      syncStatus: 'pending',
    );
    final next = state.copyWith(
      activeQuestId: null,
      entries: [entry, ...state.entries.where((item) => item.id != entry.id)],
      entryCount: state.entryCount + 1,
      draft: '',
      draftAttachments: const [],
      canRequestNext: true,
    );
    try {
      await _offline.mutateWithCommand(
        accountId: account.id,
        snapshot: next,
        commandId: _uuid.v4(),
        type: 'complete',
        payload: {
          'clientRecordId': entry.id,
          'questId': entry.questId,
          'text': entry.text,
          'mediaIds': media.map((item) => item.id).toList(),
          'createdAt': entry.createdAt.toIso8601String(),
        },
        pendingEntry: entry,
        expectedBranchId: expectedBranchId ?? account.activeBranchId,
      );
    } on OfflineBranchChangedException {
      if (expectedBranchId == null || expectedQuestId == null) rethrow;
      return _moveStaleEditorToConflict(
        account: account,
        branchId: expectedBranchId,
        questId: expectedQuestId,
        text: text,
        attachments: media,
      );
    }
    _launchBackground(_afterLocalMutation);
    return next;
  });

  @override
  Future<AppSnapshot> nextQuest() => _serial(() async {
    final account = await _requireAccount();
    final state = await _rollDay(account);
    if (!state.canRequestNext || state.activeQuestId != null) {
      throw const QuestException('完成当前活动后，可以继续探索。');
    }
    final nextId = recommendQuestId(
      preferences: state.profile!.preferences,
      history: state.recommendationHistory,
      currentId: state.recommendedQuestId,
    );
    final next = state.copyWith(
      recommendedQuestId: nextId,
      recommendationHistory: appendRecommendation(
        state.recommendationHistory,
        nextId,
      ),
      canRequestNext: false,
    );
    await _offline.mutateWithCommand(
      accountId: account.id,
      snapshot: next,
      commandId: _uuid.v4(),
      type: 'next',
      payload: const {},
      expectedBranchId: account.activeBranchId,
    );
    _launchBackground(_afterLocalMutation);
    return next;
  });

  @override
  Future<EntryPageResult> queryEntries({String query = '', String? cursor}) =>
      _serial(() async {
        if (query.runes.length > 100) {
          throw const QuestException('搜索内容最多 100 个字。');
        }
        final account = await _requireAccount();
        final local = await _offline.localEntries(account.id, query: query);
        final token = await _tokens.read();
        if (account.requiresLogin || token == null) {
          return EntryPageResult(
            entries: local.take(20).toList(),
            total: local.length,
          );
        }
        try {
          Future<void> guard() => _assertAccountToken(account.id, token);
          final response = await _request(
            'entries',
            query: {'q': query, 'limit': '20', 'cursor': ?cursor},
            sessionToken: token,
            guard: guard,
          );
          final remote = (response['entries'] as List? ?? [])
              .map((item) => JournalEntry.fromJson(jsonMap(item)))
              .toList();
          await guard();
          await _offline.cacheEntries(account.id, remote);
          final pending = cursor == null
              ? local.where((entry) => !entry.isSynced).toList()
              : <JournalEntry>[];
          final remoteIds = remote.map((entry) => entry.id).toSet();
          final uniquePending = pending
              .where((entry) => !remoteIds.contains(entry.id))
              .toList();
          final byId = <String, JournalEntry>{
            for (final entry in remote) entry.id: entry,
            for (final entry in pending) entry.id: entry,
          };
          final merged = byId.values.toList()
            ..sort((a, b) {
              final time = b.createdAt.compareTo(a.createdAt);
              return time != 0 ? time : b.id.compareTo(a.id);
            });
          return EntryPageResult(
            entries: merged,
            nextCursor: response['nextCursor'] as String?,
            total: (response['total'] as num).toInt() + uniquePending.length,
          );
        } on _ApiException catch (error) {
          if (error.statusCode != 401) rethrow;
          await _authenticationExpired(account.id);
          return EntryPageResult(
            entries: local.take(20).toList(),
            total: local.length,
          );
        } on QuestException {
          return EntryPageResult(
            entries: local.take(20).toList(),
            total: local.length,
          );
        }
      });

  @override
  Future<AppSnapshot> updateEntry(
    String id,
    String text,
    List<MediaAttachment> attachments,
    int expectedRevision,
  ) => _serial(() async {
    validateText(text, required: true);
    validateMedia(attachments);
    final account = await _requireSyncedAccountForOnlineMutation();
    await _offline.validateAttachments(account.id, attachments);
    return _withPinnedOnlineAccount(account, (token, guard) async {
      final mediaIds = await _readyMediaIds(
        account.id,
        attachments,
        sessionToken: token,
        guard: guard,
        meteredAuthorized: true,
      );
      final requestKey =
          'update:$id:$expectedRevision:${jsonEncode({'text': text.trim(), 'mediaIds': mediaIds})}';
      final requestId = await _offline.requestId(account.id, requestKey);
      final response = await _request(
        'update-entry',
        method: 'POST',
        body: {
          'id': id,
          'text': text.trim(),
          'mediaIds': mediaIds,
          'expectedRevision': expectedRevision,
          'requestId': requestId,
        },
        sessionToken: token,
        guard: guard,
      );
      final entry = JournalEntry.fromJson(jsonMap(response['entry']));
      await guard();
      await _offline.cacheEntries(account.id, [entry]);
      await _offline.clearRequestId(account.id, requestKey);
      await _cleanupReceivedMedia(account.id, attachments);
      return _offline.adoptCloud(account.id, _stateFrom(response));
    });
  });

  @override
  Future<AppSnapshot> deleteEntry(String id) => _serial(() async {
    final account = await _requireSyncedAccountForOnlineMutation();
    if (await _offline.isPendingEntry(account.id, id)) {
      throw const QuestException('这条记录仍在等待同步，请同步完成后再删除。');
    }
    return _withPinnedOnlineAccount(account, (token, guard) async {
      final requestKey = 'delete:$id';
      final requestId = await _offline.requestId(account.id, requestKey);
      final response = await _request(
        'delete-entry',
        method: 'POST',
        body: {'id': id, 'requestId': requestId},
        sessionToken: token,
        guard: guard,
      );
      await guard();
      await _offline.removeSavedEntry(account.id, id);
      await _offline.clearRequestId(account.id, requestKey);
      return _offline.adoptCloud(account.id, _stateFrom(response));
    });
  });

  @override
  Future<AppSnapshot> deleteAccount(String password) => _serial(
    () => _withSessionLease(() async {
      validatePassword(password);
      final account = await _requireAccount();
      final token = await _tokens.read();
      if (token == null) throw const QuestException('请重新登录后继续。');
      Future<void> guard() => _assertPinnedSession(
        accountId: account.id,
        token: token,
        leaseOwner: _sessionLeaseOwner,
      );
      final response = await _request(
        'delete-account',
        method: 'POST',
        body: {'password': password},
        sessionToken: token,
        guard: guard,
      );
      await guard();
      await _offline.purgeAccount(account.id);
      await _cleanupQueue();
      await _tokens.clear();
      return _stateFrom(response);
    }),
  );

  @override
  Future<MediaAttachment> stageMedia(
    String path,
    MediaKind kind, {
    int? durationMs,
  }) => _serial(() async {
    final account = await _requireAccount();
    NormalizedImage? normalized;
    try {
      var sourcePath = path;
      if (kind == MediaKind.image) {
        normalized = await _imageNormalizer(path);
        sourcePath = normalized.path;
      }
      final source = File(sourcePath);
      if (!await source.exists()) {
        throw const QuestException('选择的附件已经不存在。');
      }
      final byteSize = await source.length();
      if (byteSize <= 0) throw const QuestException('不能添加空文件。');
      final mimeType = kind == MediaKind.image
          ? 'image/jpeg'
          : _mimeType(sourcePath, kind);
      final candidate = MediaAttachment(
        id: _uuid.v4(),
        kind: kind,
        mimeType: mimeType,
        byteSize: byteSize,
        durationMs: durationMs,
        status: 'reserved',
      );
      validateMedia([candidate]);
      final staged = await _offline.stageMedia(
        accountId: account.id,
        sourcePath: sourcePath,
        kind: kind,
        mimeType: mimeType,
        byteSize: byteSize,
        durationMs: durationMs,
      );
      await _emitSummary();
      return staged.attachment;
    } finally {
      await normalized?.dispose();
    }
  });

  @override
  Future<void> discardStagedMedia(List<String> ids) => _serial(() async {
    if (ids.isEmpty) return;
    final account = await _requireAccount();
    final result = await _offline.discardStagedMedia(account.id, ids);
    await _cleanupQueue();
    final token = await _tokens.read();
    if (token != null && result.serverIds.isNotEmpty) {
      _launchBackground(
        () => _cancelUnboundUploads(
          accountId: account.id,
          token: token,
          serverIds: result.serverIds,
        ),
      );
    }
    await _emitSummary();
  });

  @override
  Future<void> removePendingAttachments(String entryId) => _serial(() async {
    final account = await _requireAccount();
    await _withPinnedOnlineAccount(account, (token, guard) async {
      final affected = await _offline.pendingAttachmentRepairCommands(
        account.id,
        entryId,
      );
      if (affected.isEmpty) {
        throw const QuestException('这条记录没有可移除的待同步附件。');
      }
      final missing = <String>{};
      final persisted = affected
          .where((command) => command.wireJson != null)
          .toList();
      final branchIds = persisted.map((command) => command.branchId).toSet();
      for (final branchId in branchIds) {
        final branch = await _offline.branch(branchId);
        final commands = persisted
            .where((command) => command.branchId == branchId)
            .toList();
        for (var offset = 0; offset < commands.length; offset += 10) {
          final chunk = commands.skip(offset).take(10).toList();
          final batch = OfflineSyncBatch(
            batchId: 'repair:${_uuid.v4()}',
            branch: branch,
            commands: chunk,
            meteredAuthorized: true,
          );
          final wireBody = {
            'branchId': branch.id,
            'baseRevision': branch.baseRevision,
            'commands': chunk.map((item) => item.wireJson!).toList(),
          };
          if (utf8.encode(jsonEncode(wireBody)).length > 16 * 1024) {
            throw const QuestException('待修复操作超过同步限制，无法安全更改。');
          }
          final response = await _request(
            'sync-status',
            method: 'POST',
            body: wireBody,
            sessionToken: token,
            guard: guard,
          );
          final parsed = _parseSyncResponse(
            response,
            batch,
            statusResponse: true,
          );
          await _applyParsedSync(
            accountId: account.id,
            batch: batch,
            parsed: parsed,
            guard: guard,
            leaseOwner: _sessionLeaseOwner,
          );
          missing.addAll(parsed.missingCommandIds);
        }
      }
      await guard();
      await _offline.stripPendingAttachments(
        account.id,
        entryId,
        missingCommandIds: missing,
        leaseOwner: _sessionLeaseOwner,
      );
      await _cleanupQueue();
      await _emitSummary('已移除失败附件，将只同步文字。');
    });
    await syncNow();
  });

  Future<void> _cancelUnboundUploads({
    required String accountId,
    required String token,
    required Iterable<String> serverIds,
  }) async {
    Future<void> guard() async {
      if (await _offline.activeAccountId() != accountId ||
          await _tokens.read() != token) {
        throw const _SyncAbortedException('账号已变更。');
      }
    }

    for (final id in serverIds) {
      try {
        await _request(
          'uploads/${Uri.encodeComponent(id)}',
          method: 'DELETE',
          sessionToken: token,
          guard: guard,
        );
      } on QuestException {
        // The server expires abandoned unbound uploads independently.
        return;
      }
    }
  }

  String _mimeType(String path, MediaKind kind) {
    final extension = p.extension(path).toLowerCase();
    const known = {
      '.jpg': 'image/jpeg',
      '.jpeg': 'image/jpeg',
      '.png': 'image/png',
      '.webp': 'image/webp',
      '.mp4': 'video/mp4',
      '.mov': 'video/quicktime',
      '.m4a': 'audio/mp4',
      '.aac': 'audio/aac',
      '.mp3': 'audio/mpeg',
      '.wav': 'audio/wav',
    };
    return known[extension] ??
        switch (kind) {
          MediaKind.image => 'image/jpeg',
          MediaKind.video => 'video/mp4',
          MediaKind.audio => 'audio/mp4',
        };
  }

  Future<void> _authenticationExpired(String accountId) async {
    await _tokens.clear();
    await _offline.markRequiresLogin(accountId, true);
    await _emitSummary('登录已失效，本机待同步内容仍已保留。');
  }

  Future<void> _assertPinnedSession({
    required String accountId,
    required String token,
    required String leaseOwner,
    bool leaseHealthy = true,
  }) async {
    if (!leaseHealthy || !await _offline.ownsLease(leaseOwner)) {
      throw const _SyncAbortedException('同步任务已由其他进程接管，本机内容已保留。');
    }
    if (await _offline.activeAccountId() != accountId ||
        await _tokens.read() != token) {
      throw const _SyncAbortedException('账号已变更，已停止原账号同步。');
    }
  }

  Future<void> _assertAccountToken(String accountId, String token) async {
    if (await _offline.activeAccountId() != accountId ||
        await _tokens.read() != token) {
      throw const _SyncAbortedException('账号已变更，已停止原账号请求。');
    }
  }

  Future<void> _requireNetworkForBatch(bool meteredAuthorized) async {
    if (!meteredAuthorized && !await _canAutoSync()) {
      throw const QuestException('同步已暂停，内容都还在。');
    }
  }

  Future<List<String>> _readyMediaIds(
    String accountId,
    List<MediaAttachment> attachments, {
    required String sessionToken,
    required Future<void> Function() guard,
    required bool meteredAuthorized,
  }) async {
    final result = <String>[];
    for (final attachment in attachments) {
      final local = await _offline.mediaById(accountId, attachment.id);
      if (local == null) {
        result.add(attachment.id);
      } else {
        result.add(
          (await _uploadMedia(
            local,
            sessionToken: sessionToken,
            guard: guard,
            meteredAuthorized: meteredAuthorized,
          )).id,
        );
      }
    }
    return result;
  }

  Future<MediaAttachment> _uploadMedia(
    OfflineMedia media, {
    required String sessionToken,
    required Future<void> Function() guard,
    required bool meteredAuthorized,
  }) async {
    await _requireNetworkForBatch(meteredAuthorized);
    await guard();
    var current = media;
    var serverId = current.serverId;
    if (serverId == null) {
      final response = await _request(
        'uploads',
        method: 'POST',
        body: {
          'kind': current.attachment.kind.name,
          'byteSize': current.sourceBytes,
          'clientUploadId': current.clientId,
        },
        sessionToken: sessionToken,
        guard: guard,
      );
      final reserved = MediaAttachment.fromJson(jsonMap(response['media']));
      serverId = reserved.id;
      await _offline.updateMedia(
        clientId: current.clientId,
        serverId: serverId,
        state: reserved.status,
        attachment: reserved.copyWith(localPath: current.localPath),
      );
      current = (await _offline.mediaById(
        current.accountId,
        current.clientId,
      ))!;
    }
    var remote = current.attachment.copyWith(id: serverId);
    if (remote.status != 'ready' && remote.status != 'processing') {
      await _requireNetworkForBatch(meteredAuthorized);
      await guard();
      final path = current.localPath;
      if (path == null || !await File(path).exists()) {
        const message = '附件源文件缺失，无法继续同步。';
        await _offline.updateMedia(
          clientId: current.clientId,
          state: 'failed',
          error: message,
        );
        await _emitSummary(message);
        throw const QuestException('附件源文件缺失，无法继续同步。');
      }
      await _offline.updateMedia(
        clientId: current.clientId,
        state: 'uploading',
        attachment: remote.copyWith(status: 'uploading', localPath: path),
      );
      await _emitSummary();
      try {
        final uploaded = await _putFile(
          'uploads/$serverId/content',
          File(path),
          current.attachment.mimeType,
          sessionToken: sessionToken,
          guard: guard,
        );
        final decoded = jsonMap(jsonDecode(utf8.decode(uploaded.bodyBytes)));
        remote = MediaAttachment.fromJson(jsonMap(decoded['media']));
      } catch (error) {
        await _offline.updateMedia(
          clientId: current.clientId,
          state: 'failed',
          error: error.toString(),
        );
        await _emitSummary();
        rethrow;
      }
    }
    if (remote.status == 'processing') {
      await _offline.updateMedia(
        clientId: current.clientId,
        serverId: serverId,
        state: 'processing',
        attachment: remote.copyWith(localPath: current.localPath),
      );
      await _emitSummary();
    }
    for (
      var attempt = 0;
      remote.status == 'processing' && attempt < 120;
      attempt++
    ) {
      if (_disposed) throw const QuestException('同步已停止，本机文件仍已保留。');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final response = await _request(
        'uploads/$serverId',
        sessionToken: sessionToken,
        guard: guard,
      );
      remote = MediaAttachment.fromJson(jsonMap(response['media']));
      if (remote.status == 'failed') {
        final message = response['error'] as String? ?? '附件处理失败，请重新选择。';
        await _offline.updateMedia(
          clientId: current.clientId,
          state: 'failed',
          attachment: remote.copyWith(localPath: current.localPath),
          error: message,
        );
        await _emitSummary(message);
        throw QuestException(message);
      }
    }
    if (remote.status != 'ready') {
      throw const QuestException('附件仍在处理中，请稍后继续同步。');
    }
    final ready = remote.copyWith(localPath: current.localPath);
    await _offline.updateMedia(
      clientId: current.clientId,
      serverId: serverId,
      state: 'ready',
      attachment: ready,
    );
    return ready.copyWith(localPath: null);
  }

  Future<Map<String, dynamic>> _wireCommand(
    OfflineCommand command, {
    required String sessionToken,
    required Future<void> Function() guard,
    required bool meteredAuthorized,
  }) async {
    final persisted = command.wireJson;
    if (persisted != null) return Map<String, dynamic>.from(persisted);
    final payload = Map<String, dynamic>.from(command.payload);
    final ids = List<String>.from(payload['mediaIds'] as List? ?? []);
    if (ids.isNotEmpty) {
      final converted = <String>[];
      for (final id in ids) {
        final local = await _offline.mediaById(command.accountId, id);
        converted.add(
          local == null
              ? id
              : (await _uploadMedia(
                  local,
                  sessionToken: sessionToken,
                  guard: guard,
                  meteredAuthorized: meteredAuthorized,
                )).id,
        );
      }
      payload['mediaIds'] = converted;
    }
    return {
      'commandId': command.commandId,
      'type': command.type,
      'payload': payload,
    };
  }

  _ParsedSyncResponse _parseSyncResponse(
    Map<String, dynamic> response,
    OfflineSyncBatch batch, {
    required bool statusResponse,
  }) {
    final known = batch.commands.map((item) => item.commandId).toSet();
    final rawReceipts = response['receipts'];
    final rawEntries = response['entries'];
    final mode = response['branchMode'];
    if (rawReceipts is! List ||
        rawEntries is! List ||
        (mode != 'active' && mode != 'records_only')) {
      throw const QuestException('同步回执格式无效，本机内容已保留。');
    }
    final receipts = rawReceipts.map(jsonMap).toList(growable: false);
    final receiptIds = <String>{};
    for (final receipt in receipts) {
      final id = receipt['commandId'];
      if (id is! String || !known.contains(id) || !receiptIds.add(id)) {
        throw const QuestException('服务返回了不属于本批的回执，已拒绝应用。');
      }
    }
    final missing = statusResponse
        ? (response['missingCommandIds'] as List? ?? const []).map((item) {
            if (item is! String) {
              throw const QuestException('同步状态响应无效。');
            }
            return item;
          }).toSet()
        : <String>{};
    if (!known.containsAll(missing) ||
        receiptIds.any(missing.contains) ||
        (statusResponse &&
            receiptIds.length + missing.length != known.length) ||
        (!statusResponse && receiptIds.length != known.length)) {
      throw const QuestException('服务回执与本批操作不匹配，本机内容已保留。');
    }
    final entries = rawEntries
        .map((item) => JournalEntry.fromJson(jsonMap(item)))
        .toList(growable: false);
    final receiptEntryIds = receipts
        .map((item) => item['entryId'])
        .whereType<String>()
        .toSet();
    if (entries.map((item) => item.id).toSet().length != entries.length ||
        entries.any((item) => !receiptEntryIds.contains(item.id))) {
      throw const QuestException('服务返回了不属于本批的记录，已拒绝应用。');
    }
    return _ParsedSyncResponse(
      state: _stateFrom(response),
      branchMode: mode as String,
      receipts: receipts,
      entries: entries,
      missingCommandIds: missing,
    );
  }

  Future<void> _applyParsedSync({
    required String accountId,
    required OfflineSyncBatch batch,
    required _ParsedSyncResponse parsed,
    required Future<void> Function() guard,
    String leaseOwner = '',
  }) async {
    await guard();
    await _offline.applySyncResult(
      accountId: accountId,
      batch: batch,
      cloudState: parsed.state,
      branchMode: parsed.branchMode,
      receipts: parsed.receipts,
      savedEntries: parsed.entries,
      leaseOwner: leaseOwner.isEmpty ? _syncLeaseOwner : leaseOwner,
    );
    await _cleanupQueue();
  }

  Future<Set<String>> _recoverBatchStatus({
    required String accountId,
    required OfflineSyncBatch batch,
    required Map<String, dynamic> wireBody,
    required String sessionToken,
    required Future<void> Function() guard,
  }) async {
    final response = await _request(
      'sync-status',
      method: 'POST',
      body: wireBody,
      sessionToken: sessionToken,
      guard: guard,
    );
    final parsed = _parseSyncResponse(response, batch, statusResponse: true);
    await _applyParsedSync(
      accountId: accountId,
      batch: batch,
      parsed: parsed,
      guard: guard,
    );
    final missing = parsed.missingCommandIds;
    if (missing.isNotEmpty) {
      await _offline.clearMissingWireCommands(accountId, missing);
      final remaining = await _offline.commandsForBranch(batch.branch.id);
      for (final command in remaining.where(
        (item) => missing.contains(item.commandId),
      )) {
        for (final id in List<String>.from(
          command.payload['mediaIds'] as List? ?? const [],
        )) {
          final media = await _offline.mediaById(accountId, id);
          if (media?.serverId != null) {
            await _offline.resetMediaReservation(id);
          }
        }
      }
    }
    await _emitSummary(
      batch.branch.recordsOnly || parsed.branchMode == 'records_only'
          ? '云端进度已保留；本机完成的记录已单独同步。'
          : null,
    );
    return missing;
  }

  Future<void> _syncInternal() async {
    var acquired = false;
    OfflineSyncBatch? prefetchedBatch;
    Timer? heartbeat;
    Future<void>? renewalFuture;
    var leaseHealthy = true;
    try {
      await _ensureStarted();
      acquired = await _offline.acquireLease(
        _syncLeaseOwner,
        ttl: const Duration(seconds: 30),
      );
      if (!acquired) return;
      void renew() {
        if (renewalFuture != null || !leaseHealthy) return;
        late final Future<void> current;
        current = _offline
            .renewLease(_syncLeaseOwner, ttl: const Duration(seconds: 30))
            .then<void>(
              (owned) {
                if (!owned) leaseHealthy = false;
              },
              onError: (Object _, StackTrace _) {
                leaseHealthy = false;
              },
            )
            .whenComplete(() {
              if (identical(renewalFuture, current)) renewalFuture = null;
            });
        renewalFuture = current;
      }

      heartbeat = Timer.periodic(const Duration(seconds: 10), (_) => renew());

      var account = await _offline.activeAccount();
      if (account == null) return;
      final token = await _tokens.read();
      if (token == null) {
        await _offline.markRequiresLogin(account.id, true);
        await _emitSummary('请重新登录以继续同步。');
        return;
      }
      Future<void> guard() => _assertPinnedSession(
        accountId: account.id,
        token: token,
        leaseOwner: _syncLeaseOwner,
        leaseHealthy: leaseHealthy,
      );
      await guard();
      final automaticSyncAllowed = await _canAutoSync();
      if (!automaticSyncAllowed) {
        prefetchedBatch = await _offline.captureBatch(
          accountId: account.id,
          wifi: false,
          allowMetered: false,
        );
        if (prefetchedBatch == null) return;
        await _requireNetworkForBatch(prefetchedBatch.meteredAuthorized);
      }
      late final AppSnapshot initialCloud;
      try {
        initialCloud = _stateFrom(
          await _request('state', sessionToken: token, guard: guard),
        );
      } on _ApiException catch (error) {
        if (error.statusCode != 401) rethrow;
        await _authenticationExpired(account.id);
        return;
      }
      if (initialCloud.profile?.id != account.snapshot.profile?.id) {
        await _tokens.clear();
        await _offline.markRequiresLogin(account.id, true);
        await _emitSummary('登录账号与本机待同步内容不匹配，请重新登录。');
        return;
      }
      await guard();
      if (await _offline.pendingCommandCount(account.id) == 0) {
        await _offline.adoptCloud(account.id, initialCloud);
        await _emitSummary();
        return;
      }
      var captureLimit = 10;
      final recoveryAttempts = <String, int>{};
      while (!_disposed) {
        await guard();
        final batch =
            prefetchedBatch ??
            await _offline.captureBatch(
              accountId: account.id,
              // The persistent setting must not become a permanent per-command
              // grant: disabling it must stop later automatic mobile uploads.
              wifi: await _canAutoSync(),
              allowMetered: false,
              limit: captureLimit,
            );
        prefetchedBatch = null;
        if (batch == null) break;
        try {
          await _requireNetworkForBatch(batch.meteredAuthorized);
          await guard();
          final hadPersistedWire = batch.commands.any(
            (command) => command.wireJson != null,
          );
          final commands = <Map<String, dynamic>>[];
          for (final command in batch.commands) {
            commands.add(
              await _wireCommand(
                command,
                sessionToken: token,
                guard: guard,
                meteredAuthorized: batch.meteredAuthorized,
              ),
            );
          }
          // Consent may change while a file upload is already in flight.
          // Keep its result, but do not begin the next request after revocation.
          await _requireNetworkForBatch(batch.meteredAuthorized);
          final wireBody = {
            'branchId': batch.branch.id,
            'baseRevision': batch.branch.baseRevision,
            'commands': commands,
          };
          if (utf8.encode(jsonEncode(wireBody)).length > 16 * 1024) {
            if (batch.commands.length == 1) {
              throw const QuestException('一条待同步操作超过 16 KiB，无法安全发送。');
            }
            captureLimit = batch.commands.length - 1;
            await _offline.releaseBatch(batch.batchId);
            continue;
          }
          for (var index = 0; index < batch.commands.length; index++) {
            final command = batch.commands[index];
            if (command.wireJson == null) {
              await _offline.persistWireCommand(
                account.id,
                command.commandId,
                commands[index],
                leaseOwner: _syncLeaseOwner,
              );
            }
          }
          if (hadPersistedWire) {
            final missing = await _recoverBatchStatus(
              accountId: account.id,
              batch: batch,
              wireBody: wireBody,
              sessionToken: token,
              guard: guard,
            );
            for (final id in missing) {
              recoveryAttempts[id] = (recoveryAttempts[id] ?? 0) + 1;
            }
          } else {
            try {
              final response = await _request(
                'sync',
                method: 'POST',
                body: wireBody,
                sessionToken: token,
                guard: guard,
                uncertainWrite: true,
                timeout: const Duration(minutes: 2),
              );
              final parsed = _parseSyncResponse(
                response,
                batch,
                statusResponse: false,
              );
              await _applyParsedSync(
                accountId: account.id,
                batch: batch,
                parsed: parsed,
                guard: guard,
              );
              await _emitSummary(
                batch.branch.recordsOnly || parsed.branchMode == 'records_only'
                    ? '云端进度已保留；本机完成的记录已单独同步。'
                    : null,
              );
            } on _UncertainNetworkException {
              final missing = await _recoverBatchStatus(
                accountId: account.id,
                batch: batch,
                wireBody: wireBody,
                sessionToken: token,
                guard: guard,
              );
              for (final id in missing) {
                recoveryAttempts[id] = (recoveryAttempts[id] ?? 0) + 1;
              }
            } on _ApiException catch (error) {
              if (error.statusCode == 401) rethrow;
              final missing = await _recoverBatchStatus(
                accountId: account.id,
                batch: batch,
                wireBody: wireBody,
                sessionToken: token,
                guard: guard,
              );
              if (missing.isEmpty) continue;
              if (missing.any((id) => (recoveryAttempts[id] ?? 0) > 0)) {
                rethrow;
              }
              for (final id in missing) {
                recoveryAttempts[id] = 1;
              }
            }
          }
          captureLimit = 10;
        } on _ApiException catch (error) {
          final permanent = _isPermanentSyncRejection(error.statusCode);
          if (permanent) {
            await _offline.markBatchError(
              account.id,
              batch.batchId,
              error.message,
            );
          }
          await _offline.releaseBatch(batch.batchId);
          if (error.statusCode == 401) {
            await _authenticationExpired(account.id);
            return;
          }
          await _emitSummary(permanent ? error.message : null);
          rethrow;
        } catch (_) {
          await _offline.releaseBatch(batch.batchId);
          rethrow;
        }
      }
      await _emitSummary();
    } finally {
      final prefetched = prefetchedBatch;
      if (prefetched != null) {
        await _offline.releaseBatch(prefetched.batchId);
      }
      heartbeat?.cancel();
      final renewal = renewalFuture;
      if (renewal != null) await renewal;
      if (acquired) await _offline.releaseLease(_syncLeaseOwner);
    }
  }

  @override
  Future<bool> getMobileDataSyncEnabled() =>
      _syncSettings.getMobileDataSyncEnabled();

  @override
  Future<void> setMobileDataSyncEnabled(bool enabled) async {
    if (_disposed) throw const QuestException('设置没保存，请重新打开后再试。');
    await _syncSettings.setMobileDataSyncEnabled(enabled);
    await refreshSyncScheduling();
    if (enabled && _autoSync) _launchBackground(_bestEffortSync);
  }

  @override
  Future<void> syncNow({bool allowMetered = false}) async {
    if (_disposed) throw const QuestException('仓储已关闭，请重新打开应用。');
    await _ensureStarted();
    if (_disposed) throw const QuestException('仓储已关闭，请重新打开应用。');
    if (allowMetered) {
      final account = await _offline.activeAccount();
      if (account != null) {
        await _offline.authorizeMeteredSnapshot(account.id);
      }
      if (_disposed) throw const QuestException('仓储已关闭，请重新打开应用。');
    }
    final running = _syncFuture;
    if (running != null) return running;
    late final Future<void> started;
    started = _syncInternal().whenComplete(() {
      if (identical(_syncFuture, started)) _syncFuture = null;
    });
    _syncFuture = started;
    return started;
  }

  @override
  Future<SyncSummary> getSyncSummary() => _serial(() async {
    await _ensureStarted();
    final account = await _offline.activeAccount();
    return account == null ? const SyncSummary() : _offline.summary(account.id);
  });
  @override
  Future<Map<String, String>> mediaHeaders() async {
    await _ensureProtocol();
    final token = await _tokens.read();
    return {
      'X-Sidequest-Protocol': '2',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  @override
  String mediaUrl(MediaAttachment media, {bool thumbnail = false}) =>
      '$_base/api/media/${Uri.encodeComponent(media.id)}/${thumbnail ? 'thumbnail' : 'content'}';

  @override
  Future<AppSnapshot> resumeConflictDraft(String id) => _serial(() async {
    final account = await _requireAccount();
    final selected = account.snapshot.conflictDrafts
        .where((draft) => draft.id == id)
        .firstOrNull;
    if (selected == null) {
      throw const QuestException('这份冲突草稿已经不存在。');
    }
    // This is an editor projection only; it is deliberately not persisted as
    // canonical progress.
    return account.snapshot.copyWith(
      activeQuestId: selected.questId,
      draft: selected.text,
      draftAttachments: selected.attachments,
    );
  });

  @override
  Future<AppSnapshot> discardConflictDraft(String id) => _serial(() async {
    final account = await _requireAccount();
    final drafts = account.snapshot.conflictDrafts
        .where((draft) => draft.id != id)
        .toList();
    if (drafts.length == account.snapshot.conflictDrafts.length) {
      throw const QuestException('这份冲突草稿已经不存在。');
    }
    final next = account.snapshot.copyWith(conflictDrafts: drafts);
    await _offline.saveConflictSnapshot(
      accountId: account.id,
      snapshot: next,
      conflictId: id,
      mediaIds: const [],
    );
    return next;
  });

  @override
  Future<AppSnapshot> saveConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  }) => _serial(() async {
    validateText(text);
    final account = await _requireAccount();
    final drafts = [...account.snapshot.conflictDrafts];
    final index = drafts.indexWhere((draft) => draft.id == id);
    if (index < 0) throw const QuestException('这份冲突草稿已经不存在。');
    final media = attachments ?? drafts[index].attachments;
    validateMedia(media);
    await _offline.validateAttachments(account.id, media);
    final current = drafts[index];
    drafts[index] = ConflictDraft(
      id: current.id,
      questId: current.questId,
      text: text,
      createdAt: current.createdAt,
      attachments: media,
      branchId: current.branchId,
      baseRevision: current.baseRevision,
    );
    final next = account.snapshot.copyWith(conflictDrafts: drafts);
    await _offline.saveConflictSnapshot(
      accountId: account.id,
      snapshot: next,
      conflictId: id,
      mediaIds: media.map((item) => item.id),
    );
    return next;
  });

  @override
  Future<AppSnapshot> completeConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  }) => _serial(() async {
    validateText(text, required: true);
    final account = await _requireAccount();
    final drafts = [...account.snapshot.conflictDrafts];
    final index = drafts.indexWhere((draft) => draft.id == id);
    if (index < 0) throw const QuestException('这份冲突草稿已经不存在。');
    final draft = drafts[index];
    final media = attachments ?? draft.attachments;
    validateMedia(media);
    await _offline.validateAttachments(account.id, media);
    final entry = JournalEntry(
      id: _uuid.v4(),
      questId: draft.questId,
      questTitle: questById(draft.questId).title,
      text: text.trim(),
      createdAt: _now().toUtc(),
      attachments: media,
      syncStatus: 'pending',
    );
    drafts.removeAt(index);
    final next = account.snapshot.copyWith(
      conflictDrafts: drafts,
      entries: [entry, ...account.snapshot.entries],
      entryCount: account.snapshot.entryCount + 1,
    );
    await _offline.completeConflictDraft(
      accountId: account.id,
      branchId: draft.branchId,
      baseRevision: draft.baseRevision,
      snapshot: next,
      commandId: _uuid.v4(),
      entry: entry,
      mediaIds: media.map((item) => item.id).toList(),
    );
    _launchBackground(_afterLocalMutation);
    return next;
  });

  Future<void> _cleanupReceivedMedia(
    String accountId,
    List<MediaAttachment> attachments,
  ) async {
    await _offline.queueMediaCleanup(
      accountId,
      attachments.map((item) => item.id),
    );
    await _cleanupQueue();
  }

  Future<void> _cleanupQueue() async {
    for (final path in await _offline.pendingCleanupPaths()) {
      try {
        if (!await _offline.isManagedMediaPath(path)) continue;
        final file = File(path);
        if (await file.exists()) await file.delete();
        await _offline.markPathCleaned(path);
      } on FileSystemException {
        // Persistent cleanup retries after a later successful sync.
      }
    }
  }

  @override
  Future<void> dispose() => _disposeFuture ??= _dispose();

  Future<void> _dispose() async {
    _disposed = true;
    await _connectivitySubscription?.cancel();
    if (_ownsClient) _client.close();
    try {
      await _syncFuture;
    } on Object {
      // Closing the HTTP client intentionally interrupts an in-flight sync.
    }
    await _tail;
    await _drainBackgroundTasks();
    await _offline.releaseLease(_syncLeaseOwner);
    await _offline.releaseLease(_sessionLeaseOwner);
    await _offline.close();
    await _syncController.close();
  }
}
