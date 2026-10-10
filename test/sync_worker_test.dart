import 'package:flutter_test/flutter_test.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/sync_worker.dart';

import 'ui_test_harness.dart';

class _BackgroundRepository extends InMemoryQuestRepository {
  _BackgroundRepository({bool authenticated = true})
    : super(snapshotFixture(authenticated: authenticated));

  SyncSummary before = const SyncSummary(pending: 1);
  SyncSummary after = const SyncSummary();
  bool synced = false;
  bool disposed = false;
  bool failSync = false;
  bool failLoad = false;
  bool grantedMetered = false;

  @override
  Future<AppSnapshot> load() async {
    if (failLoad) throw const QuestException('磁盘暂不可用');
    return snapshot;
  }

  @override
  Future<SyncSummary> getSyncSummary() async => synced ? after : before;

  @override
  Future<void> syncNow({bool allowMetered = false}) async {
    grantedMetered = allowMetered;
    if (failSync) throw const QuestException('网络中断');
    synced = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

void main() {
  test('background task never grants mobile-data authorization', () async {
    final repo = _BackgroundRepository();
    expect(await runBackgroundSync(repo), isTrue);
    expect(repo.synced, isTrue);
    expect(repo.grantedMetered, isFalse);
    expect(repo.disposed, isTrue);
  });

  test('logged out task does not take over another account queue', () async {
    final repo = _BackgroundRepository(authenticated: false);
    expect(await runBackgroundSync(repo), isTrue);
    expect(repo.synced, isFalse);
    expect(repo.disposed, isTrue);
  });

  test(
    'draft and progress commands run without being counted as records',
    () async {
      final repo = _BackgroundRepository()
        ..before = const SyncSummary(queuedCommands: 2);
      expect(await runBackgroundSync(repo), isTrue);
      expect(repo.synced, isTrue);
      expect(repo.grantedMetered, isFalse);
    },
  );

  test('expired login retains queue and waits for explicit login', () async {
    final repo = _BackgroundRepository()
      ..before = const SyncSummary(pending: 1, requiresLogin: true);
    expect(await runBackgroundSync(repo), isTrue);
    expect(repo.synced, isFalse);
    expect(repo.disposed, isTrue);
  });

  test('unfinished upload is eligible for OS backoff retry', () async {
    final repo = _BackgroundRepository()
      ..after = const SyncSummary(pending: 1, failed: 1);
    expect(await runBackgroundSync(repo), isFalse);
    expect(repo.disposed, isTrue);
  });

  test('network failure still disposes the shared worker instance', () async {
    final repo = _BackgroundRepository()..failSync = true;
    expect(await runBackgroundSync(repo), isFalse);
    expect(repo.disposed, isTrue);
  });

  test(
    'database load failure is retryable and is not reported as saved',
    () async {
      final repo = _BackgroundRepository()..failLoad = true;
      expect(await runBackgroundSync(repo), isFalse);
      expect(repo.synced, isFalse);
      expect(repo.disposed, isTrue);
    },
  );
}
