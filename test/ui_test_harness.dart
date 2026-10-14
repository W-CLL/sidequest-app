import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/main.dart';
import 'package:sidequest/repository.dart';

const testNow = '2026-10-10';
const testPassword = 'testing-password';

enum LocalFixture { guest, authenticated, active, completed }

Future<InMemoryQuestRepository> createLocalFixture({
  LocalFixture fixture = LocalFixture.guest,
  bool onboarded = true,
  String role = 'employee',
  List<String> preferences = const ['观察细节'],
}) async {
  SharedPreferences.setMockInitialValues(
    onboarded
        ? <String, Object>{
            'ui_role': role,
            'ui_preferences': List<String>.from(preferences),
          }
        : <String, Object>{},
  );
  final repository = InMemoryQuestRepository();
  if (onboarded) await repository.savePreferences(role, preferences);
  if (fixture != LocalFixture.guest) {
    await repository.register('小叶子', testPassword);
  }
  if (fixture == LocalFixture.active || fixture == LocalFixture.completed) {
    await repository.claim();
  }
  if (fixture == LocalFixture.completed) {
    await repository.complete('窗边的叶子是柔和的绿色。');
  }
  return repository;
}

AppSnapshot snapshotFixture({
  String recommendedQuestId = 'green',
  bool authenticated = true,
  bool active = false,
  bool completed = false,
}) => AppSnapshot(
  profile: authenticated
      ? UserProfile(
          id: 'fixture-user',
          nickname: '小叶子',
          role: 'employee',
          preferences: const ['观察细节'],
        )
      : null,
  activeQuestId: active ? recommendedQuestId : null,
  recommendedQuestId: recommendedQuestId,
  entries: completed
      ? [
          JournalEntry(
            id: 'fixture-entry',
            questId: recommendedQuestId,
            questTitle: questById(recommendedQuestId).title,
            text: '窗边的叶子是柔和的绿色。',
            createdAt: DateTime(2026, 10, 10, 12),
          ),
        ]
      : const [],
  day: testNow,
  canRequestNext: completed,
);

/// Deterministic UI-only fixture. No production account/storage fallback.
class InMemoryQuestRepository implements QuestRepository {
  InMemoryQuestRepository([AppSnapshot? initial])
    : snapshot = initial ?? AppSnapshot(day: testNow);
  AppSnapshot snapshot;
  String pendingRole = 'employee';
  List<String> pendingPreferences = [];
  final Map<String, ({String password, AppSnapshot state})> _accounts = {};
  int _counter = 0;
  int draftSaves = 0;
  int completeCalls = 0;
  int editCalls = 0;
  final stagedMedia = <String, MediaAttachment>{};
  final discardedMedia = <String>[];
  final discardMediaCalls = <List<String>>[];
  final removedPendingAttachments = <String>[];
  String? pendingRemovalError;
  bool failDraftSave = false;
  Future<void>? draftSaveGate;
  Future<void>? editorOpenGate;
  Future<void>? mediaHeadersGate;
  String branchId = 'fixture-branch';
  bool? lastAllowMetered;
  SyncSummary? summaryOverride;
  final _updates = StreamController<SyncSummary>.broadcast();
  Future<EntryPageResult> Function(String query, String? cursor)? queryOverride;

  @override
  bool get isRemote => true;
  @override
  bool get isConfigured => true;
  @override
  String get cacheScope => 'fixture';

  /// 静默上报在 UI 测试里只记录、不外发（与真实仓储同语义：用户无感知）。
  final reportedProblems = <(String scope, Object error)>[];
  @override
  void reportProblem(Object error, String scope) =>
      reportedProblems.add((scope, error));
  @override
  Stream<SyncSummary> get syncUpdates => _updates.stream;

  void _remember() {
    final profile = snapshot.profile;
    if (profile == null) return;
    final previous = _accounts[profile.nickname];
    _accounts[profile.nickname] = (
      password: previous?.password ?? testPassword,
      state: snapshot,
    );
  }

  AppSnapshot _set(AppSnapshot next) {
    snapshot = next;
    _remember();
    return snapshot;
  }

  void _requireUser() {
    if (snapshot.profile == null) throw const QuestException('请先登录后继续。');
  }

