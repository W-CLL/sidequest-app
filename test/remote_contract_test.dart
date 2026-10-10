import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/repository.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _MemorySessionTokens implements SessionTokenStore {
  String? value;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String token) async => value = token;
  @override
  Future<void> clear() async => value = null;
}

Future<String> _nodeExecutable() async {
  final configured = Platform.environment['SIDEQUEST_NODE'];
  final candidates = <String>[
    if (configured != null && configured.isNotEmpty) configured,
    'node',
  ];
  for (final candidate in candidates) {
    try {
      final result = await Process.run(candidate, [
        '--version',
      ]).timeout(const Duration(seconds: 5));
      if (result.exitCode == 0 &&
          result.stdout.toString().trim().startsWith('v24.')) {
        return candidate;
      }
    } on ProcessException {
      // Try the configured executable or Node.js on PATH.
    } on TimeoutException {
      // A stuck executable is not a valid runtime for this bounded test.
    }
    if (configured != null && candidate == configured) {
      throw StateError(
        'SIDEQUEST_NODE must point to a working Node.js 24 executable.',
      );
    }
  }
  throw StateError(
    'Node.js 24 is required for the real API contract test. Install it or set SIDEQUEST_NODE.',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Flutter remote repository and real Node API obey the complete private-account contract', () async {
    final node = await _nodeExecutable();
    final serverFile = File('server/server.mjs').absolute;
    expect(
      serverFile.existsSync(),
      isTrue,
      reason: 'Run flutter test from the app directory.',
    );
    final directory = await Directory.systemTemp.createTemp(
      'sidequest-contract-',
    );
    Process? server;
    StreamSubscription<String>? output;
    StreamSubscription<String>? errors;
    final clients = <IOClient>[];
    try {
      // Port zero lets the operating system allocate an unused port atomically.
      // Only the port is printed, never request bodies, tokens or passwords.
      const harness = r'''
const { createApp } = await import(process.argv[1]);
const app = createApp({ databasePath: process.argv[2] });
app.server.listen(0, '127.0.0.1', () => {
  process.stdout.write(JSON.stringify({port: app.server.address().port}) + '\n');
});
process.on('SIGTERM', () => app.close().then(() => process.exit(0)));
''';
      server = await Process.start(node, [
        '--input-type=module',
        '-e',
        harness,
        serverFile.uri.toString(),
        '${directory.path}${Platform.pathSeparator}contract.sqlite',
      ]);
      final listening = Completer<int>();
      output = server.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            if (listening.isCompleted) return;
            try {
              final port = (jsonDecode(line) as Map)['port'];
              if (port is int && port > 0) listening.complete(port);
            } on FormatException {
              // Non-protocol startup output is deliberately not echoed.
            }
          });
      errors = server.stderr.transform(utf8.decoder).listen((_) {});
      unawaited(
        server.exitCode.then((code) {
          if (!listening.isCompleted) {
            listening.completeError(
              StateError('Temporary API exited before readiness (code $code).'),
            );
          }
        }),
      );
      final port = await listening.future.timeout(const Duration(seconds: 8));
      final baseUrl = 'http://127.0.0.1:$port';
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      IOClient realClient() {
        // Widget bindings install a rejecting HttpClient by default. Explicitly
        // disable only that override for these loopback integration clients.
        final client = HttpOverrides.runWithHttpOverrides(
          () => IOClient(
            HttpClient()..connectionTimeout = const Duration(seconds: 3),
          ),
          _RealHttpOverrides(),
        );
        clients.add(client);
        return client;
      }

      RemoteQuestRepository repository(_MemorySessionTokens tokens) =>
          RemoteQuestRepository(
            apiBaseUrl: baseUrl,
            preferences: prefs,
            tokenStore: tokens,
            client: realClient(),
          );
      final aliceTokens = _MemorySessionTokens();
      final bobTokens = _MemorySessionTokens();
      final guestTokens = _MemorySessionTokens();
      final alice = repository(aliceTokens);
      final bob = repository(bobTokens);
      final guest = repository(guestTokens);
      const password = 'contract-password-123';
      final failure = throwsA(isA<QuestException>());

      expect((await guest.load()).profile, isNull);
      await expectLater(guest.claim(), failure);
      await expectLater(guest.exportData(), failure);
      await alice.savePreferences('student', ['观察细节']);
      final registered = await alice.register('Ａlice', password);
      final aliceId = registered.profile!.id;
      expect(registered.profile!.nickname, 'Alice');
      expect(registered.profile!.role, 'student');
      expect(registered.profile!.preferences, ['观察细节']);
      expect(aliceTokens.value, isNotNull);
      await bob.savePreferences('employee', ['熟悉安心']);
      await expectLater(bob.register('alice', password), failure);
      expect(bobTokens.value, isNull);
      final bobState = await bob.register('Bob', password);
      expect(bobState.profile!.id, isNot(aliceId));

      expect((await alice.claim()).activeQuestId, 'green');
      expect((await alice.saveDraft('窗边有三种绿')).draft, '窗边有三种绿');
      final restored = repository(aliceTokens);
      expect((await restored.load()).draft, '窗边有三种绿');
      final completed = await alice.complete('第一条私密发现');
      expect(completed.canRequestNext, isTrue);
      expect(completed.activeQuestId, isNull);
      expect(completed.draft, isEmpty);
      final firstEntry = completed.entries.single;
      await expectLater(alice.claim(), failure);
      await expectLater(alice.saveDraft('完成后不可继续写'), failure);
      expect((await bob.load()).entries, isEmpty);
      await expectLater(bob.deleteEntry(firstEntry.id), failure);
      expect((await guest.load()).entries, isEmpty);
      expect((await alice.nextQuest()).recommendedQuestId, 'light');
      await alice.claim();
      await alice.saveDraft('换题前的草稿');
      final replaced = await alice.replace();
      expect(replaced.activeQuestId, 'texture');
      expect(replaced.draft, isEmpty);
      expect(replaced.replacementAvailable, isFalse);
      await expectLater(alice.replace(), failure);
      await alice.saveDraft('停止之后保留');
      expect((await alice.stop()).draft, '停止之后保留');
      await expectLater(alice.saveDraft('停止之后不可改'), failure);
      expect((await alice.claim()).draft, '停止之后保留');
      final twoEntries = await alice.complete('第二条私密发现');
      expect(twoEntries.entries.map((entry) => entry.text).toList(), [
        '第一条私密发现',
        '第二条私密发现',
      ]);
      await alice.savePreferences('freelancer', ['动手创作']);

      final revoked = aliceTokens.value!;
      expect((await alice.logout()).profile, isNull);
      expect(aliceTokens.value, isNull);
      final raw = realClient();
      final revokedResponse = await raw.get(
        Uri.parse('$baseUrl/api/state'),
        headers: {'Authorization': 'Bearer $revoked'},
      );
      expect(revokedResponse.statusCode, 401);
      await expectLater(alice.login('Alice', 'incorrect-password'), failure);
      final loggedIn = await alice.login('ALICE', password);
      expect(loggedIn.profile!.id, aliceId);
      expect(loggedIn.profile!.role, 'freelancer');
      expect(loggedIn.profile!.preferences, ['动手创作']);
      expect(loggedIn.entries.length, 2);
      final exportedText = await alice.exportData();
      final exported = jsonDecode(exportedText) as Map;
      expect(((exported['state'] as Map)['entries'] as List).length, 2);
      for (final secret in [
        password,
        aliceTokens.value!,
        'password_hash',
        'password_salt',
        'token_hash',
      ]) {
        expect(exportedText, isNot(contains(secret)));
      }
      expect((await alice.deleteEntry(firstEntry.id)).entries.length, 1);
      await expectLater(alice.deleteAccount('incorrect-password'), failure);
      final deletedSession = aliceTokens.value!;
      expect((await alice.deleteAccount(password)).profile, isNull);
      expect(aliceTokens.value, isNull);
      expect(
        (await raw.get(
          Uri.parse('$baseUrl/api/state'),
          headers: {'Authorization': 'Bearer $deletedSession'},
        )).statusCode,
        401,
      );
      await expectLater(alice.login('Alice', password), failure);
      expect((await bob.load()).profile!.id, bobState.profile!.id);
      expect((await bob.load()).entries, isEmpty);
      await bob.deleteAccount(password);
      expect((await guest.load()).profile, isNull);
    } finally {
      for (final client in clients) {
        client.close();
      }
      if (server != null) {
        server.kill();
        try {
          await server.exitCode.timeout(const Duration(seconds: 3));
        } on TimeoutException {
          server.kill(ProcessSignal.sigkill);
          await server.exitCode.timeout(const Duration(seconds: 3));
        }
      }
      await output?.cancel();
      await errors?.cancel();
      // Delete only the unique directory created by this test, never its parent.
      expect(
        directory.parent.absolute.path,
        Directory.systemTemp.absolute.path,
      );
      expect(
        directory.uri.pathSegments.where((part) => part.isNotEmpty).last,
        startsWith('sidequest-contract-'),
      );
      if (await directory.exists()) await directory.delete(recursive: true);
    }
  }, timeout: const Timeout(Duration(seconds: 45)));
}
