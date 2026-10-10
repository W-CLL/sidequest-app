import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/repository.dart';

class MemoryTokens implements SessionTokenStore {
  String? token;
  @override
  Future<String?> read() async => token;
  @override
  Future<void> write(String value) async {
    token = value;
  }

  @override
  Future<void> clear() async {
    token = null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late DateTime now;
  late LocalQuestRepository repository;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = DateTime(2026, 10, 10, 12);
    repository = LocalQuestRepository(
      preferences: prefs,
      now: () => now,
      passwordIterations: 100,
    );
  });
  Future<AppSnapshot> register([String name = '小探索家']) async {
    await repository.savePreferences('student', ['观察细节']);
    return repository.register(name, 'safe-password');
  }

  test('requires role and login before claiming or replacing', () async {
    expect((await repository.load()).profile, isNull);
    await expectLater(repository.claim(), throwsA(isA<QuestException>()));
    await expectLater(repository.replace(), throwsA(isA<QuestException>()));
    await expectLater(
      repository.register('小探索家', 'safe-password'),
      throwsA(isA<QuestException>()),
    );
    await repository.savePreferences('student', []);
    await expectLater(
      repository.register('小探索家', 'short'),
      throwsA(isA<QuestException>()),
    );
    expect((await register()).profile!.role, 'student');
  });
  test(
    'nickname uniqueness, authentication, IDs and salted passwords',
    () async {
      final first = await register('Alice');
      await repository.logout();
      await expectLater(
        repository.register(' alice ', 'safe-password'),
        throwsA(isA<QuestException>()),
      );
      await expectLater(
        repository.login('Alice', 'wrong-password'),
        throwsA(isA<QuestException>()),
      );
      final logged = await repository.login('alice', 'safe-password');
      expect(logged.profile!.id, first.profile!.id);
      await repository.logout();
      final second = await repository.register('Bob', 'safe-password');
      expect(second.profile!.id, isNot(first.profile!.id));
      final raw = prefs.getString(LocalQuestRepository.storageKey)!;
      expect(raw, isNot(contains('safe-password')));
      final accounts = (jsonDecode(raw) as Map)['accounts'] as Map;
      expect(accounts.values.map((a) => (a as Map)['hash']).toSet().length, 2);
      expect(accounts.values.map((a) => (a as Map)['salt']).toSet().length, 2);
    },
  );
  test(
    'draft and active quest persist across repository instances and login',
    () async {
      await register();
      await repository.claim();
      await repository.saveDraft('绿得像一颗小星星');
      final restored = LocalQuestRepository(
        preferences: prefs,
        now: () => now,
        passwordIterations: 100,
      );
      final state = await restored.load();
      expect(state.activeQuestId, 'green');
      expect(state.draft, '绿得像一颗小星星');
      await restored.logout();
      expect((await restored.load()).entries, isEmpty);
      expect(
        (await restored.login('小探索家', 'safe-password')).draft,
        state.draft,
      );
    },
  );
  test(
    'only one replacement daily; stop, role change and login do not reset it',
    () async {
      await register();
      await repository.claim();
      await repository.saveDraft('保留草稿');
      final changed = await repository.replace();
      expect(changed.activeQuestId, 'light');
      expect(changed.replacementAvailable, isFalse);
      expect(changed.draft, '');
      await repository.saveDraft('停止后仍保留');
      await repository.stop();
      expect((await repository.load()).draft, '停止后仍保留');
      await repository.savePreferences('employee', []);
      await repository.logout();
      await repository.login('小探索家', 'safe-password');
      final claimed = await repository.claim();
      expect(claimed.activeQuestId, 'light');
      await expectLater(repository.replace(), throwsA(isA<QuestException>()));
      await expectLater(repository.nextQuest(), throwsA(isA<QuestException>()));
      now = DateTime(2026, 10, 11);
      expect((await repository.load()).activeQuestId, 'light');
      expect((await repository.replace()).activeQuestId, 'texture');
    },
  );
  test('completion permits exactly one next; deleting entry cannot alter permission', () async {
    await register();
    await repository.claim();
    await expectLater(
      repository.complete('   '),
      throwsA(isA<QuestException>()),
    );
    await expectLater(
      repository.complete(List.filled(301, '字').join()),
      throwsA(isA<QuestException>()),
    );
    final completed = await repository.complete('今天发现一片漂亮的绿色');
    expect(completed.activeQuestId, isNull);
    expect(completed.draft, '');
    expect(completed.canRequestNext, isTrue);
    await expectLater(repository.claim(), throwsA(isA<QuestException>()));
    await expectLater(repository.replace(), throwsA(isA<QuestException>()));
    await repository.deleteEntry(completed.entries.first.id);
    final next = await repository.nextQuest();
    expect(next.recommendedQuestId, 'light');
    expect(next.entries, isEmpty);
    await expectLater(repository.nextQuest(), throwsA(isA<QuestException>()));
  });
  test('entries are stored oldest first and view can reverse them', () async {
    await register();
    await repository.claim();
    await repository.complete('第一条记录');
    await repository.nextQuest();
    await repository.claim();
    now = now.add(const Duration(minutes: 10));
    final state = await repository.complete('第二条记录');
    expect(state.entries.map((e) => e.text).toList(), ['第一条记录', '第二条记录']);
    expect(
      state.entries.first.createdAt.isBefore(state.entries.last.createdAt),
      isTrue,
    );
  });
  test('new day rolls completed recommendation only once and retains unfinished one', () async {
    await register();
    await repository.claim();
    await repository.complete('绿色的书');
    now = DateTime(2026, 10, 11);
    expect((await repository.load()).recommendedQuestId, 'light');
    expect((await repository.load()).recommendedQuestId, 'light');
    now = DateTime(2026, 10, 12);
    expect((await repository.load()).recommendedQuestId, 'light');
  });
  test(
    'concurrent replacements serialize and only consume one allowance',
    () async {
      await register();
      final results = await Future.wait([
        repository.replace().then<Object>((v) => v).catchError((Object e) => e),
        repository.replace().then<Object>((v) => v).catchError((Object e) => e),
      ]);
      expect(results.whereType<AppSnapshot>().length, 1);
      expect(results.whereType<QuestException>().length, 1);
    },
  );
  test('exports omit credentials; account deletion requires password and isolates users', () async {
    await register();
    await repository.claim();
    await repository.complete('仅自己的记录');
    final exported = await repository.exportData();
    expect(exported, contains('仅自己的记录'));
    for (final secret in ['safe-password', 'nicknameKey', 'salt', 'hash']) {
      expect(exported, isNot(contains(secret)));
    }
    await expectLater(
      repository.deleteAccount('incorrect'),
      throwsA(isA<QuestException>()),
    );
    expect((await repository.load()).entries.length, 1);
    await repository.deleteAccount('safe-password');
    await expectLater(
      repository.login('小探索家', 'safe-password'),
      throwsA(isA<QuestException>()),
    );
    expect((await repository.load()).profile, isNull);
    await register();
    expect((await repository.load()).entries, isEmpty);
  });
  test(
    'remote register sends selected preferences and stores bearer token',
    () async {
      final tokens = MemoryTokens();
      final state = AppSnapshot(
        day: '2026-10-10',
        profile: UserProfile(
          id: 'remote-id',
          nickname: '远程用户',
          role: 'student',
          preferences: [],
        ),
      );
      final remote = RemoteQuestRepository(
        apiBaseUrl: 'https://example.test',
        preferences: prefs,
        tokenStore: tokens,
        client: MockClient((request) async {
          if (request.url.path == '/api/register') {
            final body = jsonDecode(request.body) as Map;
            expect(body['role'], 'student');
            expect(body['preferences'], ['观察细节']);
            return http.Response(
              jsonEncode({'token': 'private-token', 'state': state.toJson()}),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }
          expect(request.headers['Authorization'], 'Bearer private-token');
          return http.Response(
            jsonEncode({'state': state.toJson()}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );
      await remote.savePreferences('student', ['观察细节']);
      expect(
        (await remote.register('远程用户', 'safe-password')).profile!.id,
        'remote-id',
      );
      expect(tokens.token, 'private-token');
      await remote.claim();
    },
  );
  test('remote failure keeps credentials and returns server error', () async {
    final tokens = MemoryTokens()..token = 'private-token';
    final remote = RemoteQuestRepository(
      apiBaseUrl: 'https://example.test',
      preferences: prefs,
      tokenStore: tokens,
      client: MockClient(
        (request) async => http.Response(
          jsonEncode({'error': '测试错误'}),
          409,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    await expectLater(
      remote.replace(),
      throwsA(
        isA<QuestException>().having((e) => e.message, 'message', '测试错误'),
      ),
    );
    expect(tokens.token, 'private-token');
  });
  test(
    'expired remote session returns guest state instead of trapping boot',
    () async {
      final tokens = MemoryTokens()..token = 'expired-token';
      var calls = 0;
      final remote = RemoteQuestRepository(
        apiBaseUrl: 'https://example.test',
        preferences: prefs,
        tokenStore: tokens,
        client: MockClient((request) async {
          calls++;
          if (request.headers['Authorization'] != null) {
            return http.Response(jsonEncode({'error': 'session expired'}), 401);
          }
          return http.Response(
            jsonEncode({'state': AppSnapshot(day: '2026-10-10').toJson()}),
            200,
          );
        }),
      );
      expect((await remote.load()).profile, isNull);
      expect(tokens.token, isNull);
      expect(calls, 2);
    },
  );
  test(
    'incorrect account deletion password does not clear a valid remote session',
    () async {
      final tokens = MemoryTokens()..token = 'valid-token';
      final remote = RemoteQuestRepository(
        apiBaseUrl: 'https://example.test',
        tokenStore: tokens,
        client: MockClient(
          (request) async =>
              http.Response(jsonEncode({'error': 'incorrect password'}), 401),
        ),
      );
      await expectLater(
        remote.deleteAccount('bad-password'),
        throwsA(isA<QuestException>()),
      );
      expect(tokens.token, 'valid-token');
    },
  );
  test('remote production URL requires TLS', () {
    expect(
      () => RemoteQuestRepository(apiBaseUrl: 'http://example.test'),
      throwsA(isA<QuestException>()),
    );
    expect(
      () => RemoteQuestRepository(apiBaseUrl: 'https://user:pass@example.test'),
      throwsA(isA<QuestException>()),
    );
    expect(
      RemoteQuestRepository(apiBaseUrl: 'http://10.0.2.2:8787').isRemote,
      isTrue,
    );
  });
}
