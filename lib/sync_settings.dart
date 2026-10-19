import 'package:shared_preferences/shared_preferences.dart';

import 'domain.dart';

/// Device-local consent shared by foreground and WorkManager isolates.
/// Reload on every read: another isolate may have changed the setting.
class SyncSettings {
  SyncSettings({this.preferences});

  static const mobileDataKey = 'sidequest.sync.mobileDataEnabled';
  final SharedPreferences? preferences;

  Future<bool> getMobileDataSyncEnabled() async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(mobileDataKey) ?? false;
  }

  Future<void> setMobileDataSyncEnabled(bool enabled) async {
    final prefs = preferences ?? await SharedPreferences.getInstance();
    if (!await prefs.setBool(mobileDataKey, enabled)) {
      throw const QuestException('设置没保存，再试一次。');
    }
  }
}
