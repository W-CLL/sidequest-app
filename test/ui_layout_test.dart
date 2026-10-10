import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/pages.dart';
import 'package:sidequest/repository.dart';

import 'ui_test_harness.dart';

class _ViewportCase {
  const _ViewportCase(this.name, this.size, {this.textScale = 1});

  final String name;
  final Size size;
  final double textScale;
}

const _viewportCases = <_ViewportCase>[
  _ViewportCase('320x568', Size(320, 568)),
  _ViewportCase('360x640', Size(360, 640)),
  _ViewportCase('390x844 at 1.3x text', Size(390, 844), textScale: 1.3),
  _ViewportCase('390x844 at 2.0x text', Size(390, 844), textScale: 2),
];

Finder _navigationIcon(IconData icon) => find.descendant(
  of: find.byType(NavigationBar),
  matching: find.byIcon(icon),
);

Future<void> _clearWidgetTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

Future<void> _pumpSnapshot(WidgetTester tester, AppSnapshot snapshot) async {
  await _clearWidgetTree(tester);
  SharedPreferences.setMockInitialValues(<String, Object>{
    'ui_role': 'employee',
    'ui_preferences': <String>['观察细节'],
  });
  await pumpSideQuest(tester, SnapshotQuestRepository(snapshot));
}

Future<LocalQuestRepository> _pumpLocal(
  WidgetTester tester, {
  LocalFixture fixture = LocalFixture.guest,
  bool onboarded = true,
  bool logOutBeforePump = false,
}) async {
  await _clearWidgetTree(tester);
  final repository = await createLocalFixture(
    fixture: fixture,
    onboarded: onboarded,
  );
  if (logOutBeforePump) {
    await repository.logout();
  }
  await pumpSideQuest(tester, repository);
  return repository;
}

Future<void> _openProfile(WidgetTester tester) async {
  final destination = _navigationIcon(Icons.person_outline);
  expect(destination, findsOneWidget);
  await tester.tap(destination);
  await tester.pumpAndSettle();
}

Future<void> _openJournal(WidgetTester tester) async {
  final destination = _navigationIcon(Icons.menu_book_outlined);
  expect(destination, findsOneWidget);
  await tester.tap(destination);
  await tester.pumpAndSettle();
}

Future<void> _openQuestDetail(WidgetTester tester) async {
  await revealAndTap(
    tester,
    find.byKey(const Key('today-primary-action')),
    scrollableKey: const Key('today-scroll'),
  );
  expect(find.byType(QuestDetail), findsOneWidget);
}

