import 'dart:collection';

part 'quest_catalog.g.dart';

class RoleOption {
  const RoleOption(this.id, this.label, this.subtitle);
  final String id;
  final String label;
  final String subtitle;
}

const roles = <RoleOption>[
  RoleOption('student', '学生', '在课间和日常里发现一点不同'),
  RoleOption('employee', '上班族', '给忙碌的一天留一点呼吸'),
  RoleOption('freelancer', '自由工作者', '在自己的节奏里轻轻探索'),
  RoleOption('leader', '经营者 / 团队负责人', '暂时放下待办，看看身边'),
  RoleOption('caregiver', '家庭照护者', '给照顾他人的自己一点时间'),
  RoleOption('retired', '退休生活', '熟悉的日常也有新发现'),
  RoleOption('transition', '生活过渡期', '不着急，先从一件小事开始'),
  RoleOption('other', '其他身份', '按照舒服的方式探索'),
];
const roleOptions = roles;
const preferences = <String>['安静独处', '熟人同行', '观察细节', '动手创作', '尝试新鲜', '熟悉安心'];
const preferenceOptions = preferences;

class Quest {
  const Quest({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.category,
    required this.minutes,
    required this.steps,
    required this.hint,
    this.roleHints = const {},
    this.preferenceTags = const [],
    this.enabled = true,
  });
  final String id;
  final String title;
  final String subtitle;
  final String category;
  final int minutes;
  final List<String> steps;
  final String hint;
  final Map<String, String> roleHints;
  final List<String> preferenceTags;

  /// 已停用的任务仍保留在目录中（历史记录与已激活任务照常展示），
  /// 但不会被推荐、轮换到或作为新用户的初始推荐。
  final bool enabled;
}

Quest questById(String id) => questCatalog.firstWhere(
  (q) => q.id == id,
  orElse: () => throw const QuestException('活动内容与当前版本不匹配，请更新应用。'),
);
String nextQuestId(String id) {
  questById(id); // Unknown catalog versions must never silently become green.
  final start = questCatalog.indexWhere((q) => q.id == id);
  for (var step = 1; step <= questCatalog.length; step++) {
    final candidate = questCatalog[(start + step) % questCatalog.length];
    if (candidate.enabled) return candidate.id;
  }
  return id;
}

String localDay(DateTime date) {
  final day = date.toUtc().add(const Duration(hours: 8));
  return '${day.year.toString().padLeft(4, '0')}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}';
}

String recommendQuestId({
  required List<String> preferences,
  List<String> history = const [],
  String? currentId,
}) {
  final ids = questCatalog.map((q) => q.id).toList();
  final valid = history.where(ids.contains).toList();
  final recent = valid.skip(valid.length > 7 ? valid.length - 7 : 0).toList();
  var candidates = questCatalog
      .where((q) => q.enabled && q.id != currentId && !recent.contains(q.id))
      .toList();
  while (candidates.isEmpty && recent.isNotEmpty) {
    recent.removeAt(0);
    candidates = questCatalog
        .where((q) => q.enabled && q.id != currentId && !recent.contains(q.id))
        .toList();
  }
  if (candidates.isEmpty) {
    return questCatalog
        .firstWhere((q) => q.enabled, orElse: () => questCatalog.first)
        .id;
  }
  final current = currentId == null ? -1 : ids.indexOf(currentId);
  int distance(String id) => current < 0
      ? ids.indexOf(id)
      : (ids.indexOf(id) - current + ids.length) % ids.length;
  candidates.sort((a, b) {
    final score = b.preferenceTags
        .where(preferences.contains)
        .length
        .compareTo(a.preferenceTags.where(preferences.contains).length);
    if (score != 0) return score;
    final recent = valid.lastIndexOf(a.id).compareTo(valid.lastIndexOf(b.id));
    return recent != 0 ? recent : distance(a.id).compareTo(distance(b.id));
  });
  return candidates.first.id;
}

List<String> appendRecommendation(List<String> history, String id) {
  final all = [...history, id];
  return all.skip(all.length > 40 ? all.length - 40 : 0).toList();
}

class UserProfile {
  UserProfile({
    required this.id,
    required this.nickname,
    required this.role,
    required List<String> preferences,
  }) : preferences = UnmodifiableListView(preferences);
  final String id;
  final String nickname;
  final String role;
  final List<String> preferences;
  Map<String, dynamic> toJson() => {
    'id': id,
    'nickname': nickname,
    'role': role,
    'preferences': preferences,
  };
  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
    id: json['id'] as String,
    nickname: json['nickname'] as String,
    role: json['role'] as String,
    preferences: List<String>.from(json['preferences'] as List? ?? []),
  );
}

