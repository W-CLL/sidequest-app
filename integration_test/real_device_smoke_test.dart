// 真机端到端冒烟测试（integration_test 在设备上运行真实应用与真实插件）。
//
// 目的：绕开 HyperOS 对 adb 输入注入的限制，在真机上通过 Flutter 引擎内部
// 手势驱动真实应用：注册账号 → 开始今日活动 → 写记录并保存 → 探索册确认。
// 依赖：API_BASE_URL dart-define 指向本地服务（本机经 adb reverse tcp:8787）。
//
// 运行：
//   flutter test integration_test/real_device_smoke_test.dart \
//     -d <无线调试设备号> --dart-define=API_BASE_URL=http://127.0.0.1:8787
//
// 该文件为本地真机验证新增，不属于生产代码。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:sidequest/main.dart' as app;

const nickname = 'shiyan02';
const password = 'testpass123';
const recordText = '真机冒烟01 smoke e2e 记录';

Future<void> waitFor(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  String? note,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isNotEmpty) return;
  }
  fail('waitFor 超时${note == null ? '' : '（$note）'}: $finder');
}

Future<void> waitGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
  String? note,
}) async {
  final end = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 200));
    if (finder.evaluate().isEmpty) return;
  }
  fail('waitGone 超时${note == null ? '' : '（$note）'}: $finder');
}

Future<void> tapText(WidgetTester tester, String text,
    {Duration settle = const Duration(milliseconds: 400)}) async {
  final finder = find.text(text);
  await waitFor(tester, finder, note: text);
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pump(settle);
}

Future<void> tapKey(WidgetTester tester, Key key,
    {Duration settle = const Duration(milliseconds: 400)}) async {
  final finder = find.byKey(key);
  await waitFor(tester, finder, note: '$key');
  await tester.ensureVisible(finder);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.tap(finder);
  await tester.pump(settle);
}

Future<void> tapNav(WidgetTester tester, String label) async {
  final finder = find.descendant(
    of: find.byType(NavigationBar),
    matching: find.text(label),
  );
  await waitFor(tester, finder, note: '底部导航 $label');
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真机冒烟：注册 → 开始活动 → 记录 → 保存 → 探索册', (tester) async {
    app.main();
    await tester.pump(const Duration(seconds: 3));

    // 若为全新安装（无本地偏好），先完成最简引导；已有状态则跳过。
    if (find.byKey(const ValueKey('role-student')).evaluate().isNotEmpty) {
      await tapKey(tester, const ValueKey('role-student'));
      await tapKey(tester, const ValueKey('onboarding-next-action'));
      if (find.byKey(const ValueKey('preference-安静独处')).evaluate().isNotEmpty) {
        await tapKey(tester, const ValueKey('preference-安静独处'));
        await tapKey(tester, const ValueKey('onboarding-next-action'),
            settle: const Duration(milliseconds: 900));
      }
    }

    await waitFor(tester, find.byType(NavigationBar), note: '首页导航栏');
    debugPrint('E2E_STEP=home');

    // 1) 「我的」→ 注册
    await tapNav(tester, '我的');
    await tapText(tester, '登录 / 创建昵称',
        settle: const Duration(milliseconds: 700));
    await waitFor(tester, find.text('从一件小事开始'), note: '登录页');

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), nickname);
    await tester.pump(const Duration(milliseconds: 150));
    await tester.enterText(fields.at(1), password);
    await tester.pump(const Duration(milliseconds: 150));
    final agreement = find.byType(CheckboxListTile);
    if (agreement.evaluate().isNotEmpty) {
      await tester.ensureVisible(agreement);
      await tester.tap(agreement);
      await tester.pump(const Duration(milliseconds: 150));
    }
    await tapText(tester, '创建账号并继续',
        settle: const Duration(milliseconds: 500));

    // 注册为真实网络往返：登录页消失即注册成功返回
    await waitGone(tester, find.text('从一件小事开始'),
        timeout: const Duration(seconds: 45), note: '注册返回');
    final loggedIn = find.text('上传与同步').evaluate().isNotEmpty;
    debugPrint('E2E_STEP=registered loggedIn=$loggedIn');

    // 2) 今日 → 查看详情 → 开始
    await tapNav(tester, '今日');
    await tapKey(tester, const ValueKey('today-primary-action'),
        settle: const Duration(milliseconds: 700));
    await waitFor(tester, find.text('探索详情'), note: '活动详情页');
    await tapKey(tester, const Key('quest-primary-action'),
        settle: const Duration(milliseconds: 800));
    debugPrint('E2E_STEP=claiming');

    // 3) 记录页：写文字 → 完成并保存
    await waitFor(tester, find.text('完成并保存'),
        timeout: const Duration(seconds: 45), note: '记录页（含 claim）');
    await tester.enterText(find.byType(TextField).first, recordText);
    await tester.pump(const Duration(milliseconds: 300));
    await tapText(tester, '完成并保存',
        settle: const Duration(milliseconds: 800));
    debugPrint('E2E_STEP=completing');

    // 4) 保存结果弹窗（真实回执等待，可能先本机后上传）
    await waitFor(tester, find.text('回到今日'),
        timeout: const Duration(seconds: 60), note: '保存结果弹窗');
    final synced = find.textContaining('已保存到探索册').evaluate().isNotEmpty;
    debugPrint('E2E_SYNC=${synced ? 'synced' : 'pending'}');
    await tapText(tester, '回到今日', settle: const Duration(milliseconds: 500));
    debugPrint('E2E_STEP=saved');

    // 5) 探索册确认记录可见
    await tapNav(tester, '探索册');
    await waitFor(tester, find.textContaining('真机冒烟01'),
        timeout: const Duration(seconds: 45), note: '探索册条目');
    debugPrint('E2E_JOURNAL_OK');

    // 留出前台自动同步的时间，便于服务端核对
    await tester.pump(const Duration(seconds: 20));
    debugPrint('E2E_DONE');
  },
      timeout: const Timeout(Duration(minutes: 10)));
}
