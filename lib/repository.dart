import 'dart:async';

import 'domain.dart';
// 平台实现按编译目标二选一：安卓/桌面走 remote_repository（离线 + 同步），
// 网页版走 web_repository（在线优先、无本地存储）。两侧共用同一套接口与数据格式。
import 'remote_repository.dart' if (dart.library.js_interop) 'web_repository.dart' as platform_repository;

abstract class QuestRepository {
  bool get isRemote;
  bool get isConfigured => true;
  String get cacheScope;

  /// 网页版没有本地存储（部分文案与行为按此区分）；安卓/桌面为 false。
  bool get isWebClient => false;

  /// 把错误细节静默送到后台（用户无感知）；本地/配置仓储为空实现。
  void reportProblem(Object error, String scope);
  Future<AppSnapshot> load();
  Future<AppSnapshot> savePreferences(String role, List<String> preferences);
  Future<AppSnapshot> register(String nickname, String password);
  Future<AppSnapshot> login(String nickname, String password);
  Future<AppSnapshot> logout({bool discardPending = false});
  Future<AppSnapshot> claim();
  Future<AppSnapshot> replace();
  Future<AppSnapshot> stop();
  Future<DraftEditorContext> openDraftEditor(String questId);
  Future<AppSnapshot> saveDraft(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  });
  Future<AppSnapshot> complete(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  });
  Future<AppSnapshot> nextQuest();
  Future<EntryPageResult> queryEntries({String query = '', String? cursor});
  Future<AppSnapshot> updateEntry(
    String id,
    String text,
    List<MediaAttachment> attachments,
    int expectedRevision,
  );
  Future<AppSnapshot> deleteEntry(String id);
  Future<AppSnapshot> deleteAccount(String password);
  Future<MediaAttachment> stageMedia(
    String path,
    MediaKind kind, {
    int? durationMs,
  });
  Future<void> discardStagedMedia(List<String> ids);
  Future<void> removePendingAttachments(String entryId);
  Future<void> syncNow({bool allowMetered = false});
  Future<SyncSummary> getSyncSummary();
  Stream<SyncSummary> get syncUpdates;
  Future<Map<String, String>> mediaHeaders();
  String mediaUrl(MediaAttachment media, {bool thumbnail = false});
  Future<AppSnapshot> resumeConflictDraft(String id);
  Future<AppSnapshot> discardConflictDraft(String id);
  Future<AppSnapshot> saveConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  });
  Future<AppSnapshot> completeConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  });
  Future<void> dispose();
}

class DraftEditorMovedException extends QuestException {
  const DraftEditorMovedException({
    required this.snapshot,
    required this.conflictDraftId,
  }) : super('云端进度已变更，这次编辑已保留为冲突草稿。');

  final AppSnapshot snapshot;
  final String conflictDraftId;
}

QuestRepository createRepository({String apiBaseUrl = ''}) =>
    platform_repository.createPlatformRepository(apiBaseUrl: apiBaseUrl);

class ConfigurationRepository implements QuestRepository {
  const ConfigurationRepository();
  static const _error = QuestException('暂时无法连接服务，请更新应用后再试。');
  @override
  void reportProblem(Object error, String scope) {}
  Future<T> _future<T>() => Future<T>.error(_error);
  Never _fail() => throw _error;
  @override
  bool get isRemote => true;
  @override
  bool get isConfigured => false;
  @override
  bool get isWebClient => false;
  @override
  String get cacheScope => 'sidequest:unconfigured';
  @override
  Future<AppSnapshot> load() => _future();
  @override
  Future<AppSnapshot> savePreferences(String role, List<String> preferences) =>
      _future();
  @override
  Future<AppSnapshot> register(String nickname, String password) => _future();
  @override
  Future<AppSnapshot> login(String nickname, String password) => _future();
  @override
  Future<AppSnapshot> logout({bool discardPending = false}) => _future();
  @override
  Future<AppSnapshot> claim() => _future();
  @override
  Future<AppSnapshot> replace() => _future();
  @override
  Future<AppSnapshot> stop() => _future();
  @override
  Future<DraftEditorContext> openDraftEditor(String questId) => _future();
  @override
  Future<AppSnapshot> saveDraft(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  }) => _future();
  @override
  Future<AppSnapshot> complete(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  }) => _future();
  @override
  Future<AppSnapshot> nextQuest() => _future();
  @override
  Future<EntryPageResult> queryEntries({String query = '', String? cursor}) =>
      _future();
  @override
  Future<AppSnapshot> updateEntry(
    String id,
    String text,
    List<MediaAttachment> attachments,
    int expectedRevision,
  ) => _future();
  @override
  Future<AppSnapshot> deleteEntry(String id) => _future();
  @override
  Future<AppSnapshot> deleteAccount(String password) => _future();
  @override
  Future<MediaAttachment> stageMedia(
    String path,
    MediaKind kind, {
    int? durationMs,
  }) => _future();
  @override
  Future<void> discardStagedMedia(List<String> ids) => _future();
  @override
  Future<void> removePendingAttachments(String entryId) => _future();
  @override
  Future<void> syncNow({bool allowMetered = false}) => _future();
  @override
  Future<SyncSummary> getSyncSummary() => _future();
  @override
  Stream<SyncSummary> get syncUpdates => Stream<SyncSummary>.error(_error);
  @override
  Future<Map<String, String>> mediaHeaders() => _future();
  @override
  String mediaUrl(MediaAttachment media, {bool thumbnail = false}) => _fail();
  @override
  Future<AppSnapshot> resumeConflictDraft(String id) => _future();
  @override
  Future<AppSnapshot> discardConflictDraft(String id) => _future();
  @override
  Future<AppSnapshot> saveConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  }) => _future();
  @override
  Future<AppSnapshot> completeConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  }) => _future();
  @override
  Future<void> dispose() async {}
}

void validatePreferences(String role, List<String> chosen) {
  if (!roles.any((option) => option.id == role)) {
    throw const QuestException('请选择一个身份。');
  }
  if (chosen.length > 3 ||
      chosen.toSet().length != chosen.length ||
      chosen.any((item) => !preferences.contains(item))) {
    throw const QuestException('探索偏好最多选择三项。');
  }
}

void validateText(String text, {bool required = false}) {
  if (required && text.trim().isEmpty) {
    throw const QuestException('请先写一点记录，再完成并保存。');
  }
  if (text.runes.length > 500) {
    throw const QuestException('记录最多 500 个字，请稍微精简一下。');
  }
}

String validateNickname(String nickname) {
  final result = nickname.trim();
  if (result.runes.length < 2 ||
      result.runes.length > 20 ||
      !RegExp(r'^[\p{L}\p{N}_-]+$', unicode: true).hasMatch(result)) {
    throw const QuestException('昵称需为 2–20 个字，仅支持文字、数字、下划线和短横线。');
  }
  return result;
}

void validatePassword(String password) {
  if (password.runes.length < 8 || password.runes.length > 128) {
    throw const QuestException('密码需为 8–128 个字符。');
  }
}

Map<String, dynamic> jsonMap(Object? value) =>
    Map<String, dynamic>.from(value as Map);

abstract class SessionTokenStore {
  /// 读取令牌；读不到（含存储损坏等异常）时返回 null，绝不抛出。
  Future<String?> read();
  Future<void> write(String token);
  Future<void> clear();
}