  void _text(String text, {bool required = false}) {
    if (text.runes.length > 500 || (required && text.trim().isEmpty)) {
      throw const QuestException('记录需为 1–500 个字。');
    }
  }

  @override
  Future<AppSnapshot> load() async => snapshot;
  @override
  Future<AppSnapshot> savePreferences(
    String role,
    List<String> preferences,
  ) async {
    pendingRole = role;
    pendingPreferences = List.of(preferences);
    final p = snapshot.profile;
    return p == null
        ? snapshot
        : _set(
            snapshot.copyWith(
              profile: UserProfile(
                id: p.id,
                nickname: p.nickname,
                role: role,
                preferences: preferences,
              ),
            ),
          );
  }

  @override
  Future<AppSnapshot> register(String nickname, String password) async {
    if (nickname.trim().length < 2 || password.runes.length < 8) {
      throw const QuestException('请检查昵称与密码。');
    }
    if (_accounts.containsKey(nickname)) {
      throw const QuestException('这个昵称已被使用，请换一个。');
    }
    snapshot = AppSnapshot(
      day: testNow,
      profile: UserProfile(
        id: 'fixture-user-${++_counter}',
        nickname: nickname,
        role: pendingRole,
        preferences: pendingPreferences,
      ),
    );
    _accounts[nickname] = (password: password, state: snapshot);
    return snapshot;
  }

  @override
  Future<AppSnapshot> login(String nickname, String password) async {
    final account = _accounts[nickname];
    if (account == null || account.password != password) {
      throw const QuestException('昵称或密码不正确。');
    }
    return snapshot = account.state;
  }

  @override
  Future<AppSnapshot> logout({bool discardPending = false}) async {
    _remember();
    return snapshot = AppSnapshot(day: testNow);
  }

  @override
  Future<AppSnapshot> claim() async {
    _requireUser();
    if (snapshot.canRequestNext) throw const QuestException('请先继续探索。');
    return _set(snapshot.copyWith(activeQuestId: snapshot.recommendedQuestId));
  }

  @override
  Future<AppSnapshot> replace() async {
    _requireUser();
    if (!snapshot.replacementAvailable) {
      throw const QuestException('今天已经更换过一次。');
    }
    final id = nextQuestId(snapshot.recommendedQuestId);
    return _set(
      snapshot.copyWith(
        recommendedQuestId: id,
        activeQuestId: snapshot.activeQuestId == null ? null : id,
        replacedOn: testNow,
        draft: '',
        draftAttachments: [],
      ),
    );
  }

  @override
  Future<AppSnapshot> stop() async =>
      _set(snapshot.copyWith(activeQuestId: null));
  @override
  Future<DraftEditorContext> openDraftEditor(String questId) async {
    if (editorOpenGate != null) await editorOpenGate;
    _requireUser();
    if (snapshot.activeQuestId != questId) {
      throw const QuestException('活动已变化，请重新打开。');
    }
    return DraftEditorContext(
      snapshot: snapshot,
      branchId: branchId,
      questId: questId,
    );
  }

  AppSnapshot? _redirectDraftGuard(
    String text,
    List<MediaAttachment>? media,
    String? expectedBranchId,
    String? expectedQuestId,
  ) {
    if (expectedBranchId == null ||
        (expectedBranchId == branchId &&
            expectedQuestId == snapshot.activeQuestId)) {
      return null;
    }
    final id = 'fixture-conflict-$expectedBranchId';
    final state = _set(
      snapshot.copyWith(
        conflictDrafts: [
          ...snapshot.conflictDrafts.where((d) => d.id != id),
          ConflictDraft(
            id: id,
            questId: expectedQuestId!,
            text: text,
            attachments: media ?? [],
            createdAt: DateTime(2026, 10, 10),
            branchId: expectedBranchId,
          ),
        ],
      ),
    );
    throw DraftEditorMovedException(snapshot: state, conflictDraftId: id);
  }