enum MediaKind { image, video, audio }

class MediaAttachment {
  const MediaAttachment({
    required this.id,
    required this.kind,
    this.mimeType = '',
    this.byteSize = 0,
    this.durationMs,
    this.width,
    this.height,
    this.status = 'ready',
    this.localPath,
  });
  final String id, mimeType, status;
  final MediaKind kind;
  final int byteSize;
  final int? durationMs, width, height;
  final String? localPath;
  bool get isReady => status == 'ready';
  MediaAttachment copyWith({
    String? id,
    MediaKind? kind,
    String? mimeType,
    int? byteSize,
    Object? durationMs = _unchanged,
    Object? width = _unchanged,
    Object? height = _unchanged,
    String? status,
    Object? localPath = _unchanged,
  }) => MediaAttachment(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    mimeType: mimeType ?? this.mimeType,
    byteSize: byteSize ?? this.byteSize,
    durationMs: identical(durationMs, _unchanged)
        ? this.durationMs
        : durationMs as int?,
    width: identical(width, _unchanged) ? this.width : width as int?,
    height: identical(height, _unchanged) ? this.height : height as int?,
    status: status ?? this.status,
    localPath: identical(localPath, _unchanged)
        ? this.localPath
        : localPath as String?,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'kind': kind.name,
    'mimeType': mimeType,
    'byteSize': byteSize,
    if (durationMs != null) 'durationMs': durationMs,
    if (width != null) 'width': width,
    if (height != null) 'height': height,
    'status': status,
    if (localPath != null) 'localPath': localPath,
  };
  factory MediaAttachment.fromJson(Map<String, dynamic> json) =>
      MediaAttachment(
        id: json['id'] as String,
        kind: MediaKind.values.byName(json['kind'] as String),
        mimeType: json['mimeType'] as String? ?? '',
        byteSize: _mediaInteger(json['byteSize']) ?? 0,
        durationMs: _mediaInteger(json['durationMs']),
        width: _mediaInteger(json['width']),
        height: _mediaInteger(json['height']),
        status: json['status'] as String? ?? 'ready',
        localPath: json['localPath'] as String?,
      );
}

int? _mediaInteger(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite || value < 0 || value != value.toInt()) {
    throw const QuestException('媒体信息无效，请更新应用或重新选择附件。');
  }
  return value.toInt();
}

List<MediaAttachment> mediaList(Object? value) => (value as List? ?? [])
    .map((m) => MediaAttachment.fromJson(Map<String, dynamic>.from(m as Map)))
    .toList();
void validateMedia(List<MediaAttachment> media) {
  if (media.map((m) => m.id).toSet().length != media.length) {
    throw const QuestException('同一附件不能重复添加。');
  }
  if (media.where((m) => m.kind == MediaKind.image).length > 5 ||
      media.where((m) => m.kind == MediaKind.video).length > 1 ||
      media.where((m) => m.kind == MediaKind.audio).length > 1) {
    throw const QuestException('每条最多 5 张图片、1 段视频和 1 段语音。');
  }
  for (final item in media) {
    final limit = switch (item.kind) {
      MediaKind.image => 10 * 1024 * 1024,
      MediaKind.video => 50 * 1024 * 1024,
      MediaKind.audio => 2 * 1024 * 1024,
    };
    if (item.byteSize < 0 || item.byteSize > limit) {
      throw const QuestException('附件超过文件大小限制。');
    }
    if (item.kind != MediaKind.image &&
        item.durationMs != null &&
        item.durationMs! <= 0) {
      throw const QuestException('媒体时长无效，请重新选择或录制。');
    }
    if (item.kind == MediaKind.video && (item.durationMs ?? 0) > 15000) {
      throw const QuestException('视频不能超过 15 秒，请重新选择。');
    }
    if (item.kind == MediaKind.audio && (item.durationMs ?? 0) > 60000) {
      throw const QuestException('语音不能超过 60 秒。');
    }
  }
}

