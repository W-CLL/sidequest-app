import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/media_capture.dart';

import 'ui_test_harness.dart';

class _Picker extends ImagePicker {
  int recoveries = 0;
  List<XFile> files = [XFile('/test/picked.jpg')];
  Future<void> Function()? beforeResult;
  @override
  Future<LostDataResponse> retrieveLostData() async {
    recoveries++;
    return LostDataResponse(files: files, type: RetrieveType.image);
  }

  @override
  Future<List<XFile>> pickMultiImage({
    double? maxWidth,
    double? maxHeight,
    int? imageQuality,
    int? limit,
    bool requestFullMetadata = true,
  }) async {
    await beforeResult?.call();
    return files;
  }
}

class _FailSecondRepository extends InMemoryQuestRepository {
  _FailSecondRepository(super.initial);
  int stages = 0;
  @override
  Future<MediaAttachment> stageMedia(
    String path,
    MediaKind kind, {
    int? durationMs,
  }) {
    if (++stages == 2) throw const QuestException('第二个文件暂存失败');
    return super.stageMedia(path, kind, durationMs: durationMs);
  }
}

class _FailOnceRepository extends InMemoryQuestRepository {
  _FailOnceRepository(super.initial);
  bool failStage = true;
  @override
  Future<MediaAttachment> stageMedia(
    String path,
    MediaKind kind, {
    int? durationMs,
  }) async {
    if (failStage) {
      failStage = false;
      throw const QuestException('暂存失败');
    }
    return super.stageMedia(path, kind, durationMs: durationMs);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.android);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test('same activity on a different branch cannot consume a pending gallery result', () async {
    final repo = await createLocalFixture(fixture: LocalFixture.active);
    SharedPreferences.setMockInitialValues({
      'sidequest.picker.context.v2': jsonEncode({
        'scope': 'fixture',
        'accountId': repo.snapshot.profile!.id,
        'contextId': 'branch:original:green',
        'kind': 'image',
      }),
    });
    final picker = _Picker();
    final capture = MediaCapture(picker: picker);
    expect(
      await capture.recover(
        repository: repo,
        accountId: repo.snapshot.profile!.id,
        contextId: 'branch:replacement:green',
      ),
      isEmpty,
    );
    expect(picker.recoveries, 0);
    expect(await capture.hasRecovery(), isTrue);
    expect(
      await capture.recover(
        repository: repo,
        accountId: repo.snapshot.profile!.id,
        contextId: 'branch:original:green',
      ),
      hasLength(1),
    );
    expect(picker.recoveries, 1);
    expect(await capture.hasRecovery(), isFalse);
  });

  test('an ordinary gallery staging failure retains the selected file paths for retry', () async {
    final repo = _FailOnceRepository(snapshotFixture(active: true));
    SharedPreferences.setMockInitialValues({});
    final picker = _Picker();
    final capture = MediaCapture(picker: picker);
    await expectLater(
      capture.pick(
        repository: repo,
        accountId: repo.snapshot.profile!.id,
        contextId: 'branch:original:green',
        kind: MediaKind.image,
        remainingImages: 5,
      ),
      throwsA(isA<QuestException>()),
    );
    expect(await capture.hasRecovery(), isTrue);
    expect(
      await capture.recover(
        repository: repo,
        accountId: repo.snapshot.profile!.id,
        contextId: 'branch:original:green',
      ),
      hasLength(1),
    );
    expect(picker.recoveries, 0);
    expect(await capture.hasRecovery(), isFalse);
  });

  test('partial gallery failure cleans detached stages while preserving recovery files', () async {
    final repo = _FailSecondRepository(snapshotFixture(active: true));
    SharedPreferences.setMockInitialValues({
      'sidequest.picker.context.v2': jsonEncode({
        'scope': 'fixture',
        'accountId': repo.snapshot.profile!.id,
        'contextId': 'draft:green',
        'kind': 'image',
      }),
    });
    final picker = _Picker()
      ..files = [XFile('/test/one.jpg'), XFile('/test/two.jpg')];
    final capture = MediaCapture(picker: picker);
    await expectLater(
      capture.recover(
        repository: repo,
        accountId: repo.snapshot.profile!.id,
        contextId: 'draft:green',
      ),
      throwsA(isA<QuestException>()),
    );
    expect(repo.discardedMedia, hasLength(1));
    expect(repo.stagedMedia, isEmpty);
    expect(await capture.hasRecovery(), isTrue);
    final restored = await capture.recover(
      repository: repo,
      accountId: repo.snapshot.profile!.id,
      contextId: 'draft:green',
    );
    expect(restored, hasLength(2));
    expect(picker.recoveries, 1);
    expect(await capture.hasRecovery(), isFalse);
  });

