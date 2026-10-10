import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/media_normalizer.dart';
import 'package:sidequest/offline_store.dart';
import 'package:sidequest/repository.dart';

const _password = 'contract-password-123';

class _RealHttpOverrides extends HttpOverrides {}

class _Tokens implements SessionTokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String token) async => value = token;
  @override
  Future<void> clear() async => value = null;
}

class _FaultClient extends http.BaseClient {
  _FaultClient(this.inner);
  final IOClient inner;
  bool online = true;
  bool loseNextSyncResponse = false;
  int uploads = 0;
  Future<void> Function(http.BaseRequest)? beforeSend;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (!online) throw http.ClientException('Simulated offline', request.url);
    await beforeSend?.call(request);
    if (request.method == 'PUT') uploads++;
    final response = await inner.send(request);
    if (request.url.path == '/api/sync' &&
        loseNextSyncResponse &&
        response.statusCode == 200) {
      loseNextSyncResponse = false;
      await response.stream.drain<void>(); // The server really committed first.
      online = false; // Receipt recovery must wait for the next connection.
      throw http.ClientException('Simulated lost response', request.url);
    }
    return response;
  }

  @override
  void close() => inner.close();
}

class _Device {
  _Device(this.repo, this.store, this.client, this.tokens, this.path);
  final RemoteQuestRepository repo;
  final OfflineStore store;
  final _FaultClient client;
  final _Tokens tokens;
  final String path;

  Future<AppSnapshot> register(String nickname) async {
    await repo.savePreferences('student', []);
    return repo.register(nickname, _password);
  }
}

class _Harness {
  _Harness(
    this.directory,
    this.process,
    this.output,
    this.errors,
    this.base,
    this.prefs,
  );
  final Directory directory;
  final Process process;
  final StreamSubscription<String> output, errors;
  final String base;
  final SharedPreferences prefs;
  final devices = <_Device>[];
  final rawClients = <IOClient>[];

