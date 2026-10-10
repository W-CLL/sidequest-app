import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequest/domain.dart';

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
      // Only the explicit override and PATH are allowed, never a local SDK path.
    } on TimeoutException {
      // Report an unusable override rather than masking it with another runtime.
    }
    if (configured != null && candidate == configured) {
      throw StateError(
        'SIDEQUEST_NODE must point to a working Node.js 24 executable.',
      );
    }
  }
  throw StateError(
    'Node.js 24 is required for catalog parity. Install it on PATH or set SIDEQUEST_NODE.',
  );
}

void main() {
  test('Dart and Node agree across eight preference profiles and 200 recommendations each', () async {
    final node = await _nodeExecutable();
    final catalogModule = File('server/catalog.mjs').absolute;
    expect(catalogModule.existsSync(), isTrue);
    final ids = questCatalog.map((quest) => quest.id).toList();
    final profiles = <List<String>>[
      [],
      for (final preference in preferences) [preference],
      preferences.take(3).toList(),
    ];
    final histories = <List<String>>[
      [],
      ['retired_activity', ...ids.take(7)],
      [...ids],
      [...ids, ...ids.take(5)],
      List.filled(10, 'green'),
      ids.reversed.toList(),
      ['retired_activity', 'another_old_activity'],
      ids.skip(10).take(8).toList(),
    ];
    final fixtures = List.generate(profiles.length, (index) {
      final history = histories[index];
      return <String, dynamic>{
        'preferences': profiles[index],
        'history': history,
        'currentId': history.isEmpty
            ? null
            : history.lastWhere(ids.contains, orElse: () => 'green'),
      };
    });
    const harness = r'''
const { recommendQuest, appendRecommendation } = await import(process.argv[1]);
const fixtures = JSON.parse(process.argv[2]);
const results = fixtures.map(fixture => {
  let history = [...fixture.history], currentId = fixture.currentId;
  const sequence = [];
  for (let iteration = 0; iteration < 200; iteration++) {
    const next = recommendQuest({ preferences: fixture.preferences, history, currentId });
    sequence.push(next);
    history = appendRecommendation(history, next);
    currentId = next;
  }
  return { sequence, history };
});
process.stdout.write(JSON.stringify(results));
''';
    final result = await Process.run(node, [
      '--input-type=module',
      '-e',
      harness,
      catalogModule.uri.toString(),
      jsonEncode(fixtures),
    ]).timeout(const Duration(seconds: 10));
    expect(result.exitCode, 0, reason: result.stderr.toString());
    final reference = jsonDecode(result.stdout.toString()) as List;
    expect(reference, hasLength(8));
    for (var profile = 0; profile < fixtures.length; profile++) {
      var history = List<String>.from(histories[profile]);
      var currentId = fixtures[profile]['currentId'] as String?;
      final expected = List<String>.from(
        (reference[profile] as Map)['sequence'] as List,
      );
      for (var iteration = 0; iteration < 200; iteration++) {
        final next = recommendQuestId(
          preferences: profiles[profile],
          history: history,
          currentId: currentId,
        );
        expect(
          next,
          expected[iteration],
          reason: 'profile=$profile iteration=$iteration history=$history',
        );
        final valid = history.where(ids.contains).toList();
        final recent = valid.skip(valid.length > 7 ? valid.length - 7 : 0);
        expect(recent, isNot(contains(next)));
        expect(next, isNot(currentId));
        history = appendRecommendation(history, next);
        expect(history.length, lessThanOrEqualTo(40));
        currentId = next;
      }
      expect(history, (reference[profile] as Map)['history']);
    }
  }, timeout: const Timeout(Duration(seconds: 30)));
}
