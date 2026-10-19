import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/sync_settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'mobile data consent defaults off and persists for new readers',
    () async {
      final settings = SyncSettings();
      expect(await settings.getMobileDataSyncEnabled(), isFalse);
      await settings.setMobileDataSyncEnabled(true);
      expect(await SyncSettings().getMobileDataSyncEnabled(), isTrue);
      await settings.setMobileDataSyncEnabled(false);
      expect(await SyncSettings().getMobileDataSyncEnabled(), isFalse);
    },
  );

  test(
    'an existing reader reloads changes made outside its cached preferences',
    () async {
      final cached = await SharedPreferences.getInstance();
      final worker = SyncSettings(preferences: cached);
      await worker.setMobileDataSyncEnabled(true);
      expect(await worker.getMobileDataSyncEnabled(), isTrue);

      // Replace the backing store while keeping the old reader/cache alive,
      // simulating a setting changed by the other Flutter isolate.
      SharedPreferences.setMockInitialValues({
        SyncSettings.mobileDataKey: false,
      });
      expect(await worker.getMobileDataSyncEnabled(), isFalse);
    },
  );
}