class JournalEntry {
  const JournalEntry({
    required this.id,
    required this.questId,
    required this.questTitle,
    required this.text,
    required this.createdAt,
    this.attachments = const [],
    this.revision = 1,
    DateTime? updatedAt,
    this.syncStatus = 'saved',
    this.syncError,
  }) : updatedAt = updatedAt ?? createdAt;
  final String id;
  final String questId;
  final String questTitle;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;
  final List<MediaAttachment> attachments;
  final int revision;
  final String syncStatus;
  final String? syncError;
  bool get isSynced => syncStatus == 'saved';
  JournalEntry copyWith({
    String? text,
    List<MediaAttachment>? attachments,
    int? revision,
    DateTime? updatedAt,
    String? syncStatus,
    Object? syncError = _unchanged,
  }) => JournalEntry(
    id: id,
    questId: questId,
    questTitle: questTitle,
    text: text ?? this.text,
    createdAt: createdAt,
    attachments: attachments ?? this.attachments,
    revision: revision ?? this.revision,
    updatedAt: updatedAt ?? this.updatedAt,
    syncStatus: syncStatus ?? this.syncStatus,
    syncError: identical(syncError, _unchanged)
        ? this.syncError
        : syncError as String?,
  );
  Map<String, dynamic> toJson() => {
    'id': id,
    'questId': questId,
    'questTitle': questTitle,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'updatedAt': updatedAt.toIso8601String(),
    'revision': revision,
    'attachments': attachments.map((m) => m.toJson()).toList(),
    'syncStatus': syncStatus,
    if (syncError != null) 'syncError': syncError,
  };
  factory JournalEntry.fromJson(Map<String, dynamic> json) => JournalEntry(
    id: json['id'] as String,
    questId: json['questId'] as String,
    questTitle: json['questTitle'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    updatedAt: json['updatedAt'] == null
        ? null
        : DateTime.parse(json['updatedAt'] as String),
    revision: (json['revision'] as num?)?.toInt() ?? 1,
    attachments: mediaList(json['attachments']),
    syncStatus: json['syncStatus'] as String? ?? 'saved',
    syncError: json['syncError'] as String?,
  );
}

const _unchanged = Object();

class ConflictDraft {
  const ConflictDraft({
    required this.id,
    required this.questId,
    required this.text,
    required this.createdAt,
    this.attachments = const [],
    this.branchId = '',
    this.baseRevision = 0,
  });
  final String id, questId, text;
  final String branchId;
  final int baseRevision;
  final DateTime createdAt;
  final List<MediaAttachment> attachments;
  Map<String, dynamic> toJson() => {
    'id': id,
    'questId': questId,
    'text': text,
    'createdAt': createdAt.toIso8601String(),
    'attachments': attachments.map((m) => m.toJson()).toList(),
    'branchId': branchId,
    'baseRevision': baseRevision,
  };
  factory ConflictDraft.fromJson(Map<String, dynamic> json) => ConflictDraft(
    id: json['id'] as String,
    questId: json['questId'] as String,
    text: json['text'] as String,
    createdAt: DateTime.parse(json['createdAt'] as String),
    attachments: mediaList(json['attachments']),
    branchId: json['branchId'] as String? ?? '',
    baseRevision: (json['baseRevision'] as num?)?.toInt() ?? 0,
  );
}

/// A record editor remains attached to the branch it opened, even if sync
/// adopts another device's canonical progress while this screen is visible.
class DraftEditorContext {
  const DraftEditorContext({
    required this.snapshot,
    required this.branchId,
    required this.questId,
  });
  final AppSnapshot snapshot;
  final String branchId, questId;
}

class EntryPageResult {
  const EntryPageResult({
    required this.entries,
    this.nextCursor,
    required this.total,
  });
  final List<JournalEntry> entries;
  final String? nextCursor;
  final int total;
}

class SyncSummary {
  const SyncSummary({
    this.pending = 0,
    this.uploading = 0,
    this.failed = 0,
    this.queuedCommands = 0,
    this.message,
    this.requiresLogin = false,
  });
  final int pending, uploading, failed;