  test('failed recovery retains file references for a retry without re-consuming the picker', () async {
    final repo = _FailOnceRepository(snapshotFixture(active: true));
    SharedPreferences.setMockInitialValues({
      'sidequest.picker.context.v2': jsonEncode({
        'scope': 'fixture',
        'accountId': repo.snapshot.profile!.id,
        'contextId': 'draft:green',
        'kind': 'image',
      }),
    });
    final picker = _Picker();
    final capture = MediaCapture(picker: picker);
    await expectLater(
      capture.recover(
        repository: repo,
        accountId: repo.snapshot.profile!.id,
        contextId: 'draft:green',
      ),
      throwsA(isA<QuestException>()),
    );
    expect(await capture.hasRecovery(), isTrue);
    expect(
      (await capture.recover(
        repository: repo,
        accountId: repo.snapshot.profile!.id,
        contextId: 'draft:green',
      )).length,
      1,
    );
    expect(picker.recoveries, 1);
    expect(await capture.hasRecovery(), isFalse);
  });

  test('lost picker can only be claimed by the original service account and editor', () async {
    final repo = await createLocalFixture(fixture: LocalFixture.active);
    final id = repo.snapshot.profile!.id;
    final prefs = await SharedPreferences.getInstance();
    const key = 'sidequest.picker.context.v2';
    await prefs.setString(
      key,
      jsonEncode({
        'scope': 'fixture',
        'accountId': id,
        'contextId': 'draft:green',
        'kind': 'image',
      }),
    );
    final picker = _Picker();
    final capture = MediaCapture(picker: picker);
    expect(
      await capture.recover(
        repository: repo,
        accountId: 'other-user',
        contextId: 'draft:green',
      ),
      isEmpty,
    );
    expect(
      await capture.recover(
        repository: repo,
        accountId: id,
        contextId: 'entry:saved:1',
      ),
      isEmpty,
    );
    await prefs.setString(
      key,
      jsonEncode({
        'scope': 'another-service',
        'accountId': id,
        'contextId': 'draft:green',
        'kind': 'image',
      }),
    );
    expect(
      await capture.recover(
        repository: repo,
        accountId: id,
        contextId: 'draft:green',
      ),
      isEmpty,
    );
    expect(picker.recoveries, 0);
    await prefs.setString(
      key,
      jsonEncode({
        'scope': 'fixture',
        'accountId': id,
        'contextId': 'draft:green',
        'kind': 'image',
      }),
    );
    final media = await capture.recover(
      repository: repo,
      accountId: id,
      contextId: 'draft:green',
    );
    expect(media.single.kind, MediaKind.image);
    expect(picker.recoveries, 1);
    expect(await capture.hasRecovery(), isFalse);
  });

  test(
    'account switch while gallery is open cannot attach results to new account',
    () async {
      final repo = await createLocalFixture(fixture: LocalFixture.active);
      final id = repo.snapshot.profile!.id;
      final picker = _Picker()
        ..beforeResult = () async {
          await repo.logout();
          await repo.register('另一个账号', testPassword);
          await repo.claim();
        };
      final capture = MediaCapture(picker: picker);
      await expectLater(
        capture.pick(
          repository: repo,
          accountId: id,
          contextId: 'draft:green',
          kind: MediaKind.image,
          remainingImages: 5,
        ),
        throwsA(isA<QuestException>()),
      );
      expect(repo.snapshot.draftAttachments, isEmpty);
      expect(await capture.hasRecovery(), isTrue);
    },
  );

  test(
    'explicitly abandoning stale recovery clears only picker context',
    () async {
      final repo = await createLocalFixture(fixture: LocalFixture.completed);
      final original = repo.snapshot.entries.single;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sidequest.picker.context.v2', '{}');
      final capture = MediaCapture(picker: _Picker());
      await capture.discardRecovery();
      expect(await capture.hasRecovery(), isFalse);
      expect(repo.snapshot.entries.single, same(original));
    },
  );
}
