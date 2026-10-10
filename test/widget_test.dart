import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/main.dart';
import 'package:sidequest/pages.dart';
import 'package:sidequest/repository.dart';

Future<void> showAndTap(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    250,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<LocalQuestRepository> start(
    WidgetTester tester, {
    bool onboarded = false,
    double width = 390,
  }) async {
    tester.view.physicalSize = Size(width, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues(
      onboarded ? {'ui_role': 'employee'} : {},
    );
    final prefs = await SharedPreferences.getInstance();
    final repository = LocalQuestRepository(
      preferences: prefs,
      passwordIterations: 100,
    );
    await tester.pumpWidget(SideQuestApp(repository: repository));
    await tester.pumpAndSettle();
    return repository;
  }

  testWidgets('onboarding requires a role and preferences can be skipped', (
    tester,
  ) async {
    await start(tester);
    expect(find.text('此刻，你的生活角色？'), findsOneWidget);
    final next = find.widgetWithText(FilledButton, '下一步');
    await tester.scrollUntilVisible(next, 300);
    expect(tester.widget<FilledButton>(next).onPressed, isNull);
    await tester.scrollUntilVisible(find.text('学生'), -300);
    await tester.tap(find.text('学生'));
    await tester.pumpAndSettle();
    await showAndTap(tester, next);
    expect(find.text('探索偏好'), findsOneWidget);
    await showAndTap(tester, find.text('跳过，轻松开始'));
    expect(find.text('给日常一点新鲜。'), findsOneWidget);
    expect(find.text('三种绿色'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'quest detail leads to registration before claim, then private completion',
    (tester) async {
      final repository = await start(tester, onboarded: true);
      expect((await repository.load()).profile, isNull);
      await showAndTap(tester, find.text('看看这条支线'));
      expect(find.byType(QuestDetail), findsOneWidget);
      expect((await repository.load()).activeQuestId, isNull);
      await showAndTap(tester, find.text('选择这条支线'));
      expect(find.byType(LoginPage), findsOneWidget);
      final nickname = find.widgetWithText(TextField, '昵称');
      await tester.scrollUntilVisible(
        nickname,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(nickname, '小叶子');
      final password = find.widgetWithText(TextField, '密码');
      await tester.scrollUntilVisible(
        password,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(password, 'testing-password');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await showAndTap(tester, find.byType(CheckboxListTile));
      await showAndTap(tester, find.text('创建账号，继续支线'));
      expect(find.byType(RecordPage), findsOneWidget);
      expect((await repository.load()).activeQuestId, 'green');
      await tester.enterText(find.byType(TextField), '窗边的叶子是柔和的绿色。');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await showAndTap(tester, find.text('完成，收进探索册'));
      expect(find.text('今天多了一点不一样。'), findsOneWidget);
      final state = await repository.load();
      expect(state.profile!.nickname, '小叶子');
      expect(state.entries.single.text, '窗边的叶子是柔和的绿色。');
      expect(state.canRequestNext, isTrue);
      await tester.tap(find.text('看看探索册'));
      await tester.pumpAndSettle();
      expect(find.text('我的探索册'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    '320 logical pixels home, journal, profile and detail do not overflow',
    (tester) async {
      await start(tester, onboarded: true, width: 320);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('探索册'));
      await tester.pumpAndSettle();
      expect(find.text('我的探索册'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('今日'));
      await tester.pumpAndSettle();
      await showAndTap(tester, find.text('看看这条支线'));
      expect(find.byType(QuestDetail), findsOneWidget);
      expect(tester.takeException(), isNull);
      await showAndTap(tester, find.text('选择这条支线'));
      expect(find.byType(LoginPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
