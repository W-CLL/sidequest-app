import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import 'domain.dart';

const _uuid = Uuid();

DatabaseFactory _platformDatabaseFactory() => databaseFactory;

Map<String, dynamic> _jsonMap(Object? value) =>
    Map<String, dynamic>.from(value as Map);

String _canonicalJson(Map<String, dynamic> value) => jsonEncode(value);

class OfflineBranch {
  const OfflineBranch({
    required this.id,
    required this.accountId,
    required this.baseRevision,
    required this.mode,
  });

  final String id;
  final String accountId;
  final int baseRevision;
  final String mode;
  bool get recordsOnly => mode == 'records_only';
}

class OfflineAccount {
  const OfflineAccount({
    required this.id,
    required this.snapshot,
    required this.activeBranchId,
    required this.requiresLogin,
  });

  final String id;
  final AppSnapshot snapshot;
  final String activeBranchId;
  final bool requiresLogin;
}

class OfflineCommand {
  const OfflineCommand({
    required this.commandId,
    required this.accountId,
    required this.branchId,
    required this.type,
    required this.payload,
    required this.createdAt,
    required this.meteredAllowed,
    this.wireJson,
  });

  final String commandId;
  final String accountId;
  final String branchId;
  final String type;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final bool meteredAllowed;

  /// Exact command sent on the wire, retained across process death and retries.
  final Map<String, dynamic>? wireJson;
}

class OfflineSyncBatch {
  const OfflineSyncBatch({
    required this.batchId,
    required this.branch,
    required this.commands,
    required this.meteredAuthorized,
  });

  final String batchId;
  final OfflineBranch branch;
  final List<OfflineCommand> commands;
  final bool meteredAuthorized;
}

class OfflineMedia {
  const OfflineMedia({
    required this.clientId,
    required this.accountId,
    required this.attachment,
    required this.localPath,
    required this.serverId,
    required this.state,
    required this.sourceBytes,
    this.error,
    this.boundRecordId,
  });

  final String clientId;
  final String accountId;
  final MediaAttachment attachment;
  final String? localPath;
  final String? serverId;
  final String state;
  final int sourceBytes;
  final String? error;
  final String? boundRecordId;
}

class OfflineApplyResult {
  const OfflineApplyResult({
    required this.snapshot,
    required this.cleanupPaths,
  });

  final AppSnapshot snapshot;
  final List<String> cleanupPaths;
}

class OfflineDiscardResult {
  const OfflineDiscardResult({
    required this.cleanupPaths,
    required this.serverIds,
  });
  final List<String> cleanupPaths;
  final List<String> serverIds;
}

class OfflineBranchChangedException extends QuestException {
  const OfflineBranchChangedException() : super('探索进度已变化，请重新打开记录页；原有草稿仍已保留。');
}

/// Durable, account-scoped client state. Tokens and passwords deliberately do
/// not have columns in this database.
class OfflineStore {
  OfflineStore({
    DatabaseFactory? databaseFactory,
    this._databasePath,
    this._mediaRoot,
    String namespace = 'default',
    DateTime Function()? now,
  }) : _factory = databaseFactory ?? _platformDatabaseFactory(),
       _namespace = sha256
           .convert(utf8.encode(namespace))
           .toString()
           .substring(0, 20),
       _now = now ?? DateTime.now;

  static const maxPendingRecords = 20;
  static const maxDeviceBytes = 500 * 1024 * 1024;
  static const leaseName = 'sidequest-sync-v2';

  final DatabaseFactory _factory;
  final String? _databasePath;
  final String? _mediaRoot;
  final String _namespace;
  final DateTime Function() _now;
  Database? _database;
  Future<Database>? _opening;
  String? _resolvedMediaRoot;

  Future<String> _resolveDatabasePath() async {
    if (_databasePath != null) return _databasePath;
    final root = await getDatabasesPath();
    return p.join(root, 'sidequest-v2.sqlite');
  }

  Future<String> get mediaRootPath async {
    if (_resolvedMediaRoot != null) return _resolvedMediaRoot!;
    final root =
        _mediaRoot ??
        p.join(
          (await getApplicationSupportDirectory()).path,
          'sidequest-media',
        );
    await Directory(root).create(recursive: true);
    return _resolvedMediaRoot = root;
  }

  Future<Database> get database {
    if (_database != null) return Future.value(_database);
    return _opening ??= _open();
  }