Future<void> _openRecord(WidgetTester tester) async {
  await _openQuestDetail(tester);
  await revealAndTap(tester, find.byKey(const Key('quest-primary-action')));
  expect(find.byType(RecordPage), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('390x844 default viewport', () {
    testWidgets('all role and preference choices fit without body scrolling', (
      tester,
    ) async {
      configureTestView(tester);
      await _pumpLocal(tester, onboarded: false);

      expect(roles, hasLength(8));
      for (final role in roles) {
        expectOnScreenAndHitTestable(
          tester,
          find.byKey(Key('role-${role.id}')),
        );
      }
      expectNoExtraScroll(const Key('onboarding-scroll'), tester);
      expectOnScreen(tester, find.byKey(const Key('onboarding-next-action')));

      await revealAndTap(tester, find.byKey(const Key('role-student')));
      expectNoExtraScroll(const Key('onboarding-scroll'), tester);
      await revealAndTap(
        tester,
        find.byKey(const Key('onboarding-next-action')),
      );

      expect(preferences, hasLength(6));
      for (final preference in preferences) {
        expectOnScreenAndHitTestable(
          tester,
          find.byKey(Key('preference-$preference')),
        );
      }
      expectNoExtraScroll(const Key('onboarding-scroll'), tester);
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('preferences-skip-action')),
      );
      expectNoLayoutException(tester);
    });

    testWidgets('guest, active, and completed Today states need no scrolling', (
      tester,
    ) async {
      configureTestView(tester);

      await _pumpSnapshot(tester, snapshotFixture(authenticated: false));
      expectNoExtraScroll(const Key('today-scroll'), tester);
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('today-primary-action')),
      );
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('replace-quest-action')),
      );
      expectNoLayoutException(tester);

      await _pumpSnapshot(tester, snapshotFixture(active: true));
      expectNoExtraScroll(const Key('today-scroll'), tester);
      for (final key in const [
        'today-primary-action',
        'replace-quest-action',
        'stop-quest-action',
      ]) {
        expectOnScreenAndHitTestable(tester, find.byKey(Key(key)));
      }
      expectNoLayoutException(tester);

      await _pumpSnapshot(tester, snapshotFixture(completed: true));
      expectNoExtraScroll(const Key('today-scroll'), tester);
      expect(find.byKey(const Key('next-quest-action')), findsOneWidget);
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('today-primary-action')),
      );
      expectNoLayoutException(tester);
    });

    testWidgets('initial Journal and guest/authenticated Profile states fit', (
      tester,
    ) async {
      configureTestView(tester);

      await _pumpSnapshot(tester, snapshotFixture(authenticated: false));
      await _openJournal(tester);
      expectNoExtraScroll(const Key('journal-scroll'), tester);
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('journal-empty-action')),
      );
      expectNoLayoutException(tester);

      await _pumpSnapshot(tester, snapshotFixture(authenticated: false));
      await _openProfile(tester);
      expectNoExtraScroll(const Key('profile-scroll'), tester);
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('profile-login-action')),
      );
      expectNoLayoutException(tester);

      await _pumpSnapshot(tester, snapshotFixture());
      await _openProfile(tester);
      expectNoExtraScroll(const Key('profile-scroll'), tester);
      expect(find.byKey(const Key('profile-login-action')), findsNothing);
      expect(find.text('导出我的记录'), findsOneWidget);
      expect(find.text('退出登录'), findsOneWidget);
      expect(find.text('删除账号与全部记录'), findsOneWidget);
      expectNoLayoutException(tester);
    });

    testWidgets('register, login, and initial Record actions are first-fold', (
      tester,
    ) async {
      configureTestView(tester);
      await _pumpLocal(tester);
      await _openProfile(tester);
      await revealAndTap(tester, find.byKey(const Key('profile-login-action')));
      expect(find.byType(LoginPage), findsOneWidget);
      for (final key in const [
        'auth-nickname-field',
        'auth-password-field',
        'auth-consent',
        'auth-submit-action',
      ]) {
        expectOnScreenAndHitTestable(tester, find.byKey(Key(key)));
      }
      final passwordRequirements = find.byKey(
        const Key('auth-password-requirements'),
      );
      expectOnScreen(tester, passwordRequirements);
      expect(tester.widget<Text>(passwordRequirements).maxLines, isNull);
      expect(find.text('创建账号并继续'), findsOneWidget);

      await tester.tap(find.text('登录'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('auth-consent')), findsNothing);
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('auth-submit-action')),
      );
      expect(find.text('登录并继续'), findsOneWidget);
      expectNoLayoutException(tester);

      await _pumpSnapshot(tester, snapshotFixture(active: true));
      await _openRecord(tester);
      expectNoExtraScroll(const Key('record-scroll'), tester);
      for (final key in const [
        'record-text-field',
        'record-save-draft-action',
        'record-complete-action',
      ]) {
        expectOnScreenAndHitTestable(tester, find.byKey(Key(key)));
      }
      expectNoLayoutException(tester);
    });
  });

  testWidgets('all 16 quest details keep the primary action fixed', (
    tester,
  ) async {
    configureTestView(tester);
    expect(questCatalog, hasLength(16));
    for (final quest in questCatalog) {
      await _pumpSnapshot(
        tester,
        snapshotFixture(recommendedQuestId: quest.id),
      );
      await _openQuestDetail(tester);
      expect(find.text(quest.title), findsOneWidget);
      final action = find.byKey(const Key('quest-primary-action'));
      expectOnScreenAndHitTestable(tester, action);
      final actionRect = tester.getRect(action);
      final scrollable = scrollableStateWithin(
        const Key('quest-detail-scroll'),
        tester,
      );
      if (scrollable.position.maxScrollExtent > 0.5) {
        scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      expect(tester.getRect(action).top, closeTo(actionRect.top, 0.5));
      expect(tester.getRect(action).bottom, closeTo(actionRect.bottom, 0.5));
      expectOnScreenAndHitTestable(tester, action);
      expectNoLayoutException(tester);
    }
  });

  for (final viewport in _viewportCases) {
    testWidgets('${viewport.name} keeps every primary interaction reachable', (
      tester,
    ) async {
      configureTestView(
        tester,
        size: viewport.size,
        textScale: viewport.textScale,
      );

      await _pumpLocal(tester, onboarded: false);
      for (final role in roles) {
        await revealAndExpectReachable(
          tester,
          find.byKey(Key('role-${role.id}')),
        );
      }
      await revealAndTap(tester, find.byKey(const Key('role-other')));
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('onboarding-next-action')),
      );
      await revealAndTap(
        tester,
        find.byKey(const Key('onboarding-next-action')),
      );
      for (final preference in preferences) {
        await revealAndExpectReachable(
          tester,
          find.byKey(Key('preference-$preference')),
        );
      }
      await revealAndTap(
        tester,
        find.byKey(const Key('preferences-skip-action')),
      );
      await revealAndExpectReachable(
        tester,
        find.byKey(const Key('replace-quest-action')),
        scrollableKey: const Key('today-scroll'),
      );
      await _openQuestDetail(tester);
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('quest-primary-action')),
      );
      await revealAndTap(tester, find.byKey(const Key('quest-primary-action')));
      expect(find.byType(LoginPage), findsOneWidget);
      for (final key in const [
        'auth-nickname-field',
        'auth-password-field',
        'auth-consent',
      ]) {
        await revealAndExpectReachable(
          tester,
          find.byKey(Key(key)),
          scrollableKey: const Key('auth-scroll'),
        );
        expectOnScreenAndHitTestable(
          tester,
          find.byKey(const Key('auth-submit-action')),
        );
      }
      final passwordRequirements = find.byKey(
        const Key('auth-password-requirements'),
      );
      await revealAndExpectVisible(
        tester,
        passwordRequirements,
        scrollableKey: const Key('auth-scroll'),
      );
      expect(tester.widget<Text>(passwordRequirements).maxLines, isNull);
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('auth-submit-action')),
      );
      expectNoLayoutException(tester);

      await _pumpSnapshot(tester, snapshotFixture(active: true));
      for (final key in const [
        'replace-quest-action',
        'stop-quest-action',
        'today-primary-action',
      ]) {
        await revealAndExpectReachable(
          tester,
          find.byKey(Key(key)),
          scrollableKey: const Key('today-scroll'),
        );
      }
      await _openRecord(tester);
      await revealAndExpectReachable(
        tester,
        find.byKey(const Key('record-text-field')),
        scrollableKey: const Key('record-scroll'),
      );
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('record-save-draft-action')),
      );
      expectOnScreenAndHitTestable(
        tester,
        find.byKey(const Key('record-complete-action')),
      );
      expectNoLayoutException(tester);

      await _pumpSnapshot(tester, snapshotFixture(completed: true));
      expect(find.byKey(const Key('next-quest-action')), findsOneWidget);
      await revealAndExpectReachable(
        tester,
        find.byKey(const Key('today-primary-action')),
        scrollableKey: const Key('today-scroll'),
      );
      expectNoLayoutException(tester);

      await _pumpSnapshot(tester, snapshotFixture(authenticated: false));
      await _openJournal(tester);
      await revealAndExpectReachable(
        tester,
        find.byKey(const Key('journal-empty-action')),
        scrollableKey: const Key('journal-scroll'),
      );
      await _openProfile(tester);
      await revealAndExpectReachable(
        tester,
        find.byKey(const Key('profile-login-action')),
        scrollableKey: const Key('profile-scroll'),
      );
      expectNoLayoutException(tester);
    });
  }

  group('300 logical pixel keyboard inset', () {
    testWidgets('auth fields scroll while the submit action stays visible', (
      tester,
    ) async {
      configureTestView(tester);
      final repository = await _pumpLocal(
        tester,
        fixture: LocalFixture.authenticated,
        logOutBeforePump: true,
      );
      await _openProfile(tester);
      await revealAndTap(tester, find.byKey(const Key('profile-login-action')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();

      final nickname = find.byKey(const Key('auth-nickname-field'));
      final password = find.byKey(const Key('auth-password-field'));
      final passwordRequirements = find.byKey(
        const Key('auth-password-requirements'),
      );
      final consent = find.byKey(const Key('auth-consent'));
      final submit = find.byKey(const Key('auth-submit-action'));
      await revealAndExpectReachable(
        tester,
        nickname,
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      await tester.enterText(nickname, '小叶子');
      await revealAndExpectReachable(
        tester,
        password,
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      await tester.enterText(password, testPassword);
      expect(tester.widget<TextField>(nickname).controller!.text, '小叶子');
      expect(tester.widget<TextField>(password).controller!.text, testPassword);
      await revealAndExpectVisible(
        tester,
        passwordRequirements,
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      expect(tester.widget<Text>(passwordRequirements).maxLines, isNull);
      expectOnScreenAndHitTestable(tester, submit, keyboardInset: 300);

      // A completed form must still surface the local registration validation
      // below the fold while the fixed submit action remains above the keyboard.
      expectOnScreenAndHitTestable(tester, submit, keyboardInset: 300);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await revealAndExpectVisible(
        tester,
        find.text('请先确认已了解测试版账号和隐私说明。'),
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      await revealAndExpectReachable(
        tester,
        consent,
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      expectOnScreenAndHitTestable(tester, submit, keyboardInset: 300);
      await tester.tap(consent);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(consent).value, isTrue);

      // The fixture already owns this nickname, so registration must fail
      // without dismissing or obscuring the form.
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await revealAndExpectVisible(
        tester,
        find.text('这个昵称已被使用，请换一个。'),
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      await revealAndExpectReachable(
        tester,
        consent,
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      expectOnScreenAndHitTestable(tester, submit, keyboardInset: 300);

      // Switch to login, submit a real but incorrect password, and verify the
      // repository error can also be brought into the keyboard-safe viewport.
      final authScroll = scrollableStateWithin(
        const Key('auth-scroll'),
        tester,
      );
      authScroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      final loginSegment = find.text('登录');
      await revealAndExpectReachable(
        tester,
        loginSegment,
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      await tester.tap(loginSegment);
      await tester.pumpAndSettle();
      await revealAndExpectReachable(
        tester,
        password,
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      await tester.enterText(password, 'incorrect-password');
      expectOnScreenAndHitTestable(tester, submit, keyboardInset: 300);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      await revealAndExpectVisible(
        tester,
        find.text('昵称或密码不正确。'),
        keyboardInset: 300,
        scrollableKey: const Key('auth-scroll'),
      );
      expect(find.byKey(const Key('auth-consent')), findsNothing);
      expectOnScreenAndHitTestable(tester, submit, keyboardInset: 300);
      expect((await repository.load()).profile, isNull);
      expectNoLayoutException(tester);
    });

    testWidgets('record editor scrolls while both actions stay visible', (
      tester,
    ) async {
      configureTestView(tester);
      final repository = await _pumpLocal(tester, fixture: LocalFixture.active);
      await _openRecord(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pumpAndSettle();

      final field = find.byKey(const Key('record-text-field'));
      final save = find.byKey(const Key('record-save-draft-action'));
      final complete = find.byKey(const Key('record-complete-action'));
      await revealAndExpectReachable(
        tester,
        field,
        keyboardInset: 300,
        scrollableKey: const Key('record-scroll'),
      );
      final maximumText = List<String>.filled(300, '字').join();
      await tester.enterText(field, maximumText);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(field).controller!.text.runes,
        hasLength(300),
      );
      expect(find.text('300 / 300'), findsOneWidget);

      // An over-limit edit is rejected by the Unicode code-point formatter,
      // retaining the valid 300-code-point draft and counter.
      await tester.enterText(field, '$maximumText超');
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(field).controller!.text, maximumText);
      expect(find.text('300 / 300'), findsOneWidget);
      for (final action in [save, complete]) {
        expectOnScreenAndHitTestable(tester, action, keyboardInset: 300);
      }
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect((await repository.load()).draft, maximumText);
      expect(find.text('草稿已保存，可以晚一点继续。'), findsOneWidget);
      for (final action in [save, complete]) {
        expectOnScreenAndHitTestable(tester, action, keyboardInset: 300);
      }
      expectNoLayoutException(tester);
    });
  });
}
