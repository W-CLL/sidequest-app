import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'sync_settings.dart';

const syncTaskName = 'sidequest.sync.protocol2';
const _oneOffName = 'sidequest.sync.protocol2.once';
const _periodicName = 'sidequest.sync.protocol2.periodic';

bool get supportsBackgroundSync =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Future<Constraints> _constraints() async => Constraints(
  networkType: await SyncSettings().getMobileDataSyncEnabled()
      ? NetworkType.connected
      : NetworkType.unmetered,
  requiresBatteryNotLow: true,
);

/// OS scheduling is best effort. No token, account data or mutable API URL is
/// stored in WorkManager input; the worker opens the same account-scoped store.
Future<void> scheduleSyncWork({bool replaceExisting = false}) async {
  if (!supportsBackgroundSync ||
      const String.fromEnvironment('API_BASE_URL').isEmpty) {
    return;
  }
  try {
    await Workmanager().registerOneOffTask(
      _oneOffName,
      syncTaskName,
      existingWorkPolicy: replaceExisting
          ? ExistingWorkPolicy.replace
          : ExistingWorkPolicy.keep,
      constraints: await _constraints(),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
    );
  } catch (_) {
    // Foreground sync still respects the setting if OS scheduling is unavailable.
    // Never report a durable record save as failed because scheduling failed.
  }
}

/// Update both existing jobs when consent changes. Never fail a saved setting
/// just because the OS cannot currently schedule work.
Future<void> refreshSyncScheduling() async {
  if (!supportsBackgroundSync ||
      const String.fromEnvironment('API_BASE_URL').isEmpty) {
    return;
  }
  try {
    await registerPeriodicSync();
  } catch (_) {
    // Retry registration on the next app start.
  }
  await scheduleSyncWork(replaceExisting: true);
}

Future<void> registerPeriodicSync() async {
  await Workmanager().registerPeriodicTask(
    _periodicName,
    syncTaskName,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
    constraints: await _constraints(),
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(seconds: 30),
  );
}
