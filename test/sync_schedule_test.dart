import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sidequest/sync_schedule.dart';
import 'package:workmanager/workmanager.dart';

class _ScheduledWork extends WorkmanagerPlatform {
  Constraints? oneOffConstraints;
  ExistingWorkPolicy? oneOffPolicy;
  int periodicCalls = 0;
  int oneOffCalls = 0;
  Constraints? constraints;
  ExistingPeriodicWorkPolicy? policy;
  Map<String, dynamic>? input;
  ForegroundServiceConfig? foreground;

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
    ForegroundServiceConfig? foregroundServiceConfig,
    bool expedited = false,
  }) async {
    oneOffCalls++;
    oneOffConstraints = constraints;
    oneOffPolicy = existingWorkPolicy;
    input = inputData;
    foreground = foregroundServiceConfig;
  }

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    ForegroundServiceConfig? foregroundServiceConfig,
  }) async {
    periodicCalls++;
    this.constraints = constraints;
    policy = existingWorkPolicy;
    input = inputData;
    foreground = foregroundServiceConfig;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late WorkmanagerPlatform previous;
  late _ScheduledWork scheduler;
  setUp(() {
    Workmanager();
    previous = WorkmanagerPlatform.instance;
    scheduler = _ScheduledWork();
    WorkmanagerPlatform.instance = scheduler;
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() {
    WorkmanagerPlatform.instance = previous;
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'changing consent refreshes both Android jobs without credentials',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('sidequest.sync.mobileDataEnabled', true);
      await refreshSyncScheduling();
      expect(scheduler.periodicCalls, 1);
      expect(scheduler.oneOffCalls, 1);
      expect(scheduler.constraints!.networkType, NetworkType.connected);
      expect(scheduler.oneOffConstraints!.networkType, NetworkType.connected);
      expect(scheduler.oneOffPolicy, ExistingWorkPolicy.replace);
      expect(scheduler.policy, ExistingPeriodicWorkPolicy.update);
      expect(scheduler.input, isNull);
      expect(scheduler.foreground, isNull);

      await preferences.setBool('sidequest.sync.mobileDataEnabled', false);
      await refreshSyncScheduling();
      expect(scheduler.oneOffConstraints!.networkType, NetworkType.unmetered);
      expect(scheduler.constraints!.networkType, NetworkType.unmetered);
    },
    skip: const String.fromEnvironment('API_BASE_URL').isEmpty
        ? 'Run with --dart-define=API_BASE_URL=https://sidequest.test to verify Android job refresh'
        : false,
  );

  test('background scheduling stays unmetered by default', () async {
    await registerPeriodicSync();
    expect(scheduler.constraints!.networkType, NetworkType.unmetered);
    expect(scheduler.constraints!.requiresBatteryNotLow, isTrue);
    expect(scheduler.input, isNull);
    expect(scheduler.foreground, isNull);
  });

  test(
    'mobile data preference updates existing background constraints',
    () async {
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('sidequest.sync.mobileDataEnabled', true);
      await registerPeriodicSync();
      expect(scheduler.constraints!.networkType, NetworkType.connected);
      expect(scheduler.policy, ExistingPeriodicWorkPolicy.update);

      await preferences.setBool('sidequest.sync.mobileDataEnabled', false);
      await registerPeriodicSync();
      expect(scheduler.constraints!.networkType, NetworkType.unmetered);
      expect(scheduler.policy, ExistingPeriodicWorkPolicy.update);
    },
  );
}
