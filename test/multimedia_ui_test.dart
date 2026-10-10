import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:record/record.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/media_widgets.dart';
import 'package:sidequest/pages.dart';

import 'ui_test_harness.dart';

const mixedAttachments = [
  MediaAttachment(id: 'image-one', kind: MediaKind.image, byteSize: 1024),
  MediaAttachment(
    id: 'video-one',
    kind: MediaKind.video,
    durationMs: 15000,
    byteSize: 4096,
  ),
  MediaAttachment(
    id: 'audio-one',
    kind: MediaKind.audio,
    durationMs: 60000,
    byteSize: 2048,
  ),
];

class _RecorderPlatform extends RecordPlatform {
  final states = StreamController<RecordState>.broadcast();
  String? path;
  bool permission = true;
  @override
  Future<void> create(String recorderId) async {}
  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) async =>
      permission;
  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async {
    this.path = path;
  }

  @override
  Stream<RecordState> onStateChanged(String recorderId) => states.stream;
  @override
  Future<String?> stop(String recorderId) async => path;
  @override
  Future<void> cancel(String recorderId) async {}
  @override
  Future<void> dispose(String recorderId) async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AudioStageFailure extends InMemoryQuestRepository {
  _AudioStageFailure(super.initial);
  bool failNextStage = true;
  @override
  Future<MediaAttachment> stageMedia(
    String path,
    MediaKind kind, {
    int? durationMs,
  }) async {
    if (failNextStage) {
      failNextStage = false;
      throw const QuestException('附件暂存失败');
    }
    return super.stageMedia(path, kind, durationMs: durationMs);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'mixed attachment controls grow at two-times text and image order is editable',
    (tester) async {
      configureTestView(tester, size: const Size(320, 568), textScale: 2);
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      var attachments = [
        ...mixedAttachments,
        const MediaAttachment(id: 'image-two', kind: MediaKind.image),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => MediaComposer(
                  repository: repo,
                  accountId: repo.snapshot.profile!.id,
                  contextId: 'draft:green',
                  attachments: attachments,
                  onChanged: (media) => setState(() => attachments = media),
                  onError: (error) => fail(error),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await revealAndTap(
        tester,
        find.byKey(const Key('media-later-image-one')),
      );
      expect(
        attachments.where((m) => m.kind == MediaKind.image).first.id,
        'image-two',
      );
      expectNoLayoutException(tester);
    },
  );

  testWidgets(
    'interrupted recording requires explicit confirmation before attachment',
    (tester) async {
      configureTestView(tester);
      final previous = RecordPlatform.instance;
      final recorder = _RecorderPlatform();
      RecordPlatform.instance = recorder;
      addTearDown(() {
        RecordPlatform.instance = previous;
        return recorder.states.close();
      });
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      var attachments = <MediaAttachment>[];
      final deletedRecordings = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MediaComposer(
                repository: repo,
                accountId: repo.snapshot.profile!.id,
                contextId: 'draft:green',
                attachments: attachments,
                onChanged: (media) => setState(() => attachments = media),
                onError: (error) => fail(error),
                recordingDirectory: () async => '/fixture',
                removeRecordingFile: (path) async =>
                    deletedRecordings.add(path),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await revealAndTap(tester, find.byKey(const Key('media-add-audio')));
      await tester.pump(const Duration(seconds: 3));
      recorder.states.add(RecordState.pause);
      await tester.pumpAndSettle();
      expect(find.text('确认这段语音'), findsOneWidget);
      expect(find.byKey(const Key('audio-review-play')), findsOneWidget);
      expect(attachments, isEmpty);
      await tester.tap(find.byKey(const Key('audio-review-add')));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(attachments.single.kind, MediaKind.audio);
      expect(attachments.single.durationMs, inInclusiveRange(1, 60000));
      expect(deletedRecordings, [recorder.path]);
      expectNoLayoutException(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recording staging failure keeps its temp source until explicit retry succeeds',
    (tester) async {
      configureTestView(tester);
      final previous = RecordPlatform.instance;
      final recorder = _RecorderPlatform();
      RecordPlatform.instance = recorder;
      addTearDown(() {
        RecordPlatform.instance = previous;
        return recorder.states.close();
      });
      final repo = _AudioStageFailure(snapshotFixture(active: true));
      var attachments = <MediaAttachment>[];
      final deleted = <String>[];
      final errors = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MediaComposer(
                repository: repo,
                accountId: repo.snapshot.profile!.id,
                contextId: 'draft:green',
                attachments: attachments,
                onChanged: (media) => setState(() => attachments = media),
                onError: errors.add,
                recordingDirectory: () async => '/fixture',
                removeRecordingFile: (path) async => deleted.add(path),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await revealAndTap(tester, find.byKey(const Key('media-add-audio')));
      await tester.pump(const Duration(seconds: 2));
      await revealAndTap(tester, find.byKey(const Key('media-add-audio')));
      await tester.tap(find.byKey(const Key('audio-review-add')));
      await tester.pumpAndSettle();
      expect(attachments, isEmpty);
      expect(deleted, isEmpty);
      expect(errors.single, contains('附件暂存失败'));
      await tester.tap(find.byKey(const Key('audio-resume-review')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('audio-review-add')));
      await tester.pumpAndSettle();
      expect(attachments, hasLength(1));
      expect(deleted, [recorder.path]);
      expectNoLayoutException(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'discarded recording removes only its own temp file and creates no stage',
    (tester) async {
      configureTestView(tester);
      final previous = RecordPlatform.instance;
      final recorder = _RecorderPlatform();
      RecordPlatform.instance = recorder;
      addTearDown(() {
        RecordPlatform.instance = previous;
        return recorder.states.close();
      });
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      final deleted = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaComposer(
              repository: repo,
              accountId: repo.snapshot.profile!.id,
              contextId: 'draft:green',
              attachments: const [],
              onChanged: (_) => fail('Discard must not add an attachment.'),
              onError: fail,
              recordingDirectory: () async => '/fixture',
              removeRecordingFile: (path) async => deleted.add(path),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await revealAndTap(tester, find.byKey(const Key('media-add-audio')));
      await tester.pump(const Duration(seconds: 2));
      await revealAndTap(tester, find.byKey(const Key('media-add-audio')));
      await tester.tap(find.text('放弃'));
      await tester.pumpAndSettle();
      expect(deleted, [recorder.path]);
      expect(repo.stagedMedia, isEmpty);
      expectNoLayoutException(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'removed draft media is cleaned only after the new draft is persisted',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      final media = await repo.stageMedia(
        '/fixture/voice.m4a',
        MediaKind.audio,
      );
      repo.snapshot = repo.snapshot.copyWith(
        draft: '一段发现',
        draftAttachments: [media],
      );
      final gate = Completer<void>();
      repo.draftSaveGate = gate.future;
      await tester.pumpWidget(
        MaterialApp(
          home: RecordPage(
            repository: repo,
            quest: questById('green'),
            initialDraft: '一段发现',
            initialAttachments: [media],
            accountId: repo.snapshot.profile!.id,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await revealAndTap(tester, find.byKey(Key('media-remove-${media.id}')));
      await tester.pump(const Duration(seconds: 1));
      expect(repo.draftSaves, 1);
      expect(repo.discardMediaCalls, isEmpty);
      expect(repo.stagedMedia, contains(media.id));
      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.snapshot.draftAttachments, isEmpty);
      expect(repo.discardedMedia, [media.id]);
      expectNoLayoutException(tester);
    },
  );

  testWidgets('opening a draft obtains branch context before allowing edits', (
    tester,
  ) async {
    configureTestView(tester);
    final repo = await createLocalFixture(fixture: LocalFixture.active);
    repo.snapshot = repo.snapshot.copyWith(draft: '仓储里的草稿');
    final gate = Completer<void>();
    repo.editorOpenGate = gate.future;
    await tester.pumpWidget(
      MaterialApp(
        home: RecordPage(
          repository: repo,
          quest: questById('green'),
          initialDraft: '旧页面缓存',
          accountId: repo.snapshot.profile!.id,
        ),
      ),
    );
    await tester.pump();
    final field = find.byKey(const Key('record-text-field'));
    expect(tester.widget<TextField>(field).readOnly, isTrue);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('record-complete-action')))
          .onPressed,
      isNull,
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(field).readOnly, isFalse);
    expect(tester.widget<TextField>(field).controller!.text, '仓储里的草稿');
    expectNoLayoutException(tester);
  });

  for (final canonicalQuest in ['green', 'light']) {
    testWidgets(
      'a changed branch on $canonicalQuest cannot receive an old editor completion',
      (tester) async {
        configureTestView(tester);
        final repo = await createLocalFixture(fixture: LocalFixture.active);
        repo.snapshot = repo.snapshot.copyWith(draft: '原来的发现');
        await tester.pumpWidget(
          MaterialApp(
            home: RecordPage(
              repository: repo,
              quest: questById('green'),
              initialDraft: '原来的发现',
              accountId: repo.snapshot.profile!.id,
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const Key('record-text-field')),
          '尚未同步的发现',
        );
        repo.branchId = 'new-canonical-branch';
        repo.snapshot = repo.snapshot.copyWith(
          activeQuestId: canonicalQuest,
          draft: '云端当前草稿',
        );
        await tester.tap(find.byKey(const Key('record-complete-action')));
        await tester.pumpAndSettle();
        expect(repo.snapshot.draft, '云端当前草稿');
        expect(repo.snapshot.entries, isEmpty);
        expect(repo.snapshot.conflictDrafts.single.text, '尚未同步的发现');
        expect(find.byKey(const Key('record-conflict-notice')), findsOneWidget);
        expect(find.byType(RecordPage), findsOneWidget);
        await tester.enterText(
          find.byKey(const Key('record-text-field')),
          '旧分支的补充',
        );
        await tester.pump(const Duration(seconds: 1));
        await tester.pumpAndSettle();
        expect(repo.snapshot.draft, '云端当前草稿');
        expect(repo.snapshot.conflictDrafts.single.text, '旧分支的补充');
        await tester.tap(find.byKey(const Key('record-complete-action')));
        await tester.pumpAndSettle();
        expect(repo.snapshot.entries.single.text, '旧分支的补充');
        expect(repo.snapshot.activeQuestId, canonicalQuest);
        expect(repo.snapshot.draft, '云端当前草稿');
        expect(repo.snapshot.conflictDrafts, isEmpty);
        expectNoLayoutException(tester);
      },
    );
  }

  testWidgets(
    'closing a viewer before headers arrive does not create a late player',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      final gate = Completer<void>();
      repo.mediaHeadersGate = gate.future;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaViewer(media: mixedAttachments[1], repository: repo),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      gate.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expectNoLayoutException(tester);
    },
  );

  testWidgets(
    'conflict completion saves a record without replacing canonical progress',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      repo.snapshot = repo.snapshot.copyWith(
        activeQuestId: 'light',
        recommendedQuestId: 'light',
        draft: '云端草稿',
        conflictDrafts: [
          ConflictDraft(
            id: 'old-branch',
            questId: 'green',
            text: '旧分支发现',
            createdAt: DateTime(2026, 10, 10),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RecordPage(
            repository: repo,
            quest: questById('green'),
            initialDraft: '旧分支发现',
            accountId: repo.snapshot.profile!.id,
            conflictDraftId: 'old-branch',
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('record-complete-action')));
      await tester.pumpAndSettle();
      expect(repo.snapshot.activeQuestId, 'light');
      expect(repo.snapshot.draft, '云端草稿');
      expect(repo.snapshot.entries.single.text, '旧分支发现');
      expect(repo.snapshot.conflictDrafts, isEmpty);
      expectNoLayoutException(tester);
    },
  );

  testWidgets(
    'auto draft waits one second and never blocks typing; complete drains it',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      final gate = Completer<void>();
      repo.draftSaveGate = gate.future;
      await tester.pumpWidget(
        MaterialApp(
          home: RecordPage(
            repository: repo,
            quest: questById('green'),
            initialDraft: '',
            accountId: repo.snapshot.profile!.id,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('record-text-field'));
      await tester.enterText(field, '第一句');
      await tester.pump(const Duration(milliseconds: 999));
      expect(repo.draftSaves, 0);
      await tester.pump(const Duration(milliseconds: 1));
      expect(repo.draftSaves, 1);
      expect(tester.widget<TextField>(field).readOnly, isFalse);
      await tester.enterText(field, '第一句，第二句');
      expect(tester.widget<TextField>(field).controller!.text, '第一句，第二句');
      gate.complete();
      await tester.pumpAndSettle();
      expect(repo.snapshot.draft, '第一句，第二句');
      expect(find.text('草稿已存本机'), findsOneWidget);
      expectNoLayoutException(tester);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    '500 code points and mixed attachments persist together without upload wait',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      repo.snapshot = repo.snapshot.copyWith(
        draftAttachments: mixedAttachments,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RecordPage(
            repository: repo,
            quest: questById('green'),
            initialDraft: '',
            initialAttachments: mixedAttachments,
            accountId: repo.snapshot.profile!.id,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const Key('record-text-field'));
      final text = List.filled(500, '😀').join();
      await tester.enterText(field, text);
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
      expect(repo.snapshot.draft.runes.length, 500);
      expect(
        repo.snapshot.draftAttachments.map((m) => m.kind),
        MediaKind.values,
      );
      await tester.tap(find.byKey(const Key('record-complete-action')));
      await tester.pumpAndSettle();
      expect(repo.completeCalls, 1);
      expect(repo.snapshot.entries.single.attachments.length, 3);
      expect(repo.snapshot.entries.single.syncStatus, 'pending');
      expect(repo.lastAllowMetered, isNull);
      expectNoLayoutException(tester);
    },
  );

  testWidgets(
    'mixed media editor stays reachable with short screen and keyboard',
    (tester) async {
      configureTestView(tester, size: const Size(320, 568), textScale: 1.3);
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      repo.snapshot = repo.snapshot.copyWith(
        draft: '今天的发现',
        draftAttachments: mixedAttachments,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: RecordPage(
            repository: repo,
            quest: questById('green'),
            initialDraft: '今天的发现',
            initialAttachments: mixedAttachments,
            accountId: repo.snapshot.profile!.id,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await revealAndExpectReachable(
        tester,
        find.byKey(const Key('media-add-image')),
        scrollableKey: const Key('record-scroll'),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 240);
      await tester.pumpAndSettle();
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('record-complete-action')),
        keyboardInset: 240,
      );
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('record-save-draft-action')),
        keyboardInset: 240,
      );
      expectNoLayoutException(tester);
    },
  );

  testWidgets(
    'sharing defaults to zero images and uses an independent preview',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.completed);
      final entry = repo.snapshot.entries.single.copyWith(
        attachments: mixedAttachments,
        syncStatus: 'saved',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ShareSelectionPage(entry: entry, repository: repo),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选 0 张图片'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('share-select-image-one')),
            )
            .value,
        isFalse,
      );
      expect(find.byKey(const Key('share-select-video-one')), findsNothing);
      expect(find.byKey(const Key('share-select-audio-one')), findsNothing);
      await tester.tap(find.byKey(const Key('share-preview-action')));
      await tester.pumpAndSettle();
      expect(find.byType(SharePreviewPage), findsOneWidget);
      final preview = find.byKey(const Key('share-card-content'));
      expect(
        find.descendant(of: preview, matching: find.byType(PrivateMediaImage)),
        findsNothing,
      );
      expect(
        find.descendant(of: preview, matching: find.text('小叶子')),
        findsNothing,
      );
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('share-confirm-action')),
      );
      expectNoLayoutException(tester);
    },
  );

  testWidgets('canceling an edit leaves bound media untouched', (tester) async {
    configureTestView(tester);
    final repo = await createLocalFixture(fixture: LocalFixture.completed);
    final entry = repo.snapshot.entries.single.copyWith(
      attachments: mixedAttachments,
      syncStatus: 'saved',
    );
    repo.snapshot = repo.snapshot.copyWith(entries: [entry]);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<JournalEntry>(
                  builder: (_) => EntryEditor(entry: entry, repository: repo),
                ),
              ),
              child: const Text('编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await revealAndTap(tester, find.byKey(const Key('media-remove-image-one')));
    await tester.tap(find.byKey(const Key('entry-editor-back')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(repo.editCalls, 0);
    expect(repo.snapshot.entries.single.attachments.length, 3);
    expect(repo.discardMediaCalls, isEmpty);
    expectNoLayoutException(tester);
  });

  for (final save in [false, true]) {
    testWidgets(
      save ? 'saving an edit keeps newly submitted media' : 'canceling an edit cleans new staged media but not original attachments',
      (tester) async {
        configureTestView(tester);
        final repo = await createLocalFixture(fixture: LocalFixture.completed);
        final original = repo.snapshot.entries.single.copyWith(
          attachments: [mixedAttachments.last],
          syncStatus: 'saved',
        );
        repo.snapshot = repo.snapshot.copyWith(entries: [original]);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<JournalEntry>(
                      builder: (_) =>
                          EntryEditor(entry: original, repository: repo),
                    ),
                  ),
                  child: const Text('编辑'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('编辑'));
        await tester.pumpAndSettle();
        final newMedia = await repo.stageMedia(
          '/fixture/new.mp4',
          MediaKind.video,
        );
        tester.widget<MediaComposer>(find.byType(MediaComposer)).onChanged([
          ...original.attachments,
          newMedia,
        ]);
        await tester.pumpAndSettle();
        if (save) {
          await tester.tap(find.byKey(const Key('entry-save-edit')));
          await tester.pumpAndSettle();
          expect(repo.editCalls, 1);
          expect(repo.discardedMedia, isEmpty);
          expect(repo.snapshot.entries.single.attachments.map((m) => m.id), [
            mixedAttachments.last.id,
            newMedia.id,
          ]);
        } else {
          await tester.tap(find.byKey(const Key('entry-editor-back')));
          await tester.pumpAndSettle();
          await tester.tap(find.text('放弃修改'));
          await tester.pumpAndSettle();
          expect(repo.editCalls, 0);
          expect(repo.discardedMedia, [newMedia.id]);
          expect(
            repo.snapshot.entries.single.attachments,
            original.attachments,
          );
        }
        expectNoLayoutException(tester);
      },
    );
  }

  testWidgets(
    'text-only retry is explicit and preserves text and saved records',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.completed);
      final failed = repo.snapshot.entries.single.copyWith(
        attachments: mixedAttachments,
        syncStatus: 'failed',
        syncError: '附件处理失败',
      );
      final saved = JournalEntry(
        id: 'saved-media-entry',
        questId: 'light',
        questTitle: '原已保存记录',
        text: '原记录文字',
        createdAt: DateTime(2026, 10, 9),
        attachments: mixedAttachments,
      );
      final textOnly = JournalEntry(
        id: 'failed-text-entry',
        questId: 'light',
        questTitle: '仅文字',
        text: '文字记录',
        createdAt: DateTime(2026, 10, 9),
        syncStatus: 'failed',
      );
      repo.snapshot = repo.snapshot.copyWith(
        entries: [failed, saved, textOnly],
      );
      await tester.pumpWidget(
        MaterialApp(home: SyncStatusPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      final action = find.byKey(Key('sync-text-only-${failed.id}'));
      expect(action, findsOneWidget);
      expect(
        find.byKey(const Key('sync-text-only-saved-media-entry')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('sync-text-only-failed-text-entry')),
        findsNothing,
      );
      await revealAndTap(tester, action);
      expect(find.textContaining('原已保存的记录不受影响'), findsOneWidget);
      expect(repo.removedPendingAttachments, isEmpty);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(repo.removedPendingAttachments, isEmpty);
      await revealAndTap(tester, action);
      await tester.tap(find.text('移除附件并重试'));
      await tester.pumpAndSettle();
      expect(repo.removedPendingAttachments, [failed.id]);
      final changed = repo.snapshot.entries.firstWhere(
        (e) => e.id == failed.id,
      );
      expect(changed.text, failed.text);
      expect(changed.attachments, isEmpty);
      expect(changed.syncStatus, 'saved');
      expect(
        repo.snapshot.entries.firstWhere((e) => e.id == saved.id).attachments,
        mixedAttachments,
      );
      expect(repo.lastAllowMetered, isFalse);
      expectNoLayoutException(tester);
    },
  );

  testWidgets(
    'already committed text-only retry shows the online-edit instruction',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.completed);
      final entry = repo.snapshot.entries.single.copyWith(
        attachments: mixedAttachments,
        syncStatus: 'failed',
      );
      repo.snapshot = repo.snapshot.copyWith(entries: [entry]);
      repo.pendingRemovalError = '记录已经保存，请到记录详情在线编辑附件。';
      await tester.pumpWidget(
        MaterialApp(home: SyncStatusPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      await revealAndTap(tester, find.byKey(Key('sync-text-only-${entry.id}')));
      await tester.tap(find.text('移除附件并重试'));
      await tester.pumpAndSettle();
      expect(find.text(repo.pendingRemovalError!), findsOneWidget);
      expect(repo.removedPendingAttachments, isEmpty);
      expect(repo.snapshot.entries.single.attachments, mixedAttachments);
      expectNoLayoutException(tester);
    },
  );

  testWidgets(
    'sync now asks for metered batch permission and exposes conflicts',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.completed);
      repo.snapshot = repo.snapshot.copyWith(
        conflictDrafts: [
          ConflictDraft(
            id: 'conflict-one',
            questId: 'green',
            text: '保留的发现',
            createdAt: DateTime(2026, 10, 10),
          ),
        ],
      );
      await tester.pumpWidget(
        MaterialApp(home: SyncStatusPage(repository: repo)),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('conflict-resume-conflict-one')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('conflict-delete-conflict-one')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('sync-upload-now')));
      await tester.pumpAndSettle();
      expect(repo.lastAllowMetered, isNull);
      expect(find.textContaining('只上传确认时队列'), findsOneWidget);
      await tester.tap(find.text('立即上传'));
      await tester.pumpAndSettle();
      expect(repo.lastAllowMetered, isTrue);
      expect(find.text('待上传 0 · 上传中 0 · 失败 0'), findsOneWidget);
      expectNoLayoutException(tester);
    },
  );

  testWidgets(
    'search ignores stale responses and pagination de-duplicates record ids',
    (tester) async {
      configureTestView(tester);
      final repo = await createLocalFixture(fixture: LocalFixture.completed);
      final first = repo.snapshot.entries.single;
      final second = JournalEntry(
        id: 'second',
        questId: 'green',
        questTitle: '另一条',
        text: '新查询',
        createdAt: DateTime(2026, 10, 10),
      );
      final old = Completer<EntryPageResult>();
      repo.queryOverride = (query, cursor) async {
        if (query == '旧') return old.future;
        if (query == '新') return EntryPageResult(entries: [second], total: 1);
        return EntryPageResult(
          entries: cursor == null ? [first] : [first, second],
          nextCursor: cursor == null ? 'page2' : null,
          total: 2,
        );
      };
      await pumpSideQuest(tester, repo);
      await tester.tap(find.text('探索册'));
      await tester.pumpAndSettle();
      await revealAndTap(
        tester,
        find.byKey(const Key('journal-load-more')),
        scrollableKey: const Key('journal-scroll'),
      );
      expect(find.byKey(ValueKey('journal-entry-${first.id}')), findsOneWidget);
      final search = find.byKey(const Key('journal-search-field'));
      await tester.ensureVisible(search);
      await tester.enterText(search, '旧');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.enterText(search, '新');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      old.complete(EntryPageResult(entries: [first], total: 1));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('journal-entry-second')), findsOneWidget);
      expect(find.byKey(ValueKey('journal-entry-${first.id}')), findsNothing);
      expectNoLayoutException(tester);
    },
  );
}
