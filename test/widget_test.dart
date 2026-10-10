import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sidequest/pages.dart';

import 'ui_test_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<InMemoryQuestRepository> start(
    WidgetTester tester, {
    bool onboarded = false,
    double width = 390,
    double height = 844,
  }) async {
    configureTestView(tester, size: Size(width, height));
    final repository = await createLocalFixture(
      onboarded: onboarded,
      preferences: const [],
    );
    await pumpSideQuest(tester, repository);
    return repository;
  }

  testWidgets('onboarding requires a role and preferences can be skipped', (
    tester,
  ) async {
    await start(tester);
    expect(find.text('此刻，你的生活角色？'), findsOneWidget);
    final next = find.byKey(const Key('onboarding-next-action'));
    expectOnScreen(tester, next);
    expect(tester.widget<FilledButton>(next).onPressed, isNull);
    await revealAndTap(tester, find.byKey(const Key('role-student')));
    await revealAndTap(tester, next);
    expect(find.text('探索偏好'), findsOneWidget);
    await revealAndTap(
      tester,
      find.byKey(const Key('preferences-skip-action')),
    );
    expect(find.text('给日常一点新鲜。'), findsOneWidget);
    expect(find.text('三种绿色'), findsOneWidget);
    expectNoLayoutException(tester);
  });
  testWidgets(
    'quest detail leads to registration before claim, then private completion',
    (tester) async {
      final repository = await start(tester, onboarded: true);
      expect((await repository.load()).profile, isNull);
      await revealAndTap(tester, find.byKey(const Key('today-primary-action')));
      expect(find.byType(QuestDetail), findsOneWidget);
      expect((await repository.load()).activeQuestId, isNull);
      await revealAndTap(tester, find.byKey(const Key('quest-primary-action')));
      expect(find.byType(LoginPage), findsOneWidget);
      final nickname = find.byKey(const Key('auth-nickname-field'));
      await tester.enterText(nickname, '小叶子');
      final password = find.byKey(const Key('auth-password-field'));
      await tester.enterText(password, 'testing-password');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await revealAndTap(tester, find.byKey(const Key('auth-consent')));
      await revealAndTap(tester, find.byKey(const Key('auth-submit-action')));
      expect(find.byType(RecordPage), findsOneWidget);
      expect((await repository.load()).activeQuestId, 'green');
      await tester.enterText(
        find.byKey(const Key('record-text-field')),
        '窗边的叶子是柔和的绿色。',
      );
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await revealAndTap(
        tester,
        find.byKey(const Key('record-complete-action')),
      );
      expect(find.text('已存到本机，等待上传'), findsOneWidget);
      final state = await repository.load();
      expect(state.profile!.nickname, '小叶子');
      expect(state.entries.single.text, '窗边的叶子是柔和的绿色。');
      expect(state.canRequestNext, isTrue);
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('查看探索册'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('我的探索册'), findsOneWidget);
      expectNoLayoutException(tester);
    },
  );
  testWidgets('compact home, journal, profile and detail remain reachable', (
    tester,
  ) async {
    await start(tester, onboarded: true, width: 320, height: 568);
    expectNoLayoutException(tester);
    await tester.tap(find.text('探索册'));
    await tester.pumpAndSettle();
    expect(find.text('我的探索册'), findsOneWidget);
    expectNoLayoutException(tester);
    await tester.tap(find.text('我的'));
    await tester.pumpAndSettle();
    expectNoLayoutException(tester);
    await tester.tap(find.text('今日'));
    await tester.pumpAndSettle();
    await revealAndTap(tester, find.byKey(const Key('today-primary-action')));
    expect(find.byType(QuestDetail), findsOneWidget);
    expectNoLayoutException(tester);
    await revealAndTap(tester, find.byKey(const Key('quest-primary-action')));
    expect(find.byType(LoginPage), findsOneWidget);
    expectNoLayoutException(tester);
  });
}
