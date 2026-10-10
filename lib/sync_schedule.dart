import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

const syncTaskName = 'sidequest.sync.protocol2';
const _oneOffName = 'sidequest.sync.protocol2.once';
const _periodicName = 'sidequest.sync.protocol2.periodic';

bool get supportsBackgroundSync =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

Constraints _constraints() => Constraints(
  networkType: NetworkType.unmetered,
  requiresBatteryNotLow: true,
);

/// OS scheduling is best effort. No token, account data or mutable API URL is
/// stored in WorkManager input; the worker opens the same account-scoped store.
Future<void> scheduleSyncWork() async {
  if (!supportsBackgroundSync ||
      const String.fromEnvironment('API_BASE_URL').isEmpty) {
    return;
  }
  try {
    await Workmanager().registerOneOffTask(
      _oneOffName,
      syncTaskName,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: _constraints(),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
    );
  } catch (_) {
    // Foreground WiFi sync remains available if OS scheduling is unavailable.
    // Never report a durable record save as failed because scheduling failed.
  }
}

Future<void> registerPeriodicSync() async {
  await Workmanager().registerPeriodicTask(
    _periodicName,
    syncTaskName,
    frequency: const Duration(minutes: 15),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: _constraints(),
    backoffPolicy: BackoffPolicy.exponential,
    backoffPolicyDelay: const Duration(seconds: 30),
  );
}
