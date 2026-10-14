import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart' show XFile;
import 'package:uuid/uuid.dart';

import 'client_info.dart';
import 'domain.dart';
import 'repository.dart';
import 'silent_reporter.dart';

const _uuid = Uuid();
const _uploadSourceLimit = 10 * 1024 * 1024;

/// 网页版平台实现工厂：同源部署时 [apiBaseUrl] 留空即可（默认当前站点）。
QuestRepository createPlatformRepository({required String apiBaseUrl}) =>
    WebQuestRepository(apiBaseUrl: apiBaseUrl.trim());

/// 网页版仓储：**在线优先、无本地存储**。
///
/// - 会话：服务端下发的 HttpOnly Cookie（浏览器自动携带），前端不落地任何令牌；
/// - 数据：直接读写服务端（协议 v2 的直接动作，与安卓端共用同一套接口与数据格式）；
/// - 草稿：直接使用服务端 `/api/draft`，断网时输入只存在于页面内存；
/// - 没有离线队列、没有后台任务、没有冲突草稿（这些都是安卓端的能力）。
class WebQuestRepository implements QuestRepository {
  WebQuestRepository({String apiBaseUrl = ''})
    : apiBaseUrl = apiBaseUrl,
      _base = _normalizeBase(apiBaseUrl),
      _client = http.Client() {
    _reporter = SilentReporter(_sendDiagnostic);
  }

  static String _normalizeBase(String value) {
    final trimmed = value.trim();
    // 同源部署（线上 /app、本地代理）留空即用当前站点；去掉尾部斜杠避免 //api。
    if (trimmed.isEmpty) return Uri.base.origin;
    return trimmed.endsWith('/')
        ? trimmed.replaceFirst(RegExp(r'/+$'), '')
        : trimmed;
  }

  final String apiBaseUrl;
  final String _base;
  final http.Client _client;
  late final SilentReporter _reporter;
  final _syncController = StreamController<SyncSummary>.broadcast();
  AppSnapshot _snapshot = AppSnapshot(day: localDay(DateTime.now()));
  SyncSummary? _lastSummary;
  // 引导阶段的选择只存在于页面内存（刷新后重新选择；注册时随请求提交）。
  String _role = '';
  List<String> _preferences = const [];
  bool _disposed = false;

  @override
  bool get isRemote => true;

  @override
  bool get isConfigured => true;

  @override
  bool get isWebClient => true;

  @override
  String get cacheScope => 'sidequest:web';

  @override
  void reportProblem(Object error, String scope) =>
      _reporter.report(error, scope, client: 'web');

  // ---- 基础请求 -----------------------------------------------------------

  Map<String, String> _headers({bool json = false}) => {
    'X-Sidequest-Protocol': '2',
    'X-Sidequest-Client': clientTagWeb,
    if (json) 'Content-Type': 'application/json; charset=utf-8',
  };

  Uri _uri(String path, [Map<String, String?> query = const {}]) {
    final base = Uri.parse('$_base$path');
    final cleaned = <String, String>{
      for (final item in query.entries)
        if (item.value != null && item.value!.isNotEmpty) item.key: item.value!,
    };
    return cleaned.isEmpty ? base : base.replace(queryParameters: cleaned);
  }

  Future<http.Response> _send(
    Future<http.Response> Function() run, {
    Duration timeout = const Duration(seconds: 30),
    bool keepSession = false,
  }) async {
    late http.Response response;
    try {
      response = await run().timeout(timeout);
    } on TimeoutException {
      throw const QuestException('连接超时，请稍后重试。');
    } on http.ClientException {
      throw const QuestException('暂时连接不到服务，请检查网络后再试。');
    }
    if (response.statusCode == 401 && !keepSession) {
      _snapshot = AppSnapshot(day: _snapshot.day);
      _emitSync();
      throw const QuestException('登录已失效，请重新登录。');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw QuestException(_errorMessage(response));
    }
    return response;
  }

