import 'domain.dart';

/// 「支线」给用户看的一句话。
///
/// 主题：先行动，再记录。报错只说一句温和的话，技术细节不出现在界面上；
/// 细节交给 SilentReporter 静默上报（见 lib/silent_reporter.dart）。
String userMessageFor(Object error) {
  if (error is QuestException) {
    final message = error.message.trim();
    if (message.isNotEmpty && !_isTechnical(message)) return message;
    return '这次没成功，稍后再试一下。';
  }
  final raw = error.toString();
  if (_networkPattern.hasMatch(raw)) return '这次没连上，稍后再试一下。';
  if (raw.contains('TimeoutException')) return '等太久了，稍后再试一下。';
  if (raw.contains('DatabaseException') || raw.contains('sqlite')) {
    return '手机这边没存上，再试一次。';
  }
  return '这次没成功，稍后再试一下。';
}

final RegExp _networkPattern = RegExp(
  'SocketException|ClientException|Failed host lookup|Connection refused|'
  'Connection reset|Network is unreachable',
);

final RegExp _technicalPattern = RegExp(
  r'Exception|api/|http|HTTP|status|stack|\.dart|#\d|code=|API_BASE_URL|协议|protocol',
);

bool _isTechnical(String text) =>
    _technicalPattern.hasMatch(text) || text.length > 60;
