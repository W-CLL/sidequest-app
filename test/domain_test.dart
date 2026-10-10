import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequest/domain.dart';

void main() {
  test('catalog has distinct safe, low effort tasks and every role', () {
    expect(questCatalog.length, 40);
    expect(questCatalog.map((q) => q.id).toSet().length, questCatalog.length);
    expect(
      questCatalog.every(
        (q) =>
            q.minutes >= 5 &&
            q.minutes <= 15 &&
            q.steps.isNotEmpty &&
            q.hint.isNotEmpty,
      ),
      isTrue,
    );
    expect(roles.length, 8);
    expect(questById('green').title, '三种绿色');
    expect(nextQuestId('gratitude'), 'fold');
    expect(nextQuestId('tiny_plan'), 'green');
    for (final preference in preferences) {
      expect(
        questCatalog.where((q) => q.preferenceTags.contains(preference)).length,
        greaterThanOrEqualTo(8),
      );
    }
    expect(() => questById('unknown'), throwsA(isA<QuestException>()));
    expect(() => nextQuestId('unknown'), throwsA(isA<QuestException>()));
  });
  test('snapshot JSON roundtrip and explicit null copying', () {
    final state = AppSnapshot(
      profile: UserProfile(
        id: 'immutable-id',
        nickname: '小探索家',
        role: 'student',
        preferences: ['观察细节'],
      ),
      activeQuestId: 'green',
      day: '2026-10-10',
      replacedOn: '2026-10-10',
      draft: '草稿',
      entries: [
        JournalEntry(
          id: 'entry',
          questId: 'green',
          questTitle: '三种绿色',
          text: '发现绿色',
          createdAt: DateTime(2026, 10, 10),
        ),
      ],
    );
    final restored = AppSnapshot.fromJson(
      jsonDecode(jsonEncode(state.toJson())) as Map<String, dynamic>,
    );
    expect(restored.toJson(), state.toJson());
    expect(restored.replacementAvailable, isFalse);
    expect(restored.copyWith(day: '2026-10-11').replacementAvailable, isTrue);
    expect(restored.copyWith(activeQuestId: null).activeQuestId, isNull);
    expect(restored.copyWith(profile: null).profile, isNull);
    expect(() => restored.entries.clear(), throwsUnsupportedError);
  });
  test('older snapshots default canRequestNext to false', () {
    expect(AppSnapshot.fromJson({'day': '2026-10-10'}).canRequestNext, isFalse);
  });
  test('catalog source and generated Flutter match', () {
    final source =
        jsonDecode(File('server/catalog.json').readAsStringSync()) as List;
    expect(
      source.map((q) => q['id']).toList(),
      questCatalog.map((q) => q.id).toList(),
    );
    for (var i = 0; i < source.length; i++) {
      expect(source[i]['title'], questCatalog[i].title);
      expect(source[i]['preferenceTags'], questCatalog[i].preferenceTags);
    }
  });
  test('recommendation favors preferences and excludes recent seven', () {
    var history = <String>[];
    String? current;
    for (var i = 0; i < 80; i++) {
      final next = recommendQuestId(
        preferences: const ['熟人同行'],
        history: history,
        currentId: current,
      );
      expect(
        history.skip(history.length > 7 ? history.length - 7 : 0),
        isNot(contains(next)),
      );
      expect(questById(next).preferenceTags, contains('熟人同行'));
      history = appendRecommendation(history, next);
      current = next;
    }
    expect(history.length, 40);
  });
  test('empty preferences rotate from current; day is Shanghai', () {
    expect(
      recommendQuestId(preferences: [], history: ['paper'], currentId: 'paper'),
      'detail',
    );
    expect(localDay(DateTime.utc(2026, 10, 10, 16)), '2026-10-11');
  });
  test('media mixed limits and pending models roundtrip', () {
    final media = [
      for (var i = 0; i < 5; i++)
        MediaAttachment(id: 'photo-$i', kind: MediaKind.image),
      const MediaAttachment(
        id: 'video',
        kind: MediaKind.video,
        durationMs: 15000,
      ),
      const MediaAttachment(
        id: 'audio',
        kind: MediaKind.audio,
        durationMs: 60000,
      ),
    ];
    validateMedia(media);
    expect(
      () => validateMedia([
        ...media,
        const MediaAttachment(id: 'photo-6', kind: MediaKind.image),
      ]),
      throwsA(isA<QuestException>()),
    );
    expect(
      () => validateMedia([
        const MediaAttachment(
          id: 'v',
          kind: MediaKind.video,
          durationMs: 15001,
        ),
      ]),
      throwsA(isA<QuestException>()),
    );
    expect(
      () => validateMedia([
        const MediaAttachment(
          id: 'a',
          kind: MediaKind.audio,
          durationMs: 60001,
        ),
      ]),
      throwsA(isA<QuestException>()),
    );
    final entry = JournalEntry(
      id: 'e',
      questId: 'green',
      questTitle: '三种绿色',
      text: '测试',
      createdAt: DateTime.utc(2026),
      attachments: media,
      syncStatus: 'pending',
    );
    expect(JournalEntry.fromJson(entry.toJson()).toJson(), entry.toJson());
    expect(entry.isSynced, false);
  });
  test('media metadata never truncates invalid fractional durations', () {
    for (final invalid in [-1, 15000.9, double.infinity]) {
      expect(
        () => MediaAttachment.fromJson({
          'id': 'v',
          'kind': 'video',
          'durationMs': invalid,
        }),
        throwsA(isA<QuestException>()),
      );
    }
    expect(
      () => validateMedia([
        const MediaAttachment(id: 'a', kind: MediaKind.audio, durationMs: 0),
      ]),
      throwsA(isA<QuestException>()),
    );
  });
  test('conflict draft retains its immutable records-only branch', () {
    final draft = ConflictDraft(
      id: 'd',
      questId: 'green',
      text: '离线草稿',
      createdAt: DateTime.utc(2026),
      branchId: 'old-branch',
      baseRevision: 3,
    );
    final restored = ConflictDraft.fromJson(draft.toJson());
    expect(restored.branchId, 'old-branch');
    expect(restored.baseRevision, 3);
  });
  test(
    'progress-only queue still requires sync without inflating record counts',
    () {
      const summary = SyncSummary(queuedCommands: 3);
      expect(summary.pending, 0);
      expect(summary.uploading, 0);
      expect(summary.failed, 0);
      expect(summary.hasPending, isTrue);
    },
  );
}