  @override
  Future<AppSnapshot> saveDraft(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  }) async {
    draftSaves++;
    if (draftSaveGate != null) await draftSaveGate;
    if (failDraftSave) throw const QuestException('保存失败，请重试。');
    _requireUser();
    _text(text);
    final conflict = _redirectDraftGuard(
      text,
      attachments,
      expectedBranchId,
      expectedQuestId,
    );
    if (conflict != null) return conflict;
    if (snapshot.activeQuestId == null) throw const QuestException('请先开始活动。');
    return _set(snapshot.copyWith(draft: text, draftAttachments: attachments));
  }

  @override
  Future<AppSnapshot> complete(
    String text, {
    List<MediaAttachment>? attachments,
    String? expectedBranchId,
    String? expectedQuestId,
  }) async {
    _requireUser();
    _text(text, required: true);
    final conflict = _redirectDraftGuard(
      text,
      attachments,
      expectedBranchId,
      expectedQuestId,
    );
    if (conflict != null) return conflict;
    final id = snapshot.activeQuestId;
    if (id == null) throw const QuestException('请先开始活动。');
    completeCalls++;
    final quest = questById(id);
    return _set(
      snapshot.copyWith(
        activeQuestId: null,
        draft: '',
        draftAttachments: [],
        canRequestNext: true,
        entryCount: snapshot.entryCount + 1,
        entries: [
          ...snapshot.entries,
          JournalEntry(
            id: 'fixture-entry-${++_counter}',
            questId: id,
            questTitle: quest.title,
            text: text.trim(),
            createdAt: DateTime(2026, 10, 10, 12, 0, _counter),
            attachments: List.of(attachments ?? []),
            syncStatus: 'pending',
          ),
        ],
      ),
    );
  }

  @override
  Future<AppSnapshot> nextQuest() async {
    if (!snapshot.canRequestNext) throw const QuestException('请先完成当前活动。');
    return _set(
      snapshot.copyWith(
        recommendedQuestId: nextQuestId(snapshot.recommendedQuestId),
        canRequestNext: false,
      ),
    );
  }

  @override
  Future<AppSnapshot> deleteEntry(String id) async => _set(
    snapshot.copyWith(
      entries: snapshot.entries.where((e) => e.id != id).toList(),
      entryCount: snapshot.entries.where((e) => e.id != id).length,
    ),
  );
  @override
  Future<AppSnapshot> deleteAccount(String password) async {
    final nickname = snapshot.profile?.nickname;
    if (_accounts[nickname]?.password != password) {
      throw const QuestException('密码不正确。');
    }
    _accounts.remove(nickname);
    return snapshot = AppSnapshot(day: testNow);
  }

  @override
  Future<EntryPageResult> queryEntries({
    String query = '',
    String? cursor,
  }) async {
    if (queryOverride != null) return queryOverride!(query, cursor);
    final list =
        snapshot.entries
            .where(
              (e) => e.text.contains(query) || e.questTitle.contains(query),
            )
            .toList()
          ..sort((a, b) {
            final time = b.createdAt.compareTo(a.createdAt);
            return time == 0 ? b.id.compareTo(a.id) : time;
          });
    final start = int.tryParse(cursor ?? '') ?? 0;
    final page = list.skip(start).take(20).toList();
    return EntryPageResult(
      entries: page,
      nextCursor: start + page.length < list.length
          ? '${start + page.length}'
          : null,
      total: list.length,
    );
  }

  @override
  Future<AppSnapshot> updateEntry(
    String id,
    String text,
    List<MediaAttachment> attachments,
    int expectedRevision,
  ) async {
    _text(text, required: true);
    final original = snapshot.entries.firstWhere((e) => e.id == id);
    if (original.revision != expectedRevision) {
      throw const QuestException('记录已更新，请重新打开后编辑。');
    }
    editCalls++;
    return _set(
      snapshot.copyWith(
        entries: snapshot.entries
            .map(
              (e) => e.id == id
                  ? e.copyWith(
                      text: text,
                      attachments: List.of(attachments),
                      revision: e.revision + 1,
                      updatedAt: DateTime(2026, 10, 11),
                    )
                  : e,
            )
            .toList(),
      ),
    );
  }

  @override
  Future<MediaAttachment> stageMedia(
    String path,
    MediaKind kind, {
    int? durationMs,
  }) async {
    final media = MediaAttachment(
      id: 'fixture-media-${++_counter}',
      kind: kind,
      localPath: path,
      durationMs: durationMs,
    );
    stagedMedia[media.id] = media;
    return media;
  }

  @override
  Future<void> discardStagedMedia(List<String> ids) async {
    discardMediaCalls.add(List.of(ids));
    final referenced = {
      ...snapshot.draftAttachments.map((m) => m.id),
      ...snapshot.entries.expand((e) => e.attachments.map((m) => m.id)),
      ...snapshot.conflictDrafts.expand((d) => d.attachments.map((m) => m.id)),
    };
    for (final id in ids) {
      if (!referenced.contains(id) && stagedMedia.remove(id) != null) {
        discardedMedia.add(id);
      }
    }
  }

  @override
  Future<void> removePendingAttachments(String entryId) async {
    if (pendingRemovalError != null) throw QuestException(pendingRemovalError!);
    final entry = snapshot.entries.firstWhere((e) => e.id == entryId);
    if (entry.syncStatus != 'failed' || entry.attachments.isEmpty) {
      throw const QuestException('当前记录不支持移除待同步附件。');
    }
    removedPendingAttachments.add(entryId);
    _set(
      snapshot.copyWith(
        entries: snapshot.entries
            .map(
              (e) => e.id == entryId
                  ? e.copyWith(
                      attachments: [],
                      syncStatus: 'pending',
                      syncError: null,
                    )
                  : e,
            )
            .toList(),
      ),
    );
    await syncNow();
  }

  @override
  Future<void> syncNow({bool allowMetered = false}) async {
    lastAllowMetered = allowMetered;
    _set(
      snapshot.copyWith(
        entries: snapshot.entries
            .map((e) => e.copyWith(syncStatus: 'saved'))
            .toList(),
      ),
    );
    _updates.add(await getSyncSummary());
  }

  @override
  Future<SyncSummary> getSyncSummary() async =>
      summaryOverride ??
      SyncSummary(
        pending: snapshot.entries
            .where((e) => e.syncStatus == 'pending')
            .length,
        uploading: snapshot.entries
            .where((e) => e.syncStatus == 'uploading')
            .length,
        failed: snapshot.entries.where((e) => e.syncStatus == 'failed').length,
      );
  @override
  Future<Map<String, String>> mediaHeaders() async {
    if (mediaHeadersGate != null) await mediaHeadersGate;
    return {'Authorization': 'Bearer fixture'};
  }

  @override
  String mediaUrl(MediaAttachment media, {bool thumbnail = false}) =>
      'https://fixture.invalid/api/media/${media.id}/${thumbnail ? 'thumbnail' : 'content'}';
  @override
  Future<AppSnapshot> resumeConflictDraft(String id) async {
    final draft = snapshot.conflictDrafts.firstWhere((d) => d.id == id);
    return snapshot.copyWith(
      activeQuestId: draft.questId,
      recommendedQuestId: draft.questId,
      draft: draft.text,
      draftAttachments: draft.attachments,
      canRequestNext: false,
    );
  }

  @override
  Future<AppSnapshot> saveConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  }) async {
    _text(text);
    return _set(
      snapshot.copyWith(
        conflictDrafts: snapshot.conflictDrafts
            .map(
              (draft) => draft.id == id
                  ? ConflictDraft(
                      id: draft.id,
                      questId: draft.questId,
                      text: text,
                      createdAt: draft.createdAt,
                      attachments: attachments ?? draft.attachments,
                      branchId: draft.branchId,
                      baseRevision: draft.baseRevision,
                    )
                  : draft,
            )
            .toList(),
      ),
    );
  }

  @override
  Future<AppSnapshot> completeConflictDraft(
    String id,
    String text, {
    List<MediaAttachment>? attachments,
  }) async {
    _text(text, required: true);
    final draft = snapshot.conflictDrafts.firstWhere((d) => d.id == id);
    return _set(
      snapshot.copyWith(
        entries: [
          ...snapshot.entries,
          JournalEntry(
            id: 'fixture-entry-${++_counter}',
            questId: draft.questId,
            questTitle: questById(draft.questId).title,
            text: text,
            createdAt: DateTime(2026, 10, 10),
            attachments: attachments ?? draft.attachments,
            syncStatus: 'pending',
          ),
        ],
        entryCount: snapshot.entryCount + 1,
        conflictDrafts: snapshot.conflictDrafts
            .where((d) => d.id != id)
            .toList(),
      ),
    );
  }

  @override
  Future<AppSnapshot> discardConflictDraft(String id) async => _set(
    snapshot.copyWith(
      conflictDrafts: snapshot.conflictDrafts.where((d) => d.id != id).toList(),
    ),
  );
  @override
  Future<void> dispose() async {
    await _updates.close();
  }
}

