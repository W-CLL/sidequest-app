import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'domain.dart';

abstract class QuestRepository {
  bool get isRemote;
  Future<AppSnapshot> load();
  Future<AppSnapshot> savePreferences(String role, List<String> preferences);
  Future<AppSnapshot> register(String nickname, String password);
  Future<AppSnapshot> login(String nickname, String password);
  Future<AppSnapshot> logout();
  Future<AppSnapshot> claim();
  Future<AppSnapshot> replace();
  Future<AppSnapshot> stop();
  Future<AppSnapshot> saveDraft(String text);
  Future<AppSnapshot> complete(String text);
  Future<AppSnapshot> nextQuest();
  Future<AppSnapshot> deleteEntry(String id);
  Future<AppSnapshot> deleteAccount(String password);
  Future<String> exportData();
}

QuestRepository createRepository({String apiBaseUrl = ''}) =>
    apiBaseUrl.trim().isEmpty
    ? LocalQuestRepository()
    : RemoteQuestRepository(apiBaseUrl: apiBaseUrl);

void _validatePreferences(String role, List<String> chosen) {
  if (!roles.any((r) => r.id == role)) throw const QuestException('请选择一个身份。');
  if (chosen.length > 3 ||
      chosen.toSet().length != chosen.length ||
      chosen.any((p) => !preferences.contains(p))) {
    throw const QuestException('探索偏好最多选择三项。');
  }
}

void _validateText(String text, {bool required = false}) {
  if (required && text.trim().isEmpty) {
    throw const QuestException('请先写一点记录，再完成并保存。');
  }
  if (text.runes.length > 300) {
    throw const QuestException('记录最多 300 个字，请稍微精简一下。');
  }
}

String _nickname(String nickname) {
  final result = nickname.trim();
  if (result.runes.length < 2 ||
      result.runes.length > 20 ||
      !RegExp(r'^[\p{L}\p{N}_-]+$', unicode: true).hasMatch(result)) {
    throw const QuestException('昵称需为 2–20 个字，仅支持文字、数字、下划线和短横线。');
  }
  return result;
}

void _validatePassword(String password) {
  if (password.runes.length < 8 || password.runes.length > 128) {
    throw const QuestException('密码需为 8–128 个字符。');
  }
}

String _randomId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Map<String, dynamic> _map(Object? value) =>
    Map<String, dynamic>.from(value as Map);

/// Local alpha: accounts and private text remain on this installation. This is
/// not a server-wide identity system or an encrypted journal vault.
class LocalQuestRepository implements QuestRepository {
  LocalQuestRepository({
    SharedPreferences? preferences,
    DateTime Function()? now,
    this.passwordIterations = 210000,
  }) : _prefs = preferences,
       _now = now ?? DateTime.now;
  static const storageKey = 'sidequest.local.v1';
  SharedPreferences? _prefs;
  final DateTime Function() _now;
  final int passwordIterations;
  Map<String, dynamic>? _store;
  Future<void> _tail = Future.value();
  @override
  bool get isRemote => false;
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _init() async {
    if (_store != null) return;
    _prefs ??= await SharedPreferences.getInstance();
    final raw = _prefs!.getString(storageKey);
    if (raw == null) {
      _store = {
        'accounts': <String, dynamic>{},
        'current': null,
        'pendingRole': null,
        'pendingPreferences': <String>[],
      };
    } else {
      try {
        _store = _map(jsonDecode(raw));
        _map(_store!['accounts']);
      } catch (_) {
        throw const QuestException('本地数据暂时无法读取，请不要清除应用数据，先保留备份。');
      }
    }
  }

  Future<void> _write(Map<String, dynamic> data) async {
    if (!await _prefs!.setString(storageKey, jsonEncode(data))) {
      throw const QuestException('保存失败，请保留当前内容并重试。');
    }
    _store = data;
  }

  Map<String, dynamic> _clone() => _map(jsonDecode(jsonEncode(_store)));
  AppSnapshot _snapshot() {
    final current = _store!['current'];
    if (current == null) return AppSnapshot(day: localDay(_now()));
    final account = _map(_map(_store!['accounts'])[current]);
    return AppSnapshot.fromJson(_map(account['state']));
  }

  Future<AppSnapshot> _save(AppSnapshot state) async {
    final copy = _clone();
    final id = copy['current'];
    if (id == null) throw const QuestException('请先登录，再开始探索。');
    final accounts = _map(copy['accounts']);
    final account = _map(accounts[id]);
    account['state'] = state.toJson();
    accounts[id as String] = account;
    copy['accounts'] = accounts;
    await _write(copy);
    return state;
  }

