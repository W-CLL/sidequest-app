import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/media_normalizer.dart';
import 'package:sidequest/offline_store.dart';
import 'package:sidequest/repository.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MemoryTokens implements SessionTokenStore {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async => token = value;
  @override
  Future<void> clear() async => token = null;
}

/// 模拟设备密钥失效导致的解密失败（真实设备上的 BadPaddingException 一类）。
class _BrokenSecureStorage extends FlutterSecureStorage {
  _BrokenSecureStorage({this.failRead = true, this.failWrite = false});
  final bool failRead, failWrite;
  var deletes = 0;
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failRead) {
      throw PlatformException(code: 'read', message: 'BAD_DECRYPT');
    }
    return 'ok';
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrite) {
      throw PlatformException(code: 'write', message: 'KEYSTORE_LOST');
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deletes += 1;
  }
}

class _Call {
  _Call(
    this.path,
    this.method,
    this.token,
    this.body,
    this.bytes,
    this.streamed,
  );
  final String path, method;
  final String? token;
  final Map<String, dynamic> body;
  final List<int> bytes;
  final bool streamed;
}

// Real server/SQLite/FFmpeg contracts are tested separately; this peer controls
// response loss and concurrent foreground edits without timing-dependent sleeps.
class _Api extends http.BaseClient {
  AppSnapshot state = AppSnapshot(
    day: '2026-10-10',
    profile: UserProfile(
      id: 'account-a',
      nickname: '小探索家',
      role: 'student',
      preferences: [],
    ),
  );
  final calls = <_Call>[];
  final receipts = <String, Map<String, dynamic>>{};
  final entries = <String, JournalEntry>{};
  final media = <String, MediaAttachment>{};
  int protocol = 2;
  bool online = true, loseNext = false, tombstone = false, unauthorized = false;
  bool rejectPut = false;
  Future<void> Function()? beforeSync;
  http.StreamedResponse response(Object value, [int status = 200]) =>
      http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(value))),
        status,
      );
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!online) throw http.ClientException('Offline');
    final bytes = await request.finalize().toBytes();
    final path = request.url.path;
    final body = bytes.isEmpty || request.method == 'PUT'
        ? <String, dynamic>{}
        : Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    calls.add(
      _Call(
        path,
        request.method,
        request.headers['authorization'],
        body,
        bytes,
        request is http.StreamedRequest,
      ),
    );
    if (path == '/api/health') return response({'protocolVersion': protocol});
    if (unauthorized) return response({'error': '登录已失效'}, 401);
    if (path == '/api/register' || path == '/api/login') {
      return response({'token': 'token-a', 'state': state.toJson()});
    }
    if (path == '/api/state') return response({'state': state.toJson()});
    if (path == '/api/uploads') {
      final id = 'server-${body['clientUploadId']}';
      media.putIfAbsent(
        id,
        () => MediaAttachment(
          id: id,
          kind: MediaKind.values.byName(body['kind'] as String),
          status: 'reserved',
        ),
      );
      return response({'media': media[id]!.toJson()});
    }
    if (path.startsWith('/api/uploads/')) {
      final id = path.split('/')[3];
      if (request.method == 'PUT' && rejectPut) {
        return response({'error': '媒体文件无效'}, 413);
      }
      if (request.method == 'DELETE') {
        media.remove(id);
        return response({});
      }
      if (!media.containsKey(id)) return response({'error': '附件不存在'}, 404);
      if (request.method == 'PUT') {
        media[id] = media[id]!.copyWith(
          status: 'ready',
          byteSize: bytes.length,
          mimeType: 'image/jpeg',
        );
      }
      return response({'media': media[id]!.toJson()});
    }
    if (path == '/api/sync' || path == '/api/sync-status') {
      final commands = (body['commands'] as List).cast<Map>();
      if (path == '/api/sync') {
        await beforeSync?.call();
        for (final command in commands) {
          final id = command['commandId'] as String;
          if (receipts.containsKey(id)) continue;
          final payload = Map<String, dynamic>.from(command['payload'] as Map);
          String? entryId;
          switch (command['type']) {
            case 'claim':
              state = state.copyWith(
                activeQuestId: payload['questId'] as String,
              );
            case 'draft':
              state = state.copyWith(draft: payload['text'] as String);
            case 'stop':
              state = state.copyWith(activeQuestId: null);
            case 'complete':
              entryId = payload['clientRecordId'] as String;
              entries[entryId] = JournalEntry(
                id: entryId,
                questId: payload['questId'] as String,
                questTitle: questById(payload['questId'] as String).title,
                text: payload['text'] as String,
                createdAt: DateTime.parse(payload['createdAt'] as String),
                attachments: (payload['mediaIds'] as List)
                    .map((id) => media[id]!)
                    .toList(),
              );
              state = state.copyWith(
                activeQuestId: null,
                draft: '',
                draftAttachments: [],
                canRequestNext: true,
              );
            case 'next':
              final next = recommendQuestId(
                preferences: state.profile!.preferences,
                history: state.recommendationHistory,
                currentId: state.recommendedQuestId,
              );
              state = state.copyWith(
                recommendedQuestId: next,
                canRequestNext: false,
                recommendationHistory: appendRecommendation(
                  state.recommendationHistory,
                  next,
                ),
              );
          }
          state = state.copyWith(
            progressRevision: state.progressRevision + 1,
            entryCount: entries.length,
          );
          receipts[id] = {
            'commandId': id,
            'entryId': ?entryId,
            'progressApplied': true,
          };
        }
        if (loseNext) {
          loseNext = false;
          if (tombstone) {
            entries.clear();
            media.clear();
            state = state.copyWith(entryCount: 0);
          }
          online = false;
          throw http.ClientException('Committed but response lost');
        }
      }
      final found = [
        for (final command in commands)
          if (receipts.containsKey(command['commandId']))
            receipts[command['commandId']]!,
      ];
      return response({
        'state': state.toJson(),
        'branchMode': 'active',
        'receipts': found,
        'entries': found
            .map((r) => entries[r['entryId']])
            .whereType<JournalEntry>()
            .map((e) => e.toJson())
            .toList(),
        if (path == '/api/sync-status')
          'missingCommandIds': [
            for (final command in commands)
              if (!receipts.containsKey(command['commandId']))
                command['commandId'],
          ],
      });
    }
    if (path == '/api/entries') {
      return response({
        'entries': entries.values.map((e) => e.toJson()).toList(),
        'total': entries.length,
        'nextCursor': null,
      });
    }
    if (path == '/api/logout') {
      return response({'state': AppSnapshot(day: '2026-10-10').toJson()});
    }
    return response({'error': 'Unexpected route $path'}, 404);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late Directory dir;
  late OfflineStore store;
  late RemoteQuestRepository repo;
  late MemoryTokens tokens;
  late _Api api;
  late bool wifi;
  late List<String> normalized;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('sidequest-repository-test-');
    SharedPreferences.setMockInitialValues({});
    wifi = true;
    normalized = [];
    tokens = MemoryTokens();
    api = _Api();
    store = OfflineStore(
      databaseFactory: databaseFactoryFfi,
      databasePath: p.join(dir.path, 'state.sqlite'),
      mediaRoot: p.join(dir.path, 'media'),
      namespace: 'https://sidequest.test',
      now: () => DateTime.utc(2026, 10, 10),
    );
    repo = RemoteQuestRepository(
      apiBaseUrl: 'https://sidequest.test',
      client: api,
      tokenStore: tokens,
      offlineStore: store,
      preferences: await SharedPreferences.getInstance(),
      wifiCheck: () async => wifi,
      autoSync: false,
      now: () => DateTime.utc(2026, 10, 10),
      imageNormalizer: (source) async {
        normalized.add(source);
        final file = File(p.join(dir.path, 'normalized.jpg'));
        await file.writeAsBytes([0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]);
        return NormalizedImage(file.path);
      },
    );
  });
  tearDown(() async {
    await repo.dispose();
    await dir.delete(recursive: true);
  });
  Future<void> register() async {
    await repo.savePreferences('student', []);
    await repo.register('小探索家', 'safe-password');
  }

  Future<String> source([String name = 'source.jpg']) async {
    final file = File(p.join(dir.path, name));
    await file.writeAsBytes([7, 8, 9]);
    return file.path;
  }

  test(
    'configuration is explicit and production transport requires TLS',
    () async {
      expect(createRepository().isConfigured, isFalse);
      await expectLater(
        createRepository().load(),
        throwsA(isA<QuestException>()),
      );
      expect(
        () => RemoteQuestRepository(
          apiBaseUrl: 'http://example.test',
          offlineStore: store,
          client: api,
        ),
        throwsA(isA<QuestException>()),
      );
      expect(
        () => RemoteQuestRepository(
          apiBaseUrl: 'https://user:pass@example.test',
          offlineStore: store,
          client: api,
        ),
        throwsA(isA<QuestException>()),
      );
    },
  );
  test('protocol gate rejects v1 before sending credentials', () async {
    api.protocol = 1;
    await repo.savePreferences('student', []);
    await expectLater(
      repo.register('小探索家', 'safe-password'),
      throwsA(isA<QuestException>()),
    );
    expect(api.calls.map((c) => c.path), ['/api/health']);
    expect(tokens.token, isNull);
  });
  test('concurrent dispose calls share and await the same close', () async {
    await register();
    await repo.claim();

    final first = repo.dispose();
    final second = repo.dispose();

    expect(identical(first, second), isTrue);
    await second;
    await first;
    await expectLater(store.database, throwsStateError);
  });
  test('offline draft and completed record remain durable', () async {
    await register();
    api.online = false;
    await repo.claim();
    await repo.saveDraft('离线文字');
    final result = await repo.complete('离线文字');
    expect(result.entries.single.isSynced, isFalse);
    expect((await repo.queryEntries()).entries.single.text, '离线文字');
    expect(
      await store.pendingCommandCount((await store.activeAccount())!.id),
      3,
    );
  });
  test('in-flight sync does not block foreground autosave', () async {
    await register();
    await repo.claim();
    final started = Completer<void>(), resume = Completer<void>();
    api.beforeSync = () async {
      if (!started.isCompleted) {
        started.complete();
        await resume.future;
      }
    };
    final sync = repo.syncNow();
    await started.future.timeout(const Duration(seconds: 3));
    try {
      expect(
        (await repo.saveDraft('上传时继续输入').timeout(const Duration(seconds: 2)))
            .draft,
        '上传时继续输入',
      );
    } finally {
      resume.complete();
    }
    await sync;
    expect(api.state.draft, '上传时继续输入');
  });
  test('metered authorization never includes later commands', () async {
    await register();
    await repo.claim();
    wifi = false;
    final started = Completer<void>(), resume = Completer<void>();
    api.beforeSync = () async {
      if (!started.isCompleted) {
        started.complete();
        await resume.future;
      }
    };
    final sync = repo.syncNow(allowMetered: true);
    await started.future.timeout(const Duration(seconds: 3));
    await repo.saveDraft('未经移动网络授权');
    resume.complete();
    await sync;
    final account = (await store.activeAccount())!;
    expect(await store.pendingCommandCount(account.id), 1);
    expect(api.state.draft, isEmpty);
    expect(account.snapshot.draft, '未经移动网络授权');
    await repo.syncNow();
    expect(await store.pendingCommandCount(account.id), 1);
  });
  test(
    'normalization feeds streamed upload and never deletes gallery source',
    () async {
      await register();
      final gallery = await source();
      final item = await repo.stageMedia(gallery, MediaKind.image);
      await repo.claim();
      await repo.complete('图片记录', attachments: [item]);
      await repo.syncNow();
      final put = api.calls.singleWhere((c) => c.method == 'PUT');
      expect(put.streamed, isTrue);
      expect(put.bytes, [0xff, 0xd8, 1, 2, 3, 0xff, 0xd9]);
      expect(normalized, [gallery]);
      expect(await File(gallery).readAsBytes(), [7, 8, 9]);
      expect(put.token, 'Bearer token-a');
      expect((await repo.getSyncSummary()).hasPending, isFalse);
    },
  );
  test(
    'lost response checks original receipts and never resurrects tombstones',
    () async {
      await register();
      final item = await repo.stageMedia(await source(), MediaKind.image);
      await repo.claim();
      await repo.complete('不得复活', attachments: [item]);
      api.loseNext = true;
      api.tombstone = true;
      await expectLater(repo.syncNow(), throwsA(isA<QuestException>()));
      final puts = api.calls.where((c) => c.method == 'PUT').length;
      api.online = true;
      await repo.syncNow();
      expect(api.calls.where((c) => c.path == '/api/sync-status'), isNotEmpty);
      expect(api.calls.where((c) => c.method == 'PUT').length, puts);
      expect(api.calls.where((c) => c.path == '/api/sync').length, 1);
      expect((await repo.queryEntries()).entries, isEmpty);
    },
  );
  test(
    'token change fences response and never sends A commands under B token',
    () async {
      await register();
      await repo.claim();
      api.beforeSync = () async {
        tokens.token = 'token-b';
      };
      await expectLater(repo.syncNow(), throwsA(isA<QuestException>()));
      expect(
        api.calls
            .where((c) => c.path == '/api/sync')
            .every((c) => c.token == 'Bearer token-a'),
        isTrue,
      );
      final account = (await store.activeAccount())!;
      expect(account.snapshot.profile!.id, 'account-a');
      expect(await store.pendingCommandCount(account.id), 1);
    },
  );
  test('401 preserves queue and asks for reauthentication', () async {
    await register();
    await repo.claim();
    api.unauthorized = true;
    try {
      await repo.syncNow();
    } on QuestException {
      /* The UI reports expiry. */
    }
    final account = (await store.activeAccount())!;
    expect(await store.pendingCommandCount(account.id), 1);
    expect(account.requiresLogin, isTrue);
    expect(tokens.token, isNull);
  });
  test(
    'same-quest stale editor keeps its text outside the new canonical branch',
    () async {
      await register();
      await repo.claim();
      await repo.syncNow();
      final context = await repo.openDraftEditor('green');
      final account = (await store.activeAccount())!;
      api.state = api.state.copyWith(
        progressRevision: api.state.progressRevision + 1,
        draft: '云端新稿',
      );
      await store.adoptCloud(account.id, api.state);
      await expectLater(
        repo.saveDraft(
          '未自动保存的本机文字',
          expectedBranchId: context.branchId,
          expectedQuestId: context.questId,
        ),
        throwsA(isA<DraftEditorMovedException>()),
      );
      final current = (await store.activeAccount())!.snapshot;
      expect(current.draft, '云端新稿');
      expect(current.conflictDrafts.single.text, '未自动保存的本机文字');
    },
  );
  test(
    'discard protects draft references but removes unreferenced staged files',
    () async {
      await register();
      final kept = await repo.stageMedia(
        await source('keep.jpg'),
        MediaKind.image,
      );
      final removed = await repo.stageMedia(
        await source('remove.jpg'),
        MediaKind.image,
      );
      await repo.claim();
      await repo.saveDraft('保留附件', attachments: [kept]);
      await repo.discardStagedMedia([kept.id, removed.id]);
      expect(await File(kept.localPath!).exists(), isTrue);
      expect(await File(removed.localPath!).exists(), isFalse);
    },
  );

  test(
    'failed upload stays intact until user chooses text-only recovery',
    () async {
      await register();
      final image = await repo.stageMedia(await source(), MediaKind.image);
      await repo.claim();
      await repo.saveDraft('文字不能丢', attachments: [image]);
      final complete = await repo.complete('文字不能丢', attachments: [image]);
      api.rejectPut = true;
      await expectLater(repo.syncNow(), throwsA(isA<QuestException>()));
      expect(
        (await repo.queryEntries()).entries.single.attachments.single.id,
        image.id,
      );
      expect(await File(image.localPath!).exists(), isTrue);
      var sourceStillPresentAtCommit = false;
      api.beforeSync = () async {
        sourceStillPresentAtCommit = await File(image.localPath!).exists();
      };
      await repo.removePendingAttachments(complete.entries.single.id);
      expect(sourceStillPresentAtCommit, isTrue);
      final saved = api.entries.values.single;
      expect(saved.id, complete.entries.single.id);
      expect(saved.text, '文字不能丢');
      expect(saved.attachments, isEmpty);
      expect(await File(image.localPath!).exists(), isFalse);
      expect((await repo.getSyncSummary()).hasPending, isFalse);
    },
  );

  test(
    'repair never changes sent wire before original status confirms missing',
    () async {
      await register();
      final image = await repo.stageMedia(await source(), MediaKind.image);
      await repo.claim();
      await repo.saveDraft('待确认的记录', attachments: [image]);
      final complete = await repo.complete('待确认的记录', attachments: [image]);
      final account = (await store.activeAccount())!;
      final commands = await store.pendingAttachmentRepairCommands(
        account.id,
        complete.entries.single.id,
      );
      for (final command in commands) {
        await store.persistWireCommand(account.id, command.commandId, {
          'commandId': command.commandId,
          'type': command.type,
          'payload': command.payload,
        });
      }
      api.online = false;
      await expectLater(
        repo.removePendingAttachments(complete.entries.single.id),
        throwsA(isA<QuestException>()),
      );
      expect(
        (await store.localEntries(account.id)).single.attachments,
        isNotEmpty,
      );
      expect(
        (await store.pendingAttachmentRepairCommands(
          account.id,
          complete.entries.single.id,
        )).every((c) => c.wireJson != null),
        isTrue,
      );
      api.online = true;
      await repo.removePendingAttachments(complete.entries.single.id);
      expect(api.calls.where((c) => c.path == '/api/sync-status'), isNotEmpty);
      expect(api.entries.values.single.attachments, isEmpty);
    },
  );
  test('令牌存储损坏时自愈：按未登录处理、清掉坏数据并回调上报', () async {
    final broken = _BrokenSecureStorage();
    Object? reported;
    final store = PlatformSessionTokenStore(scope: 'heal-test', secure: broken)
      ..onCorruption = (error) => reported = error;
    expect(await store.read(), isNull);
    expect(broken.deletes, 1);
    expect(reported, isA<PlatformException>());
  });
  test('令牌写入失败映射为温和文案', () async {
    final broken = _BrokenSecureStorage(failRead: false, failWrite: true);
    final store = PlatformSessionTokenStore(scope: 'heal-test', secure: broken);
    await expectLater(store.write('token-value'), throwsA(isA<QuestException>()));
  });
}
