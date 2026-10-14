import 'dart:js_interop';

import 'package:web/web.dart' as web;

/// 网页版：关闭/刷新页面前，如果草稿还没保存完，弹出浏览器的通用离开确认。
///
/// 只做“尽力而为”的保护：文案由浏览器统一给出，应用无法自定义；
/// 通过单例回调避免记录页反复打开时堆积监听器。
void attachUnsavedDraftGuard(bool Function() hasUnsaved) {
  _current = hasUnsaved;
  if (_installed) return;
  _installed = true;
  final listener = ((web.BeforeUnloadEvent event) {
    if (_current?.call() ?? false) {
      event.preventDefault();
      event.returnValue = '';
    }
  }).toJS;
  web.window.addEventListener('beforeunload', listener);
}

bool Function()? _current;
bool _installed = false;
