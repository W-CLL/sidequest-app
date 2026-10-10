import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/main.dart';
import 'package:sidequest/repository.dart';

const testNow = '2026-10-10';
const testPassword = 'testing-password';

enum LocalFixture { guest, authenticated, active, completed }

Future<LocalQuestRepository> createLocalFixture({
  LocalFixture fixture = LocalFixture.guest,
  bool onboarded = true,
  String role = 'employee',
  List<String> preferences = const ['观察细节'],
}) async {
  SharedPreferences.setMockInitialValues(
    onboarded
        ? <String, Object>{
            'ui_role': role,
            'ui_preferences': List<String>.from(preferences),
          }
        : <String, Object>{},
  );
  final sharedPreferences = await SharedPreferences.getInstance();
  final repository = LocalQuestRepository(
    preferences: sharedPreferences,
    now: () => DateTime(2026, 10, 10, 12),
    passwordIterations: 100,
  );

  if (onboarded) {
    await repository.savePreferences(role, preferences);
  }
  if (fixture != LocalFixture.guest) {
    await repository.register('小叶子', testPassword);
  }
  if (fixture == LocalFixture.active || fixture == LocalFixture.completed) {
    await repository.claim();
  }
  if (fixture == LocalFixture.completed) {
    await repository.complete('窗边的叶子是柔和的绿色。');
  }
  return repository;
}

AppSnapshot snapshotFixture({
  String recommendedQuestId = 'green',
  bool authenticated = true,
  bool active = false,
  bool completed = false,
}) {
  final profile = authenticated
      ? UserProfile(
          id: 'fixture-user',
          nickname: '小叶子',
          role: 'employee',
          preferences: const ['观察细节'],
        )
      : null;
  return AppSnapshot(
    profile: profile,
    activeQuestId: active ? recommendedQuestId : null,
    recommendedQuestId: recommendedQuestId,
    entries: completed
        ? [
            JournalEntry(
              id: 'fixture-entry',
              questId: recommendedQuestId,
              questTitle: questById(recommendedQuestId).title,
              text: '窗边的叶子是柔和的绿色。',
              createdAt: DateTime(2026, 10, 10, 12),
            ),
          ]
        : const [],
    day: testNow,
    canRequestNext: completed,
  );
}

/// A rendering fixture for states that cannot be reached cheaply through the
/// local repository (for example, every quest in the catalog). Interaction
/// rules continue to be covered by the LocalQuestRepository widget tests.
class SnapshotQuestRepository implements QuestRepository {
  SnapshotQuestRepository(this.snapshot);

  AppSnapshot snapshot;

  @override
  bool get isRemote => false;

  @override
  Future<AppSnapshot> load() async => snapshot;

  @override
  Future<AppSnapshot> savePreferences(
    String role,
    List<String> preferences,
  ) async => snapshot;

  Never _unsupported() => throw UnsupportedError(
    'SnapshotQuestRepository only supports rendering fixtures.',
  );

  @override
  Future<AppSnapshot> register(String nickname, String password) =>
      _unsupported();

  @override
  Future<AppSnapshot> login(String nickname, String password) => _unsupported();

  @override
  Future<AppSnapshot> logout() => _unsupported();

  @override
  Future<AppSnapshot> claim() => _unsupported();

  @override
  Future<AppSnapshot> replace() => _unsupported();

  @override
  Future<AppSnapshot> stop() => _unsupported();

  @override
  Future<AppSnapshot> saveDraft(String text) => _unsupported();

  @override
  Future<AppSnapshot> complete(String text) => _unsupported();

  @override
  Future<AppSnapshot> nextQuest() => _unsupported();

  @override
  Future<AppSnapshot> deleteEntry(String id) => _unsupported();

  @override
  Future<AppSnapshot> deleteAccount(String password) => _unsupported();

  @override
  Future<String> exportData() => _unsupported();
}

