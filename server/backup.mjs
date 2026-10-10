import { DatabaseSync, backup } from 'node:sqlite';
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, resolve, sep } from 'node:path';
import { pathToFileURL } from 'node:url';
import { acquireDataLock } from './service-lock.mjs';

const hash = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
function copyTree(source, target, base, files) {
  mkdirSync(target, { recursive: true, mode: 0o700 });
  for (const item of readdirSync(source, { withFileTypes: true })) {
    if (item.isSymbolicLink()) throw new Error('Backup refuses symbolic links.');
    const src = join(source, item.name), dst = join(target, item.name);
    if (item.isDirectory()) copyTree(src, dst, base, files);
    else if (item.isFile()) { copyFileSync(src, dst); files.push({ path: relative(base, dst).split(sep).join('/'), byteSize: statSync(dst).size, sha256: hash(dst) }); }
    else throw new Error('Backup refuses special files.');
  }
}
function absent(path) { if (existsSync(path)) throw new Error(`Destination already exists; refusing overwrite: ${path}`); }
function verifyDatabase(path) {
  const db = new DatabaseSync(path, { readOnly: true });
  try {
    if (db.prepare('PRAGMA integrity_check').get().integrity_check !== 'ok' || db.prepare('PRAGMA foreign_key_check').all().length) throw new Error('Database integrity check failed.');
  } finally { db.close(); }
}

export async function createBackup({ databasePath, mediaDirectory, destination }) {
  const dbPath = resolve(databasePath), root = resolve(mediaDirectory), output = resolve(destination);
  absent(output);
  if (output === root || output.startsWith(root + sep) || output === dirname(dbPath)) throw new Error('Backup destination must be outside the live data directory.');
  const release = acquireDataLock(dbPath);
  let db;
  try {
    if (!existsSync(dbPath) || !existsSync(root)) throw new Error('Database and private media directory are both required.');
    verifyDatabase(dbPath);
    db = new DatabaseSync(dbPath, { readOnly: true });
    const owner = db.prepare("SELECT value FROM server_metadata WHERE key='media_owner'").get()?.value;
    if (!owner || !existsSync(join(root, '.sidequest-media-owner')) || readFileSync(join(root, '.sidequest-media-owner'), 'utf8') !== owner) throw new Error('Media directory does not belong to this database; refusing backup.');
    mkdirSync(output, { recursive: false, mode: 0o700 });
    const target = join(output, 'sidequest-v2.sqlite');
    await backup(db, target); db.close(); db = null;
    const files = [{ path: 'sidequest-v2.sqlite', byteSize: statSync(target).size, sha256: hash(target) }];
    copyTree(root, join(output, 'media'), output, files);
    writeFileSync(join(output, 'manifest.json'), JSON.stringify({ format: 'sidequest-operator-backup-v2', createdAt: new Date().toISOString(), files }, null, 2), { flag: 'wx', mode: 0o600 });
    verifyBackup(output);
    return { directory: output, files: files.length };
  } finally { db?.close(); release(); }
}

export function verifyBackup(directory) {
  const root = resolve(directory), manifest = JSON.parse(readFileSync(join(root, 'manifest.json'), 'utf8'));
  if (manifest.format !== 'sidequest-operator-backup-v2' || !Array.isArray(manifest.files)) throw new Error('Unsupported backup format.');
  const seen = new Set();
  for (const file of manifest.files) {
    if (typeof file.path !== 'string' || file.path.includes('\\') || file.path.includes(':') || file.path.startsWith('/') || file.path.split('/').some((part) => !part || part === '.' || part === '..') || seen.has(file.path)) throw new Error('Unsafe or duplicate backup path.');
    seen.add(file.path);
    const path = resolve(root, file.path);
    if (!path.startsWith(root + sep)) throw new Error('Backup path escapes its directory.');
    let parent = path;
    while (parent !== root) { if (existsSync(parent) && lstatSync(parent).isSymbolicLink()) throw new Error('Backup refuses symbolic links.'); parent = dirname(parent); }
    if (!path.startsWith(root + sep) || !existsSync(path) || statSync(path).size !== file.byteSize || hash(path) !== file.sha256) throw new Error(`Backup verification failed: ${file.path}`);
  }
  if (!seen.has('sidequest-v2.sqlite')) throw new Error('Backup is missing the database.');
  const dbPath = join(root, 'sidequest-v2.sqlite'); verifyDatabase(dbPath);
  const db = new DatabaseSync(dbPath, { readOnly: true });
  try {
    if (!seen.has('media/.sidequest-media-owner') || readFileSync(join(root, 'media', '.sidequest-media-owner'), 'utf8') !== db.prepare("SELECT value FROM server_metadata WHERE key='media_owner'").get()?.value) throw new Error('Backup media ownership does not match its database.');
    for (const row of db.prepare("SELECT id,content_name,thumbnail_name FROM media WHERE status='ready'").all()) {
      for (const name of [row.content_name,row.thumbnail_name].filter(Boolean)) if (!seen.has(`media/${row.id}/${name}`)) throw new Error(`Backup is missing a referenced attachment: ${row.id}`);
    }
  } finally { db.close(); }
  return manifest;
}

export function restoreBackup({ source, destination }) {
  const input = resolve(source), output = resolve(destination); absent(output);
  verifyBackup(input); mkdirSync(output, { recursive: false, mode: 0o700 });
  const manifest = JSON.parse(readFileSync(join(input, 'manifest.json'), 'utf8'));
  for (const file of manifest.files) { const path = join(output, file.path); mkdirSync(dirname(path), { recursive: true, mode: 0o700 }); copyFileSync(join(input, file.path), path); }
  mkdirSync(join(output, 'media'), { recursive: true, mode: 0o700 });
  verifyDatabase(join(output, 'sidequest-v2.sqlite'));
  return { databasePath: join(output, 'sidequest-v2.sqlite'), mediaDirectory: join(output, 'media') };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const [command, ...args] = process.argv.slice(2);
  try {
    let result;
    if (command === 'backup' && args.length === 3) result = await createBackup({ databasePath: args[0], mediaDirectory: args[1], destination: args[2] });
    else if (command === 'verify' && args.length === 1) result = { verified: true, files: verifyBackup(args[0]).files.length };
    else if (command === 'restore' && args.length === 2) result = restoreBackup({ source: args[0], destination: args[1] });
    else throw new Error('Usage: node backup.mjs backup <database> <media-directory> <new-backup-directory> | verify <backup-directory> | restore <backup-directory> <new-data-directory>. Stop the service first.');
    console.log(JSON.stringify(result));
  } catch (error) { console.error(error.message); process.exitCode = 1; }
}