  Future<AppSnapshot> _current({bool authenticated = false}) async {
    await _init();
    var state = _snapshot();
    if (authenticated && state.profile == null) {
      throw const QuestException('请先登录，再开始探索。');
    }
    final today = localDay(_now());
    if (state.day != today) {
      state = state.copyWith(
        day: today,
        recommendedQuestId: state.activeQuestId == null && state.canRequestNext
            ? nextQuestId(state.recommendedQuestId)
            : state.recommendedQuestId,
        canRequestNext: state.activeQuestId == null
            ? false
            : state.canRequestNext,
      );
      if (state.profile != null) await _save(state);
    }
    return state;
  }

  Future<String> _hash(String password, String salt, int iterations) async {
    final key =
        await Pbkdf2(
          macAlgorithm: Hmac.sha256(),
          iterations: iterations,
          bits: 256,
        ).deriveKey(
          secretKey: SecretKey(utf8.encode(password)),
          nonce: base64Decode(salt),
        );
    return base64Encode(await key.extractBytes());
  }

  Future<bool> _matches(Map<String, dynamic> account, String password) async {
    final expected = base64Decode(account['hash'] as String);
    final actual = base64Decode(
      await _hash(
        password,
        account['salt'] as String,
        account['iterations'] as int,
      ),
    );
    var different = expected.length ^ actual.length;
    for (var i = 0; i < expected.length && i < actual.length; i++) {
      different |= expected[i] ^ actual[i];
    }
    return different == 0;
  }

  @override
  Future<AppSnapshot> load() => _serial(() => _current());
  @override
  Future<AppSnapshot> savePreferences(String role, List<String> preferences) =>
      _serial(() async {
        _validatePreferences(role, preferences);
        final state = await _current();
        if (state.profile == null) {
          final copy = _clone();
          copy['pendingRole'] = role;
          copy['pendingPreferences'] = List<String>.from(preferences);
          await _write(copy);
          return state;
        }
        final user = state.profile!;
        return _save(
          state.copyWith(
            profile: UserProfile(
              id: user.id,
              nickname: user.nickname,
              role: role,
              preferences: preferences,
            ),
          ),
        );
      });
  @override
  Future<AppSnapshot> register(String nickname, String password) => _serial(
    () async {
      final display = _nickname(nickname);
      _validatePassword(password);
      await _init();
      final role = _store!['pendingRole'] as String?;
      final chosen = List<String>.from(
        _store!['pendingPreferences'] as List? ?? [],
      );
      if (role == null) throw const QuestException('请先选择你的身份，再创建账号。');
      _validatePreferences(role, chosen);
      final copy = _clone();
      final accounts = _map(copy['accounts']);
      if (accounts.values.any(
        (a) => _map(a)['nicknameKey'] == display.toLowerCase(),
      )) {
        throw const QuestException('这个昵称已被使用，请换一个。');
      }
      final id = _randomId();
      final random = Random.secure();
      final salt = base64Encode(List.generate(16, (_) => random.nextInt(256)));
      final state = AppSnapshot(
        profile: UserProfile(
          id: id,
          nickname: display,
          role: role,
          preferences: chosen,
        ),
        day: localDay(_now()),
      );
      accounts[id] = {
        'nicknameKey': display.toLowerCase(),
        'salt': salt,
        'iterations': passwordIterations,
        'hash': await _hash(password, salt, passwordIterations),
        'state': state.toJson(),
      };
      copy['accounts'] = accounts;
      copy['current'] = id;
      await _write(copy);
      return state;
    },
  );
  @override
  Future<AppSnapshot> login(String nickname, String password) =>
      _serial(() async {
        final key = _nickname(nickname).toLowerCase();
        _validatePassword(password);
        await _init();
        final accounts = _map(_store!['accounts']);
        String? id;
        for (final entry in accounts.entries) {
          if (_map(entry.value)['nicknameKey'] == key) {
            id = entry.key;
            break;
          }
        }
        if (id == null || !await _matches(_map(accounts[id]), password)) {
          throw const QuestException('昵称或密码不正确。');
        }
        final copy = _clone();
        copy['current'] = id;
        await _write(copy);
        return _current(authenticated: true);
      });
  @override
  Future<AppSnapshot> logout() => _serial(() async {
    await _init();
    final copy = _clone();
    copy['current'] = null;
    await _write(copy);
    return _snapshot();
  });
  @override
  Future<AppSnapshot> claim() => _serial(() async {
    final state = await _current(authenticated: true);
    if (state.activeQuestId != null) return state;
    if (state.canRequestNext) {
      throw const QuestException('这次已完成，可以从首页继续探索。');
    }
    return _save(state.copyWith(activeQuestId: state.recommendedQuestId));
  });
  @override
  Future<AppSnapshot> replace() => _serial(() async {
    final state = await _current(authenticated: true);
    if (state.canRequestNext) throw const QuestException('这次已完成，可以从首页继续探索。');
    if (!state.replacementAvailable) {
      throw const QuestException('今天已经更换过一次，也可以先放一放。');
    }
    final next = nextQuestId(state.recommendedQuestId);
    return _save(
      state.copyWith(
        recommendedQuestId: next,
        activeQuestId: state.activeQuestId == null ? null : next,
        replacedOn: state.day,
        draft: '',
      ),
    );
  });
  @override
  Future<AppSnapshot> stop() => _serial(() async {
    final state = await _current(authenticated: true);
    return _save(state.copyWith(activeQuestId: null));
  });
  @override
  Future<AppSnapshot> saveDraft(String text) => _serial(() async {
    _validateText(text);
    final state = await _current(authenticated: true);
    if (state.activeQuestId == null) throw const QuestException('请先开始活动，再写记录。');
    return _save(state.copyWith(draft: text));
  });
  @override
  Future<AppSnapshot> complete(String text) => _serial(() async {
    _validateText(text, required: true);
    final state = await _current(authenticated: true);
    if (state.activeQuestId == null) throw const QuestException('请先开始活动，再写记录。');
    final quest = questById(state.activeQuestId!);
    final entry = JournalEntry(
      id: _randomId(),
      questId: quest.id,
      questTitle: quest.title,
      text: text.trim(),
      createdAt: _now(),
    );
    return _save(
      state.copyWith(
        activeQuestId: null,
        entries: [...state.entries, entry],
        draft: '',
        canRequestNext: true,
      ),
    );
  });
  @override
  Future<AppSnapshot> nextQuest() => _serial(() async {
    final state = await _current(authenticated: true);
    if (!state.canRequestNext || state.activeQuestId != null) {
      throw const QuestException('完成当前活动后，可以继续探索。');
    }
    return _save(
      state.copyWith(
        recommendedQuestId: nextQuestId(state.recommendedQuestId),
        canRequestNext: false,
      ),
    );
  });
  @override
  Future<AppSnapshot> deleteEntry(String id) => _serial(() async {
    final state = await _current(authenticated: true);
    return _save(
      state.copyWith(entries: state.entries.where((e) => e.id != id).toList()),
    );
  });
  @override
  Future<AppSnapshot> deleteAccount(String password) => _serial(() async {
    final state = await _current(authenticated: true);
    final copy = _clone();
    final accounts = _map(copy['accounts']);
    if (!await _matches(_map(accounts[state.profile!.id]), password)) {
      throw const QuestException('密码不正确，账号尚未删除。');
    }
    accounts.remove(state.profile!.id);
    copy['accounts'] = accounts;
    copy['current'] = null;
    copy['pendingRole'] = null;
    copy['pendingPreferences'] = <String>[];
    await _write(copy);
    return _snapshot();
  });
  @override
  Future<String> exportData() => _serial(() async {
    final state = await _current(authenticated: true);
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'sidequest-export-v1',
      'exportedAt': _now().toIso8601String(),
      'mode': 'local',
      'state': state.toJson(),
    });
  });
}