  static Future<_Harness> start() async {
    final node = Platform.environment['SIDEQUEST_NODE'] ?? 'node';
    final version = await Process.run(node, ['--version']);
    if (version.exitCode != 0 ||
        !version.stdout.toString().startsWith('v24.')) {
      throw StateError(
        'Real API tests require Node 24 on PATH or SIDEQUEST_NODE.',
      );
    }
    final dir = await Directory.systemTemp.createTemp('sidequest-v2-contract-');
    const script = r'''
const {createApp} = await import(process.argv[1]);
const app = createApp({databasePath:process.argv[2],authLimit:1000});
app.server.listen(0,'127.0.0.1',()=>process.stdout.write(JSON.stringify({port:app.server.address().port})+'\n'));
process.on('SIGTERM',()=>app.close().then(()=>process.exit(0)));
''';
    final server = await Process.start(node, [
      '--input-type=module',
      '-e',
      script,
      File('server/server.mjs').absolute.uri.toString(),
      '${dir.path}/server-v2.sqlite',
    ]);
    final ready = Completer<int>();
    final output = server.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          if (!ready.isCompleted) {
            try {
              ready.complete((jsonDecode(line) as Map)['port'] as int);
            } catch (_) {}
          }
        });
    final messages = StringBuffer();
    final errors = server.stderr.transform(utf8.decoder).listen(messages.write);
    unawaited(
      server.exitCode.then((code) {
        if (!ready.isCompleted) {
          ready.completeError(
            StateError('Temporary API failed ($code): $messages'),
          );
        }
      }),
    );
    try {
      final port = await ready.future.timeout(const Duration(seconds: 15));
      SharedPreferences.setMockInitialValues({});
      return _Harness(
        dir,
        server,
        output,
        errors,
        'http://127.0.0.1:$port',
        await SharedPreferences.getInstance(),
      );
    } catch (_) {
      server.kill();
      await server.exitCode;
      await output.cancel();
      await errors.cancel();
      await dir.delete(recursive: true);
      rethrow;
    }
  }

  IOClient httpClient() {
    final client = HttpOverrides.runWithHttpOverrides(
      () => IOClient(
        HttpClient()..connectionTimeout = const Duration(seconds: 3),
      ),
      _RealHttpOverrides(),
    );
    rawClients.add(client);
    return client;
  }

  Future<File> createImage(String name) async {
    final source = File('${directory.path}/$name.jpg');
    final ffmpeg = Platform.environment['FFMPEG_PATH'] ?? 'ffmpeg';
    final generated = await Process.run(ffmpeg, [
      '-nostdin',
      '-hide_banner',
      '-v',
      'error',
      '-f',
      'lavfi',
      '-i',
      'color=c=green:s=96x64',
      '-frames:v',
      '1',
      '-threads',
      '1',
      source.path,
    ]);
    expect(generated.exitCode, 0, reason: generated.stderr.toString());
    return source;
  }

  _Device device(
    String name, {
    String? sharedPath,
    _Tokens? tokens,
    WifiCheck? wifi,
  }) {
    final path = sharedPath ?? '${directory.path}/$name.sqlite';
    final store = OfflineStore(
      databaseFactory: createDatabaseFactoryFfi(),
      databasePath: path,
      mediaRoot: '${directory.path}/phone-media',
      namespace: base,
    );
    final client = _FaultClient(httpClient());
    final session = tokens ?? _Tokens();
    final repo = RemoteQuestRepository(
      apiBaseUrl: base,
      offlineStore: store,
      tokenStore: session,
      client: client,
      preferences: prefs,
      autoSync: false,
      wifiCheck: wifi ?? () async => true,
      imageNormalizer: (path) async => NormalizedImage(path),
    );
    final result = _Device(repo, store, client, session, path);
    devices.add(result);
    return result;
  }

  Future<Map<String, dynamic>> api(
    String endpoint,
    _Tokens tokens, {
    Map<String, dynamic>? body,
  }) async {
    final url = Uri.parse('$base/api/$endpoint');
    final headers = {
      'X-Sidequest-Protocol': '2',
      'Authorization': 'Bearer ${tokens.value}',
      'Content-Type': 'application/json',
    };
    final client = httpClient();
    final response = body == null
        ? await client.get(url, headers: headers)
        : await client.post(url, headers: headers, body: jsonEncode(body));
    expect(
      response.statusCode,
      inInclusiveRange(200, 299),
      reason: response.body,
    );
    return Map<String, dynamic>.from(jsonDecode(response.body) as Map);
  }

  Future<void> close() async {
    for (final device in devices) {
      await device.repo.dispose();
    }
    for (final client in rawClients) {
      client.close();
    }
    process.kill();
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
    await output.cancel();
    await errors.cancel();
    expect(directory.parent.absolute.path, Directory.systemTemp.absolute.path);
    expect(
      directory.path.split(Platform.pathSeparator).last,
      startsWith('sidequest-v2-contract-'),
    );
    await directory.delete(recursive: true);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  late _Harness harness;
  setUp(() async => harness = await _Harness.start());
  tearDown(() async => harness.close());

  test(
    'real account contract, Unicode limits, online edit/search and isolation',
    () async {
      final alice = harness.device('alice');
      final bob = harness.device('bob');
      await alice.repo.savePreferences('student', ['观察细节']);
      final account = await alice.repo.register('Ａlice', _password);
      expect(account.profile!.nickname, 'Alice');
      await expectLater(bob.register('alice'), throwsA(isA<QuestException>()));
      await bob.register('Bob');
      await alice.repo.claim();
      await expectLater(
        alice.repo.complete('   '),
        throwsA(isA<QuestException>()),
      );
      await expectLater(
        alice.repo.complete('😀' * 501),
        throwsA(isA<QuestException>()),
      );
      final pending = await alice.repo.complete('😀' * 500);
      expect(pending.entries.single.isSynced, isFalse);
      final id = pending.entries.single.id;
      await alice.repo.syncNow();
      var page = await alice.repo.queryEntries();
      expect(page.entries.single.id, id);
      expect(page.entries.single.isSynced, isTrue);
      expect((await bob.repo.queryEntries()).entries, isEmpty);
      await expectLater(
        bob.repo.deleteEntry(id),
        throwsA(isA<QuestException>()),
      );
      await alice.repo.updateEntry(
        id,
        '修改后的窗边发现',
        [],
        page.entries.single.revision,
      );
      page = await alice.repo.queryEntries(query: '窗边');
      expect(page.total, 1);
      expect(page.entries.single.text, '修改后的窗边发现');
      await expectLater(
        alice.repo.updateEntry(id, '旧版本覆盖', [], 1),
        throwsA(isA<QuestException>()),
      );
      await alice.repo.deleteEntry(id);
      expect((await alice.repo.queryEntries()).entries, isEmpty);
      await expectLater(
        alice.repo.deleteAccount('incorrect-password'),
        throwsA(isA<QuestException>()),
      );
      final revoked = alice.tokens.value!;
      await alice.repo.deleteAccount(_password);
      expect(alice.tokens.value, isNull);
      expect(
        (await harness.httpClient().get(
          Uri.parse('${harness.base}/api/state'),
          headers: {
            'X-Sidequest-Protocol': '2',
            'Authorization': 'Bearer $revoked',
          },
        )).statusCode,
        401,
      );
      expect(
        (await harness.httpClient().get(
          Uri.parse('${harness.base}/api/export'),
          headers: {
            'X-Sidequest-Protocol': '2',
            'Authorization': 'Bearer ${bob.tokens.value}',
          },
        )).statusCode,
        404,
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'multiple offline completions survive app restart then upload exactly once',
    () async {
      final first = harness.device('restart');
      await first.register('OfflineUser');
      first.client.online = false;
      final ids = <String>{};
      for (var i = 0; i < 5; i++) {
        await first.repo.claim();
        final saved = await first.repo.complete('离线记录 $i');
        ids.addAll(saved.entries.map((e) => e.id));
        if (i < 4) await first.repo.nextQuest();
      }
      expect((await first.repo.queryEntries()).entries.length, 5);
      await first.repo.dispose();
      final restarted = harness.device(
        'restarted',
        sharedPath: first.path,
        tokens: first.tokens,
      );
      expect((await restarted.repo.load()).entries.length, 5);
      await restarted.repo.syncNow();
      await restarted.repo.syncNow();
      final cloud = await harness.api('entries', restarted.tokens);
      expect(cloud['total'], 5);
      expect((cloud['entries'] as List).map((e) => e['id']).toSet(), ids);
      expect((await restarted.repo.getSyncSummary()).pending, 0);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test('two devices preserve completed records and paused conflict draft without cloud overwrite', () async {
    final phone = harness.device('phone');
    final tablet = harness.device('tablet');
    await phone.register('ConflictUser');
    await tablet.repo.login('ConflictUser', _password);
    await phone.repo.claim();
    await phone.repo.complete('手机离线完成');
    await phone.repo.nextQuest();
    await phone.repo.claim();
    await phone.repo.saveDraft('暂停的离线草稿');
    await phone.repo.stop();
    await tablet.repo.claim();
    await tablet.repo.saveDraft('云端草稿必须保留');
    await tablet.repo.syncNow();
    await phone.repo.syncNow();
    final state = await phone.repo.load();
    expect(state.draft, '云端草稿必须保留');
    expect(state.conflictDrafts.single.text, '暂停的离线草稿');
    final draft = state.conflictDrafts.single;
    final view = await phone.repo.resumeConflictDraft(draft.id);
    expect(view.draft, draft.text);
    await phone.repo.saveConflictDraft(draft.id, '补全后的原活动记录');
    await phone.repo.completeConflictDraft(draft.id, '补全后的原活动记录');
    await phone.repo.syncNow();
    final cloud = await harness.api('state', phone.tokens);
    expect((cloud['state'] as Map)['draft'], '云端草稿必须保留');
    expect((await phone.repo.queryEntries()).total, 2);
    expect((await phone.repo.load()).conflictDrafts, isEmpty);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('open editor retains its original branch when the same activity conflicts in background', () async {
    final phone = harness.device('open-editor');
    final tablet = harness.device('open-editor-other');
    await phone.register('EditorConflictUser');
    await tablet.repo.login('EditorConflictUser', _password);
    await phone.repo.claim();
    final editor = await phone.repo.openDraftEditor('green');
    await phone.repo.saveDraft(
      '手机最初的草稿',
      expectedBranchId: editor.branchId,
      expectedQuestId: editor.questId,
    );
    await tablet.repo.claim();
    await tablet.repo.saveDraft('同一活动的云端草稿');
    await tablet.repo.syncNow();
    await phone.repo.syncNow();
    await expectLater(
      phone.repo.saveDraft(
        '页面未关闭时继续输入的文字',
        expectedBranchId: editor.branchId,
        expectedQuestId: editor.questId,
      ),
      throwsA(isA<DraftEditorMovedException>()),
    );
    await expectLater(
      phone.repo.complete(
        '点击完成时保留的原活动记录',
        expectedBranchId: editor.branchId,
        expectedQuestId: editor.questId,
      ),
      throwsA(isA<DraftEditorMovedException>()),
    );
    final state = await phone.repo.load();
    expect(state.draft, '同一活动的云端草稿');
    final conflict = state.conflictDrafts.single;
    expect(conflict.branchId, editor.branchId);
    expect(conflict.text, '点击完成时保留的原活动记录');
    expect((await phone.repo.queryEntries()).entries, isEmpty);
    await phone.repo.completeConflictDraft(conflict.id, conflict.text);
    await phone.repo.syncNow();
    final cloud = await harness.api('state', tablet.tokens);
    expect(cloud['state']['draft'], '同一活动的云端草稿');
    expect(
      (await phone.repo.queryEntries()).entries.single.text,
      conflict.text,
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('real media upload remains private and source survives until a record receipt', () async {
    final device = harness.device('media');
    await device.register('MediaUser');
    final source = await harness.createImage('real-source');
    final media = await device.repo.stageMedia(source.path, MediaKind.image);
    expect(media.localPath, isNot(source.path));
    await device.repo.claim();
    await device.repo.complete('真实图片记录', attachments: [media]);
    expect(await File(media.localPath!).exists(), isTrue);
    await device.repo.syncNow();
    final record = (await device.repo.queryEntries()).entries.single;
    expect(record.isSynced, isTrue);
    expect(record.attachments.single.mimeType, 'image/jpeg');
    expect(await File(media.localPath!).exists(), isFalse);
    expect(await source.exists(), isTrue);
    final url = device.repo.mediaUrl(record.attachments.single);
    final raw = harness.httpClient();
    expect(
      (await raw.get(
        Uri.parse(url),
        headers: {'X-Sidequest-Protocol': '2'},
      )).statusCode,
      401,
    );
    final response = await raw.get(
      Uri.parse(url),
      headers: {...await device.repo.mediaHeaders(), 'Range': 'bytes=0-15'},
    );
    expect(response.statusCode, 206);
    expect(response.bodyBytes.length, 16);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('lost successful response followed by another-device deletion cannot resurrect local or cloud record', () async {
    final device = harness.device('lost');
    final other = harness.device('deleter');
    await device.register('LostUser');
    await other.repo.login('LostUser', _password);
    final source = await harness.createImage('lost-response');
    final media = await device.repo.stageMedia(source.path, MediaKind.image);
    await device.repo.claim();
    final record = (await device.repo.complete(
      '只保存一次',
      attachments: [media],
    )).entries.single;
    device.client.loseNextSyncResponse = true;
    try {
      await device.repo.syncNow();
    } on QuestException {
      /* uncertain response */
    }
    expect((await harness.api('entries', other.tokens))['total'], 1);
    expect(await File(media.localPath!).exists(), isTrue);
    await other.repo.queryEntries();
    await other.repo.deleteEntry(record.id);
    await device.repo.dispose();
    final restarted = harness.device(
      'lost-restarted',
      sharedPath: device.path,
      tokens: device.tokens,
    );
    await restarted.repo.syncNow();
    expect((await harness.api('entries', other.tokens))['total'], 0);
    expect((await restarted.repo.queryEntries()).entries, isEmpty);
    expect((await restarted.repo.getSyncSummary()).pending, 0);
    expect(restarted.client.uploads, 0);
    expect(await File(media.localPath!).exists(), isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('real decoder failure can explicitly recover as text without losing the source before receipt', () async {
    var wifi = true;
    final device = harness.device('media-repair', wifi: () async => wifi);
    await device.register('RepairUser');
    final corrupt = File('${harness.directory.path}/corrupt-video.mp4');
    await corrupt.writeAsBytes([0, 1, 2, 3], flush: true);
    final media = await device.repo.stageMedia(
      corrupt.path,
      MediaKind.video,
      durationMs: 1000,
    );
    await device.repo.claim();
    final pending = (await device.repo.complete(
      '附件失败也要保留的文字',
      attachments: [media],
    )).entries.single;
    await expectLater(device.repo.syncNow(), throwsA(isA<QuestException>()));
    expect(
      (await device.repo.queryEntries()).entries.single.syncStatus,
      'failed',
    );
    expect((await harness.api('entries', device.tokens))['total'], 0);
    wifi = false;
    await device.repo.removePendingAttachments(pending.id);
    expect(await File(media.localPath!).exists(), isTrue);
    wifi = true;
    await device.repo.syncNow();
    final saved = (await device.repo.queryEntries()).entries.single;
    expect(saved.id, pending.id);
    expect(saved.text, pending.text);
    expect(saved.isSynced, isTrue);
    expect(saved.attachments, isEmpty);
    expect(await File(media.localPath!).exists(), isFalse);
    expect(await corrupt.exists(), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('mobile authorization covers captured commands across batches without blocking new offline records', () async {
    final device = harness.device('metered', wifi: () async => false);
    await device.register('MeteredUser');
    for (var i = 0; i < 5; i++) {
      await device.repo.claim();
      await device.repo.complete('授权批次记录 $i');
      if (i < 4) await device.repo.nextQuest();
    }
    final entered = Completer<void>(), release = Completer<void>();
    device.client.beforeSend = (request) async {
      if (request.url.path == '/api/sync' && !entered.isCompleted) {
        entered.complete();
        await release.future;
      }
    };
    final uploading = device.repo.syncNow(allowMetered: true);
    await entered.future.timeout(const Duration(seconds: 5));
    try {
      await (() async {
        await device.repo.nextQuest();
        await device.repo.claim();
        await device.repo.saveDraft('上传期间仍可离线编辑');
        await device.repo.complete('未授权的新记录');
      })().timeout(const Duration(seconds: 3));
    } finally {
      release.complete();
    }
    await uploading;
    final cloud = await harness.api('entries', device.tokens);
    expect(cloud['total'], 5);
    expect(
      (cloud['entries'] as List).any((e) => e['text'] == '未授权的新记录'),
      isFalse,
    );
    final pending = (await device.repo.queryEntries()).entries.where(
      (e) => !e.isSynced,
    );
    expect(pending.single.text, '未授权的新记录');
    await device.repo.syncNow(); // Mobile data still needs fresh authorization.
    expect((await harness.api('entries', device.tokens))['total'], 5);
    await device.repo.syncNow(allowMetered: true);
    expect((await harness.api('entries', device.tokens))['total'], 6);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('background sync racing account switch never sends A text with B credentials', () async {
    final foreground = harness.device('switch');
    final bob = harness.device('bob-seed');
    await foreground.register('SwitchAlice');
    await bob.register('SwitchBob');
    await bob.repo.claim();
    await bob.repo.saveDraft('Bob cloud draft');
    await bob.repo.syncNow();
    await foreground.repo.claim();
    await foreground.repo.complete('ALICE PRIVATE BODY');
    final entered = Completer<void>(), release = Completer<void>();
    final background = harness.device(
      'background',
      sharedPath: foreground.path,
      tokens: foreground.tokens,
      wifi: () async {
        if (!entered.isCompleted) {
          entered.complete();
          await release.future;
        }
        return true;
      },
    );
    final sync = background.repo.syncNow().catchError((Object _) {});
    await entered.future.timeout(const Duration(seconds: 5));
    final switching = () async {
      try {
        await foreground.repo.logout();
        await foreground.repo.login('SwitchBob', _password);
      } on QuestException {
        /* Safe rejection while another worker owns lease. */
      }
    }();
    await Future.any([
      switching,
      Future<void>.delayed(const Duration(milliseconds: 100)),
    ]);
    release.complete();
    await sync;
    await switching;
    final cloud = await harness.api('entries', bob.tokens);
    expect(cloud['total'], 0);
    expect(
      (await harness.api('state', bob.tokens))['state']['draft'],
      'Bob cloud draft',
    );
    // If switching was deferred/rejected, explicitly switch after the lease ends.
    if ((await foreground.repo.load()).profile?.nickname != 'SwitchBob') {
      await foreground.repo.logout();
      await foreground.repo.login('SwitchBob', _password);
    }
    expect((await foreground.repo.queryEntries()).entries, isEmpty);
    await foreground.repo.logout();
    await foreground.repo.login('SwitchAlice', _password);
    await foreground.repo.syncNow();
    expect(
      (await foreground.repo.queryEntries()).entries.single.text,
      'ALICE PRIVATE BODY',
    );
  }, timeout: const Timeout(Duration(seconds: 60)));
}
