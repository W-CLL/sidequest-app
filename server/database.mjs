import { DatabaseSync } from 'node:sqlite';
import { mkdirSync, chmodSync, existsSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { randomUUID } from 'node:crypto';

export function transaction(db, fn) {
  db.exec('BEGIN IMMEDIATE');
  try { const result = fn(); db.exec('COMMIT'); return result; }
  catch (error) { db.exec('ROLLBACK'); throw error; }
}

export function openDatabase(databasePath) {
  if (databasePath !== ':memory:' && existsSync(databasePath)) {
    const inspection = new DatabaseSync(databasePath, { readOnly: true });
    try {
      const previousVersion = inspection.prepare('PRAGMA user_version').get().user_version;
      const tables = inspection.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all();
      if (previousVersion > 2 || (tables.length > 0 && previousVersion !== 2)) {
        throw new Error('Existing database is not a v2 database. No migration is performed. Preserve it and configure a new DATABASE_PATH such as sidequest-v2.sqlite.');
      }
    } finally { inspection.close(); }
  }
  if (databasePath !== ':memory:') mkdirSync(dirname(resolve(databasePath)), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(databasePath);
  if (databasePath !== ':memory:') chmodSync(databasePath, 0o600);
  db.exec('PRAGMA foreign_keys = ON; PRAGMA journal_mode = WAL; PRAGMA busy_timeout = 5000;');
  const version = db.prepare('PRAGMA user_version').get().user_version;
  if (version > 2) { db.close(); throw new Error('Database version is newer than this server; refusing to downgrade.'); }
  transaction(db, () => {
    db.exec(`
      CREATE TABLE IF NOT EXISTS server_metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY, nickname TEXT NOT NULL, normalized_nickname TEXT NOT NULL UNIQUE,
        password_salt TEXT NOT NULL, password_hash TEXT NOT NULL, role TEXT NOT NULL, preferences TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS quest_state (
        user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
        active_quest_id TEXT, recommended_quest_id TEXT NOT NULL DEFAULT 'green',
        replaced_on TEXT, draft TEXT NOT NULL DEFAULT '', day TEXT NOT NULL,
        can_request_next INTEGER NOT NULL DEFAULT 0,
        progress_revision INTEGER NOT NULL DEFAULT 0, recommendation_history TEXT NOT NULL DEFAULT '[]'
      );
      CREATE TABLE IF NOT EXISTS entries (
        id TEXT NOT NULL, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        quest_id TEXT NOT NULL, quest_title TEXT NOT NULL, text TEXT NOT NULL, created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, revision INTEGER NOT NULL DEFAULT 1, creation_hash TEXT,
        PRIMARY KEY(user_id,id)
      );
      CREATE INDEX IF NOT EXISTS entries_by_user ON entries(user_id, created_at DESC, id DESC);
      CREATE TABLE IF NOT EXISTS sessions (
        token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, expires_at INTEGER NOT NULL,
        client TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS sessions_by_user ON sessions(user_id);
    `);
    db.exec(`
      CREATE TABLE IF NOT EXISTS sync_branches (
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, id TEXT NOT NULL,
        base_revision INTEGER NOT NULL, last_revision INTEGER NOT NULL, mode TEXT NOT NULL,
        PRIMARY KEY(user_id, id)
      );
      CREATE TABLE IF NOT EXISTS command_receipts (
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, id TEXT NOT NULL,
        branch_id TEXT NOT NULL, request_hash TEXT NOT NULL, receipt TEXT NOT NULL,
        PRIMARY KEY(user_id, id)
      );
      CREATE TABLE IF NOT EXISTS mutation_receipts (
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, id TEXT NOT NULL,
        request_hash TEXT NOT NULL, result TEXT NOT NULL, PRIMARY KEY(user_id, id)
      );
      CREATE TABLE IF NOT EXISTS entry_tombstones (
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, id TEXT NOT NULL,
        creation_hash TEXT, deleted_at TEXT NOT NULL, PRIMARY KEY(user_id, id)
      );
      CREATE TABLE IF NOT EXISTS media (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        client_upload_id TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL,
        source_bytes INTEGER NOT NULL, reserved_bytes INTEGER NOT NULL, byte_size INTEGER NOT NULL DEFAULT 0,
        mime_type TEXT NOT NULL DEFAULT '', duration_ms INTEGER, width INTEGER, height INTEGER,
        content_name TEXT, thumbnail_name TEXT, error TEXT, created_at INTEGER NOT NULL,
        UNIQUE(user_id, client_upload_id)
      );
      CREATE INDEX IF NOT EXISTS media_by_user ON media(user_id, created_at);
      CREATE TABLE IF NOT EXISTS media_bindings (
        media_id TEXT NOT NULL REFERENCES media(id) ON DELETE CASCADE,
        user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
        target_kind TEXT NOT NULL, target_id TEXT NOT NULL, position INTEGER NOT NULL,
        PRIMARY KEY(media_id, target_kind, target_id),
        UNIQUE(user_id, target_kind, target_id, position)
      );
      CREATE INDEX IF NOT EXISTS bindings_by_target ON media_bindings(user_id, target_kind, target_id, position);
      CREATE TABLE IF NOT EXISTS media_cleanup (
        media_id TEXT PRIMARY KEY, attempts INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL,
        last_error TEXT
      );
      PRAGMA user_version = 2;
    `);
    // v2 增量列：给旧库补“登录来源”列（幂等、非破坏性；不改变 user_version）。
    const sessionColumns = db.prepare('PRAGMA table_info(sessions)').all();
    if (!sessionColumns.some((column) => column.name === 'client')) {
      db.exec("ALTER TABLE sessions ADD COLUMN client TEXT NOT NULL DEFAULT ''");
    }
    db.prepare("INSERT OR IGNORE INTO server_metadata(key,value) VALUES('media_owner',?)").run(randomUUID());
  });
  return db;
}
