import 'dart:async';

/// 静默上报：错误细节只进后台，界面上永远不展示。
///
/// - 每次运行最多 [limit] 条；同一条（scope+message）在 [window] 内只报一次；
/// - 发送失败一律吞掉——上报绝不能打扰用户。
class SilentReporter {
  SilentReporter(
    this._send, {
    this.limit = 6,
    this.window = const Duration(minutes: 30),
  });

  final Future<void> Function(Map<String, Object?> payload) _send;
  final int limit;
  final Duration window;
  final Map<String, DateTime> _seen = <String, DateTime>{};
  int _sent = 0;

  void report(Object error, String scope, {String? client}) {
    if (_sent >= limit) return;
    final message = _clip(error.toString(), 300);
    final key =
        '$scope|${message.length > 120 ? message.substring(0, 120) : message}';
    final at = DateTime.now();
    final last = _seen[key];
    if (last != null && at.difference(last) < window) return;
    _seen[key] = at;
    _sent += 1;
    final payload = <String, Object?>{
      'scope': scope,
      'type': error.runtimeType.toString(),
      'message': message,
      'client': client,
      'at': at.toUtc().toIso8601String(),
    };
    unawaited(() async {
      try {
        await _send(payload);
      } catch (_) {
        // 静默：上报失败不影响用户。
      }
    }());
  }
}

String _clip(String value, int max) =>
    value.length <= max ? value : value.substring(0, max);
