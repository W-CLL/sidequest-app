import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { once } from 'node:events';
import { createApp } from './server.mjs';

const password = 'Test-Pass-1234';

async function fixture(t, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'sidequest-api-test-'));
  const databasePath = join(directory, 'test.sqlite');
  let time = new Date('2026-10-10T06:00:00.000Z');
  const app = createApp({ databasePath, now: () => time, authLimit: 100, ...options });
  app.server.listen(0, '127.0.0.1');
  await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  t.after(async () => {
    await app.close();
    // This exact directory was created by mkdtemp above; never remove its parent.
    assert.equal(dirname(resolve(directory)), resolve(tmpdir()));
    assert.ok(basename(directory).startsWith('sidequest-api-test-'));
    rmSync(directory, { recursive: true, force: true });
  });
  async function api(action, body, token, extra = {}) {
    const response = await fetch(`${base}/api/${action}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(extra.headers ?? {}) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
    });
    return { status: response.status, body: await response.json(), headers: response.headers };
  }
  const register = (nickname = '测试玩家') => api('register', { nickname, password, role: 'student', preferences: ['观察细节'] });
  return { app, api, register, base, setTime: (value) => { time = new Date(value); } };
}

test('guest state is safe; claiming, private exports, and unsupported uploads require proper requests', async (t) => {
  const { api } = await fixture(t);
  const guest = await api('state');
  assert.equal(guest.status, 200);
  assert.equal(guest.body.state.profile, null);
  assert.equal(guest.body.state.recommendedQuestId, 'green');
  assert.deepEqual(guest.body.state.entries, []);
  assert.equal(guest.headers.get('cache-control'), 'no-store');
  assert.equal((await api('claim', {})).status, 401);
  assert.equal((await api('export')).status, 401);
  assert.equal((await api('upload', {})).status, 404);
  assert.equal((await api('health')).body.timezone, 'Asia/Shanghai');
});

test('atomic normalized nickname uniqueness, stable IDs, salted passwords and hashed-only tokens', async (t) => {
  const { app, api, register } = await fixture(t);
  const results = await Promise.all([register('Ａlice'), register('alice')]);
  assert.deepEqual(results.map((result) => result.status).sort(), [201, 409]);
  const created = results.find((result) => result.status === 201).body;
  const row = app.db.prepare('SELECT * FROM users').get();
  assert.equal(row.normalized_nickname, 'alice');
  assert.notEqual(row.password_hash, password);
  assert.equal(row.password_hash.length, 128);
  assert.equal(row.password_salt.length, 32);
  const sessions = app.db.prepare('SELECT * FROM sessions').all();
  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].token_hash.length, 64);
  assert.notEqual(sessions[0].token_hash, created.token);
  const login = await api('login', { nickname: 'ALICE', password });
  assert.equal(login.status, 200);
  assert.equal(login.body.state.profile.id, created.state.profile.id);
  assert.equal((await api('login', { nickname: 'ALICE', password: 'incorrect-password' })).status, 401);
  assert.equal((await api('login', { nickname: 'missing', password })).body.error, (await api('login', { nickname: 'ALICE', password: 'incorrect-password' })).body.error);
});

test('parallel replacement grants only one per Shanghai day; stop and role changes cannot reroll', async (t) => {
  const { api, register, setTime } = await fixture(t);
  const { token } = (await register()).body;
  assert.equal((await api('claim', {}, token)).body.state.activeQuestId, 'green');
  await api('draft', { text: '保留这个草稿' }, token);
  const replacements = await Promise.all([api('replace', {}, token), api('replace', {}, token)]);
  assert.deepEqual(replacements.map((result) => result.status).sort(), [200, 409]);
  const replaced = replacements.find((result) => result.status === 200).body.state;
  assert.equal(replaced.activeQuestId, 'light');
  assert.equal(replaced.replacedOn, '2026-10-10');
  assert.equal(replaced.draft, '');
  await api('draft', { text: '保留新任务的草稿' }, token);
  await api('preferences', { role: 'leader', preferences: [] }, token);
  const stopped = (await api('stop', {}, token)).body.state;
  assert.equal(stopped.activeQuestId, null);
  assert.equal(stopped.recommendedQuestId, 'light');
  assert.equal(stopped.draft, '保留新任务的草稿');
  assert.equal((await api('draft', { text: '停止后不能再修改' }, token)).status, 409);
  assert.equal((await api('next', {}, token)).status, 409);
  assert.equal((await api('replace', {}, token)).status, 409);
  await api('claim', {}, token);
  setTime('2026-10-10T16:01:00.000Z');
  const nextDay = (await api('state', undefined, token)).body.state;
  assert.equal(nextDay.day, '2026-10-11');
  assert.equal(nextDay.activeQuestId, 'light');
  assert.equal(nextDay.draft, '保留新任务的草稿');
  assert.equal((await api('replace', {}, token)).body.state.activeQuestId, 'texture');
});

test('completion is atomic, next is voluntary, deletion cannot reset progression', async (t) => {
  const { api, register } = await fixture(t);
  const { token } = (await register()).body;
  await api('claim', {}, token);
  const completions = await Promise.all([api('complete', { text: '看见了三种绿色。' }, token), api('complete', { text: '重复' }, token)]);
  assert.deepEqual(completions.map((result) => result.status).sort(), [200, 409]);
  const completed = (await api('state', undefined, token)).body.state;
  assert.equal(completed.activeQuestId, null);
  assert.equal(completed.canRequestNext, true);
  assert.equal(completed.entries.length, 1);
  assert.equal(completed.entries[0].questTitle, '三种绿色');
  assert.equal((await api('claim', {}, token)).status, 409);
  assert.equal((await api('replace', {}, token)).status, 409);
  const deleted = (await api('delete-entry', { id: completed.entries[0].id }, token)).body.state;
  assert.equal(deleted.entries.length, 0);
  assert.equal(deleted.canRequestNext, true);
  const next = (await api('next', {}, token)).body.state;
  assert.equal(next.recommendedQuestId, 'light');
  assert.equal(next.activeQuestId, null);
  assert.equal(next.canRequestNext, false);
  assert.equal((await api('next', {}, token)).status, 409);
});

test('day rollover after completion advances once, and drafts require an active quest', async (t) => {
  const { api, register, setTime } = await fixture(t);
  const { token } = (await register()).body;
  await api('claim', {}, token);
  await api('complete', { text: '完成' }, token);
  assert.equal((await api('draft', { text: '下一次的想法' }, token)).status, 409);
  setTime('2026-10-10T16:00:00.000Z');
  const state = (await api('state', undefined, token)).body.state;
  assert.equal(state.recommendedQuestId, 'light');
  assert.equal(state.canRequestNext, false);
  assert.equal(state.draft, '');
  assert.equal((await api('state', undefined, token)).body.state.recommendedQuestId, 'light');
});

test('journal entries are oldest first, including equal timestamp completions; claim is idempotent', async (t) => {
  const { api, register } = await fixture(t);
  const { token } = (await register()).body;
  assert.equal((await api('draft', { text: '未领取' }, token)).status, 409);
  const firstClaim = (await api('claim', {}, token)).body.state;
  assert.deepEqual((await api('claim', {}, token)).body.state, firstClaim);
  await api('complete', { text: '第一篇' }, token);
  await api('next', {}, token);
  await api('claim', {}, token);
  const state = (await api('complete', { text: '第二篇' }, token)).body.state;
  assert.deepEqual(state.entries.map((entry) => entry.text), ['第一篇', '第二篇']);
  assert.deepEqual(state.entries.map((entry) => entry.questId), ['green', 'light']);
});

test('private records are isolated, exports contain no secrets, and deletion cascades', async (t) => {
  const { app, api, register } = await fixture(t);
  const alice = (await register('Alice')).body;
  const bob = (await register('Bob')).body;
  await api('claim', {}, alice.token);
  const entry = (await api('complete', { text: '我的私密记录' }, alice.token)).body.state.entries[0];
  assert.equal((await api('delete-entry', { id: entry.id }, bob.token)).status, 404);
  assert.deepEqual((await api('state', undefined, bob.token)).body.state.entries, []);
  const exported = await api('export', undefined, alice.token);
  assert.equal(exported.body.state.entries[0].text, '我的私密记录');
  assert.ok(!JSON.stringify(exported.body).includes('password'));
  assert.ok(!JSON.stringify(exported.body).includes(alice.token));
  assert.equal((await api('delete-account', { password: 'wrong-password' }, alice.token)).status, 401);
  assert.equal((await api('delete-account', { password }, alice.token)).status, 200);
  assert.equal((await api('state', undefined, alice.token)).status, 401);
  assert.equal(app.db.prepare('SELECT count(*) AS count FROM entries').get().count, 0);
  assert.equal(app.db.prepare('SELECT count(*) AS count FROM quest_state').get().count, 1);
  assert.equal(app.db.prepare('SELECT count(*) AS count FROM sessions').get().count, 1);
  assert.equal((await register('alice')).status, 201);
});

test('logout revokes only its session, expiration rejects stale tokens', async (t) => {
  const { api, register, setTime } = await fixture(t);
  const { token } = (await register()).body;
  const second = (await api('login', { nickname: '测试玩家', password })).body.token;
  assert.equal((await api('logout', {}, token)).body.state.profile, null);
  assert.equal((await api('state', undefined, token)).status, 401);
  assert.equal((await api('state', undefined, second)).status, 200);
  setTime('2026-10-18T06:00:00.000Z');
  assert.equal((await api('state', undefined, second)).status, 401);
});

test('validation uses Unicode codepoints, rejects unsupported media and oversized JSON', async (t) => {
  const { api, register } = await fixture(t);
  assert.equal((await api('register', { nickname: 'a', password, role: 'student' })).status, 400);
  assert.equal((await api('register', { nickname: 'valid', password: 'short', role: 'student' })).status, 400);
  assert.equal((await api('register', { nickname: 'valid', password, role: 'invented' })).status, 400);
  const { token } = (await register()).body;
  await api('claim', {}, token);
  assert.equal((await api('complete', { text: '  ' }, token)).status, 400);
  assert.equal((await api('draft', { text: '😀'.repeat(300) }, token)).status, 200);
  assert.equal((await api('complete', { text: '😀'.repeat(301) }, token)).status, 400);
  assert.equal((await api('complete', { text: '图片', media: [] }, token)).status, 400);
  assert.equal((await api('draft', { text: 'x'.repeat(17000) }, token)).status, 413);
  assert.equal((await api('complete', { text: '😀'.repeat(300) }, token)).status, 200);
});

test('origin checks and auth throttling are enforced without trusting forwarded IP headers', async (t) => {
  const { api, register } = await fixture(t, { authLimit: 2, allowedOrigins: ['https://trusted.example'] });
  assert.equal((await api('health', undefined, undefined, { headers: { Origin: 'https://evil.example' } })).status, 403);
  const allowed = await api('health', undefined, undefined, { headers: { Origin: 'https://trusted.example' } });
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'https://trusted.example');
  assert.equal((await register()).status, 201);
  assert.equal((await api('login', { nickname: '测试玩家', password: 'wrong-password' })).status, 401);
  const limited = await api('login', { nickname: '测试玩家', password }, undefined, { headers: { 'X-Forwarded-For': '1.2.3.4' } });
  assert.equal(limited.status, 429);
  assert.equal(limited.headers.get('retry-after'), '900');
});