  /// Internal progress/draft work also needs syncing, but is not another record
  /// in the user-facing pending/uploading/failed counts.
  final int queuedCommands;
  final String? message;
  final bool requiresLogin;
  bool get hasPending =>
      pending > 0 || uploading > 0 || failed > 0 || queuedCommands > 0;
}

class AppSnapshot {
  AppSnapshot({
    this.profile,
    this.activeQuestId,
    this.recommendedQuestId = 'green',
    List<JournalEntry> entries = const [],
    this.replacedOn,
    this.draft = '',
    required this.day,
    this.canRequestNext = false,
    List<MediaAttachment> draftAttachments = const [],
    this.progressRevision = 0,
    List<String> recommendationHistory = const [],
    int? entryCount,
    List<ConflictDraft> conflictDrafts = const [],
    this.nextCursor,
  }) : entries = UnmodifiableListView(entries),
       draftAttachments = UnmodifiableListView(draftAttachments),
       recommendationHistory = UnmodifiableListView(recommendationHistory),
       conflictDrafts = UnmodifiableListView(conflictDrafts),
       entryCount = entryCount ?? entries.length;
  final UserProfile? profile;
  final String? activeQuestId;
  final String recommendedQuestId;
  final List<JournalEntry> entries;
  final String? replacedOn;
  final String draft;
  final String day;
  final bool canRequestNext;
  final List<MediaAttachment> draftAttachments;
  final int progressRevision, entryCount;
  final List<String> recommendationHistory;
  final List<ConflictDraft> conflictDrafts;
  final String? nextCursor;
  bool get replacementAvailable => replacedOn != day;
  AppSnapshot copyWith({
    Object? profile = _unchanged,
    Object? activeQuestId = _unchanged,
    String? recommendedQuestId,
    List<JournalEntry>? entries,
    Object? replacedOn = _unchanged,
    String? draft,
    String? day,
    bool? canRequestNext,
    List<MediaAttachment>? draftAttachments,
    int? progressRevision,
    List<String>? recommendationHistory,
    int? entryCount,
    List<ConflictDraft>? conflictDrafts,
    Object? nextCursor = _unchanged,
  }) => AppSnapshot(
    profile: identical(profile, _unchanged)
        ? this.profile
        : profile as UserProfile?,
    activeQuestId: identical(activeQuestId, _unchanged)
        ? this.activeQuestId
        : activeQuestId as String?,
    recommendedQuestId: recommendedQuestId ?? this.recommendedQuestId,
    entries: entries ?? this.entries,
    replacedOn: identical(replacedOn, _unchanged)
        ? this.replacedOn
        : replacedOn as String?,
    draft: draft ?? this.draft,
    day: day ?? this.day,
    canRequestNext: canRequestNext ?? this.canRequestNext,
    draftAttachments: draftAttachments ?? this.draftAttachments,
    progressRevision: progressRevision ?? this.progressRevision,
    recommendationHistory: recommendationHistory ?? this.recommendationHistory,
    entryCount: entryCount ?? this.entryCount,
    conflictDrafts: conflictDrafts ?? this.conflictDrafts,
    nextCursor: identical(nextCursor, _unchanged)
        ? this.nextCursor
        : nextCursor as String?,
  );
  Map<String, dynamic> toJson() => {
    'profile': profile?.toJson(),
    'activeQuestId': activeQuestId,
    'recommendedQuestId': recommendedQuestId,
    'entries': entries.map((e) => e.toJson()).toList(),
    'replacedOn': replacedOn,
    'draft': draft,
    'day': day,
    'canRequestNext': canRequestNext,
    'draftAttachments': draftAttachments.map((m) => m.toJson()).toList(),
    'progressRevision': progressRevision,
    'recommendationHistory': recommendationHistory,
    'entryCount': entryCount,
    'conflictDrafts': conflictDrafts.map((d) => d.toJson()).toList(),
    'nextCursor': nextCursor,
  };
  factory AppSnapshot.fromJson(Map<String, dynamic> json) => AppSnapshot(
    profile: json['profile'] == null
        ? null
        : UserProfile.fromJson(
            Map<String, dynamic>.from(json['profile'] as Map),
          ),
    activeQuestId: json['activeQuestId'] as String?,
    recommendedQuestId: json['recommendedQuestId'] as String? ?? 'green',
    entries: (json['entries'] as List? ?? [])
        .map((e) => JournalEntry.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList(),
    replacedOn: json['replacedOn'] as String?,
    draft: json['draft'] as String? ?? '',
    day: json['day'] as String? ?? localDay(DateTime.now()),
    canRequestNext: json['canRequestNext'] as bool? ?? false,
    draftAttachments: mediaList(json['draftAttachments']),
    progressRevision: (json['progressRevision'] as num?)?.toInt() ?? 0,
    recommendationHistory: List<String>.from(
      json['recommendationHistory'] as List? ?? [],
    ),
    entryCount: (json['entryCount'] as num?)?.toInt(),
    conflictDrafts: (json['conflictDrafts'] as List? ?? [])
        .map((d) => ConflictDraft.fromJson(Map<String, dynamic>.from(d as Map)))
        .toList(),
    nextCursor: json['nextCursor'] as String?,
  );
}

class QuestException implements Exception {
  const QuestException(this.message);
  final String message;
  @override
  String toString() => message;
}
