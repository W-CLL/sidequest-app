import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sidequest/domain.dart';
import 'package:sidequest/offline_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory directory;
  late OfflineStore store;
  late DateTime now;
  late OfflineAccount account;

  AppSnapshot cloud({String id = 'account-a', int revision = 0}) => AppSnapshot(
    day: '2026-10-10',
    profile: UserProfile(
      id: id,
      nickname: id,
      role: 'student',
      preferences: const [],
    ),
    progressRevision: revision,
  );

  OfflineStore createStore([String namespace = 'service-a']) => OfflineStore(
    databaseFactory: databaseFactoryFfi,
    databasePath: p.join(directory.path, 'store.sqlite'),
    mediaRoot: p.join(directory.path, 'private'),
    namespace: namespace,
    now: () => now,
  );

  Future<void> command(
    String id, {
    String type = 'claim',
    Map<String, dynamic>? payload,
    AppSnapshot? snapshot,
    JournalEntry? entry,
  }) => store.mutateWithCommand(
    accountId: account.id,
    snapshot: snapshot ?? account.snapshot,
    commandId: id,
    type: type,
    payload: payload ?? {'questId': 'green'},
    pendingEntry: entry,
  );

  Future<OfflineMedia> media([String name = 'source.jpg']) async {
    final source = File(p.join(directory.path, name));
    await source.writeAsBytes(List.filled(12, 1), flush: true);
    return store.stageMedia(
      accountId: account.id,
      sourcePath: source.path,
      kind: MediaKind.image,
      mimeType: 'image/jpeg',
      byteSize: 12,
    );
  }

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('sidequest-store-test-');
    now = DateTime.utc(2026, 10, 10);
    store = createStore();
    account = await store.activateFromCloud(cloud());
  });
  tearDown(() async {
    await store.close();
    await directory.delete(recursive: true);
  });

  test(
    'expired lease releases captured batches but preserves exact sent wire',
    () async {
      await command('command-a');
      expect(await store.acquireLease('worker-a'), isTrue);
      final batch = (await store.captureBatch(
        accountId: account.id,
        wifi: true,
        allowMetered: false,
      ))!;
      final wire = {
        'commandId': 'command-a',
        'type': 'claim',
        'payload': {'questId': 'green'},
      };
      await store.persistWireCommand(account.id, 'command-a', wire);
      expect(await store.acquireLease('worker-a'), isTrue);
      expect(
        await store.captureBatch(
          accountId: account.id,
          wifi: true,
          allowMetered: false,
        ),
        isNull,
      );
      expect(await store.acquireLease('worker-b'), isFalse);
      now = now.add(const Duration(minutes: 6));
      expect(await store.renewLease('worker-a'), isFalse);
      expect(await store.acquireLease('worker-b'), isTrue);
      final recovered = (await store.captureBatch(
        accountId: account.id,
        wifi: true,
        allowMetered: false,
      ))!;
      expect(recovered.batchId, isNot(batch.batchId));
      expect(recovered.commands.single.wireJson, wire);
      expect(await store.ownsLease('worker-a'), isFalse);
    },
  );

  test(
    'sent wire is immutable until server explicitly reports missing',
    () async {
      await command('command-a');
      final first = {
        'commandId': 'command-a',
        'type': 'claim',
        'payload': {'questId': 'green'},
      };
      final changed = {
        'commandId': 'command-a',
        'type': 'claim',
        'payload': {'questId': 'light'},
      };
      await store.persistWireCommand(account.id, 'command-a', first);
      await expectLater(
        store.persistWireCommand(account.id, 'command-a', changed),
        throwsA(isA<QuestException>()),
      );
      await store.close();
      store = createStore();
      expect(
        (await store.commandsForBranch(account.activeBranchId)).single.wireJson,
        first,
      );
      await store.clearMissingWireCommands(account.id, ['command-a']);
      await store.persistWireCommand(account.id, 'command-a', changed);
    },
  );

  test(
    'mobile authorization is an atomic snapshot and spans multiple batches',
    () async {
      for (var i = 0; i < 12; i++) {
        await command('before-$i');
      }
      await store.authorizeMeteredSnapshot(account.id);
      await command('after');
      final one = (await store.captureBatch(
        accountId: account.id,
        wifi: false,
        allowMetered: false,
      ))!;
      final two = (await store.captureBatch(
        accountId: account.id,
        wifi: false,
        allowMetered: false,
      ))!;
      expect(one.commands.length, 10);
      expect(two.commands.length, 2);
      expect(one.meteredAuthorized && two.meteredAuthorized, isTrue);
      expect(
        await store.captureBatch(
          accountId: account.id,
          wifi: false,
          allowMetered: false,
        ),
        isNull,
      );
    },
  );

  test(
    'completion tombstone removes pending ghost without recreating its media',
    () async {
      final item = await media();
      final entry = JournalEntry(
        id: 'record-a',
        questId: 'green',
        questTitle: '绿色',
        text: '记录',
        createdAt: now,
        attachments: [item.attachment],
        syncStatus: 'pending',
      );
      await command(
        'complete-a',
        type: 'complete',
        snapshot: account.snapshot.copyWith(entries: [entry], entryCount: 1),
        entry: entry,
        payload: {
          'clientRecordId': entry.id,
          'questId': 'green',
          'text': '记录',
          'mediaIds': [item.clientId],
        },
      );
      final batch = (await store.captureBatch(
        accountId: account.id,
        wifi: true,
        allowMetered: false,
      ))!;
      final applied = await store.applySyncResult(
        accountId: account.id,
        batch: batch,
        cloudState: cloud(revision: 2),
        branchMode: 'active',
        receipts: [
          {'commandId': 'complete-a', 'entryId': 'record-a'},
        ],
        savedEntries: [],
      );
      expect(await store.localEntries(account.id), isEmpty);
      expect(applied.snapshot.entries, isEmpty);
      expect(applied.snapshot.entryCount, 0);
      expect(await store.pendingCommandCount(account.id), 0);
      expect(await store.pendingCleanupPaths(), [item.localPath]);
    },
  );

  test('foreign cloud state and foreign receipt are rejected without deleting outbox', () async {
    await command('own-command');
    final batch = (await store.captureBatch(
      accountId: account.id,
      wifi: true,
      allowMetered: false,
    ))!;
    await expectLater(
      store.adoptCloud(account.id, cloud(id: 'account-b')),
      throwsA(isA<QuestException>()),
    );
    await expectLater(
      store.applySyncResult(
        accountId: account.id,
        batch: batch,
        cloudState: cloud(),
        branchMode: 'active',
        receipts: [
          {'commandId': 'other-command'},
        ],
        savedEntries: [],
      ),
      throwsA(isA<QuestException>()),
    );
    expect(await store.pendingCommandCount(account.id), 1);
  });

  test('paused conflicting draft preserves text and attachments', () async {
    final item = await media();
    final paused = account.snapshot.copyWith(
      draft: '暂停的草稿',
      draftAttachments: [item.attachment],
    );
    await command(
      'draft-a',
      type: 'draft',
      snapshot: paused,
      payload: {
        'questId': 'green',
        'text': '暂停的草稿',
        'mediaIds': [item.clientId],
      },
    );
    await command('stop-a', type: 'stop', snapshot: paused, payload: {});
    final batch = (await store.captureBatch(
      accountId: account.id,
      wifi: true,
      allowMetered: false,
    ))!;
    final applied = await store.applySyncResult(
      accountId: account.id,
      batch: batch,
      cloudState: cloud(revision: 3),
      branchMode: 'records_only',
      receipts: [],
      savedEntries: [],
    );
    expect(applied.snapshot.conflictDrafts.single.text, '暂停的草稿');
    expect(applied.snapshot.conflictDrafts.single.questId, 'green');
    expect(
      (await store.discardStagedMedia(account.id, [
        item.clientId,
      ])).cleanupPaths,
      isEmpty,
    );
  });

  test(
    'source quota and reset use original bytes after server descriptor changes',
    () async {
      final item = await media();
      await store.updateMedia(
        clientId: item.clientId,
        serverId: 'server-a',
        state: 'reserved',
        attachment: item.attachment.copyWith(id: 'server-a', byteSize: 0),
      );
      await store.resetMediaReservation(item.clientId);
      expect(
        (await store.mediaById(account.id, item.clientId))!.attachment.byteSize,
        12,
      );
      final db = await store.database;
      await db.update(
        'media',
        {'source_bytes': OfflineStore.maxDeviceBytes},
        where: 'client_id = ?',
        whereArgs: [item.clientId],
      );
      await expectLater(media('second.jpg'), throwsA(isA<QuestException>()));
      expect((await db.query('media')).length, 1);
    },
  );

  test('same remote IDs are isolated across service namespaces', () async {
    final first = await media();
    await store.updateMedia(
      clientId: first.clientId,
      serverId: 'cloned-media',
      state: 'ready',
    );
    final other = createStore('service-b');
    final otherAccount = await other.activateFromCloud(cloud());
    final second = await other.stageMedia(
      accountId: otherAccount.id,
      sourcePath: p.join(directory.path, 'source.jpg'),
      kind: MediaKind.image,
      mimeType: 'image/jpeg',
      byteSize: 12,
    );
    await other.updateMedia(
      clientId: second.clientId,
      serverId: 'cloned-media',
      state: 'ready',
    );
    expect(otherAccount.id, isNot(account.id));
    expect((await store.activeAccount())!.id, account.id);
    expect(
      (await other.mediaById(otherAccount.id, 'cloned-media'))!.clientId,
      second.clientId,
    );
    await other.close();
    expect((await store.activeAccount())!.id, account.id);
  });

  test('discard refuses referenced files and stale staging cleanup ignores unknown files', () async {
    final item = await media();
    final draft = account.snapshot.copyWith(
      draft: '草稿',
      draftAttachments: [item.attachment],
    );
    await command(
      'draft-a',
      type: 'draft',
      snapshot: draft,
      payload: {
        'questId': 'green',
        'text': '草稿',
        'mediaIds': [item.clientId],
      },
    );
    expect(
      (await store.discardStagedMedia(account.id, [
        item.clientId,
      ])).cleanupPaths,
      isEmpty,
    );
    final abandoned = await media('abandoned.jpg');
    final unknown = File(p.join(await store.mediaRootPath, 'unknown.partial'));
    await unknown.writeAsBytes([1]);
    final partial = '${abandoned.localPath}.partial';
    await File(abandoned.localPath!).copy(partial);
    await (await store.database).update(
      'media',
      {'state': 'staging', 'staging_path': partial},
      where: 'client_id = ?',
      whereArgs: [abandoned.clientId],
    );
    now = now.add(const Duration(hours: 2));
    final cleanup = await store.pendingCleanupPaths();
    expect(cleanup, containsAll([abandoned.localPath, partial]));
    expect(cleanup, isNot(contains(item.localPath)));
    expect(cleanup, isNot(contains(unknown.path)));
    expect(
      await store.isManagedMediaPath(p.join(directory.path, 'source.jpg')),
      isFalse,
    );
    expect(await unknown.exists(), isTrue);
  });

  test('same quest on a newer branch rejects stale writes and preserves a separate draft', () async {
    final oldBranch = account.activeBranchId;
    final item = await media();
    final canonical = cloud(revision: 2)
        .copyWith(activeQuestId: 'green', draft: '云端当前草稿');
    await store.adoptCloud(account.id, canonical);
    await expectLater(
      store.mutateWithCommand(
        accountId: account.id,
        snapshot: canonical.copyWith(draft: '旧页面文字'),
        commandId: 'stale-command',
        type: 'draft',
        payload: {'questId': 'green', 'text': '旧页面文字', 'mediaIds': []},
        expectedBranchId: oldBranch,
      ),
      throwsA(isA<OfflineBranchChangedException>()),
    );
    final preserved = await store.saveStaleEditorDraft(
      accountId: account.id,
      branchId: oldBranch,
      questId: 'green',
      text: '旧页面刚输入的文字',
      attachments: [item.attachment],
    );
    expect(preserved.draft, '云端当前草稿');
    expect(preserved.activeQuestId, 'green');
    expect(preserved.conflictDrafts.single.text, '旧页面刚输入的文字');
    expect(preserved.conflictDrafts.single.baseRevision, 0);
    final replaced = await store.saveStaleEditorDraft(
      accountId: account.id,
      branchId: oldBranch,
      questId: 'green',
      text: '第二次编辑',
      attachments: [],
    );
    expect(replaced.conflictDrafts.length, 1);
    expect(
      replaced.conflictDrafts.single.id,
      preserved.conflictDrafts.single.id,
    );
    expect(replaced.draft, '云端当前草稿');
    expect(
      (await store.discardStagedMedia(account.id, [
        item.clientId,
      ])).cleanupPaths,
      [item.localPath],
    );
  });

  test(
    'an unchanged foreground refresh preserves the open editor branch',
    () async {
      final initial = account.activeBranchId;
      await store.adoptCloud(account.id, cloud());
      await store.adoptCloud(account.id, cloud());
      expect((await store.activeAccount())!.activeBranchId, initial);
    },
  );

  test(
    'expired worker cannot commit wire or apply receipts after takeover',
    () async {
      await command('command-a');
      await store.acquireLease('old-worker');
      final batch = (await store.captureBatch(
        accountId: account.id,
        wifi: true,
        allowMetered: false,
      ))!;
      now = now.add(const Duration(minutes: 6));
      await store.acquireLease('new-worker');
      await expectLater(
        store.persistWireCommand(account.id, 'command-a', {
          'commandId': 'command-a',
          'type': 'claim',
          'payload': {'questId': 'green'},
        }, leaseOwner: 'old-worker'),
        throwsA(isA<QuestException>()),
      );
      await expectLater(
        store.applySyncResult(
          accountId: account.id,
          batch: batch,
          cloudState: cloud(),
          branchMode: 'active',
          receipts: [
            {'commandId': 'command-a'},
          ],
          savedEntries: [],
          leaseOwner: 'old-worker',
        ),
        throwsA(isA<QuestException>()),
      );
      expect(await store.pendingCommandCount(account.id), 1);
    },
  );

  test('a partial response preserves remaining completed records and correct count', () async {
    final entries = [
      for (var i = 0; i < 2; i++)
        JournalEntry(
          id: 'record-$i',
          questId: 'green',
          questTitle: '绿色',
          text: '记录$i',
          createdAt: now,
          syncStatus: 'pending',
        ),
    ];
    for (var i = 0; i < 2; i++) {
      await command(
        'complete-$i',
        type: 'complete',
        entry: entries[i],
        snapshot: account.snapshot.copyWith(
          entries: entries.take(i + 1).toList(),
          entryCount: i + 1,
        ),
        payload: {
          'clientRecordId': entries[i].id,
          'questId': 'green',
          'text': '记录$i',
          'mediaIds': [],
        },
      );
    }
    final batch = (await store.captureBatch(
      accountId: account.id,
      wifi: true,
      allowMetered: false,
    ))!;
    final result = await store.applySyncResult(
      accountId: account.id,
      batch: batch,
      cloudState: cloud(revision: 3),
      branchMode: 'records_only',
      receipts: [
        {'commandId': 'complete-0', 'entryId': 'record-0'},
      ],
      savedEntries: [],
    );
    expect(result.snapshot.entries.map((entry) => entry.id), ['record-1']);
    expect(result.snapshot.entryCount, 1);
    expect(await store.pendingCommandCount(account.id), 1);
  });

  test(
    'logout purge keeps failed cleanup bytes reserved until actual deletion',
    () async {
      final item = await media();
      await (await store.database).update(
        'media',
        {'source_bytes': OfflineStore.maxDeviceBytes},
        where: 'client_id = ?',
        whereArgs: [item.clientId],
      );
      final paths = await store.purgeAccount(account.id);
      account = await store.activateFromCloud(cloud(id: 'account-b'));
      await expectLater(media('next.jpg'), throwsA(isA<QuestException>()));
      await File(paths.single).delete();
      await store.markPathCleaned(paths.single);
      expect((await media('next.jpg')).sourceBytes, 12);
    },
  );

  test('login snapshot entries are available offline and lists cannot acknowledge pending work', () async {
    final saved = JournalEntry(
      id: 'saved',
      questId: 'green',
      questTitle: '绿色',
      text: '已保存',
      createdAt: now,
    );
    await store.activateFromCloud(
      cloud().copyWith(entries: [saved], entryCount: 1),
    );
    expect((await store.localEntries(account.id)).single.id, 'saved');
    final pending = JournalEntry(
      id: 'pending',
      questId: 'green',
      questTitle: '绿色',
      text: '响应丢失',
      createdAt: now,
      syncStatus: 'pending',
    );
    await command(
      'complete-pending',
      type: 'complete',
      entry: pending,
      payload: {
        'clientRecordId': pending.id,
        'questId': 'green',
        'text': '响应丢失',
        'mediaIds': [],
      },
    );
    await store.cacheEntries(account.id, [
      pending.copyWith(syncStatus: 'saved'),
    ]);
    expect(await store.isPendingEntry(account.id, pending.id), isTrue);
  });

  test(
    'closing one wrapper never closes another connection to the same database',
    () async {
      final other = createStore();
      expect((await other.activeAccount())!.id, account.id);
      await other.close();
      await command('still-open');
      expect(await store.pendingCommandCount(account.id), 1);
    },
  );

  test(
    'closed wrappers cannot reopen and close waits for an opening connection',
    () async {
      final openingStore = createStore();
      final opening = openingStore.database;
      final closing = openingStore.close();
      final db = await opening;
      await closing;
      expect(db.isOpen, isFalse);
      await openingStore.close();
      await expectLater(openingStore.database, throwsStateError);
      await expectLater(openingStore.activeAccount(), throwsStateError);
      await expectLater(openingStore.mediaRootPath, throwsStateError);
      expect((await store.activeAccount())!.id, account.id);
    },
  );

  test(
    'closing an unsuccessfully opening wrapper does not repeat the open error',
    () async {
      final corrupt = File(p.join(directory.path, 'invalid.sqlite'));
      await corrupt.writeAsString('not a sqlite database', flush: true);
      final broken = OfflineStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: corrupt.path,
      );
      final opening = expectLater(
        broken.database,
        throwsA(isA<DatabaseException>()),
      );
      await Future.wait([opening, broken.close()]);
      await broken.close();
      await expectLater(broken.database, throwsStateError);
    },
  );

  test(
    'two connections serialize high-frequency reads writes and lease work',
    () async {
      await store.close();
      OfflineStore freshStore() => OfflineStore(
        databaseFactory: databaseFactoryFfi,
        databasePath: p.join(directory.path, 'concurrent.sqlite'),
        mediaRoot: p.join(directory.path, 'private'),
        namespace: 'service-a',
        now: () => now,
      );
      store = freshStore();
      final other = freshStore();
      try {
        // Both wrappers open and configure the same initially absent schema.
        final connections = await Future.wait([store.database, other.database]);
        expect(identical(connections[0], connections[1]), isFalse);
        account = await store.activateFromCloud(cloud());
        await Future.wait([
          () async {
            for (var i = 0; i < 80; i++) {
              await command('foreground-$i');
              await store.markRequiresLogin(account.id, i.isOdd);
            }
          }(),
          () async {
            for (var i = 0; i < 80; i++) {
              await other.mutateWithCommand(
                accountId: account.id,
                snapshot: account.snapshot,
                commandId: 'background-$i',
                type: 'draft',
                payload: {
                  'questId': 'green',
                  'text': 'draft-$i',
                  'mediaIds': [],
                },
              );
              await other.authorizeMeteredSnapshot(account.id);
            }
          }(),
          () async {
            for (var i = 0; i < 100; i++) {
              final reads = await Future.wait([
                store.activeAccount(),
                other.activeAccount(),
                store.summary(account.id),
                other.summary(account.id),
              ]);
              expect((reads[0] as OfflineAccount).id, account.id);
              expect((reads[1] as OfflineAccount).id, account.id);
            }
          }(),
          () async {
            for (var i = 0; i < 80; i++) {
              expect(await other.acquireLease('background-worker'), isTrue);
              expect(await store.acquireLease('foreground-worker'), isFalse);
              expect(await other.renewLease('background-worker'), isTrue);
              expect(await store.ownsLease('background-worker'), isTrue);
              await other.releaseLease('background-worker');
            }
          }(),
        ]);
        expect(await store.pendingCommandCount(account.id), 160);
        expect(await other.pendingCommandCount(account.id), 160);
        expect((await store.summary(account.id)).queuedCommands, 160);
        await other.close();
        await command('after-background-disposal');
        expect(await store.pendingCommandCount(account.id), 161);
      } finally {
        await other.close();
      }
    },
  );

  test('native SQLite contention retries asynchronously after the owner releases', () async {
    final other = createStore();
    final acquired = Completer<void>();
    final release = Completer<void>();
    Future<void>? owner;
    try {
      final db = await other.database;
      // Bypass the in-isolate queue to simulate a writer in another isolate or
      // process. A native blocking busy timeout would prevent this timer firing.
      owner = db.transaction((txn) async {
        await txn.update(
          'accounts',
          {'requires_login': 1},
          where: 'account_id = ?',
          whereArgs: [account.id],
        );
        acquired.complete();
        await release.future;
      });
      await acquired.future;
      final timer = Timer(const Duration(milliseconds: 80), release.complete);
      try {
        await command('after-native-contention');
      } finally {
        timer.cancel();
        if (!release.isCompleted) release.complete();
      }
      await owner;
      expect(await store.pendingCommandCount(account.id), 1);
      expect((await store.activeAccount())!.requiresLogin, isTrue);
    } finally {
      if (!release.isCompleted) release.complete();
      await owner;
      await other.close();
    }
  });

  test('record status derives from associated media and mixed media count only once', () async {
    final photo = await media('first.jpg');
    final secondPhoto = await media('second.jpg');
    final first = JournalEntry(
      id: 'mixed',
      questId: 'green',
      questTitle: '绿色',
      text: '混合记录',
      createdAt: now,
      attachments: [photo.attachment, secondPhoto.attachment],
      syncStatus: 'pending',
    );
    final second = JournalEntry(
      id: 'text',
      questId: 'green',
      questTitle: '绿色',
      text: '纯文字',
      createdAt: now,
      syncStatus: 'pending',
    );
    await command(
      'mixed-complete',
      type: 'complete',
      entry: first,
      snapshot: account.snapshot.copyWith(entries: [first]),
      payload: {
        'clientRecordId': first.id,
        'questId': 'green',
        'text': first.text,
        'mediaIds': [photo.clientId, secondPhoto.clientId],
      },
    );
    await command(
      'text-complete',
      type: 'complete',
      entry: second,
      snapshot: account.snapshot.copyWith(entries: [second, first]),
      payload: {
        'clientRecordId': second.id,
        'questId': 'green',
        'text': second.text,
        'mediaIds': [],
      },
    );
    await store.updateMedia(clientId: photo.clientId, state: 'processing');
    expect(
      (await store.localEntries(account.id))
          .firstWhere((e) => e.id == first.id)
          .syncStatus,
      'processing',
    );
    var summary = await store.summary(account.id);
    expect([summary.pending, summary.uploading, summary.failed], [1, 1, 0]);
    await store.updateMedia(clientId: secondPhoto.clientId, state: 'uploading');
    expect(
      (await store.localEntries(account.id))
          .firstWhere((e) => e.id == first.id)
          .syncStatus,
      'uploading',
    );
    await store.updateMedia(
      clientId: photo.clientId,
      state: 'failed',
      error: '解码失败',
    );
    await store.updateMedia(
      clientId: secondPhoto.clientId,
      state: 'failed',
      error: '另一个附件失败',
    );
    final projected = (await store.localEntries(account.id))
        .firstWhere((e) => e.id == first.id);
    expect(projected.syncStatus, 'failed');
    expect(projected.syncError, '解码失败');
    final snapshot = (await store.activeAccount())!.snapshot;
    expect(
      snapshot.entries.firstWhere((e) => e.id == first.id).syncError,
      '解码失败',
    );
    summary = await store.summary(account.id);
    expect(
      [
        summary.pending,
        summary.uploading,
        summary.failed,
        summary.queuedCommands,
      ],
      [1, 0, 1, 2],
    );
  });

  test(
    'pure JSON batch failure projects an error and a retry clears it',
    () async {
      final entry = JournalEntry(
        id: 'json-error',
        questId: 'green',
        questTitle: '绿色',
        text: '文字',
        createdAt: now,
        syncStatus: 'pending',
      );
      await command(
        'json-complete',
        type: 'complete',
        entry: entry,
        snapshot: account.snapshot.copyWith(entries: [entry]),
        payload: {
          'clientRecordId': entry.id,
          'questId': 'green',
          'text': entry.text,
          'mediaIds': [],
        },
      );
      final batch = (await store.captureBatch(
        accountId: account.id,
        wifi: true,
        allowMetered: false,
      ))!;
      expect(
        (await store.localEntries(account.id)).single.syncStatus,
        'uploading',
      );
      await store.markBatchError(account.id, batch.batchId, '服务拒绝本次操作');
      await store.releaseBatch(batch.batchId);
      expect(
        (await store.localEntries(account.id)).single.syncError,
        '服务拒绝本次操作',
      );
      expect(
        (await store.activeAccount())!.snapshot.entries.single.syncStatus,
        'failed',
      );
      expect((await store.summary(account.id)).failed, 1);
      await store.captureBatch(
        accountId: account.id,
        wifi: true,
        allowMetered: false,
      );
      expect(
        (await store.localEntries(account.id)).single.syncStatus,
        'uploading',
      );
      expect((await store.localEntries(account.id)).single.syncError, isNull);
    },
  );

  test(
    'progress-only work stays schedulable without inventing pending records',
    () async {
      await command('claim-only');
      await command(
        'draft-only',
        type: 'draft',
        payload: {'questId': 'green', 'text': '草稿', 'mediaIds': []},
      );
      final summary = await store.summary(account.id);
      expect([summary.pending, summary.uploading, summary.failed], [0, 0, 0]);
      expect(summary.queuedCommands, 2);
      expect(summary.hasPending, isTrue);
      expect(summary.message, '活动进度待同步');
    },
  );

  Future<({OfflineMedia media, JournalEntry entry})> repairFixture() async {
    final item = await media();
    final entry = JournalEntry(
      id: 'repair-record',
      questId: 'green',
      questTitle: '绿色',
      text: '保留文字',
      createdAt: now,
      attachments: [item.attachment],
      syncStatus: 'pending',
    );
    await command(
      'repair-draft',
      type: 'draft',
      snapshot: account.snapshot.copyWith(
        draft: entry.text,
        draftAttachments: [item.attachment],
      ),
      payload: {
        'questId': 'green',
        'text': entry.text,
        'mediaIds': [item.clientId],
      },
    );
    await command(
      'repair-complete',
      type: 'complete',
      entry: entry,
      snapshot: account.snapshot.copyWith(entries: [entry], entryCount: 1),
      payload: {
        'clientRecordId': entry.id,
        'questId': 'green',
        'text': entry.text,
        'mediaIds': [item.clientId],
        'createdAt': now.toIso8601String(),
      },
    );
    await command(
      'after-repair',
      type: 'next',
      payload: {},
      snapshot: account.snapshot.copyWith(entries: [entry], entryCount: 1),
    );
    return (media: item, entry: entry);
  }

  test('attachment repair requires missing proof for every already-sent draft and complete', () async {
    final fixture = await repairFixture();
    final commands = await store.pendingAttachmentRepairCommands(
      account.id,
      fixture.entry.id,
    );
    expect(commands.map((command) => command.commandId), [
      'repair-draft',
      'repair-complete',
    ]);
    for (final command in commands) {
      await store.persistWireCommand(account.id, command.commandId, {
        'commandId': command.commandId,
        'type': command.type,
        'payload': command.payload,
      });
    }
    await expectLater(
      store.stripPendingAttachments(
        account.id,
        fixture.entry.id,
        missingCommandIds: {'repair-complete'},
      ),
      throwsA(isA<QuestException>()),
    );
    expect((await store.localEntries(account.id)).single.attachments.length, 1);
  });

  test('repair preserves IDs order branch and source files until successful text acknowledgement', () async {
    final fixture = await repairFixture();
    final db = await store.database;
    final original = await db.query(
      'outbox',
      columns: ['command_id', 'sequence', 'branch_id'],
      orderBy: 'sequence',
    );
    final changed = await store.stripPendingAttachments(
      account.id,
      fixture.entry.id,
      missingCommandIds: {},
    );
    expect(changed.entries.single.id, fixture.entry.id);
    expect(changed.entries.single.text, fixture.entry.text);
    expect(changed.entries.single.attachments, isEmpty);
    expect(
      await db.query(
        'outbox',
        columns: ['command_id', 'sequence', 'branch_id'],
        orderBy: 'sequence',
      ),
      original,
    );
    final commands = await store.pendingAttachmentRepairCommands(
      account.id,
      fixture.entry.id,
    );
    expect(
      commands.every(
        (command) => (command.payload['mediaIds'] as List).isEmpty,
      ),
      isTrue,
    );
    expect(
      (await store.discardStagedMedia(account.id, [
        fixture.media.clientId,
      ])).cleanupPaths,
      isEmpty,
    );
    expect(await store.pendingCleanupPaths(), isEmpty);
    expect(await File(fixture.media.localPath!).exists(), isTrue);
    final batch = (await store.captureBatch(
      accountId: account.id,
      wifi: true,
      allowMetered: false,
    ))!;
    await store.applySyncResult(
      accountId: account.id,
      batch: batch,
      cloudState: cloud(revision: 3).copyWith(entryCount: 1),
      branchMode: 'active',
      receipts: [
        {'commandId': 'repair-draft'},
        {'commandId': 'repair-complete', 'entryId': fixture.entry.id},
        {'commandId': 'after-repair'},
      ],
      savedEntries: [
        fixture.entry.copyWith(attachments: [], syncStatus: 'saved'),
      ],
    );
    expect(await store.pendingCleanupPaths(), [fixture.media.localPath]);
  });

  test('repair rejects expired worker and committed records without changing payload', () async {
    final fixture = await repairFixture();
    await store.acquireLease('repair-worker');
    now = now.add(const Duration(minutes: 6));
    await expectLater(
      store.stripPendingAttachments(
        account.id,
        fixture.entry.id,
        missingCommandIds: {},
        leaseOwner: 'repair-worker',
      ),
      throwsA(isA<QuestException>()),
    );
    expect((await store.localEntries(account.id)).single.attachments.length, 1);
    final batch = (await store.captureBatch(
      accountId: account.id,
      wifi: true,
      allowMetered: false,
    ))!;
    await store.applySyncResult(
      accountId: account.id,
      batch: batch,
      cloudState: cloud(revision: 3).copyWith(entryCount: 1),
      branchMode: 'active',
      receipts: [
        {'commandId': 'repair-draft'},
        {'commandId': 'repair-complete', 'entryId': fixture.entry.id},
        {'commandId': 'after-repair'},
      ],
      savedEntries: [fixture.entry.copyWith(syncStatus: 'saved')],
    );
    await expectLater(
      store.stripPendingAttachments(
        account.id,
        fixture.entry.id,
        missingCommandIds: {'repair-draft', 'repair-complete'},
      ),
      throwsA(isA<QuestException>()),
    );
  });
}