class SnapshotQuestRepository extends InMemoryQuestRepository {
  SnapshotQuestRepository(super.snapshot);
}

void configureTestView(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  double keyboardInset = 0,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..viewInsets = FakeViewPadding(bottom: keyboardInset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> pumpSideQuest(
  WidgetTester tester,
  QuestRepository repository,
) async {
  await tester.pumpWidget(SideQuestApp(repository: repository));
  await tester.pumpAndSettle();
}

void expectNoLayoutException(WidgetTester tester) {
  final exceptions = <Object>[];
  Object? exception;
  while ((exception = tester.takeException()) != null) {
    exceptions.add(exception!);
  }
  expect(exceptions, isEmpty, reason: exceptions.join('\n\n'));
}

void expectOnScreen(
  WidgetTester tester,
  Finder finder, {
  double keyboardInset = 0,
}) {
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  final logicalSize = tester.view.physicalSize / tester.view.devicePixelRatio;
  final availableBottom = logicalSize.height - keyboardInset;
  expect(rect.left, greaterThanOrEqualTo(-0.5));
  expect(rect.right, lessThanOrEqualTo(logicalSize.width + 0.5));
  expect(rect.top, greaterThanOrEqualTo(-0.5));
  expect(
    rect.bottom,
    lessThanOrEqualTo(availableBottom + 0.5),
    reason: '$finder must remain above the visible viewport bottom.',
  );
}

void expectOnScreenAndHitTestable(
  WidgetTester tester,
  Finder finder, {
  double keyboardInset = 0,
}) {
  expectOnScreen(tester, finder, keyboardInset: keyboardInset);
  expect(finder.hitTestable(), findsOneWidget);
}

Future<void> revealAndExpectReachable(
  WidgetTester tester,
  Finder finder, {
  double keyboardInset = 0,
  Key? scrollableKey,
}) async {
  if (finder.evaluate().isEmpty && scrollableKey != null) {
    final scrollable = find.descendant(
      of: find.byKey(scrollableKey),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsWidgets);
    await tester.scrollUntilVisible(finder, 160, scrollable: scrollable.first);
    await tester.pumpAndSettle();
  }
  expect(finder, findsOneWidget);
  if (finder.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }
  expectOnScreenAndHitTestable(tester, finder, keyboardInset: keyboardInset);
}

Future<void> revealAndExpectVisible(
  WidgetTester tester,
  Finder finder, {
  double keyboardInset = 0,
  required Key scrollableKey,
}) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.descendant(
      of: find.byKey(scrollableKey),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsWidgets);
    await tester.scrollUntilVisible(finder, 160, scrollable: scrollable.first);
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
  expectOnScreen(tester, finder, keyboardInset: keyboardInset);
}

Future<void> revealAndTap(
  WidgetTester tester,
  Finder finder, {
  Key? scrollableKey,
}) async {
  await revealAndExpectReachable(tester, finder, scrollableKey: scrollableKey);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

ScrollableState scrollableStateWithin(Key key, WidgetTester tester) {
  final root = find.byKey(key);
  expect(root, findsOneWidget);
  final scrollable = find.descendant(
    of: root,
    matching: find.byType(Scrollable),
  );
  expect(scrollable, findsWidgets);
  return tester.state<ScrollableState>(scrollable.first);
}

void expectNoExtraScroll(Key key, WidgetTester tester) {
  final position = scrollableStateWithin(key, tester).position;
  expect(
    position.maxScrollExtent,
    lessThanOrEqualTo(0.5),
    reason: '$key should fit the default viewport without scrolling.',
  );
}
