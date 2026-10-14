import 'package:flutter_test/flutter_test.dart';
import 'package:sidequest/domain.dart';
import 'package:sidequest/silent_reporter.dart';
import 'package:sidequest/voice.dart';

void main() {
  group('userMessageFor 只给一句温和的话', () {
    test('写给用户的仓储文案原样透传', () {
      expect(
        userMessageFor(const QuestException('这个昵称已被使用，请换一个')),
        '这个昵称已被使用，请换一个',
      );
    });

    test('技术性文案被替换成统一提示', () {
      expect(
        userMessageFor(const QuestException('API_BASE_URL 未配置，需要协议 2')),
        '这次没成功，稍后再试一下。',
      );
    });

    test('网络异常映射为断网提示', () {
      expect(
        userMessageFor(StateError('SocketException: Connection refused')),
        '这次没连上，稍后再试一下。',
      );
    });

    test('超时与本地存储异常各有专句', () {
      expect(
        userMessageFor(Exception('TimeoutException after 20s')),
        '等太久了，稍后再试一下。',
      );
      expect(
        userMessageFor(Exception('DatabaseException(disk I/O error)')),
        '手机这边没存上，再试一次。',
      );
    });

    test('未知异常落到兜底句', () {
      expect(userMessageFor(Object()), '这次没成功，稍后再试一下。');
    });
  });

  group('SilentReporter 静默规则', () {
    test('同一错误窗口内只报一次，且总量有上限', () async {
      final sent = <Map<String, Object?>>[];
      final reporter = SilentReporter(
        (payload) async => sent.add(payload),
        limit: 3,
      );
      reporter.report(StateError('boom'), 'home.load');
      reporter.report(StateError('boom'), 'home.load'); // 窗口内重复 → 丢弃
      reporter.report(StateError('boom2'), 'home.load');
      reporter.report(StateError('boom'), 'other.scope');
      reporter.report(StateError('boom3'), 'home.load'); // 超过上限 → 丢弃
      await Future<void>.delayed(Duration.zero);
      expect(
        sent.map((item) => item['scope']).toList(),
        ['home.load', 'home.load', 'other.scope'],
      );
      expect(sent.first['type'], 'StateError');
      expect(sent.first['message'], 'Bad state: boom');
    });

    test('发送失败被静默吞掉', () async {
      final reporter = SilentReporter(
        (payload) => Future<void>.error(StateError('offline')),
      );
      reporter.report(StateError('boom'), 'x');
      await Future<void>.delayed(Duration.zero);
      // 到这里不抛异常即为通过
    });
  });
}
