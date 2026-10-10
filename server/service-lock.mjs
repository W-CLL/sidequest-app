import { existsSync, mkdirSync, openSync, readFileSync, closeSync, writeFileSync, unlinkSync } from 'node:fs';
import { dirname, resolve } from 'node:path';

function alive(pid) {
  if (!Number.isInteger(pid) || pid <= 0) return true;
  try { process.kill(pid, 0); return true; } catch (error) { return error.code !== 'ESRCH'; }
}

export function acquireDataLock(databasePath) {
  if (databasePath === ':memory:') return () => {};
  const path = `${resolve(databasePath)}.service-lock`;
  mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
  if (existsSync(path)) {
    let previous;
    try { previous = JSON.parse(readFileSync(path, 'utf8')); } catch { throw new Error(`Invalid service lock: ${path}; inspect it before recovery.`); }
    if (alive(previous.pid)) throw new Error(`Database is in use by process ${previous.pid}; stop the service before backup/restore or another start.`);
    // Only this exact known lock file is removed after proving its owning PID is absent.
    unlinkSync(path);
  }
  const fd = openSync(path, 'wx', 0o600);
  writeFileSync(fd, JSON.stringify({ pid: process.pid, startedAt: new Date().toISOString() })); closeSync(fd);
  return () => {
    if (existsSync(path)) {
      const owner = JSON.parse(readFileSync(path, 'utf8'));
      if (owner.pid === process.pid) unlinkSync(path);
    }
  };
}
