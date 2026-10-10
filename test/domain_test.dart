import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sidequest/domain.dart';

void main() {
  test('catalog has distinct safe, low effort tasks and every role', () {
    expect(questCatalog.length, greaterThanOrEqualTo(16));
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
    expect(nextQuestId('gratitude'), 'green');
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
}
