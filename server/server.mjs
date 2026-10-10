import { createServer } from 'node:http';
import { DatabaseSync } from 'node:sqlite';
import { randomBytes, randomUUID, createHash, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { mkdirSync, chmodSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { nextQuest, questTitle } from './catalog.mjs';

const deriveKey = promisify(scrypt);
const roles = new Set(['student', 'employee', 'freelancer', 'leader', 'caregiver', 'retired', 'transition', 'other']);
const preferences = new Set(['安静独处', '熟人同行', '观察细节', '动手创作', '尝试新鲜', '熟悉安心']);
const passwordOptions = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const SESSION_MS = 7 * 24 * 60 * 60 * 1000;
const MAX_BODY_BYTES = 16 * 1024;
const dateFormatter = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' });

class HttpError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}
const assert = (condition, status, message) => { if (!condition) throw new HttpError(status, message); };
const charLength = (value) => [...value].length;
const tokenHash = (token) => createHash('sha256').update(token).digest('hex');

function calendarDay(date) {
  const parts = Object.fromEntries(dateFormatter.formatToParts(date).map(({ type, value }) => [type, value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}

function nicknameInput(value) {
  assert(typeof value === 'string', 400, '请输入昵称');
  const display = value.normalize('NFKC').trim();
  assert(charLength(display) >= 2 && charLength(display) <= 20 && /^[\p{L}\p{N}_-]+$/u.test(display), 400, '昵称需为 2–20 个字母、汉字、数字、下划线或短横线');
  return { display, normalized: display.toLowerCase() };
}

function passwordInput(value) {
  assert(typeof value === 'string' && charLength(value) >= 8 && charLength(value) <= 128, 400, '密码需为 8–128 个字符');
  return value;
}

function profileInput(body) {
  assert(roles.has(body.role), 400, '请选择一个身份');
  const selected = body.preferences ?? [];
  assert(Array.isArray(selected) && selected.length <= 3 && selected.every((item) => preferences.has(item)) && new Set(selected).size === selected.length, 400, '探索偏好最多选择三个，且不能重复');
  return { role: body.role, preferences: selected };
}

function textInput(value, required) {
  assert(typeof value === 'string' && charLength(value) <= 300, 400, '文字记录最多 300 字');
  assert(!required || value.trim().length > 0, 400, '请先写一点记录，再完成并保存。');
  return required ? value.trim() : value;
}

function readJson(request) {
  assert(/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] ?? ''), 415, '仅支持 JSON 文字请求；此测试版暂不支持附件');
  assert(!request.headers['content-encoding'] || request.headers['content-encoding'] === 'identity', 415, '暂不支持压缩请求');
  assert(!request.headers['content-length'] || Number(request.headers['content-length']) <= MAX_BODY_BYTES, 413, '请求过大');
  return new Promise((resolveBody, rejectBody) => {
    let bytes = 0;
    const chunks = [];
    let ended = false;
    const fail = (error) => { if (!ended) { ended = true; rejectBody(error); } };
    request.on('data', (chunk) => {
      if (ended) return;
      bytes += chunk.length;
      if (bytes > MAX_BODY_BYTES) return fail(new HttpError(413, '请求过大'));
      chunks.push(chunk);
    });
    request.on('error', () => fail(new HttpError(400, '请求读取失败')));
    request.on('aborted', () => fail(new HttpError(400, '请求已中断')));
    request.on('end', () => {
      if (ended) return;
      ended = true;
      try {
        const body = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        assert(body !== null && typeof body === 'object' && !Array.isArray(body), 400, '请求格式错误');
        resolveBody(body);
      } catch (error) { rejectBody(error instanceof HttpError ? error : new HttpError(400, 'JSON 格式错误')); }
    });
  });
}

export function createApp({ databasePath = './data/sidequest.sqlite', now = () => new Date(), allowedOrigins = [], authLimit = 30, authWindowMs = 15 * 60 * 1000, maxConcurrentAuth = 4 } = {}) {
  if (databasePath !== ':memory:') mkdirSync(dirname(resolve(databasePath)), { recursive: true, mode: 0o700 });
  const db = new DatabaseSync(databasePath);
  if (databasePath !== ':memory:') chmodSync(databasePath, 0o600);
  db.exec(`
    PRAGMA foreign_keys = ON;
    PRAGMA journal_mode = WAL;
    PRAGMA busy_timeout = 5000;
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY, nickname TEXT NOT NULL, normalized_nickname TEXT NOT NULL UNIQUE,
      password_salt TEXT NOT NULL, password_hash TEXT NOT NULL, role TEXT NOT NULL, preferences TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS quest_state (
      user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
      active_quest_id TEXT, recommended_quest_id TEXT NOT NULL DEFAULT 'green',
      replaced_on TEXT, draft TEXT NOT NULL DEFAULT '', day TEXT NOT NULL,
      can_request_next INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS entries (
      id TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      quest_id TEXT NOT NULL, quest_title TEXT NOT NULL, text TEXT NOT NULL, created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS entries_by_user ON entries(user_id, created_at DESC);
    CREATE TABLE IF NOT EXISTS sessions (
      token_hash TEXT PRIMARY KEY, user_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE, expires_at INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS sessions_by_user ON sessions(user_id);
  `);
  const authBuckets = new Map();
  let activeAuth = 0;

  function transaction(fn) {
    db.exec('BEGIN IMMEDIATE');
    try { const result = fn(); db.exec('COMMIT'); return result; }
    catch (error) { db.exec('ROLLBACK'); throw error; }
  }

  function rateLimit(request, nickname) {
    const timestamp = now().getTime();
    for (const [key, bucket] of authBuckets) if (bucket.reset <= timestamp) authBuckets.delete(key);
    const keys = [`ip:${request.socket.remoteAddress ?? 'unknown'}`, `name:${nickname}`];
    for (const key of keys) {
      let bucket = authBuckets.get(key);
      if (!bucket) {
        assert(authBuckets.size < 10000, 429, '请求较多，请稍后再试');
        bucket = { count: 0, reset: timestamp + authWindowMs };
        authBuckets.set(key, bucket);
      }
      assert(bucket.count < authLimit, 429, '登录或注册尝试过多，请 15 分钟后再试');
      bucket.count++;
    }
  }

  async function passwordKey(password, salt) {
    assert(activeAuth < maxConcurrentAuth, 429, '正在处理其他登录请求，请稍后再试');
    activeAuth++;
    try { return await deriveKey(password, salt, 64, passwordOptions); }
    finally { activeAuth--; }
  }

  function session(userId) {
    const token = randomBytes(32).toString('base64url');
    db.prepare('DELETE FROM sessions WHERE expires_at <= ?').run(now().getTime());
    db.prepare('INSERT INTO sessions(token_hash, user_id, expires_at) VALUES (?, ?, ?)').run(tokenHash(token), userId, now().getTime() + SESSION_MS);
    return token;
  }

  function authenticate(request, optional = false) {
    const header = request.headers.authorization;
    if (!header && optional) return null;
    assert(typeof header === 'string' && /^Bearer [A-Za-z0-9_-]{43}$/.test(header), 401, '请先登录后再继续');
    const hash = tokenHash(header.slice(7));
    const found = db.prepare('SELECT user_id FROM sessions WHERE token_hash = ? AND expires_at > ?').get(hash, now().getTime());
    assert(found, 401, '登录已失效，请重新登录');
    return { id: found.user_id, hash };
  }

  function syncDay(userId) {
    const state = db.prepare('SELECT * FROM quest_state WHERE user_id = ?').get(userId);
    const day = calendarDay(now());
    if (state.day !== day) {
      const advance = !state.active_quest_id && state.can_request_next === 1;
      db.prepare('UPDATE quest_state SET day = ?, recommended_quest_id = ?, can_request_next = ? WHERE user_id = ?')
        .run(day, advance ? nextQuest(state.recommended_quest_id) : state.recommended_quest_id, advance ? 0 : state.can_request_next, userId);
    }
  }

  function snapshot(userId = null) {
    const day = calendarDay(now());
    if (!userId) return { profile: null, activeQuestId: null, recommendedQuestId: 'green', entries: [], replacedOn: null, draft: '', day, canRequestNext: false };
    syncDay(userId);
    const user = db.prepare('SELECT id, nickname, role, preferences FROM users WHERE id = ?').get(userId);
    const state = db.prepare('SELECT * FROM quest_state WHERE user_id = ?').get(userId);
    const entries = db.prepare('SELECT id, quest_id AS questId, quest_title AS questTitle, text, created_at AS createdAt FROM entries WHERE user_id = ? ORDER BY created_at ASC, rowid ASC').all(userId);
    return {
      profile: { ...user, preferences: JSON.parse(user.preferences) },
      activeQuestId: state.active_quest_id, recommendedQuestId: state.recommended_quest_id,
      entries, replacedOn: state.replaced_on, draft: state.draft, day, canRequestNext: state.can_request_next === 1,
    };
  }

  function respond(response, status, body, origin) {
    response.writeHead(status, {
      'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store',
      'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'none'",
      ...(origin ? { 'Access-Control-Allow-Origin': origin, Vary: 'Origin' } : {}),
      ...(status === 429 ? { 'Retry-After': '900' } : {}),
      ...(status === 413 ? { Connection: 'close' } : {}),
    });
    response.end(JSON.stringify(body));
  }

  const server = createServer(async (request, response) => {
    let allowedOrigin;
    try {
      const origin = request.headers.origin;
      assert(!origin || allowedOrigins.includes(origin), 403, '此来源未获允许');
      allowedOrigin = origin;
      const { pathname, search } = new URL(request.url, 'http://localhost');
      assert(!search, 400, '接口不接受查询参数');
      if (request.method === 'OPTIONS') {
        response.writeHead(204, {
          ...(allowedOrigin ? { 'Access-Control-Allow-Origin': allowedOrigin, Vary: 'Origin' } : {}),
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Authorization, Content-Type', 'Access-Control-Max-Age': '600',
        });
        response.end(); return;
      }
      if (request.method === 'GET' && pathname === '/api/health') {
        respond(response, 200, { ok: true, version: '0.1.0', mode: 'text-only-alpha', timezone: 'Asia/Shanghai' }, allowedOrigin); return;
      }
      if (request.method === 'GET' && pathname === '/api/state') {
        const auth = authenticate(request, true);
        respond(response, 200, { state: snapshot(auth?.id) }, allowedOrigin); return;
      }
      if (request.method === 'GET' && pathname === '/api/export') {
        const auth = authenticate(request);
        respond(response, 200, { schemaVersion: 1, exportedAt: now().toISOString(), timezone: 'Asia/Shanghai', state: snapshot(auth.id) }, allowedOrigin); return;
      }
      const actions = new Set(['register', 'login', 'logout', 'preferences', 'claim', 'replace', 'stop', 'draft', 'complete', 'next', 'delete-entry', 'delete-account']);
      const action = pathname.startsWith('/api/') ? pathname.slice(5) : '';
      assert(request.method === 'POST' && actions.has(action), 404, '接口不存在');
      const body = await readJson(request);
      const fields = { register: ['nickname', 'password', 'role', 'preferences'], login: ['nickname', 'password'], preferences: ['role', 'preferences'], draft: ['text'], complete: ['text'], 'delete-entry': ['id'], 'delete-account': ['password'] }[action] ?? [];
      assert(Object.keys(body).every((key) => fields.includes(key)), 400, '请求含未支持的字段；此测试版只支持文字记录');
      if (action === 'register' || action === 'login') {
        const nickname = nicknameInput(body.nickname);
        const password = passwordInput(body.password);
        rateLimit(request, nickname.normalized);
        if (action === 'register') {
          const profile = profileInput(body);
          const salt = randomBytes(16).toString('hex');
          const hash = (await passwordKey(password, salt)).toString('hex');
          try {
            const result = transaction(() => {
              const id = randomUUID();
              db.prepare('INSERT INTO users(id, nickname, normalized_nickname, password_salt, password_hash, role, preferences) VALUES (?, ?, ?, ?, ?, ?, ?)')
                .run(id, nickname.display, nickname.normalized, salt, hash, profile.role, JSON.stringify(profile.preferences));
              db.prepare('INSERT INTO quest_state(user_id, day) VALUES (?, ?)').run(id, calendarDay(now()));
              return { token: session(id), state: snapshot(id) };
            });
            respond(response, 201, result, allowedOrigin); return;
          } catch (error) {
            if (String(error.message).includes('UNIQUE constraint failed: users.normalized_nickname')) throw new HttpError(409, '这个昵称已被使用，请换一个');
            throw error;
          }
        }
        const user = db.prepare('SELECT * FROM users WHERE normalized_nickname = ?').get(nickname.normalized);
        const key = await passwordKey(password, user?.password_salt ?? '00000000000000000000000000000000');
        const expected = user ? Buffer.from(user.password_hash, 'hex') : Buffer.alloc(64);
        const matches = timingSafeEqual(key, expected);
        assert(user && matches, 401, '昵称或密码不正确');
        assert(db.prepare('SELECT id FROM users WHERE id = ?').get(user.id), 401, '昵称或密码不正确');
        const result = transaction(() => ({ token: session(user.id), state: snapshot(user.id) }));
        respond(response, 200, result, allowedOrigin); return;
      }
      const auth = authenticate(request);
      if (action === 'delete-account') {
        const password = passwordInput(body.password);
        const user = db.prepare('SELECT * FROM users WHERE id = ?').get(auth.id);
        rateLimit(request, user.normalized_nickname);
        const key = await passwordKey(password, user.password_salt);
        assert(timingSafeEqual(key, Buffer.from(user.password_hash, 'hex')), 401, '密码不正确，账号未删除');
        authenticate(request);
        transaction(() => db.prepare('DELETE FROM users WHERE id = ?').run(auth.id));
        respond(response, 200, { state: snapshot() }, allowedOrigin); return;
      }
      const result = transaction(() => {
        syncDay(auth.id);
        const state = db.prepare('SELECT * FROM quest_state WHERE user_id = ?').get(auth.id);
        if (action === 'logout') {
          db.prepare('DELETE FROM sessions WHERE token_hash = ?').run(auth.hash);
          return { state: snapshot() };
        }
        if (action === 'preferences') {
          const profile = profileInput(body);
          db.prepare('UPDATE users SET role = ?, preferences = ? WHERE id = ?').run(profile.role, JSON.stringify(profile.preferences), auth.id);
        } else if (action === 'claim') {
          if (state.active_quest_id) return { state: snapshot(auth.id) };
          assert(!state.can_request_next, 409, '这次已完成，可以从首页继续探索。');
          db.prepare('UPDATE quest_state SET active_quest_id = recommended_quest_id WHERE user_id = ?').run(auth.id);
        } else if (action === 'replace') {
          assert(!state.can_request_next, 409, '这次已完成，可以从首页继续探索。');
          assert(state.replaced_on !== calendarDay(now()), 409, '今天已经更换过一次，也可以先放一放。');
          const quest = nextQuest(state.recommended_quest_id);
          db.prepare("UPDATE quest_state SET recommended_quest_id = ?, active_quest_id = ?, replaced_on = ?, draft = '' WHERE user_id = ?")
            .run(quest, state.active_quest_id ? quest : null, calendarDay(now()), auth.id);
        } else if (action === 'stop') {
          db.prepare('UPDATE quest_state SET active_quest_id = NULL WHERE user_id = ?').run(auth.id);
        } else if (action === 'draft') {
          assert(state.active_quest_id, 409, '请先开始活动，再写记录。');
          db.prepare('UPDATE quest_state SET draft = ? WHERE user_id = ?').run(textInput(body.text, false), auth.id);
        } else if (action === 'complete') {
          assert(state.active_quest_id, 409, '请先开始活动，再写记录。');
          const text = textInput(body.text, true);
          db.prepare('INSERT INTO entries(id, user_id, quest_id, quest_title, text, created_at) VALUES (?, ?, ?, ?, ?, ?)')
            .run(randomUUID(), auth.id, state.active_quest_id, questTitle(state.active_quest_id), text, now().toISOString());
          db.prepare("UPDATE quest_state SET active_quest_id = NULL, draft = '', can_request_next = 1 WHERE user_id = ?").run(auth.id);
        } else if (action === 'next') {
          assert(!state.active_quest_id && state.can_request_next, 409, '完成当前活动后，可以继续探索。');
          db.prepare('UPDATE quest_state SET recommended_quest_id = ?, can_request_next = 0 WHERE user_id = ?').run(nextQuest(state.recommended_quest_id), auth.id);
        } else if (action === 'delete-entry') {
          assert(typeof body.id === 'string' && body.id.length <= 64, 400, '记录标识无效');
          const deletion = db.prepare('DELETE FROM entries WHERE id = ? AND user_id = ?').run(body.id, auth.id);
          assert(deletion.changes === 1, 404, '记录不存在');
        }
        return { state: snapshot(auth.id) };
      });
      respond(response, 200, result, allowedOrigin);
    } catch (error) {
      if (!response.headersSent) respond(response, error instanceof HttpError ? error.status : 500, { error: error instanceof HttpError ? error.message : '服务暂时不可用，请稍后再试' }, allowedOrigin);
      else response.end();
    }
  });
  server.requestTimeout = 15000;
  server.headersTimeout = 10000;
  server.timeout = 20000;
  server.maxHeadersCount = 50;
  server.on('clientError', (_error, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); });

  return {
    server, db,
    close: () => new Promise((resolveClose, rejectClose) => {
      server.close((error) => { db.close(); error ? rejectClose(error) : resolveClose(); });
      server.closeIdleConnections();
    }),
  };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const host = process.env.HOST || '127.0.0.1';
  const port = Number(process.env.PORT || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be 1–65535');
  const app = createApp({
    databasePath: process.env.DATABASE_PATH || './data/sidequest.sqlite',
    allowedOrigins: (process.env.ALLOWED_ORIGINS || '').split(',').map((item) => item.trim()).filter(Boolean),
  });
  app.server.listen(port, host, () => console.log(`Side Quest text-only alpha API listening on ${host}:${port}; HTTPS reverse proxy required for remote use.`));
  let closing = false;
  const shutdown = () => { if (!closing) { closing = true; app.close().then(() => process.exit(0), () => process.exit(1)); } };
  process.on('SIGINT', shutdown);
  process.on('SIGTERM', shutdown);
}