  Future<Database> _open() async {
    final path = await _resolveDatabasePath();
    await Directory(p.dirname(path)).create(recursive: true);
    final db = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 4,
        // Foreground/background wrappers share SQLite data and lease rows, not
        // a closable connection object. Disposing one must not close another.
        singleInstance: false,
        onConfigure: (database) async {
          await database.execute('PRAGMA foreign_keys = ON');
          await database.execute('PRAGMA journal_mode = WAL');
        },
        onCreate: (database, _) async {
          await database.execute('''
CREATE TABLE metadata (
  key TEXT PRIMARY KEY,
  value TEXT NOT NULL
)''');
          await database.execute('''
CREATE TABLE accounts (
  account_id TEXT PRIMARY KEY,
  snapshot_json TEXT NOT NULL,
  active_branch_id TEXT NOT NULL,
  requires_login INTEGER NOT NULL DEFAULT 0,
  updated_at INTEGER NOT NULL
)''');
          await database.execute('''
CREATE TABLE branches (
  branch_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  base_revision INTEGER NOT NULL,
  mode TEXT NOT NULL CHECK(mode IN ('active', 'records_only')),
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
)''');
          await database.execute(
            'CREATE INDEX branches_account ON branches(account_id, created_at)',
          );
          await database.execute('''
CREATE TABLE outbox (
  sequence INTEGER PRIMARY KEY AUTOINCREMENT,
  command_id TEXT NOT NULL UNIQUE,
  account_id TEXT NOT NULL,
  branch_id TEXT NOT NULL,
  type TEXT NOT NULL,
  payload_json TEXT NOT NULL,
  payload_hash TEXT NOT NULL,
  wire_json TEXT,
  last_error TEXT,
  created_at INTEGER NOT NULL,
  batch_id TEXT,
  metered_allowed INTEGER NOT NULL DEFAULT 0,
  FOREIGN KEY(account_id) REFERENCES accounts(account_id) ON DELETE CASCADE,
  FOREIGN KEY(branch_id) REFERENCES branches(branch_id) ON DELETE CASCADE
)''');
          await database.execute(
            'CREATE INDEX outbox_order ON outbox(account_id, sequence)',
          );
          await database.execute(
            'CREATE INDEX outbox_branch ON outbox(branch_id, sequence)',
          );
          await database.execute('''
CREATE TABLE entries (
  account_id TEXT NOT NULL,
  entry_id TEXT NOT NULL,
  entry_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  pending INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(account_id, entry_id),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
)''');
          await database.execute(
            'CREATE INDEX entries_page ON entries(account_id, created_at DESC, entry_id DESC)',
          );
          await database.execute('''
CREATE TABLE media (
  client_id TEXT PRIMARY KEY,
  account_id TEXT NOT NULL,
  server_id TEXT,
  attachment_json TEXT NOT NULL,
  source_bytes INTEGER NOT NULL,
  local_path TEXT,
  staging_path TEXT,
  state TEXT NOT NULL,
  last_error TEXT,
  bound_record_id TEXT,
  created_at INTEGER NOT NULL,
  FOREIGN KEY(account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
)''');
          await database.execute(
            'CREATE UNIQUE INDEX media_server_id ON media(account_id, server_id) WHERE server_id IS NOT NULL',
          );
          await database.execute(
            'CREATE INDEX media_account ON media(account_id, created_at)',
          );
          await database.execute('''
CREATE TABLE cleanup_queue (
  path TEXT PRIMARY KEY,
  client_id TEXT,
  source_bytes INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
)''');
          await database.execute('''CREATE TABLE cleanup_holds (
  account_id TEXT NOT NULL,
  entry_id TEXT NOT NULL,
  client_id TEXT NOT NULL,
  PRIMARY KEY(account_id, entry_id, client_id),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id) ON DELETE CASCADE,
  FOREIGN KEY(client_id) REFERENCES media(client_id) ON DELETE CASCADE
)''');
          await database.execute('''
CREATE TABLE request_ids (
  account_id TEXT NOT NULL,
  request_key TEXT NOT NULL,
  request_id TEXT NOT NULL,
  PRIMARY KEY(account_id, request_key),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id) ON DELETE CASCADE
)''');
          await database.execute('''
CREATE TABLE task_leases (
  lease_name TEXT PRIMARY KEY,
  owner TEXT NOT NULL,
  expires_at INTEGER NOT NULL
)''');
        },
        onUpgrade: (database, oldVersion, _) async {
          if (oldVersion < 2) {
            await database.execute(
              'ALTER TABLE outbox ADD COLUMN wire_json TEXT',
            );
            await database.execute(
              'ALTER TABLE media ADD COLUMN staging_path TEXT',
            );
            await database.execute(
              'ALTER TABLE cleanup_queue ADD COLUMN source_bytes INTEGER NOT NULL DEFAULT 0',
            );
          }
          if (oldVersion < 3) {
            await database.execute('''CREATE TABLE cleanup_holds (
  account_id TEXT NOT NULL, entry_id TEXT NOT NULL, client_id TEXT NOT NULL,
  PRIMARY KEY(account_id, entry_id, client_id),
  FOREIGN KEY(account_id) REFERENCES accounts(account_id) ON DELETE CASCADE,
  FOREIGN KEY(client_id) REFERENCES media(client_id) ON DELETE CASCADE
)''');
          }
          if (oldVersion < 4) {
            await database.execute(
              'ALTER TABLE outbox ADD COLUMN last_error TEXT',
            );
          }
        },
      ),
    );
    _database = db;
    return db;
  }

  Future<void> close() async {
    final db = _database;
    _database = null;
    _opening = null;
    if (db != null) await db.close();
  }

  Future<String?> activeAccountId() async {
    final db = await database;
    final rows = await db.query(
      'metadata',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [_activeAccountMetadataKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  String get _activeAccountMetadataKey => 'active_account_id:$_namespace';
  String _accountKey(String remoteId) => '$_namespace:$remoteId';

  void _validateCloudAccount(String accountId, AppSnapshot cloud) {
    if (cloud.profile == null || _accountKey(cloud.profile!.id) != accountId) {
      throw const QuestException('账号已变化，已停止应用这次同步结果。');
    }
  }

  Future<OfflineAccount?> activeAccount() async {
    final id = await activeAccountId();
    return id == null ? null : account(id);
  }

  Future<OfflineAccount?> account(String accountId) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'accounts',
        where: 'account_id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final account = _accountFromRow(rows.single);
      return OfflineAccount(
        id: account.id,
        snapshot: await _projectSnapshotIn(txn, accountId, account.snapshot),
        activeBranchId: account.activeBranchId,
        requiresLogin: account.requiresLogin,
      );
    });
  }

  OfflineAccount _accountFromRow(Map<String, Object?> row) => OfflineAccount(
    id: row['account_id'] as String,
    snapshot: AppSnapshot.fromJson(
      _jsonMap(jsonDecode(row['snapshot_json'] as String)),
    ),
    activeBranchId: row['active_branch_id'] as String,
    requiresLogin: (row['requires_login'] as int) != 0,
  );

  OfflineBranch _branchFromRow(Map<String, Object?> row) => OfflineBranch(
    id: row['branch_id'] as String,
    accountId: row['account_id'] as String,
    baseRevision: row['base_revision'] as int,
    mode: row['mode'] as String,
  );

  OfflineCommand _commandFromRow(Map<String, Object?> row) => OfflineCommand(
    commandId: row['command_id'] as String,
    accountId: row['account_id'] as String,
    branchId: row['branch_id'] as String,
    type: row['type'] as String,
    payload: _jsonMap(jsonDecode(row['payload_json'] as String)),
    createdAt: DateTime.fromMillisecondsSinceEpoch(
      row['created_at'] as int,
      isUtc: true,
    ),
    meteredAllowed: (row['metered_allowed'] as int) != 0,
    wireJson: row['wire_json'] == null
        ? null
        : _jsonMap(jsonDecode(row['wire_json'] as String)),
  );

  OfflineMedia _mediaFromRow(Map<String, Object?> row) => OfflineMedia(
    clientId: row['client_id'] as String,
    accountId: row['account_id'] as String,
    attachment: MediaAttachment.fromJson(
      _jsonMap(jsonDecode(row['attachment_json'] as String)),
    ).copyWith(localPath: row['local_path'] as String?),
    localPath: row['local_path'] as String?,
    serverId: row['server_id'] as String?,
    state: row['state'] as String,
    sourceBytes: row['source_bytes'] as int,
    error: row['last_error'] as String?,
    boundRecordId: row['bound_record_id'] as String?,
  );

  Future<OfflineBranch> branch(String branchId) async {
    final db = await database;
    final rows = await db.query(
      'branches',
      where: 'branch_id = ?',
      whereArgs: [branchId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Offline branch is missing.');
    return _branchFromRow(rows.single);
  }

  Future<OfflineAccount> activateFromCloud(AppSnapshot cloud) async {
    final profile = cloud.profile;
    if (profile == null) throw StateError('Cannot activate a guest snapshot.');
    final accountKey = _accountKey(profile.id);
    final db = await database;
    return db.transaction((txn) async {
      final accountRows = await txn.query(
        'accounts',
        where: 'account_id = ?',
        whereArgs: [accountKey],
        limit: 1,
      );
      final now = _now().toUtc().millisecondsSinceEpoch;
      String activeBranchId;
      AppSnapshot storedSnapshot = cloud;
      if (accountRows.isEmpty) {
        activeBranchId = _uuid.v4();
        await txn.insert('accounts', {
          'account_id': accountKey,
          'snapshot_json': jsonEncode(cloud.toJson()),
          'active_branch_id': activeBranchId,
          'requires_login': 0,
          'updated_at': now,
        });
        await _insertBranch(
          txn,
          id: activeBranchId,
          accountId: accountKey,
          baseRevision: cloud.progressRevision,
          now: now,
        );
      } else {
        final existing = _accountFromRow(accountRows.single);
        final branchRows = await txn.query(
          'branches',
          where: 'branch_id = ?',
          whereArgs: [existing.activeBranchId],
          limit: 1,
        );
        final queued =
            Sqflite.firstIntValue(
              await txn.rawQuery(
                'SELECT COUNT(*) FROM outbox WHERE branch_id = ?',
                [existing.activeBranchId],
              ),
            ) ??
            0;
        final keepPendingBranch =
            branchRows.isNotEmpty &&
            branchRows.single['mode'] == 'active' &&
            queued > 0;
        if (keepPendingBranch) {
          activeBranchId = existing.activeBranchId;
          storedSnapshot = existing.snapshot.copyWith(profile: profile);
        } else {
          activeBranchId = _uuid.v4();
          storedSnapshot = cloud.copyWith(
            conflictDrafts: existing.snapshot.conflictDrafts,
          );
          await _insertBranch(
            txn,
            id: activeBranchId,
            accountId: accountKey,
            baseRevision: cloud.progressRevision,
            now: now,
          );
        }
        await txn.update(
          'accounts',
          {
            'snapshot_json': jsonEncode(storedSnapshot.toJson()),
            'active_branch_id': activeBranchId,
            'requires_login': 0,
            'updated_at': now,
          },
          where: 'account_id = ?',
          whereArgs: [accountKey],
        );
      }
      await txn.insert('metadata', {
        'key': _activeAccountMetadataKey,
        'value': accountKey,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await _cacheCloudEntriesIn(txn, accountKey, cloud.entries);
      return OfflineAccount(
        id: accountKey,
        snapshot: storedSnapshot,
        activeBranchId: activeBranchId,
        requiresLogin: false,
      );
    });
  }

  Future<void> _insertBranch(
    DatabaseExecutor executor, {
    required String id,
    required String accountId,
    required int baseRevision,
    required int now,
  }) => executor.insert('branches', {
    'branch_id': id,
    'account_id': accountId,
    'base_revision': baseRevision,
    'mode': 'active',
    'created_at': now,
    'updated_at': now,
  });

  Future<void> clearActiveAccount() async {
    final db = await database;
    await db.delete(
      'metadata',
      where: 'key = ?',
      whereArgs: [_activeAccountMetadataKey],
    );
  }

  Future<void> markRequiresLogin(String accountId, bool value) async {
    final db = await database;
    await db.update(
      'accounts',
      {
        'requires_login': value ? 1 : 0,
        'updated_at': _now().toUtc().millisecondsSinceEpoch,
      },
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }

  Future<void> saveSnapshot(String accountId, AppSnapshot snapshot) async {
    _validateCloudAccount(accountId, snapshot);
    final db = await database;
    await db.update(
      'accounts',
      {
        'snapshot_json': jsonEncode(snapshot.toJson()),
        'updated_at': _now().toUtc().millisecondsSinceEpoch,
      },
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }

  /// Reconciles an online-only mutation (preferences, replace, entry edit or
  /// deletion) with local pending progress. A changed cloud progress revision
  /// permanently retires the old branch; unchanged progress keeps it intact.
  Future<AppSnapshot> adoptCloud(String accountId, AppSnapshot cloud) async {
    _validateCloudAccount(accountId, cloud);
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'accounts',
        where: 'account_id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (rows.isEmpty) throw StateError('Offline account is missing.');
      final account = _accountFromRow(rows.single);
      final queued =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COUNT(*) FROM outbox WHERE branch_id = ?',
              [account.activeBranchId],
            ),
          ) ??
          0;
      final pendingEntries =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COUNT(*) FROM entries WHERE account_id = ? AND pending = 1',
              [accountId],
            ),
          ) ??
          0;
      var activeBranchId = account.activeBranchId;
      AppSnapshot next;
      if (queued > 0 &&
          cloud.progressRevision == account.snapshot.progressRevision) {
        next = account.snapshot.copyWith(
          profile: cloud.profile,
          entryCount: cloud.entryCount + pendingEntries,
          nextCursor: cloud.nextCursor,
        );
      } else {
        final conflicts = <ConflictDraft>[...account.snapshot.conflictDrafts];
        if (queued > 0 &&
            (account.snapshot.draft.isNotEmpty ||
                account.snapshot.draftAttachments.isNotEmpty)) {
          final branch = await _branchIn(txn, account.activeBranchId);
          final questId =
              account.snapshot.activeQuestId ??
              await _draftQuestIn(
                txn,
                account.activeBranchId,
                account.snapshot.recommendedQuestId,
              );
          final conflictId = _uuid.v4();
          conflicts.add(
            ConflictDraft(
              id: conflictId,
              questId: questId,
              text: account.snapshot.draft,
              attachments: account.snapshot.draftAttachments,
              createdAt: _now().toUtc(),
              branchId: branch.id,
              baseRevision: branch.baseRevision,
            ),
          );
          await txn.update(
            'media',
            {'bound_record_id': 'conflict:$conflictId'},
            where: 'account_id = ? AND bound_record_id = ?',
            whereArgs: [accountId, 'draft'],
          );
        }
        if (queued > 0) {
          await txn.update(
            'branches',
            {
              'mode': 'records_only',
              'updated_at': _now().toUtc().millisecondsSinceEpoch,
            },
            where: 'branch_id = ?',
            whereArgs: [account.activeBranchId],
          );
        }
        // Merely refreshing an unchanged server must not invalidate an editor
        // that is already open on this activity.
        if (queued > 0 ||
            cloud.progressRevision != account.snapshot.progressRevision ||
            (await _branchIn(txn, account.activeBranchId)).recordsOnly) {
          activeBranchId = _uuid.v4();
          await _insertBranch(
            txn,
            id: activeBranchId,
            accountId: accountId,
            baseRevision: cloud.progressRevision,
            now: _now().toUtc().millisecondsSinceEpoch,
          );
        }
        next = cloud.copyWith(
          conflictDrafts: conflicts,
          entryCount: cloud.entryCount + pendingEntries,
        );
      }
      await txn.update(
        'accounts',
        {
          'snapshot_json': jsonEncode(next.toJson()),
          'active_branch_id': activeBranchId,
          'requires_login': 0,
          'updated_at': _now().toUtc().millisecondsSinceEpoch,
        },
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      await _cacheCloudEntriesIn(txn, accountId, cloud.entries);
      return next;
    });
  }

  Future<OfflineBranch> _branchIn(
    DatabaseExecutor executor,
    String branchId,
  ) async {
    final rows = await executor.query(
      'branches',
      where: 'branch_id = ?',
      whereArgs: [branchId],
      limit: 1,
    );
    if (rows.isEmpty) throw StateError('Offline branch is missing.');
    return _branchFromRow(rows.single);
  }

  Future<String> _draftQuestIn(
    DatabaseExecutor executor,
    String branchId,
    String fallback,
  ) async {
    final rows = await executor.query(
      'outbox',
      columns: const ['payload_json'],
      where: 'branch_id = ? AND type = ?',
      whereArgs: [branchId, 'draft'],
      orderBy: 'sequence DESC',
      limit: 1,
    );
    if (rows.isEmpty) return fallback;
    final payload = _jsonMap(jsonDecode(rows.single['payload_json'] as String));
    return payload['questId'] as String? ?? fallback;
  }

  Future<void> mutateWithCommand({
    required String accountId,
    required AppSnapshot snapshot,
    required String commandId,
    required String type,
    required Map<String, dynamic> payload,
    JournalEntry? pendingEntry,
    bool coalesceDraft = false,
    String? expectedBranchId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final active = await _activeAccountIdIn(txn);
      if (active != accountId) {
        throw StateError('The active account changed before the write.');
      }
      final accountRows = await txn.query(
        'accounts',
        where: 'account_id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (accountRows.isEmpty) throw StateError('Offline account is missing.');
      var branchId = accountRows.single['active_branch_id'] as String;
      if (expectedBranchId != null && branchId != expectedBranchId) {
        throw const OfflineBranchChangedException();
      }
      final branchRows = await txn.query(
        'branches',
        where: 'branch_id = ?',
        whereArgs: [branchId],
        limit: 1,
      );
      if (branchRows.isEmpty || branchRows.single['mode'] == 'records_only') {
        branchId = _uuid.v4();
        await _insertBranch(
          txn,
          id: branchId,
          accountId: accountId,
          baseRevision: snapshot.progressRevision,
          now: _now().toUtc().millisecondsSinceEpoch,
        );
      }
      if (pendingEntry != null) {
        final pendingCount =
            Sqflite.firstIntValue(
              await txn.rawQuery(
                'SELECT COUNT(*) FROM entries WHERE pending = 1',
              ),
            ) ??
            0;
        if (pendingCount >= maxPendingRecords) {
          throw const QuestException('设备上最多暂存 20 条待同步记录，请先同步后再保存。');
        }
        await txn.insert('entries', {
          'account_id': accountId,
          'entry_id': pendingEntry.id,
          'entry_json': jsonEncode(pendingEntry.toJson()),
          'created_at': pendingEntry.createdAt.toUtc().toIso8601String(),
          'pending': 1,
        }, conflictAlgorithm: ConflictAlgorithm.abort);
        final mediaIds = List<String>.from(payload['mediaIds'] as List? ?? []);
        if (mediaIds.isNotEmpty) {
          final placeholders = List.filled(mediaIds.length, '?').join(',');
          await txn.rawUpdate(
            'UPDATE media SET bound_record_id = ? WHERE account_id = ? AND client_id IN ($placeholders)',
            [pendingEntry.id, accountId, ...mediaIds],
          );
        }
      }
      if (type == 'draft') {
        final mediaIds = List<String>.from(payload['mediaIds'] as List? ?? []);
        await txn.update(
          'media',
          {'bound_record_id': null},
          where: 'account_id = ? AND bound_record_id = ?',
          whereArgs: [accountId, 'draft'],
        );
        if (mediaIds.isNotEmpty) {
          final placeholders = List.filled(mediaIds.length, '?').join(',');
          await txn.rawUpdate(
            'UPDATE media SET bound_record_id = ? WHERE account_id = ? AND client_id IN ($placeholders)',
            ['draft', accountId, ...mediaIds],
          );
        }
      }
      if (coalesceDraft) {
        final tail = await txn.query(
          'outbox',
          where: 'account_id = ? AND branch_id = ?',
          whereArgs: [accountId, branchId],
          orderBy: 'sequence DESC',
          limit: 1,
        );
        if (tail.isNotEmpty &&
            tail.single['type'] == 'draft' &&
            tail.single['batch_id'] == null &&
            tail.single['wire_json'] == null) {
          final previous = _jsonMap(
            jsonDecode(tail.single['payload_json'] as String),
          );
          if (previous['questId'] == payload['questId']) {
            await txn.delete(
              'outbox',
              where: 'command_id = ?',
              whereArgs: [tail.single['command_id']],
            );
          }
        }
      }
      final payloadJson = _canonicalJson(payload);
      await txn.insert('outbox', {
        'command_id': commandId,
        'account_id': accountId,
        'branch_id': branchId,
        'type': type,
        'payload_json': payloadJson,
        'payload_hash': sha256.convert(utf8.encode(payloadJson)).toString(),
        'created_at': _now().toUtc().millisecondsSinceEpoch,
        'batch_id': null,
        'metered_allowed': 0,
      });
      await txn.update(
        'accounts',
        {
          'snapshot_json': jsonEncode(snapshot.toJson()),
          'active_branch_id': branchId,
          'updated_at': _now().toUtc().millisecondsSinceEpoch,
        },
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
    });
  }

  Future<String?> _activeAccountIdIn(DatabaseExecutor executor) async {
    final rows = await executor.query(
      'metadata',
      columns: const ['value'],
      where: 'key = ?',
      whereArgs: [_activeAccountMetadataKey],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  Future<int> pendingCommandCount(String accountId) async {
    final db = await database;
    return Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM outbox WHERE account_id = ?',
            [accountId],
          ),
        ) ??
        0;
  }

  Future<OfflineSyncBatch?> captureBatch({
    required String accountId,
    required bool wifi,
    required bool allowMetered,
    int limit = 10,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final eligibility = wifi || allowMetered
          ? 'batch_id IS NULL'
          : 'batch_id IS NULL AND metered_allowed = 1';
      final first = await txn.rawQuery(
        '''SELECT * FROM outbox
WHERE account_id = ? AND $eligibility
ORDER BY sequence LIMIT 1''',
        [accountId],
      );
      if (first.isEmpty) return null;
      final branchId = first.single['branch_id'] as String;
      final rows = await txn.rawQuery(
        '''SELECT * FROM outbox
WHERE account_id = ? AND branch_id = ? AND $eligibility
ORDER BY sequence LIMIT ?''',
        [accountId, branchId, limit.clamp(1, 10)],
      );
      final branchRows = await txn.query(
        'branches',
        where: 'branch_id = ?',
        whereArgs: [branchId],
        limit: 1,
      );
      final branch = _branchFromRow(branchRows.single);
      final selected = <Map<String, Object?>>[];
      for (final row in rows) {
        final candidate = [...selected, row];
        final wire = {
          'branchId': branchId,
          'baseRevision': branch.baseRevision,
          'commands': candidate
              .map(
                (item) => {
                  'commandId': item['command_id'],
                  'type': item['type'],
                  'payload': item['wire_json'] == null
                      ? jsonDecode(item['payload_json'] as String)
                      : _jsonMap(
                          jsonDecode(item['wire_json'] as String),
                        )['payload'],
                },
              )
              .toList(),
        };
        if (utf8.encode(jsonEncode(wire)).length > 16 * 1024) break;
        selected.add(row);
      }
      if (selected.isEmpty) {
        throw const QuestException('一条待同步操作超过 16 KiB，无法安全发送。');
      }
      final batchId = _uuid.v4();
      final ids = selected.map((row) => row['command_id'] as String).toList();
      final placeholders = List.filled(ids.length, '?').join(',');
      await txn.rawUpdate(
        '''UPDATE outbox SET batch_id = ?, last_error = NULL,
metered_allowed = CASE WHEN ? = 1 THEN 1 ELSE metered_allowed END
WHERE command_id IN ($placeholders)''',
        [batchId, allowMetered ? 1 : 0, ...ids],
      );
      return OfflineSyncBatch(
        batchId: batchId,
        branch: branch,
        commands: selected.map(_commandFromRow).toList(growable: false),
        meteredAuthorized:
            allowMetered ||
            selected.every((row) => row['metered_allowed'] == 1),
      );
    });
  }

  Future<void> releaseBatch(String batchId) async {
    final db = await database;
    await db.update(
      'outbox',
      {'batch_id': null},
      where: 'batch_id = ?',
      whereArgs: [batchId],
    );
  }

  Future<void> markBatchError(
    String accountId,
    String batchId,
    String error,
  ) async {
    final db = await database;
    await db.update(
      'outbox',
      {'last_error': error},
      where: 'account_id = ? AND batch_id = ?',
      whereArgs: [accountId, batchId],
    );
  }

  Future<void> persistWireCommand(
    String accountId,
    String commandId,
    Map<String, dynamic> wire, {
    String? leaseOwner,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await _assertLeaseIn(txn, leaseOwner);
      final rows = await txn.query(
        'outbox',
        where: 'account_id = ? AND command_id = ?',
        whereArgs: [accountId, commandId],
        limit: 1,
      );
      if (rows.isEmpty) throw const QuestException('待同步操作已变化，请重试。');
      final row = rows.single;
      if (wire['commandId'] != commandId ||
          wire['type'] != row['type'] ||
          wire['payload'] is! Map) {
        throw const QuestException('同步内容与本机操作不匹配。');
      }
      final encoded = jsonEncode(wire);
      if (row['wire_json'] != null && row['wire_json'] != encoded) {
        throw const QuestException('已发送操作不能修改，请先核对云端回执。');
      }
      await txn.update(
        'outbox',
        {'wire_json': encoded},
        where: 'account_id = ? AND command_id = ?',
        whereArgs: [accountId, commandId],
      );
    });
  }

  /// Only call with IDs explicitly reported missing by /sync-status.
  Future<void> clearMissingWireCommands(
    String accountId,
    Iterable<String> ids,
  ) async {
    final selected = ids.toSet().toList();
    if (selected.isEmpty) return;
    final db = await database;
    await db.rawUpdate(
      'UPDATE outbox SET wire_json = NULL WHERE account_id = ? AND command_id IN (${List.filled(selected.length, '?').join(',')})',
      [accountId, ...selected],
    );
  }

  Future<List<OfflineCommand>> commandsForBranch(String branchId) async {
    final db = await database;
    final rows = await db.query(
      'outbox',
      where: 'branch_id = ?',
      whereArgs: [branchId],
      orderBy: 'sequence',
    );
    return rows.map(_commandFromRow).toList(growable: false);
  }

  Future<OfflineMedia> stageMedia({
    required String accountId,
    required String sourcePath,
    required MediaKind kind,
    required String mimeType,
    required int byteSize,
    int? durationMs,
    int? width,
    int? height,
  }) async {
    final clientId = _uuid.v4();
    final actualSourceBytes = await File(sourcePath).length();
    if (actualSourceBytes != byteSize || byteSize <= 0) {
      throw const QuestException('附件文件已经变化，请重新选择。');
    }
    final extension = p.extension(sourcePath).toLowerCase();
    final accountDirectory = p.join(
      await mediaRootPath,
      sha256.convert(utf8.encode(accountId)).toString().substring(0, 24),
    );
    await Directory(accountDirectory).create(recursive: true);
    final destination = p.join(
      accountDirectory,
      '$clientId${extension.length <= 10 ? extension : ''}',
    );
    final temporary = '$destination.partial';
    final attachment = MediaAttachment(
      id: clientId,
      kind: kind,
      mimeType: mimeType,
      byteSize: byteSize,
      durationMs: durationMs,
      width: width,
      height: height,
      status: 'reserved',
      localPath: destination,
    );
    try {
      final db = await database;
      await db.transaction((txn) async {
        if (await _activeAccountIdIn(txn) != accountId) {
          throw const QuestException('账号已变化，请重新添加附件。');
        }
        final accountRows = await txn.query(
          'accounts',
          columns: const ['account_id'],
          where: 'account_id = ?',
          whereArgs: [accountId],
          limit: 1,
        );
        if (accountRows.isEmpty) {
          throw StateError('Offline account is missing.');
        }
        final used =
            Sqflite.firstIntValue(
              await txn.rawQuery(
                'SELECT (SELECT COALESCE(SUM(source_bytes), 0) FROM media WHERE local_path IS NOT NULL) + (SELECT COALESCE(SUM(source_bytes), 0) FROM cleanup_queue WHERE client_id IS NULL OR NOT EXISTS (SELECT 1 FROM media WHERE media.client_id = cleanup_queue.client_id))',
              ),
            ) ??
            0;
        if (used + byteSize > maxDeviceBytes) {
          throw const QuestException('设备暂存已达到 500 MiB，请先同步或清理后再添加。');
        }
        await txn.insert('media', {
          'client_id': clientId,
          'account_id': accountId,
          'server_id': null,
          'attachment_json': jsonEncode(attachment.toJson()),
          'source_bytes': byteSize,
          'local_path': destination,
          'staging_path': temporary,
          'state': 'staging',
          'last_error': null,
          'bound_record_id': null,
          'created_at': _now().toUtc().millisecondsSinceEpoch,
        });
      });
      // The row reserves quota and journals both filenames before any copying.
      // An interrupted stage can therefore never become an untracked orphan.
      await File(sourcePath).copy(temporary);
      if (await File(temporary).length() != byteSize) {
        throw const QuestException('附件文件已经变化，请重新选择。');
      }
      final handle = await File(temporary).open(mode: FileMode.append);
      try {
        await handle.flush();
      } finally {
        await handle.close();
      }
      await File(temporary).rename(destination);
      await db.transaction((txn) async {
        if (await _activeAccountIdIn(txn) != accountId) {
          throw const QuestException('账号已变化，请重新添加附件。');
        }
        final changed = await txn.update(
          'media',
          {'state': 'reserved', 'staging_path': null},
          where: 'client_id = ? AND account_id = ?',
          whereArgs: [clientId, accountId],
        );
        if (changed != 1) throw const QuestException('附件暂存已取消，请重新添加。');
      });
    } catch (_) {
      // Persist cleanup first; if deletion itself fails the next worker retries.
      final db = await database;
      await db.transaction((txn) async {
        for (final path in [destination, temporary]) {
          await txn.insert('cleanup_queue', {
            'path': path,
            'client_id': null,
            'source_bytes': byteSize,
            'created_at': _now().toUtc().millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await txn.delete(
          'media',
          where: 'client_id = ?',
          whereArgs: [clientId],
        );
      });
      for (final path in [destination, temporary]) {
        try {
          final copied = File(path);
          if (await copied.exists()) await copied.delete();
          await markPathCleaned(path);
        } on FileSystemException {
          /* Cleanup remains durable. */
        }
      }
      rethrow;
    }
    return OfflineMedia(
      clientId: clientId,
      accountId: accountId,
      attachment: attachment,
      localPath: destination,
      serverId: null,
      state: 'reserved',
      sourceBytes: byteSize,
    );
  }

  Future<OfflineMedia?> mediaById(String accountId, String id) async {
    final db = await database;
    final rows = await db.query(
      'media',
      where: 'account_id = ? AND (client_id = ? OR server_id = ?)',
      whereArgs: [accountId, id, id],
      limit: 1,
    );
    return rows.isEmpty ? null : _mediaFromRow(rows.single);
  }

  Future<List<OfflineMedia>> mediaForIds(
    String accountId,
    Iterable<String> ids,
  ) async {
    final result = <OfflineMedia>[];
    for (final id in ids.toSet()) {
      final media = await mediaById(accountId, id);
      if (media != null) result.add(media);
    }
    return result;
  }

  Future<void> updateMedia({
    required String clientId,
    String? serverId,
    required String state,
    MediaAttachment? attachment,
    String? error,
  }) async {
    final db = await database;
    final values = <String, Object?>{
      'state': state,
      'last_error': error,
      'server_id': ?serverId,
      if (attachment != null)
        'attachment_json': jsonEncode(attachment.toJson()),
    };
    await db.update(
      'media',
      values,
      where: 'client_id = ?',
      whereArgs: [clientId],
    );
  }

  Future<void> validateAttachments(
    String accountId,
    List<MediaAttachment> attachments,
  ) async {
    for (final attachment in attachments) {
      if (attachment.localPath == null) continue;
      final media = await mediaById(accountId, attachment.id);
      if (media == null || media.accountId != accountId) {
        throw const QuestException('这个附件不属于当前账号，请重新选择。');
      }
    }
  }

  Future<void> cacheEntries(
    String accountId,
    Iterable<JournalEntry> entries, {
    bool pending = false,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      for (final entry in entries) {
        if (!pending) {
          final current = await txn.query(
            'entries',
            columns: ['pending'],
            where: 'account_id = ? AND entry_id = ?',
            whereArgs: [accountId, entry.id],
            limit: 1,
          );
          if (current.isNotEmpty && current.single['pending'] == 1) continue;
        }
        await txn.insert('entries', {
          'account_id': accountId,
          'entry_id': entry.id,
          'entry_json': jsonEncode(entry.toJson()),
          'created_at': entry.createdAt.toUtc().toIso8601String(),
          'pending': pending ? 1 : 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });
  }

  Future<void> removeSavedEntry(String accountId, String entryId) async {
    final db = await database;
    await db.delete(
      'entries',
      where: 'account_id = ? AND entry_id = ?',
      whereArgs: [accountId, entryId],
    );
  }

  Future<void> _cacheCloudEntriesIn(
    DatabaseExecutor txn,
    String accountId,
    Iterable<JournalEntry> entries,
  ) async {
    for (final entry in entries) {
      final current = await txn.query(
        'entries',
        columns: ['pending'],
        where: 'account_id = ? AND entry_id = ?',
        whereArgs: [accountId, entry.id],
        limit: 1,
      );
      if (current.isNotEmpty && current.single['pending'] == 1) continue;
      await txn.insert('entries', {
        'account_id': accountId,
        'entry_id': entry.id,
        'entry_json': jsonEncode(entry.toJson()),
        'created_at': entry.createdAt.toUtc().toIso8601String(),
        'pending': 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  Future<void> queueMediaCleanup(String accountId, Iterable<String> ids) async {
    final unique = ids.toSet();
    if (unique.isEmpty) return;
    final db = await database;
    await db.transaction((txn) async {
      for (final id in unique) {
        final rows = await txn.query(
          'media',
          columns: const ['client_id', 'local_path', 'server_id'],
          where: 'account_id = ? AND (client_id = ? OR server_id = ?)',
          whereArgs: [accountId, id, id],
          limit: 1,
        );
        if (rows.isEmpty || rows.single['local_path'] == null) continue;
        if (await _mediaReferencedIn(txn, accountId, rows.single)) continue;
        await txn.insert('cleanup_queue', {
          'path': rows.single['local_path'],
          'client_id': rows.single['client_id'],
          'created_at': _now().toUtc().millisecondsSinceEpoch,
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
    });
  }

  Future<void> saveConflictSnapshot({
    required String accountId,
    required AppSnapshot snapshot,
    required String conflictId,
    required Iterable<String> mediaIds,
  }) async {
    _validateCloudAccount(accountId, snapshot);
    final db = await database;
    await db.transaction((txn) async {
      if (await _activeAccountIdIn(txn) != accountId) {
        throw const QuestException('账号已变化，请重新打开草稿。');
      }
      final context = 'conflict:$conflictId';
      await txn.update(
        'media',
        {'bound_record_id': null},
        where: 'account_id = ? AND bound_record_id = ?',
        whereArgs: [accountId, context],
      );
      final ids = mediaIds.toSet().toList();
      if (ids.isNotEmpty) {
        final placeholders = List.filled(ids.length, '?').join(',');
        await txn.rawUpdate(
          'UPDATE media SET bound_record_id = ? WHERE account_id = ? AND client_id IN ($placeholders)',
          [context, accountId, ...ids],
        );
      }
      await txn.update(
        'accounts',
        {
          'snapshot_json': jsonEncode(snapshot.toJson()),
          'updated_at': _now().toUtc().millisecondsSinceEpoch,
        },
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
    });
  }

  Future<AppSnapshot> saveStaleEditorDraft({
    required String accountId,
    required String branchId,
    required String questId,
    required String text,
    required List<MediaAttachment> attachments,
  }) async {
    if (text.runes.length > 500) throw const QuestException('记录最多 500 个字。');
    questById(questId);
    validateMedia(attachments);
    final db = await database;
    return db.transaction((txn) async {
      if (await _activeAccountIdIn(txn) != accountId) {
        throw const QuestException('账号已变化，请重新打开草稿。');
      }
      final branch = await _branchIn(txn, branchId);
      if (branch.accountId != accountId) {
        throw const QuestException('草稿不属于当前账号。');
      }
      final accounts = await txn.query(
        'accounts',
        where: 'account_id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (accounts.isEmpty) throw const QuestException('账号暂存不存在。');
      final current = _accountFromRow(accounts.single).snapshot;
      final existing = current.conflictDrafts
          .where(
            (draft) => draft.branchId == branchId && draft.questId == questId,
          )
          .firstOrNull;
      final id = existing?.id ?? _uuid.v4();
      final selected = <Map<String, Object?>>[];
      for (final attachment in attachments) {
        final rows = await txn.query(
          'media',
          where: 'account_id = ? AND (client_id = ? OR server_id = ?)',
          whereArgs: [accountId, attachment.id, attachment.id],
          limit: 1,
        );
        if (attachment.localPath != null && rows.isEmpty) {
          throw const QuestException('这个附件不属于当前账号，请重新选择。');
        }
        selected.addAll(rows);
      }
      final draft = ConflictDraft(
        id: id,
        questId: questId,
        text: text,
        createdAt: existing?.createdAt ?? _now().toUtc(),
        attachments: attachments,
        branchId: branchId,
        baseRevision: branch.baseRevision,
      );
      final next = current.copyWith(
        conflictDrafts: [
          for (final item in current.conflictDrafts)
            if (item.id != id) item,
          draft,
        ],
      );
      await txn.update(
        'accounts',
        {
          'snapshot_json': jsonEncode(next.toJson()),
          'updated_at': _now().toUtc().millisecondsSinceEpoch,
        },
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      final context = 'conflict:$id';
      final previous = await txn.query(
        'media',
        where: 'account_id = ? AND bound_record_id = ?',
        whereArgs: [accountId, context],
      );
      for (final row in previous) {
        if (!await _mediaReferencedIn(
          txn,
          accountId,
          row,
          includeSavedEntries: true,
        )) {
          await txn.update(
            'media',
            {'bound_record_id': null},
            where: 'client_id = ?',
            whereArgs: [row['client_id']],
          );
        }
      }
      for (final row in selected) {
        // Shared references remain protected by the authoritative JSON scan.
        await txn.update(
          'media',
          {'bound_record_id': context},
          where: 'client_id = ? AND account_id = ? AND (bound_record_id IS NULL OR bound_record_id = ? OR bound_record_id = ?)',
          whereArgs: [row['client_id'], accountId, 'draft', context],
        );
      }
      return next;
    });
  }

  Future<void> completeConflictDraft({
    required String accountId,
    required String branchId,
    required int baseRevision,
    required AppSnapshot snapshot,
    required String commandId,
    required JournalEntry entry,
    required List<String> mediaIds,
  }) async {
    _validateCloudAccount(accountId, snapshot);
    if (branchId.isEmpty) {
      throw const QuestException('这份旧草稿缺少同步分支信息，暂时无法完成。');
    }
    final db = await database;
    await db.transaction((txn) async {
      if (await _activeAccountIdIn(txn) != accountId) {
        throw const QuestException('账号已变化，请重新打开草稿。');
      }
      final branch = await _branchIn(txn, branchId);
      if (branch.accountId != accountId ||
          branch.baseRevision != baseRevision) {
        throw const QuestException('这份草稿的同步分支已不匹配。');
      }
      final pendingCount =
          Sqflite.firstIntValue(
            await txn.rawQuery(
              'SELECT COUNT(*) FROM entries WHERE pending = 1',
            ),
          ) ??
          0;
      if (pendingCount >= maxPendingRecords) {
        throw const QuestException('设备上最多暂存 20 条待同步记录，请先同步后再保存。');
      }
      final payload = {
        'clientRecordId': entry.id,
        'questId': entry.questId,
        'text': entry.text,
        'mediaIds': mediaIds,
        'createdAt': entry.createdAt.toIso8601String(),
      };
      final payloadJson = _canonicalJson(payload);
      await txn.insert('entries', {
        'account_id': accountId,
        'entry_id': entry.id,
        'entry_json': jsonEncode(entry.toJson()),
        'created_at': entry.createdAt.toUtc().toIso8601String(),
        'pending': 1,
      });
      await txn.insert('outbox', {
        'command_id': commandId,
        'account_id': accountId,
        'branch_id': branchId,
        'type': 'complete',
        'payload_json': payloadJson,
        'payload_hash': sha256.convert(utf8.encode(payloadJson)).toString(),
        'created_at': _now().toUtc().millisecondsSinceEpoch,
        'batch_id': null,
        'metered_allowed': 0,
      });
      if (mediaIds.isNotEmpty) {
        final placeholders = List.filled(mediaIds.length, '?').join(',');
        await txn.rawUpdate(
          'UPDATE media SET bound_record_id = ? WHERE account_id = ? AND client_id IN ($placeholders)',
          [entry.id, accountId, ...mediaIds],
        );
      }
      await txn.update(
        'accounts',
        {
          'snapshot_json': jsonEncode(snapshot.toJson()),
          'updated_at': _now().toUtc().millisecondsSinceEpoch,
        },
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
    });
  }

  Future<void> authorizeMeteredSnapshot(String accountId) async {
    final db = await database;
    await db.update(
      'outbox',
      {'metered_allowed': 1},
      where: 'account_id = ?',
      whereArgs: [accountId],
    );
  }

  Future<void> resetMediaReservation(String clientId) async {
    final db = await database;
    final rows = await db.query(
      'media',
      where: 'client_id = ?',
      whereArgs: [clientId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final media = _mediaFromRow(rows.single);
    await db.update(
      'media',
      {
        'server_id': null,
        'state': 'reserved',
        'last_error': null,
        'attachment_json': jsonEncode(
          media.attachment
              .copyWith(
                id: media.clientId,
                byteSize: media.sourceBytes,
                status: 'reserved',
                localPath: media.localPath,
              )
              .toJson(),
        ),
      },
      where: 'client_id = ?',
      whereArgs: [clientId],
    );
  }

  Future<List<JournalEntry>> localEntries(
    String accountId, {
    String query = '',
    bool pendingOnly = false,
  }) async {
    final db = await database;
    final rows = await db.query(
      'entries',
      where: pendingOnly ? 'account_id = ? AND pending = 1' : 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'created_at DESC, entry_id DESC',
    );
    final normalized = query.trim().toLowerCase();
    return (await _projectEntriesIn(db, accountId, rows))
        .where(
          (entry) =>
              normalized.isEmpty ||
              entry.text.toLowerCase().contains(normalized) ||
              entry.questTitle.toLowerCase().contains(normalized),
        )
        .toList(growable: false);
  }

  Future<List<JournalEntry>> _projectEntriesIn(
    DatabaseExecutor txn,
    String accountId,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return [];
    final commands = await txn.query(
      'outbox',
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'sequence',
    );
    final segments = <String, List<Map<String, Object?>>>{};
    final recordCommands = <String, List<Map<String, Object?>>>{};
    for (final command in commands) {
      final branch = command['branch_id'] as String;
      final segment = segments.putIfAbsent(branch, () => []);
      segment.add(command);
      if (command['type'] == 'complete') {
        final recordId = _jsonMap(
          jsonDecode(command['payload_json'] as String),
        )['clientRecordId'];
        if (recordId is String) recordCommands[recordId] = [...segment];
        segment.clear();
      }
    }
    final media = <String, Map<String, Object?>>{};
    for (final item in await txn.query(
      'media',
      where: 'account_id = ?',
      whereArgs: [accountId],
    )) {
      media[item['client_id'] as String] = item;
      if (item['server_id'] is String) {
        media[item['server_id'] as String] = item;
      }
    }
    return rows.map((row) {
      final entry = JournalEntry.fromJson(
        _jsonMap(jsonDecode(row['entry_json'] as String)),
      );
      if (row['pending'] != 1) {
        return entry.copyWith(syncStatus: 'saved', syncError: null);
      }
      final related = recordCommands[entry.id] ?? [];
      final ids = entry.attachments.map((item) => item.id).toSet();
      for (final command in related) {
        ids.addAll(
          List<String>.from(
            _jsonMap(jsonDecode(command['payload_json'] as String))['mediaIds']
                    as List? ??
                [],
          ),
        );
      }
      final attachments = ids
          .map((id) => media[id])
          .whereType<Map<String, Object?>>()
          .toList();
      final failure = attachments
          .where((item) => item['state'] == 'failed')
          .firstOrNull;
      final commandFailure = related
          .where((item) => item['last_error'] != null)
          .firstOrNull;
      final status = failure != null || commandFailure != null
          ? 'failed'
          : attachments.any((item) => item['state'] == 'uploading')
          ? 'uploading'
          : attachments.any((item) => item['state'] == 'processing')
          ? 'processing'
          : related.any((item) => item['batch_id'] != null)
          ? 'uploading'
          : 'pending';
      return entry.copyWith(
        syncStatus: status,
        syncError: status == 'failed'
            ? (failure?['last_error'] as String? ??
                  commandFailure?['last_error'] as String? ??
                  '附件处理失败，请重试或移除附件后上传文字。')
            : null,
      );
    }).toList();
  }

  Future<AppSnapshot> _projectSnapshotIn(
    DatabaseExecutor txn,
    String accountId,
    AppSnapshot snapshot,
  ) async {
    final ids = snapshot.entries.map((entry) => entry.id).toSet().toList();
    final rows = await txn.query(
      'entries',
      where: ids.isEmpty
          ? 'account_id = ? AND pending = 1'
          : 'account_id = ? AND (pending = 1 OR entry_id IN (${List.filled(ids.length, '?').join(',')}))',
      whereArgs: [accountId, ...ids],
      orderBy: 'created_at DESC, entry_id DESC',
    );
    return snapshot.copyWith(
      entries: await _projectEntriesIn(txn, accountId, rows),
    );
  }

  Future<bool> isPendingEntry(String accountId, String entryId) async {
    final db = await database;
    final rows = await db.query(
      'entries',
      columns: const ['pending'],
      where: 'account_id = ? AND entry_id = ?',
      whereArgs: [accountId, entryId],
      limit: 1,
    );
    return rows.isNotEmpty && rows.single['pending'] == 1;
  }

  Future<List<Map<String, Object?>>> _repairRowsIn(
    DatabaseExecutor txn,
    String accountId,
    String entryId,
  ) async {
    final entries = await txn.query(
      'entries',
      columns: ['pending'],
      where: 'account_id = ? AND entry_id = ?',
      whereArgs: [accountId, entryId],
      limit: 1,
    );
    if (entries.isEmpty || entries.single['pending'] != 1) {
      throw const QuestException('这条记录已不在待同步队列，请刷新后查看。');
    }
    final rows = await txn.query(
      'outbox',
      where: 'account_id = ?',
      whereArgs: [accountId],
      orderBy: 'sequence',
    );
    final targets = rows
        .where(
          (row) =>
              row['type'] == 'complete' &&
              _jsonMap(
                    jsonDecode(row['payload_json'] as String),
                  )['clientRecordId'] ==
                  entryId,
        )
        .toList();
    if (targets.length != 1) throw const QuestException('记录同步操作不完整，暂时无法调整。');
    final target = targets.single;
    final payload = _jsonMap(jsonDecode(target['payload_json'] as String));
    final previousComplete = rows
        .where(
          (row) =>
              row['branch_id'] == target['branch_id'] &&
              row['type'] == 'complete' &&
              (row['sequence'] as int) < (target['sequence'] as int),
        )
        .map((row) => row['sequence'] as int)
        .fold<int>(0, (a, b) => a > b ? a : b);
    return rows
        .where(
          (row) =>
              row['command_id'] == target['command_id'] ||
              (row['branch_id'] == target['branch_id'] &&
                  row['type'] == 'draft' &&
                  (row['sequence'] as int) > previousComplete &&
                  (row['sequence'] as int) < (target['sequence'] as int) &&
                  _jsonMap(
                        jsonDecode(row['payload_json'] as String),
                      )['questId'] ==
                      payload['questId']),
        )
        .toList();
  }

  /// The caller queries existing exact wire payloads with /sync-status while
  /// holding the sync lease before asking to remove pending attachments.
  Future<List<OfflineCommand>> pendingAttachmentRepairCommands(
    String accountId,
    String entryId,
  ) async {
    final db = await database;
    return db.transaction(
      (txn) async => (await _repairRowsIn(
        txn,
        accountId,
        entryId,
      )).map(_commandFromRow).toList(),
    );
  }

  Future<AppSnapshot> stripPendingAttachments(
    String accountId,
    String entryId, {
    required Set<String> missingCommandIds,
    String? leaseOwner,
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      await _assertLeaseIn(txn, leaseOwner);
      if (await _activeAccountIdIn(txn) != accountId) {
        throw const QuestException('账号已变化，请重新打开记录。');
      }
      final rows = await _repairRowsIn(txn, accountId, entryId);
      if (rows.any(
        (row) =>
            row['wire_json'] != null &&
            !missingCommandIds.contains(row['command_id']),
      )) {
        throw const QuestException('请先确认云端尚未保存这条记录，再调整附件。');
      }
      final detachedIds = <String>{};
      for (final row in rows) {
        final payload = _jsonMap(jsonDecode(row['payload_json'] as String));
        detachedIds.addAll(
          List<String>.from(payload['mediaIds'] as List? ?? []),
        );
        payload['mediaIds'] = <String>[];
        final encoded = _canonicalJson(payload);
        await txn.update(
          'outbox',
          {
            'payload_json': encoded,
            'payload_hash': sha256.convert(utf8.encode(encoded)).toString(),
            'wire_json': null,
            'batch_id': null,
            'last_error': null,
          },
          where: 'account_id = ? AND command_id = ?',
          whereArgs: [accountId, row['command_id']],
        );
      }
      // Explicitly removing attachments is not permission to delete the only
      // source copy until the revised text record has been acknowledged.
      for (final id in detachedIds) {
        final media = await txn.query(
          'media',
          where: 'account_id = ? AND (client_id = ? OR server_id = ?)',
          whereArgs: [accountId, id, id],
          limit: 1,
        );
        if (media.isEmpty) continue;
        await txn.insert('cleanup_holds', {
          'account_id': accountId,
          'entry_id': entryId,
          'client_id': media.single['client_id'],
        }, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      final entryRow = (await txn.query(
        'entries',
        where: 'account_id = ? AND entry_id = ?',
        whereArgs: [accountId, entryId],
        limit: 1,
      )).single;
      final entry = JournalEntry.fromJson(
        _jsonMap(jsonDecode(entryRow['entry_json'] as String)),
      ).copyWith(attachments: [], syncError: null);
      await txn.update(
        'entries',
        {'entry_json': jsonEncode(entry.toJson())},
        where: 'account_id = ? AND entry_id = ?',
        whereArgs: [accountId, entryId],
      );
      final accountRow = (await txn.query(
        'accounts',
        where: 'account_id = ?',
        whereArgs: [accountId],
        limit: 1,
      )).single;
      final current = _accountFromRow(accountRow).snapshot;
      final next = current.copyWith(
        entries: [
          for (final item in current.entries) item.id == entryId ? entry : item,
        ],
      );
      await txn.update(
        'accounts',
        {
          'snapshot_json': jsonEncode(next.toJson()),
          'updated_at': _now().toUtc().millisecondsSinceEpoch,
        },
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      return next;
    });
  }

  Future<List<String>> deletePendingEntry(
    String accountId,
    String entryId,
  ) async {
    final db = await database;
    return db.transaction((txn) async {
      final commands = await txn.query(
        'outbox',
        where: 'account_id = ? AND type = ?',
        whereArgs: [accountId, 'complete'],
      );
      for (final row in commands) {
        final payload = _jsonMap(jsonDecode(row['payload_json'] as String));
        if (payload['clientRecordId'] == entryId) {
          await txn.delete(
            'outbox',
            where: 'command_id = ?',
            whereArgs: [row['command_id']],
          );
        }
      }
      final mediaRows = await txn.query(
        'media',
        columns: const ['client_id', 'local_path', 'source_bytes'],
        where: 'account_id = ? AND bound_record_id = ?',
        whereArgs: [accountId, entryId],
      );
      final paths = mediaRows
          .map((row) => row['local_path'] as String?)
          .whereType<String>()
          .toList();
      for (final row in mediaRows) {
        final path = row['local_path'] as String?;
        if (path != null) {
          await txn.insert('cleanup_queue', {
            'path': path,
            'client_id': row['client_id'],
            'source_bytes': row['source_bytes'],
            'created_at': _now().toUtc().millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }
      await txn.delete(
        'media',
        where: 'account_id = ? AND bound_record_id = ?',
        whereArgs: [accountId, entryId],
      );
      await txn.delete(
        'entries',
        where: 'account_id = ? AND entry_id = ?',
        whereArgs: [accountId, entryId],
      );
      return paths;
    });
  }

  Future<OfflineApplyResult> applySyncResult({
    required String accountId,
    required OfflineSyncBatch batch,
    required AppSnapshot cloudState,
    required String branchMode,
    required List<Map<String, dynamic>> receipts,
    required List<JournalEntry> savedEntries,
    String? leaseOwner,
  }) async {
    _validateCloudAccount(accountId, cloudState);
    if (batch.branch.accountId != accountId ||
        !['active', 'records_only'].contains(branchMode)) {
      throw const QuestException('同步分支与当前账号不匹配。');
    }
    final commandsById = {
      for (final command in batch.commands) command.commandId: command,
    };
    final receiptIds = <String>{};
    final receiptEntryIds = <String>{};
    for (final receipt in receipts) {
      final id = receipt['commandId'];
      final command = commandsById[id];
      if (id is! String || command == null || !receiptIds.add(id)) {
        throw const QuestException('云端回执与本次同步操作不匹配。');
      }
      final entryId = receipt['entryId'];
      if (entryId != null) {
        if (command.type != 'complete' ||
            entryId != command.payload['clientRecordId']) {
          throw const QuestException('云端记录回执与本机记录不匹配。');
        }
        receiptEntryIds.add(entryId as String);
      }
    }
    if (savedEntries.any((entry) => !receiptEntryIds.contains(entry.id))) {
      throw const QuestException('云端返回了不属于本次同步的记录。');
    }
    final db = await database;
    return db.transaction((txn) async {
      await _assertLeaseIn(txn, leaseOwner);
      final accountRows = await txn.query(
        'accounts',
        where: 'account_id = ?',
        whereArgs: [accountId],
        limit: 1,
      );
      if (accountRows.isEmpty) throw StateError('Offline account is missing.');
      final account = _accountFromRow(accountRows.single);
      final branchRows = await txn.query(
        'branches',
        where: 'branch_id = ?',
        whereArgs: [batch.branch.id],
        limit: 1,
      );
      if (branchRows.isEmpty) throw StateError('Offline branch is missing.');
      final wasRecordsOnly = branchRows.single['mode'] == 'records_only';
      final effectiveMode = wasRecordsOnly || branchMode == 'records_only'
          ? 'records_only'
          : 'active';
      await txn.update(
        'branches',
        {
          'mode': effectiveMode,
          'updated_at': _now().toUtc().millisecondsSinceEpoch,
        },
        where: 'branch_id = ?',
        whereArgs: [batch.branch.id],
      );

      if (receiptIds.isNotEmpty) {
        final placeholders = List.filled(receiptIds.length, '?').join(',');
        await txn.rawDelete(
          'DELETE FROM outbox WHERE account_id = ? AND branch_id = ? AND command_id IN ($placeholders)',
          [accountId, batch.branch.id, ...receiptIds],
        );
      }
      await txn.update(
        'outbox',
        {'batch_id': null},
        where: 'batch_id = ?',
        whereArgs: [batch.batchId],
      );

      for (final entry in savedEntries) {
        await txn.insert('entries', {
          'account_id': accountId,
          'entry_id': entry.id,
          'entry_json': jsonEncode(entry.toJson()),
          'created_at': entry.createdAt.toUtc().toIso8601String(),
          'pending': 0,
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }

      // A receipt without its entry means it was deleted after commit.
      final savedIds = savedEntries.map((entry) => entry.id).toSet();
      for (final entryId in receiptEntryIds.difference(savedIds)) {
        await txn.delete(
          'entries',
          where: 'account_id = ? AND entry_id = ?',
          whereArgs: [accountId, entryId],
        );
      }

      final cleanupPaths = <String>[];
      for (final receipt in receipts) {
        final entryId = receipt['entryId'];
        if (entryId is! String) continue;
        final mediaRows = await txn.query(
          'media',
          columns: const ['client_id', 'local_path', 'server_id'],
          where: 'account_id = ? AND (bound_record_id = ? OR client_id IN (SELECT client_id FROM cleanup_holds WHERE account_id = ? AND entry_id = ?))',
          whereArgs: [accountId, entryId, accountId, entryId],
        );
        await txn.delete(
          'cleanup_holds',
          where: 'account_id = ? AND entry_id = ?',
          whereArgs: [accountId, entryId],
        );
        for (final row in mediaRows) {
          final path = row['local_path'] as String?;
          if (path == null) continue;
          if (await _mediaReferencedIn(
            txn,
            accountId,
            row,
            ignoreSnapshotEntries: true,
          )) {
            continue;
          }
          cleanupPaths.add(path);
          await txn.insert('cleanup_queue', {
            'path': path,
            'client_id': row['client_id'],
            'created_at': _now().toUtc().millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
      }

      var nextSnapshot = cloudState;
      var activeBranchId = account.activeBranchId;
      if (account.activeBranchId != batch.branch.id) {
        nextSnapshot = account.snapshot.copyWith(
          profile: cloudState.profile,
          progressRevision: cloudState.progressRevision,
          entryCount: cloudState.entryCount,
        );
      } else if (effectiveMode == 'records_only') {
        final conflicts = <ConflictDraft>[...account.snapshot.conflictDrafts];
        if (account.snapshot.draft.isNotEmpty ||
            account.snapshot.draftAttachments.isNotEmpty) {
          final questId =
              account.snapshot.activeQuestId ??
              await _draftQuestIn(
                txn,
                batch.branch.id,
                account.snapshot.recommendedQuestId,
              );
          final conflictId = _uuid.v4();
          conflicts.add(
            ConflictDraft(
              id: conflictId,
              questId: questId,
              text: account.snapshot.draft,
              attachments: account.snapshot.draftAttachments,
              createdAt: _now().toUtc(),
              branchId: batch.branch.id,
              baseRevision: batch.branch.baseRevision,
            ),
          );
          await txn.update(
            'media',
            {'bound_record_id': 'conflict:$conflictId'},
            where: 'account_id = ? AND bound_record_id = ?',
            whereArgs: [accountId, 'draft'],
          );
        }
        await txn.delete(
          'outbox',
          where: 'branch_id = ? AND type != ?',
          whereArgs: [batch.branch.id, 'complete'],
        );
        activeBranchId = _uuid.v4();
        await _insertBranch(
          txn,
          id: activeBranchId,
          accountId: accountId,
          baseRevision: cloudState.progressRevision,
          now: _now().toUtc().millisecondsSinceEpoch,
        );
        nextSnapshot = cloudState.copyWith(conflictDrafts: conflicts);
      } else {
        final remaining =
            Sqflite.firstIntValue(
              await txn.rawQuery(
                'SELECT COUNT(*) FROM outbox WHERE branch_id = ?',
                [batch.branch.id],
              ),
            ) ??
            0;
        if (remaining > 0) {
          nextSnapshot = account.snapshot.copyWith(
            profile: cloudState.profile,
            progressRevision: cloudState.progressRevision,
            entryCount: cloudState.entryCount,
          );
        } else {
          nextSnapshot = cloudState.copyWith(
            conflictDrafts: account.snapshot.conflictDrafts,
          );
        }
      }
      final pendingRows = await txn.query(
        'entries',
        where: 'account_id = ? AND pending = 1',
        whereArgs: [accountId],
      );
      final pendingEntries = pendingRows
          .map(
            (row) => JournalEntry.fromJson(
              _jsonMap(jsonDecode(row['entry_json'] as String)),
            ),
          )
          .toList();
      final mergedEntries = <String, JournalEntry>{
        for (final entry in nextSnapshot.entries)
          if (!receiptEntryIds.contains(entry.id)) entry.id: entry,
        for (final entry in savedEntries) entry.id: entry,
        for (final entry in pendingEntries) entry.id: entry,
      }.values.toList()..sort((a, b) => b.createdAt.compareTo(a.createdAt));
      nextSnapshot = nextSnapshot.copyWith(
        entries: mergedEntries,
        entryCount: cloudState.entryCount + pendingEntries.length,
      );
      await txn.update(
        'accounts',
        {
          'snapshot_json': jsonEncode(nextSnapshot.toJson()),
          'active_branch_id': activeBranchId,
          'requires_login': 0,
          'updated_at': _now().toUtc().millisecondsSinceEpoch,
        },
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      return OfflineApplyResult(
        snapshot: nextSnapshot,
        cleanupPaths: cleanupPaths,
      );
    });
  }

  bool _containsMediaId(Object? value, Set<String> ids) {
    if (value is String) return ids.contains(value);
    if (value is List) return value.any((item) => _containsMediaId(item, ids));
    if (value is Map) {
      return value.values.any((item) => _containsMediaId(item, ids));
    }
    return false;
  }

  Future<bool> _mediaReferencedIn(
    DatabaseExecutor txn,
    String accountId,
    Map<String, Object?> media, {
    bool includeSavedEntries = false,
    bool ignoreSnapshotEntries = false,
  }) async {
    if ((await txn.query(
      'cleanup_holds',
      columns: ['client_id'],
      where: 'account_id = ? AND client_id = ?',
      whereArgs: [accountId, media['client_id']],
      limit: 1,
    )).isNotEmpty) {
      return true;
    }
    final ids = [
      media['client_id'],
      media['server_id'],
    ].whereType<String>().toSet();
    final accounts = await txn.query(
      'accounts',
      columns: ['snapshot_json'],
      where: 'account_id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    if (accounts.isNotEmpty) {
      final snapshot = AppSnapshot.fromJson(
        _jsonMap(jsonDecode(accounts.single['snapshot_json'] as String)),
      );
      final values = {
        'draft': snapshot.draftAttachments
            .map((media) => media.toJson())
            .toList(),
        'conflicts': snapshot.conflictDrafts
            .map((draft) => draft.toJson())
            .toList(),
        if (!ignoreSnapshotEntries)
          'entries': snapshot.entries
              .where((entry) => includeSavedEntries || !entry.isSynced)
              .map((entry) => entry.toJson())
              .toList(),
      };
      if (_containsMediaId(values, ids)) return true;
    }
    for (final row in await txn.query(
      'entries',
      columns: ['entry_json'],
      where: includeSavedEntries
          ? 'account_id = ?'
          : 'account_id = ? AND pending = 1',
      whereArgs: [accountId],
    )) {
      if (_containsMediaId(jsonDecode(row['entry_json'] as String), ids)) {
        return true;
      }
    }
    for (final row in await txn.query(
      'outbox',
      columns: ['payload_json', 'wire_json'],
      where: 'account_id = ?',
      whereArgs: [accountId],
    )) {
      if (_containsMediaId(jsonDecode(row['payload_json'] as String), ids) ||
          (row['wire_json'] != null &&
              _containsMediaId(jsonDecode(row['wire_json'] as String), ids))) {
        return true;
      }
    }
    return false;
  }

  Future<OfflineDiscardResult> discardStagedMedia(
    String accountId,
    Iterable<String> ids,
  ) async {
    final db = await database;
    return db.transaction((txn) async {
      final paths = <String>[], serverIds = <String>[];
      for (final id in ids.toSet()) {
        final rows = await txn.query(
          'media',
          where: 'account_id = ? AND (client_id = ? OR server_id = ?)',
          whereArgs: [accountId, id, id],
          limit: 1,
        );
        if (rows.isEmpty || rows.single['state'] == 'staging') continue;
        final row = rows.single;
        if (await _mediaReferencedIn(
          txn,
          accountId,
          row,
          includeSavedEntries: true,
        )) {
          continue;
        }
        for (final path in [
          row['local_path'],
          row['staging_path'],
        ].whereType<String>()) {
          paths.add(path);
          await txn.insert('cleanup_queue', {
            'path': path,
            'client_id': null,
            'source_bytes': row['source_bytes'],
            'created_at': _now().toUtc().millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        if (row['server_id'] is String) {
          serverIds.add(row['server_id'] as String);
        }
        await txn.delete(
          'media',
          where: 'client_id = ? AND account_id = ?',
          whereArgs: [row['client_id'], accountId],
        );
      }
      return OfflineDiscardResult(cleanupPaths: paths, serverIds: serverIds);
    });
  }

  /// Only journals created by this store are recovered; unknown files are never
  /// scanned or deleted. The grace period avoids racing an active copy.
  Future<void> recoverAbandonedStaging({
    Duration grace = const Duration(hours: 1),
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'media',
        where: 'state = ? AND created_at < ?',
        whereArgs: [
          'staging',
          _now().toUtc().subtract(grace).millisecondsSinceEpoch,
        ],
      );
      for (final row in rows) {
        if (await _mediaReferencedIn(
          txn,
          row['account_id'] as String,
          row,
          includeSavedEntries: true,
        )) {
          continue;
        }
        for (final path in [
          row['local_path'],
          row['staging_path'],
        ].whereType<String>()) {
          await txn.insert('cleanup_queue', {
            'path': path,
            'client_id': null,
            'source_bytes': row['source_bytes'],
            'created_at': _now().toUtc().millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.ignore);
        }
        await txn.delete(
          'media',
          where: 'client_id = ?',
          whereArgs: [row['client_id']],
        );
      }
    });
  }

  Future<bool> isManagedMediaPath(String path) async {
    final root = p.normalize(p.absolute(await mediaRootPath));
    final target = p.normalize(p.absolute(path));
    if (!p.isWithin(root, target)) return false;
    try {
      final realRoot = await Directory(root).resolveSymbolicLinks();
      final parent = await Directory(p.dirname(target)).resolveSymbolicLinks();
      return p.equals(realRoot, parent) || p.isWithin(realRoot, parent);
    } on FileSystemException {
      return false;
    }
  }

  Future<List<String>> pendingCleanupPaths() async {
    await recoverAbandonedStaging();
    final db = await database;
    final rows = await db.query('cleanup_queue', orderBy: 'created_at');
    final result = <String>[];
    for (final row in rows) {
      final path = row['path'] as String;
      if (!await isManagedMediaPath(path)) continue;
      if (row['client_id'] != null) {
        final media = await db.query(
          'media',
          where: 'client_id = ?',
          whereArgs: [row['client_id']],
          limit: 1,
        );
        if (media.isNotEmpty &&
            await _mediaReferencedIn(
              db,
              media.single['account_id'] as String,
              media.single,
            )) {
          continue;
        }
      }
      result.add(path);
    }
    return result;
  }

  Future<void> markPathCleaned(String path) async {
    final db = await database;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'cleanup_queue',
        columns: const ['client_id'],
        where: 'path = ?',
        whereArgs: [path],
        limit: 1,
      );
      if (rows.isNotEmpty && rows.single['client_id'] != null) {
        await txn.update(
          'media',
          {'local_path': null, 'staging_path': null},
          where: 'client_id = ?',
          whereArgs: [rows.single['client_id']],
        );
      }
      await txn.delete('cleanup_queue', where: 'path = ?', whereArgs: [path]);
    });
  }

  Future<String> requestId(String accountId, String key) async {
    final db = await database;
    return db.transaction((txn) async {
      final existing = await txn.query(
        'request_ids',
        columns: const ['request_id'],
        where: 'account_id = ? AND request_key = ?',
        whereArgs: [accountId, key],
        limit: 1,
      );
      if (existing.isNotEmpty) {
        return existing.single['request_id'] as String;
      }
      final id = _uuid.v4();
      await txn.insert('request_ids', {
        'account_id': accountId,
        'request_key': key,
        'request_id': id,
      });
      return id;
    });
  }

  Future<void> clearRequestId(String accountId, String key) async {
    final db = await database;
    await db.delete(
      'request_ids',
      where: 'account_id = ? AND request_key = ?',
      whereArgs: [accountId, key],
    );
  }

  Future<SyncSummary> summary(String accountId) async {
    final db = await database;
    final accountRows = await db.query(
      'accounts',
      columns: const ['requires_login'],
      where: 'account_id = ?',
      whereArgs: [accountId],
      limit: 1,
    );
    final queuedCommands =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM outbox WHERE account_id = ?',
            [accountId],
          ),
        ) ??
        0;
    final entries = await localEntries(accountId, pendingOnly: true);
    return SyncSummary(
      pending: entries.where((entry) => entry.syncStatus == 'pending').length,
      uploading: entries
          .where(
            (entry) =>
                entry.syncStatus == 'uploading' ||
                entry.syncStatus == 'processing',
          )
          .length,
      failed: entries.where((entry) => entry.syncStatus == 'failed').length,
      queuedCommands: queuedCommands,
      message: entries.isEmpty && queuedCommands > 0 ? '活动进度待同步' : null,
      requiresLogin:
          accountRows.isNotEmpty && accountRows.single['requires_login'] == 1,
    );
  }

  Future<bool> acquireLease(
    String owner, {
    Duration ttl = const Duration(minutes: 5),
  }) async {
    final db = await database;
    return db.transaction((txn) async {
      final now = _now().toUtc().millisecondsSinceEpoch;
      final rows = await txn.query(
        'task_leases',
        where: 'lease_name = ?',
        whereArgs: const [leaseName],
        limit: 1,
      );
      if (rows.isNotEmpty && (rows.single['expires_at'] as int) > now) {
        // Reentrant acquisition must not release an actively captured batch.
        if (rows.single['owner'] != owner) return false;
        await txn.update(
          'task_leases',
          {'expires_at': now + ttl.inMilliseconds},
          where: 'lease_name = ? AND owner = ?',
          whereArgs: [leaseName, owner],
        );
        return true;
      }
      // No live owner remains. Any captured batch belonged to a process that
      // could not release it, so make it eligible for deterministic retry.
      await txn.update('outbox', {
        'batch_id': null,
      }, where: 'batch_id IS NOT NULL');
      await txn.insert('task_leases', {
        'lease_name': leaseName,
        'owner': owner,
        'expires_at': now + ttl.inMilliseconds,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return true;
    });
  }

  Future<bool> renewLease(
    String owner, {
    Duration ttl = const Duration(minutes: 5),
  }) async {
    final db = await database;
    final changed = await db.update(
      'task_leases',
      {
        'expires_at':
            _now().toUtc().millisecondsSinceEpoch + ttl.inMilliseconds,
      },
      where: 'lease_name = ? AND owner = ? AND expires_at > ?',
      whereArgs: [leaseName, owner, _now().toUtc().millisecondsSinceEpoch],
    );
    return changed == 1;
  }

  Future<bool> ownsLease(String owner) async {
    final db = await database;
    final rows = await db.query(
      'task_leases',
      columns: ['owner'],
      where: 'lease_name = ? AND owner = ? AND expires_at > ?',
      whereArgs: [leaseName, owner, _now().toUtc().millisecondsSinceEpoch],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  Future<void> _assertLeaseIn(DatabaseExecutor txn, String? owner) async {
    if (owner == null) return;
    final rows = await txn.query(
      'task_leases',
      columns: ['owner'],
      where: 'lease_name = ? AND owner = ? AND expires_at > ?',
      whereArgs: [leaseName, owner, _now().toUtc().millisecondsSinceEpoch],
      limit: 1,
    );
    if (rows.isEmpty) throw const QuestException('同步任务已交接，本次操作已停止。');
  }

  Future<void> releaseLease(String owner) async {
    final db = await database;
    await db.delete(
      'task_leases',
      where: 'lease_name = ? AND owner = ?',
      whereArgs: [leaseName, owner],
    );
  }

  Future<List<String>> purgeAccount(String accountId) async {
    final db = await database;
    return db.transaction((txn) async {
      final rows = await txn.query(
        'media',
        where: 'account_id = ? AND local_path IS NOT NULL',
        whereArgs: [accountId],
      );
      final paths = <String>[];
      for (final row in rows) {
        for (final path in [
          row['local_path'],
          row['staging_path'],
        ].whereType<String>()) {
          paths.add(path);
          await txn.insert('cleanup_queue', {
            'path': path,
            'client_id': null,
            'source_bytes': row['source_bytes'],
            'created_at': _now().toUtc().millisecondsSinceEpoch,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await txn.delete(
        'accounts',
        where: 'account_id = ?',
        whereArgs: [accountId],
      );
      final active = await _activeAccountIdIn(txn);
      if (active == accountId) {
        await txn.delete(
          'metadata',
          where: 'key = ?',
          whereArgs: [_activeAccountMetadataKey],
        );
      }
      return paths;
    });
  }
}
