import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import 'repository.dart';
import 'remote_repository.dart';
import 'sync_schedule.dart';

QuestRepository? _runningRepository;

/// Returns false only when a retry may make progress. Expired login waits for
/// an explicit same-account login, retaining the queue without a retry storm.
Future<bool> runBackgroundSync(QuestRepository repository) async {
  try {
    final snapshot = await repository.load();
    if (snapshot.profile == null) return true;
    final before = await repository.getSyncSummary();
    if (before.requiresLogin || !before.hasPending) return true;
    // The repository reads saved consent; the worker never grants a one-off batch.
    await repository.syncNow();
    final after = await repository.getSyncSummary();
    return after.requiresLogin || !after.hasPending;
  } catch (_) {
    return false;
  } finally {
    await repository.dispose();
  }
}

@pragma('vm:entry-point')
void syncCallbackDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  Workmanager().executeTask(
    (task, _) async {
      if (task != syncTaskName) return true;
      const baseUrl = String.fromEnvironment('API_BASE_URL');
      if (baseUrl.isEmpty) return true;
      final repository = RemoteQuestRepository(
        apiBaseUrl: baseUrl,
        autoSync: false,
      );
      _runningRepository = repository;
      try {
        return await runBackgroundSync(repository);
      } finally {
        if (identical(_runningRepository, repository)) {
          _runningRepository = null;
        }
      }
    },
    onTaskStopped: (_, _) async {
      // The platform may kill this isolate immediately after this callback.
      // Transactions plus the expiring shared lease make a later retry safe.
      final repository = _runningRepository;
      _runningRepository = null;
      if (repository != null) unawaited(repository.dispose());
    },
  );
}

Future<void> initializeBackgroundSync() async {
  if (!supportsBackgroundSync ||
      const String.fromEnvironment('API_BASE_URL').isEmpty) {
    return;
  }
  try {
    await Workmanager().initialize(syncCallbackDispatcher);
    await registerPeriodicSync();
    await scheduleSyncWork();
  } catch (_) {
    // Starting the UI and local database must not depend on OS job availability.
  }
}