abstract class SessionTokenStore {
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

class PlatformSessionTokenStore implements SessionTokenStore {
  const PlatformSessionTokenStore();
  static const _key = 'sidequest.remote.token';
  static const _secure = FlutterSecureStorage();
  @override
  Future<String?> read() async => kIsWeb
      ? (await SharedPreferences.getInstance()).getString(_key)
      : _secure.read(key: _key);
  @override
  Future<void> write(String token) async {
    if (kIsWeb) {
      if (!await (await SharedPreferences.getInstance()).setString(
        _key,
        token,
      )) {
        throw const QuestException('无法保存登录状态。');
      }
    } else {
      await _secure.write(key: _key, value: token);
    }
  }

  @override
  Future<void> clear() async {
    if (kIsWeb) {
      if (!await (await SharedPreferences.getInstance()).remove(_key)) {
        throw const QuestException('无法清除登录状态。');
      }
    } else {
      await _secure.delete(key: _key);
    }
  }
}

class _ApiException extends QuestException {
  const _ApiException(super.message, this.statusCode);
  final int statusCode;
}

class RemoteQuestRepository implements QuestRepository {
  RemoteQuestRepository({
    required String apiBaseUrl,
    http.Client? client,
    SessionTokenStore? tokenStore,
    SharedPreferences? preferences,
  }) : _base = apiBaseUrl.replaceFirst(RegExp(r'/+$'), ''),
       _client = client ?? http.Client(),
       _tokens = tokenStore ?? const PlatformSessionTokenStore(),
       _prefs = preferences {
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
  final String _base;
  final http.Client _client;
  final SessionTokenStore _tokens;
  SharedPreferences? _prefs;
  Future<void> _tail = Future.value();
  @override
  bool get isRemote => true;
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<Map<String, dynamic>> _request(
    String endpoint, {
    Map<String, dynamic>? body,
  }) async {
    final token = await _tokens.read();
    final headers = {
      'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
    late http.Response response;
    try {
      response =
          await (body == null
                  ? _client.get(
                      Uri.parse('$_base/api/$endpoint'),
                      headers: headers,
                    )
                  : _client.post(
                      Uri.parse('$_base/api/$endpoint'),
                      headers: headers,
                      body: jsonEncode(body),
                    ))
              .timeout(const Duration(seconds: 15));
    } on TimeoutException {
      throw const QuestException('连接超时，你的草稿仍在当前页面；请稍后重试。');
    } on http.ClientException {
      throw const QuestException('暂时连接不到服务，请检查网络后重试。');
    }
    Map<String, dynamic> data;
    try {
      data = _map(jsonDecode(utf8.decode(response.bodyBytes)));
    } catch (_) {
      throw const QuestException('服务返回了无法识别的数据，请稍后重试。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _ApiException(
        data['error'] is String
            ? data['error'] as String
            : data['message'] is String
            ? data['message'] as String
            : '请求未成功，请稍后重试。',
        response.statusCode,
      );
    }
    return data;
  }

  Future<AppSnapshot> _operation(
    String endpoint, [
    Map<String, dynamic> body = const {},
  ]) async {
    final result = await _request(endpoint, body: body);
    try {
      return AppSnapshot.fromJson(_map(result['state']));
    } catch (_) {
      throw const QuestException('服务状态暂时无法读取，请刷新后重试。');
    }
  }

  @override
  Future<AppSnapshot> load() => _serial(() async {
    try {
      final result = await _request('state');
      return AppSnapshot.fromJson(_map(result['state']));
    } on _ApiException catch (error) {
      if (error.statusCode != 401) rethrow;
      await _tokens.clear();
      final guest = await _request('state');
      return AppSnapshot.fromJson(_map(guest['state']));
    }
  });
  @override
  Future<AppSnapshot> savePreferences(String role, List<String> preferences) =>
      _serial(() async {
        _validatePreferences(role, preferences);
        if (await _tokens.read() != null) {
          return _operation('preferences', {
            'role': role,
            'preferences': preferences,
          });
        }
        _prefs ??= await SharedPreferences.getInstance();
        if (!await _prefs!.setString(
          'sidequest.remote.pending',
          jsonEncode({'role': role, 'preferences': preferences}),
        )) {
          throw const QuestException('偏好保存失败，请重试。');
        }
        return AppSnapshot(day: localDay(DateTime.now()));
      });
  Future<AppSnapshot> _authenticate(
    String endpoint,
    String nickname,
    String password,
  ) async {
    final display = _nickname(nickname);
    _validatePassword(password);
    final body = <String, dynamic>{'nickname': display, 'password': password};
    if (endpoint == 'register') {
      _prefs ??= await SharedPreferences.getInstance();
      final pending = _prefs!.getString('sidequest.remote.pending');
      if (pending == null) throw const QuestException('请先选择你的身份，再创建账号。');
      body.addAll(_map(jsonDecode(pending)));
    }
    final result = await _request(endpoint, body: body);
    final state = AppSnapshot.fromJson(_map(result['state']));
    await _tokens.write(result['token'] as String);
    return state;
  }

  @override
  Future<AppSnapshot> register(String nickname, String password) =>
      _serial(() => _authenticate('register', nickname, password));
  @override
  Future<AppSnapshot> login(String nickname, String password) =>
      _serial(() => _authenticate('login', nickname, password));
  @override
  Future<AppSnapshot> logout() => _serial(() async {
    final state = await _operation('logout');
    await _tokens.clear();
    return state;
  });
  @override
  Future<AppSnapshot> claim() => _serial(() => _operation('claim'));
  @override
  Future<AppSnapshot> replace() => _serial(() => _operation('replace'));
  @override
  Future<AppSnapshot> stop() => _serial(() => _operation('stop'));
  @override
  Future<AppSnapshot> saveDraft(String text) => _serial(() {
    _validateText(text);
    return _operation('draft', {'text': text});
  });
  @override
  Future<AppSnapshot> complete(String text) => _serial(() {
    _validateText(text, required: true);
    return _operation('complete', {'text': text});
  });
  @override
  Future<AppSnapshot> nextQuest() => _serial(() => _operation('next'));
  @override
  Future<AppSnapshot> deleteEntry(String id) =>
      _serial(() => _operation('delete-entry', {'id': id}));
  @override
  Future<AppSnapshot> deleteAccount(String password) => _serial(() async {
    final state = await _operation('delete-account', {'password': password});
    await _tokens.clear();
    return state;
  });
  @override
  Future<String> exportData() => _serial(
    () async =>
        const JsonEncoder.withIndent('  ').convert(await _request('export')),
  );
}