  String _errorMessage(http.Response response) {
    try {
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is Map && decoded['error'] is String) {
        return decoded['error'] as String;
      }
    } catch (_) {
      // 无法解析的错误体走统一兜底。
    }
    return '服务暂时不可用，请稍后再试';
  }

  Map<String, dynamic> _decode(http.Response response) {
    if (response.bodyBytes.isEmpty) return const {};
    try {
      return jsonMap(jsonDecode(utf8.decode(response.bodyBytes)));
    } catch (_) {
      throw const QuestException('服务返回的内容无法识别，请稍后再试。');
    }
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, String?> query = const {}]) async {
    final response = await _send(() => _client.get(_uri(path, query), headers: _headers()));
    return _decode(response);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    bool keepSession = false,
  }) async {
    final response = await _send(
      () => _client.post(_uri(path), headers: _headers(json: true), body: jsonEncode(body)),
      keepSession: keepSession,
    );
    return _decode(response);
  }

  // ---- 状态归并 -----------------------------------------------------------

  AppSnapshot _applyState(Object? stateJson) {
    final fresh = AppSnapshot.fromJson(jsonMap(stateJson));
    _snapshot = _snapshot.copyWith(
      profile: fresh.profile,
      activeQuestId: fresh.activeQuestId,
      recommendedQuestId: fresh.recommendedQuestId,
      replacedOn: fresh.replacedOn,
      draft: fresh.draft,
      draftAttachments: fresh.draftAttachments,
      day: fresh.day,
      canRequestNext: fresh.canRequestNext,
      progressRevision: fresh.progressRevision,
      recommendationHistory: fresh.recommendationHistory,
      entryCount: fresh.entryCount,
    );
    _emitSync();
    return _snapshot;
  }

  Future<AppSnapshot> _adoptSession(Map<String, dynamic> data) async {
    final page = await queryEntries();
    final fresh = AppSnapshot.fromJson(jsonMap(data['state']));
    _snapshot = fresh.copyWith(
      entries: page.entries,
      nextCursor: page.nextCursor,
      entryCount: page.total,
    );
    _emitSync();
    return _snapshot;
  }

  void _emitSync() {
    if (_disposed) return;
    final next = SyncSummary(requiresLogin: _snapshot.profile == null);
    final last = _lastSummary;
    if (last != null &&
        last.pending == next.pending &&
        last.uploading == next.uploading &&
        last.failed == next.failed &&
        last.queuedCommands == next.queuedCommands &&
        last.message == next.message &&
        last.requiresLogin == next.requiresLogin) {
      return;
    }
    _lastSummary = next;
    _syncController.add(next);
  }

  // ---- 账号 ---------------------------------------------------------------

  @override
  Future<AppSnapshot> load() async {
    final data = await _get('/api/state');
    var snapshot = AppSnapshot.fromJson(jsonMap(data['state']));
    if (snapshot.profile != null) {
      final page = await queryEntries();
      snapshot = snapshot.copyWith(
        entries: page.entries,
        nextCursor: page.nextCursor,
        entryCount: page.total,
      );
    }
    _snapshot = snapshot;
    _emitSync();
    return snapshot;
  }

  @override
  Future<AppSnapshot> register(String nickname, String password) async {
    validateNickname(nickname);
    validatePassword(password);
    validatePreferences(_role, _preferences);
    final data = await _post('/api/register', {
      'nickname': nickname,
      'password': password,
      'role': _role,
      'preferences': _preferences,
    }, keepSession: true);
    return _adoptSession(data);
  }

  @override
  Future<AppSnapshot> login(String nickname, String password) async {
    validateNickname(nickname);
    validatePassword(password);
    final data = await _post('/api/login', {
      'nickname': nickname,
      'password': password,
    }, keepSession: true);
    return _adoptSession(data);
  }

  @override
  Future<AppSnapshot> logout({bool discardPending = false}) async {
    final data = await _post('/api/logout', const {}, keepSession: true);
    _snapshot = AppSnapshot.fromJson(jsonMap(data['state']));
    _emitSync();
    return _snapshot;
  }

  @override
  Future<AppSnapshot> deleteAccount(String password) async {
    final data = await _post('/api/delete-account', {'password': password}, keepSession: true);
    _snapshot = AppSnapshot.fromJson(jsonMap(data['state']));
    _emitSync();
    return _snapshot;
  }

  @override
  Future<AppSnapshot> savePreferences(String role, List<String> preferences) async {
    validatePreferences(role, preferences);
    _role = role;
    _preferences = List.of(preferences);
    if (_snapshot.profile == null) {
      // 未登录：只记在页面内存，注册时随请求提交，不落地任何本地存储。
      return _snapshot;
    }
    final data = await _post('/api/preferences', {'role': role, 'preferences': preferences});
    return _applyState(data['state']);
  }

  // ---- 今日流程 -----------------------------------------------------------

  @override
  Future<AppSnapshot> claim() async {
    final data = await _post('/api/claim', const {});
    return _applyState(data['state']);
  }

  @override
  Future<AppSnapshot> replace() async {
    final data = await _post('/api/replace', const {});
    return _applyState(data['state']);
  }

  @override
  Future<AppSnapshot> stop() async {
    final data = await _post('/api/stop', const {});
    return _applyState(data['state']);
  }

  @override
  Future<AppSnapshot> nextQuest() async {
    final data = await _post('/api/next', const {});
    return _applyState(data['state']);
  }

  @override
  Future<DraftEditorContext> openDraftEditor(String questId) async {
    final data = await _get('/api/state');
    final snapshot = _applyState(data['state']);
    return DraftEditorContext(snapshot: snapshot, branchId: '', questId: questId);
  }

  @override
  Future<AppSnapshot> saveDraft(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  }) async {
    validateText(text);
    final data = await _post('/api/draft', {
      'text': text,
      'mediaIds': [for (final item in attachments ?? const <MediaAttachment>[]) item.id],
      if (expectedQuestId != null && expectedQuestId.isNotEmpty) 'questId': expectedQuestId,
    });
    return _applyState(data['state']);
  }

  @override
  Future<AppSnapshot> complete(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  }) async {
    validateText(text, required: true);
    final data = await _post('/api/complete', {
      'text': text,
      'mediaIds': [for (final item in attachments ?? const <MediaAttachment>[]) item.id],
      'clientRecordId': _uuid.v4(),
      if (expectedQuestId != null && expectedQuestId.isNotEmpty) 'questId': expectedQuestId,
    });
    _applyState(data['state']);
    _spliceEntry(data['entry']);
    return _snapshot;
  }

  /// 把服务端返回的记录并入内存快照（完成后首页弹窗要立刻能读到"已保存"状态）。
  void _spliceEntry(Object? entryJson) {
    if (entryJson is! Map) return;
    final entry = JournalEntry.fromJson(jsonMap(entryJson));
    _snapshot = _snapshot.copyWith(
      entries: [
        entry,
        ...[for (final item in _snapshot.entries) if (item.id != entry.id) item],
      ],
    );
  }

  // ---- 探索册 -------------------------------------------------------------

  @override
  Future<EntryPageResult> queryEntries({String query = '', String? cursor}) async {
    final data = await _get('/api/entries', {
      'q': query.trim(),
      'cursor': cursor,
      'limit': '20',
    });
    return EntryPageResult(
      entries: [
        for (final item in (data['entries'] as List? ?? const []))
          JournalEntry.fromJson(jsonMap(item)),
      ],
      nextCursor: data['nextCursor'] as String?,
      total: (data['total'] as num?)?.toInt() ?? 0,
    );
  }

  @override
  Future<AppSnapshot> updateEntry(
    String id,
    String text,
    List<MediaAttachment> attachments,
    int expectedRevision,
  ) async {
    validateText(text, required: true);
    final data = await _post('/api/update-entry', {
      'id': id,
      'text': text,
      'expectedRevision': expectedRevision,
      'mediaIds': [for (final item in attachments) item.id],
    });
    _applyState(data['state']);
    _spliceEntry(data['entry']);
    return _snapshot;
  }

  @override
  Future<AppSnapshot> deleteEntry(String id) async {
    final data = await _post('/api/delete-entry', {'id': id});
    _applyState(data['state']);
    _snapshot = _snapshot.copyWith(
      entries: [for (final item in _snapshot.entries) if (item.id != id) item],
    );
    return _snapshot;
  }

  // ---- 媒体 ---------------------------------------------------------------

  @override
  Future<MediaAttachment> stageMedia(String path, MediaKind kind, {int? durationMs}) async {
    if (kind != MediaKind.image) {
      throw const QuestException('图片可以先放进来；视频和语音请在手机应用里记录。');
    }
    final bytes = await XFile(path).readAsBytes();
    if (bytes.isEmpty) {
      throw const QuestException('这个文件读不出来，换一张图片试试。');
    }
    if (bytes.length > _uploadSourceLimit) {
      throw const QuestException('附件超过文件大小限制。');
    }
    // 1) 占位 → 2) 上传原始字节 → 3) 等待服务端处理完成。
    final reserved = await _post('/api/uploads', {
      'kind': 'image',
      'byteSize': bytes.length,
      'clientUploadId': _uuid.v4(),
    }, keepSession: true);
    final mediaId = jsonMap(reserved['media'])['id'] as String;
    await _send(
      () => _client.put(
        _uri('/api/uploads/$mediaId/content'),
        headers: {..._headers(), 'Content-Type': 'application/octet-stream'},
        body: bytes,
      ),
      timeout: const Duration(minutes: 3),
    );
    for (var attempt = 0; attempt < 160; attempt += 1) {
      final data = await _get('/api/uploads/$mediaId');
      final media = jsonMap(data['media']);
      final status = media['status'] as String? ?? '';
      if (status == 'ready') {
        return MediaAttachment(
          id: mediaId,
          kind: MediaKind.image,
          mimeType: media['mimeType'] as String? ?? 'image/jpeg',
          byteSize: (media['byteSize'] as num?)?.toInt() ?? bytes.length,
          width: (media['width'] as num?)?.toInt(),
          height: (media['height'] as num?)?.toInt(),
          status: 'ready',
          // 页面内存里的预览路径（blob 地址）；刷新后自动回到服务端图片。
          localPath: path,
        );
      }
      if (status == 'failed') {
        final message = (data['error'] as String?) ?? (media['error'] as String?);
        throw QuestException(message ?? '这张图片没有处理成功，换个文件再试。');
      }
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    throw const QuestException('图片处理超时，请重试。');
  }

  @override
  Future<void> discardStagedMedia(List<String> ids) async {
    for (final id in ids) {
      try {
        await _send(
          () => _client.delete(_uri('/api/uploads/$id'), headers: _headers()),
          keepSession: true,
        );
      } catch (_) {
        // 仍被草稿引用或已处理：交给服务端随下次保存自动收敛，不打扰用户。
      }
    }
  }

  @override
  Future<void> removePendingAttachments(String entryId) async {
    // 网页版没有本地待上传附件。
  }

  @override
  Future<Map<String, String>> mediaHeaders() async => const {};

  @override
  String mediaUrl(MediaAttachment media, {bool thumbnail = false}) =>
      '$_base/api/media/${media.id}/${thumbnail ? 'thumbnail' : 'content'}';

  // ---- 同步与诊断 ---------------------------------------------------------

  @override
  Future<void> syncNow({bool allowMetered = false}) async {
    if (_snapshot.profile == null) return;
    await load();
  }

  @override
  Future<SyncSummary> getSyncSummary() async =>
      SyncSummary(requiresLogin: _snapshot.profile == null);

  @override
  Stream<SyncSummary> get syncUpdates => _syncController.stream;

  Future<void> _sendDiagnostic(Map<String, Object?> payload) async {
    await _client
        .post(_uri('/api/diagnostics'), headers: _headers(json: true), body: jsonEncode(payload))
        .timeout(const Duration(seconds: 20));
  }

  // ---- 冲突草稿（安卓端离线能力，网页版没有） ------------------------------

  @override
  Future<AppSnapshot> resumeConflictDraft(String id) async => _snapshot;

  @override
  Future<AppSnapshot> discardConflictDraft(String id) async => _snapshot;

  @override
  Future<AppSnapshot> saveConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  }) async {
    throw const QuestException('网页版没有冲突草稿，直接编辑并保存即可。');
  }

  @override
  Future<AppSnapshot> completeConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  }) async {
    throw const QuestException('网页版没有冲突草稿，直接编辑并保存即可。');
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _syncController.close();
    _client.close();
  }
}