void configureTestView(
  WidgetTester tester, {
  Size size = const Size(390, 844),
  double textScale = 1,
  double keyboardInset = 0,
}) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1
    ..viewInsets = FakeViewPadding(bottom: keyboardInset);
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Future<void> pumpSideQuest(
  WidgetTester tester,
  QuestRepository repository,
) async {
  await tester.pumpWidget(SideQuestApp(repository: repository));
  await tester.pumpAndSettle();
}

void expectNoLayoutException(WidgetTester tester) {
  final exceptions = <Object>[];
  Object? exception;
  while ((exception = tester.takeException()) != null) {
    exceptions.add(exception!);
  }
  expect(exceptions, isEmpty, reason: exceptions.join('\n\n'));
}

void expectOnScreen(
  WidgetTester tester,
  Finder finder, {
  double keyboardInset = 0,
}) {
  expect(finder, findsOneWidget);
  final rect = tester.getRect(finder);
  final logicalSize = tester.view.physicalSize / tester.view.devicePixelRatio;
  final availableBottom = logicalSize.height - keyboardInset;
  expect(rect.left, greaterThanOrEqualTo(-0.5));
  expect(rect.right, lessThanOrEqualTo(logicalSize.width + 0.5));
  expect(rect.top, greaterThanOrEqualTo(-0.5));
  expect(
    rect.bottom,
    lessThanOrEqualTo(availableBottom + 0.5),
    reason: '$finder must remain above the visible viewport bottom.',
  );
}

void expectOnScreenAndHitTestable(
  WidgetTester tester,
  Finder finder, {
  double keyboardInset = 0,
}) {
  expectOnScreen(tester, finder, keyboardInset: keyboardInset);
  expect(finder.hitTestable(), findsOneWidget);
}

Future<void> revealAndExpectReachable(
  WidgetTester tester,
  Finder finder, {
  double keyboardInset = 0,
  Key? scrollableKey,
}) async {
  if (finder.evaluate().isEmpty && scrollableKey != null) {
    final scrollable = find.descendant(
      of: find.byKey(scrollableKey),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsWidgets);
    await tester.scrollUntilVisible(finder, 160, scrollable: scrollable.first);
    await tester.pumpAndSettle();
  }
  expect(finder, findsOneWidget);
  if (finder.hitTestable().evaluate().isEmpty) {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
  }
  expectOnScreenAndHitTestable(tester, finder, keyboardInset: keyboardInset);
}

Future<void> revealAndExpectVisible(
  WidgetTester tester,
  Finder finder, {
  double keyboardInset = 0,
  required Key scrollableKey,
}) async {
  if (finder.evaluate().isEmpty) {
    final scrollable = find.descendant(
      of: find.byKey(scrollableKey),
      matching: find.byType(Scrollable),
    );
    expect(scrollable, findsWidgets);
    await tester.scrollUntilVisible(finder, 160, scrollable: scrollable.first);
  } else {
    await tester.ensureVisible(finder);
  }
  await tester.pumpAndSettle();
  expectOnScreen(tester, finder, keyboardInset: keyboardInset);
}

Future<void> revealAndTap(
  WidgetTester tester,
  Finder finder, {
  Key? scrollableKey,
}) async {
  await revealAndExpectReachable(tester, finder, scrollableKey: scrollableKey);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

ScrollableState scrollableStateWithin(Key key, WidgetTester tester) {
  final root = find.byKey(key);
  expect(root, findsOneWidget);
  final scrollable = find.descendant(
    of: root,
    matching: find.byType(Scrollable),
  );
  expect(scrollable, findsWidgets);
  return tester.state<ScrollableState>(scrollable.first);
}

void expectNoExtraScroll(Key key, WidgetTester tester) {
  final position = scrollableStateWithin(key, tester).position;
  expect(
    position.maxScrollExtent,
    lessThanOrEqualTo(0.5),
    reason: '$key should fit the default viewport without scrolling.',
  );
}
