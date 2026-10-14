import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { request as httpRequest } from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import { fixture, password, command, completion, fakeProcessor } from './fixtures.mjs';
import { createApp } from './server.mjs';
import { MiB } from './media.mjs';
import { createBackup, verifyBackup, restoreBackup } from './backup.mjs';

test('protocol is mandatory; guest state is lightweight; exports are absent', async (t) => {
  const { api, base } = await fixture(t);
  assert.equal((await fetch(`${base}/api/state`)).status, 426);
  const guest = await api('state'); assert.equal(guest.status, 200); assert.equal(guest.body.state.profile, null); assert.equal(guest.body.state.entryCount, 0); assert.equal(guest.body.state.entries, undefined);
  assert.equal((await api('health', undefined, undefined, { headers: { 'X-Sidequest-Protocol': '1' } })).body.protocolVersion, 2);
  assert.equal((await api('claim', {})).status, 401); assert.equal((await api('export')).status, 404);
  assert.equal((await api('state?token=secret')).status, 400); assert.equal(guest.headers.get('cache-control'), 'no-store');
});

test('client diagnostics are accepted silently, stored locally, and never require a session', async (t) => {
  const { base, register, directory } = await fixture(t);
  const post = (body, token) => fetch(`${base}/api/diagnostics`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: typeof body === 'string' ? body : JSON.stringify(body) });
  assert.equal((await post({ scope: 'home.load', message: 'boom', type: 'StateError' })).status, 204);
  const { token } = (await register()).body;
  assert.equal((await post({ scope: 'request:sync', message: 'SocketException: connection reset', type: 'SocketException' }, token)).status, 204);
  assert.equal((await post('{not-json', undefined)).status, 204);
  const lines = readFileSync(join(directory, 'diagnostics.jsonl'), 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  assert.equal(lines.length, 2);
  assert.equal(lines[0].scope, 'home.load'); assert.equal(lines[0].accountId, null); assert.ok(lines[0].at);
  assert.equal(lines[1].scope, 'request:sync'); assert.ok(lines[1].accountId); assert.equal(lines[1].type, 'SocketException');
});

test('web cookie sessions: login sets an HttpOnly cookie, cookie-only auth works, logout clears it', async (t) => {
  const { api, app, register } = await fixture(t);
  const registered = await api('register', { nickname: '网页玩家', password, role: 'student', preferences: [] }, undefined, { headers: { 'X-Sidequest-Client': 'web/0.1.0' } });
  assert.equal(registered.status, 201);
  const setCookie = registered.headers.get('set-cookie');
  assert.ok(setCookie && setCookie.startsWith('sidequest_session='), String(setCookie));
  assert.ok(setCookie.includes('HttpOnly') && setCookie.includes('SameSite=Lax') && setCookie.includes('Max-Age=604800'));
  const cookie = setCookie.split(';')[0];
  // 登录来源标记写进了会话表；Bearer 通道照旧返回 token。
  assert.equal(app.db.prepare('SELECT client FROM sessions').all().some((row) => row.client === 'web/0.1.0'), true);
  assert.match(registered.body.token, /^[A-Za-z0-9_-]{43}$/);
  // Cookie 单独即可通过鉴权；Bearer 也依旧有效，两者互不影响。
  const cookieState = await api('entries', undefined, undefined, { headers: { Cookie: cookie } });
  assert.equal(cookieState.status, 200);
  assert.equal((await api('state', undefined, registered.body.token)).body.state.profile.nickname, '网页玩家');
  // 服务端仍接受不带 Cookie 的 Bearer 请求（安卓端不受影响）。
  assert.equal((await api('entries', undefined, registered.body.token)).status, 200);
  // 登出同时清除浏览器 Cookie；旧 Cookie 随即失效。
  const logout = await api('logout', {}, registered.body.token);
  assert.ok((logout.headers.get('set-cookie') ?? '').includes('Max-Age=0'));
  assert.equal((await api('entries', undefined, undefined, { headers: { Cookie: cookie } })).status, 401);
});

test('web cookie sessions slide: renewal refreshes the browser cookie after a day', async (t) => {
  const { api, register, setTime } = await fixture(t);
  const registered = await register();
  const cookie = registered.headers.get('set-cookie').split(';')[0];
  // 当天使用：未进入续期窗口，不重发 Set-Cookie。
  const fresh = await api('state', undefined, undefined, { headers: { Cookie: cookie } });
  assert.equal(fresh.status, 200); assert.equal(fresh.headers.get('set-cookie'), null);
  setTime('2026-10-11T07:00:00.000Z'); // +25 小时：进入滑动续期窗口。
  const renewed = await api('entries', undefined, undefined, { headers: { Cookie: cookie } });
  assert.equal(renewed.status, 200);
  assert.ok((renewed.headers.get('set-cookie') ?? '').includes('sidequest_session='));
});

test('download page, latest APK, and legal pages are public; the link always tracks the newest build', async (t) => {
  const { base, directory } = await fixture(t);
  assert.equal((await fetch(`${base}/`, { redirect: 'manual' })).status, 302);
  const empty = await fetch(`${base}/download`);
  assert.equal(empty.status, 200);
  const emptyHtml = await empty.text();
  assert.ok(emptyHtml.includes('暂时还没有可下载的版本'));
  assert.ok(emptyHtml.includes('打开网页版') && emptyHtml.includes('href="/app/"'));
  assert.equal((await fetch(`${base}/download/latest`)).status, 404);
  mkdirSync(join(directory, 'apk'), { recursive: true });
  writeFileSync(join(directory, 'apk', 'sidequest-0.2.0.apk'), 'fake-apk-bytes');
  const page = await fetch(`${base}/download`);
  assert.equal(page.status, 200);
  const pageHtml = await page.text();
  assert.ok(pageHtml.includes('sidequest-0.2.0.apk'));
  assert.ok(pageHtml.includes('下载安卓版本'));
  assert.ok(pageHtml.includes('打开网页版') && pageHtml.includes('href="/app/"'));
  const apk = await fetch(`${base}/download/latest`);
  assert.equal(apk.status, 200);
  assert.equal(apk.headers.get('content-type'), 'application/vnd.android.package-archive');
  assert.equal(await apk.text(), 'fake-apk-bytes');
  const head = await fetch(`${base}/download/latest`, { method: 'HEAD' });
  assert.equal(head.status, 200);
  assert.equal(head.headers.get('content-type'), 'application/vnd.android.package-archive');
  assert.equal(head.headers.get('content-length'), String('fake-apk-bytes'.length));
  assert.equal((await fetch(`${base}/download`, { method: 'HEAD' })).status, 200);
  assert.equal((await fetch(`${base}/`, { method: 'HEAD', redirect: 'manual' })).status, 302);
  const privacy = await fetch(`${base}/privacy`);
  assert.equal(privacy.status, 200);
  assert.ok((await privacy.text()).includes('隐私政策'));
  assert.ok((await (await fetch(`${base}/terms`)).text()).includes('用户条款'));
});

test('download falls back to server bandwidth when OSS is unavailable', async (t) => {
  const attempts = [];
  const { base, directory } = await fixture(t, { oss: {
    config: { region: 'oss-cn-hangzhou', endpoint: 'oss-cn-hangzhou.aliyuncs.com', bucket: 'cllllc',
      accessKeyId: 'test-key', accessKeySecret: 'test-secret', prefix: 'sidequest', urlExpires: 900,
      downloadDomain: 'oss-download.desktoppet.online' },
    fetchImpl: async (url, init) => { attempts.push({ url: String(url), method: init?.method }); throw new Error('OSS unreachable'); },
  } });
  mkdirSync(join(directory, 'apk'), { recursive: true });
  writeFileSync(join(directory, 'apk', 'sidequest-0.2.0.apk'), 'fake-apk-bytes');
  const first = await fetch(`${base}/download/latest`);
  assert.equal(first.status, 200);
  assert.equal(await first.text(), 'fake-apk-bytes');
  assert.ok(attempts.length >= 1);
  assert.ok(attempts[0].url.startsWith('https://oss-download.desktoppet.online/'));
  const probes = attempts.length;
  const second = await fetch(`${base}/download/latest`);
  assert.equal(second.status, 200);
  assert.equal(await second.text(), 'fake-apk-bytes');
  assert.equal(attempts.length, probes); // 冷却期内直接回退，不再探测
});

test('download redirects to the signed OSS url once the object is verified', async (t) => {
  const calls = [];
  const size = String('fake-apk-bytes'.length);
  const { base, directory } = await fixture(t, { oss: {
    config: { region: 'oss-cn-hangzhou', endpoint: 'oss-cn-hangzhou.aliyuncs.com', bucket: 'cllllc',
      accessKeyId: 'test-key', accessKeySecret: 'test-secret', prefix: 'sidequest', urlExpires: 900,
      downloadDomain: 'oss-download.desktoppet.online' },
    fetchImpl: async (url, init) => {
      calls.push({ url: String(url), method: init?.method });
      return { status: 200, headers: { get: (name) => name === 'content-length' ? size : null } };
    },
  } });
  mkdirSync(join(directory, 'apk'), { recursive: true });
  writeFileSync(join(directory, 'apk', 'sidequest-0.2.0.apk'), 'fake-apk-bytes');
  const redirect = await fetch(`${base}/download/latest`, { redirect: 'manual' });
  assert.equal(redirect.status, 302);
  const location = redirect.headers.get('location');
  assert.ok(location.startsWith('https://oss-download.desktoppet.online/sidequest/sidequest-0.2.0.apk?'));
  assert.ok(location.includes('OSSAccessKeyId='));
  assert.ok(location.includes('Signature='));
  assert.equal(calls[0].method, 'HEAD');
  const head = await fetch(`${base}/download/latest`, { method: 'HEAD', redirect: 'manual' });
  assert.equal(head.status, 302);
  assert.ok(head.headers.get('location').includes('Signature='));
});

test('download page visits and download requests are recorded for stats', async (t) => {
  const { base, directory } = await fixture(t);
  mkdirSync(join(directory, 'apk'), { recursive: true });
  writeFileSync(join(directory, 'apk', 'sidequest-0.2.0.apk'), 'fake-apk-bytes');
  const wechat = { 'User-Agent': 'Mozilla/5.0 (Linux) MicroMessenger/8.0.49', 'X-Real-IP': '203.0.113.7' };
  await fetch(`${base}/download`, { headers: wechat });
  await fetch(`${base}/download/latest`, { headers: { ...wechat, Referer: `${base}/download` } });
  await fetch(`${base}/download/latest`, { method: 'HEAD', headers: { 'User-Agent': 'probe/1.0' } });
  await fetch(`${base}/download/latest`, { headers: { 'User-Agent': 'curl/8.0' } });
  await delay(200); // 事件为异步落盘
  const lines = readFileSync(join(directory, 'downloads.jsonl'), 'utf8').trim().split('\n').map((line) => JSON.parse(line));
  assert.equal(lines.length, 3); // HEAD 探测不计数
  assert.equal(lines[0].type, 'page');
  assert.equal(lines[0].ip, '203.0.113.7');
  assert.equal(lines[0].source, 'wechat');
  assert.equal(lines[1].type, 'apk');
  assert.equal(lines[1].via, 'server');
  assert.equal(lines[1].apk, 'sidequest-0.2.0.apk');
  assert.ok(lines[1].referer.endsWith('/download'));
  assert.equal(lines[1].source, 'wechat');
  assert.equal(lines[2].source, 'browser'); // curl 记浏览器类，不算微信
  assert.equal(lines[2].referer, null);
});

test('normalized accounts, password hashing and session isolation remain intact', async (t) => {
  const { app, api, register } = await fixture(t);
  const results = await Promise.all([register('Ａlice'), register('alice')]); assert.deepEqual(results.map((r) => r.status).sort(), [201,409]);
  const alice = results.find((r) => r.status === 201).body;
  const row = app.db.prepare('SELECT * FROM users').get(); assert.equal(row.normalized_nickname, 'alice'); assert.equal(row.password_hash.length, 128); assert.equal(row.password_salt.length, 32);
  const session = app.db.prepare('SELECT * FROM sessions').get(); assert.equal(session.token_hash.length, 64); assert.notEqual(session.token_hash, alice.token);
  const login = await api('login', { nickname: 'ALICE', password }); assert.equal(login.body.state.profile.id, alice.state.profile.id);
  assert.equal((await api('login', { nickname: 'ALICE', password: 'incorrect-password' })).status, 401);
  assert.equal((await api('logout', {}, alice.token)).status, 200); assert.equal((await api('state', undefined, alice.token)).status, 401); assert.equal((await api('state', undefined, login.body.token)).status, 200);
});

test('active sessions renew on use while idle ones still expire', async (t) => {
  const { app, api, register, setTime } = await fixture(t);
  const day = 24 * 60 * 60 * 1000;
  const alice = (await register('Alice')).body, bob = (await register('Bob')).body;
  const expires = (nickname) => app.db.prepare('SELECT expires_at FROM sessions WHERE user_id=(SELECT id FROM users WHERE nickname=?)').get(nickname).expires_at;
  const issued = expires('Alice');
  assert.equal(issued, expires('Bob'));
  const start = issued - 7 * day;
  assert.equal((await api('state', undefined, alice.token)).status, 200);
  assert.equal(expires('Alice'), issued);
  setTime(new Date(start + 6 * day));
  assert.equal((await api('state', undefined, alice.token)).status, 200);
  assert.equal(expires('Alice'), start + 13 * day);
  setTime(new Date(start + 8 * day));
  assert.equal((await api('state', undefined, alice.token)).status, 200);
  assert.equal((await api('state', undefined, bob.token)).status, 401);
});

test('offline batch commits once; duplicate IDs with changed content are rejected atomically', async (t) => {
  const { register, sync, api } = await fixture(t); const { token } = (await register()).body;
  const commands = [command('claim', { questId: 'green' }, 'claim1'), command('draft', { questId: 'green', text: '我的草稿', mediaIds: [] }, 'draft1'), command('complete', completion('record1'), 'complete1'), command('next', {}, 'next1')];
  const first = await sync(token, 'device-branch', 0, commands); assert.equal(first.status, 200, JSON.stringify(first.body));
  assert.equal(first.body.entries.length, 1); assert.equal(first.body.state.entryCount, 1); assert.equal(first.body.state.progressRevision, 4); assert.equal(first.body.branchMode, 'active');
  const retry = await sync(token, 'device-branch', 0, commands); assert.equal(retry.status, 200); assert.deepEqual(retry.body.receipts, first.body.receipts); assert.equal(retry.body.state.progressRevision, 4);
  assert.equal((await sync(token, 'device-branch', 4, [command('stop')])).status, 409);
  const altered = structuredClone(commands); altered[2].payload.text = '恶意改写'; assert.equal((await sync(token, 'device-branch', 0, altered)).status, 409);
  assert.equal((await api('entries/record1', undefined, token)).body.entry.text, '记录内容');
});

test('conflicting devices save every completed record without overwriting cloud draft, permanently', async (t) => {
  const { register, sync } = await fixture(t); const { token } = (await register()).body;
  const cloud = await sync(token, 'cloud', 0, [command('claim', { questId: 'green' }), command('draft', { questId: 'green', text: '云端草稿', mediaIds: [] })]); assert.equal(cloud.status, 200);
  const offline = await sync(token, 'offline', 0, [command('claim', { questId: 'green' }), command('complete', completion('offline1')), command('next'), command('claim', { questId: 'light' }), command('complete', completion('offline2', 'light'))]);
  assert.equal(offline.status, 200, JSON.stringify(offline.body)); assert.equal(offline.body.branchMode, 'records_only'); assert.equal(offline.body.entries.length, 2);
  assert.equal(offline.body.state.draft, '云端草稿'); assert.equal(offline.body.state.activeQuestId, 'green'); assert.equal(offline.body.state.progressRevision, 2);
  const later = await sync(token, 'offline', 0, [command('draft', { questId: 'light', text: '旧分支草稿', mediaIds: [] }), command('complete', completion('offline3', 'texture'))]);
  assert.equal(later.body.branchMode, 'records_only'); assert.equal(later.body.state.draft, '云端草稿'); assert.equal(later.body.state.entryCount, 3); assert.ok(later.body.receipts.every((r) => !r.progressApplied));
});

test('existing branch becomes records-only after another device changes canonical progress', async (t) => {
  const { register, sync, api } = await fixture(t); const { token } = (await register()).body;
  await sync(token, 'phone-a', 0, [command('claim', { questId: 'green' })]);
  await api('draft', { text: '云端更新' }, token);
  const result = await sync(token, 'phone-a', 0, [command('complete', completion('late-record'))]);
  assert.equal(result.body.branchMode, 'records_only'); assert.equal(result.body.state.draft, '云端更新'); assert.equal(result.body.state.entryCount, 1);
});

test('pagination is stable on equal times, search handles Unicode and literal wildcards, private detail is isolated', async (t) => {
  const { register, sync, api } = await fixture(t); const alice = (await register('Alice')).body, bob = (await register('Bob')).body;
  await sync(alice.token, 'old-branch', 99, [command('complete', completion('record-a', 'green', '中文😀 100% Apple')), command('complete', completion('record-b', 'light', '中文😀')), command('complete', completion('record-c', 'texture', 'other'))]);
  const page = await api('entries?limit=1', undefined, alice.token); assert.equal(page.body.entries[0].id, 'record-c'); assert.equal(page.body.total, 3);
  const second = await api(`entries?limit=1&cursor=${encodeURIComponent(page.body.nextCursor)}`, undefined, alice.token); assert.equal(second.body.entries[0].id, 'record-b');
  assert.equal((await api('entries?q=apple', undefined, alice.token)).body.total, 1); assert.equal((await api('entries?q=%25', undefined, alice.token)).body.total, 1);
  assert.equal((await api(`entries?q=${encodeURIComponent(' 中文😀 ')}`, undefined, alice.token)).body.total, 2);
  assert.equal((await api('entries/record-a', undefined, bob.token)).status, 404); assert.equal((await api('entries', undefined, bob.token)).body.total, 0);
});

test('record edit uses revision and idempotency; tombstones prevent resurrection', async (t) => {
  const { register, sync, api } = await fixture(t); const { token } = (await register()).body; const original = completion('edit-record');
  const complete = command('complete', original, 'original-complete'); await sync(token, 'offline', 10, [complete]);
  const edited = { id: 'edit-record', text: '修改后', mediaIds: [], expectedRevision: 1, requestId: 'edit-request' };
  const first = await api('update-entry', edited, token); assert.equal(first.status, 200); assert.equal(first.body.entry.revision, 2); assert.equal(first.body.entry.createdAt, original.createdAt);
  assert.deepEqual((await api('update-entry', edited, token)).body.entry, first.body.entry);
  assert.equal((await api('update-entry', { ...edited, requestId: 'another-request' }, token)).status, 409);
  await api('delete-entry', { id: 'edit-record', requestId: 'delete-request' }, token);
  const retry = await sync(token, 'offline', 10, [complete]); assert.equal(retry.status, 200); assert.equal(retry.body.entries.length, 0);
  const freshCommand = await sync(token, 'offline', 10, [command('complete', original)]); assert.equal(freshCommand.status, 200); assert.equal(freshCommand.body.state.entryCount, 0);
});

test('media reservation retry, authenticated ranges, draft retention, and committed cleanup', async (t) => {
  const { register, upload, api, base, app } = await fixture(t); const alice = (await register('Alice')).body, bob = (await register('Bob')).body;
  const result = await upload(alice.token, 'image', Buffer.from('abcdefghijklmnop'), 'stable-upload'); assert.equal(result.media.status, 'ready');
  const id = result.media.id;
  assert.equal((await api('uploads', { kind: 'image', byteSize: 16, clientUploadId: 'stable-upload' }, alice.token)).body.media.id, id);
  assert.equal((await api('uploads', { kind: 'image', byteSize: 17, clientUploadId: 'stable-upload' }, alice.token)).status, 409);
  assert.equal((await api(`uploads/${id}`, undefined, bob.token)).status, 404);
  const headers = { Authorization: `Bearer ${alice.token}`, 'X-Sidequest-Protocol': '2' };
  const part = await fetch(`${base}/api/media/${id}/content`, { headers: { ...headers, Range: 'bytes=2-5' } }); assert.equal(part.status, 206); assert.equal(await part.text(), 'cdef'); assert.equal(part.headers.get('content-range'), 'bytes 2-5/16');
  assert.equal((await fetch(`${base}/api/media/${id}/content`, { headers: { ...headers, Range: 'bytes=999-' } })).status, 416);
  assert.equal((await fetch(`${base}/api/media/${id}/content`, { headers: { ...headers, Range: 'bytes=0-1,3-4' } })).status, 416);
  assert.equal((await fetch(`${base}/api/media/${id}/content`, { method: 'HEAD', headers })).headers.get('content-length'), '16');
  await api('claim', {}, alice.token); await api('draft', { text: '草稿', mediaIds: [id] }, alice.token); await api('stop', {}, alice.token);
  assert.equal((await api('state', undefined, alice.token)).body.state.draftAttachments[0].id, id);
  assert.equal((await api(`uploads/${id}`, undefined, alice.token, { method: 'DELETE' })).status, 409);
  await api('claim', {}, alice.token); const complete = await api('complete', { text: '完成', mediaIds: [id], clientRecordId: 'media-record' }, alice.token); assert.equal(complete.status, 200, JSON.stringify(complete.body));
  assert.equal(complete.body.entry.attachments[0].id, id); assert.equal(complete.body.state.draftAttachments.length, 0);
  const editMedia = await upload(alice.token, 'video'); await api(`uploads/${editMedia.media.id}`, undefined, alice.token, { method: 'DELETE' });
  assert.equal((await api('entries/media-record', undefined, alice.token)).body.entry.attachments[0].id, id);
  await api('delete-entry', { id: 'media-record', requestId: 'delete-media-record' }, alice.token);
  assert.equal((await api(`uploads/${id}`, undefined, alice.token)).status, 404); assert.equal(existsSync(app.media.directory(id)), false);
});

test('media limits, ownership, cancellation, and expiration exclude referenced drafts', async (t) => {
  const { register, api, upload, app, setTime } = await fixture(t); const alice = (await register('Alice')).body, bob = (await register('Bob')).body;
  assert.equal((await api('uploads', { kind: 'video', byteSize: 50*MiB+1, clientUploadId: 'too-large' }, alice.token)).status, 413);
  const first = (await upload(alice.token)).media; await api('claim', {}, alice.token);
  assert.equal((await api('draft', { text: '偷附件', mediaIds: [first.id] }, bob.token)).status, 400);
  await api('claim', {}, bob.token); assert.equal((await api('draft', { text: '偷附件', mediaIds: [first.id] }, bob.token)).status, 404);
  await api('draft', { text: '保留', mediaIds: [first.id] }, alice.token); await api('stop', {}, alice.token);
  const orphan = (await upload(alice.token)).media;
  setTime('2026-10-12T06:00:00.000Z'); app.media.sweep();
  assert.equal((await api(`uploads/${first.id}`, undefined, alice.token)).status, 200); assert.equal((await api(`uploads/${orphan.id}`, undefined, alice.token)).status, 404);
  const tooMany = [];
  for (let i=0;i<6;i++) tooMany.push((await upload(alice.token)).media.id);
  await api('claim', {}, alice.token); assert.equal((await api('complete', { text: '太多图片', mediaIds: tooMany }, alice.token)).status, 400);
  assert.equal((await api('state', undefined, alice.token)).body.state.entryCount, 0);
});

test('quota reservation includes pending output, and record cap is enforced', async (t) => {
  const { register, api, app } = await fixture(t, { accountMediaLimit: 7*MiB }); const { token, state } = (await register()).body;
  assert.equal((await api('uploads', { kind: 'video', byteSize: 1, clientUploadId: 'no-room' }, token)).status, 413);
  const id = randomUUID(); app.db.prepare("INSERT INTO media(id,user_id,client_upload_id,kind,status,source_bytes,reserved_bytes,byte_size,mime_type,created_at) VALUES(?,?,?,'video','ready',1,1,?,'video/mp4',0)").run(id,state.profile.id,'oversized-fixture',46*MiB);
  await api('claim', {}, token); assert.equal((await api('complete', { text: '超限', mediaIds: [id] }, token)).status, 413);
});

test('parallel replacement permits one Shanghai day, pause retains draft, day roll cannot reroll active work', async (t) => {
  const { register, api, setTime } = await fixture(t); const { token } = (await register()).body;
  await api('claim', {}, token); await api('draft', { text: '初稿' }, token);
  const replacements = await Promise.all([api('replace', {}, token), api('replace', {}, token)]); assert.deepEqual(replacements.map((r) => r.status).sort(), [200,409]);
  const current = replacements.find((r) => r.status === 200).body.state; assert.equal(current.draft, '');
  await api('draft', { text: '留下' }, token); await api('stop', {}, token); setTime('2026-10-10T16:01:00.000Z');
  const state = (await api('state', undefined, token)).body.state; assert.equal(state.recommendedQuestId, current.recommendedQuestId); assert.equal(state.draft, '留下'); assert.equal(state.day, '2026-10-11');
});

test('Unicode 500 boundary, oversized JSON, and invalid batches cannot partially commit', async (t) => {
  const { register, api, sync } = await fixture(t); const { token } = (await register()).body;
  assert.equal((await sync(token, 'invalid', 10, [command('complete', completion('good')), command('complete', completion('bad', 'green', ' '))])).status, 400);
  assert.equal((await api('entries', undefined, token)).body.total, 0);
  await api('claim', {}, token); assert.equal((await api('draft', { text: '😀'.repeat(500) }, token)).status, 200); assert.equal((await api('complete', { text: '😀'.repeat(501) }, token)).status, 400);
  assert.equal((await api('draft', { text: 'x'.repeat(17000) }, token)).status, 413); assert.equal((await api('complete', { text: '😀'.repeat(500) }, token)).status, 200);
  assert.equal((await sync(token, 'big-batch', 10, Array.from({length:11},()=>command('stop')))).status, 400);
});

test('account deletion invalidates sessions and persists file cleanup independent of user cascade', async (t) => {
  const { register, api, upload, app } = await fixture(t); const { token } = (await register()).body; const photo = (await upload(token)).media;
  await api('claim', {}, token); await api('draft', { text: '草稿', mediaIds: [photo.id] }, token);
  assert.equal((await api('delete-account', { password: 'incorrect-password' }, token)).status, 401);
  const oldCleanup = app.media.cleanup; app.media.cleanup = () => {};
  assert.equal((await api('delete-account', { password }, token)).status, 200); assert.equal(app.db.prepare('SELECT count(*) AS n FROM media_cleanup').get().n, 1);
  assert.equal((await api('state', undefined, token)).status, 401); assert.equal(app.db.prepare('SELECT count(*) AS n FROM media').get().n, 0);
  app.media.cleanup = oldCleanup; app.media.cleanup(); assert.equal(existsSync(app.media.directory(photo.id)), false);
});

test('origin checks, throttling, and expiry reject unauthorized access', async (t) => {
  const { register, api, setTime } = await fixture(t, { authLimit: 2, allowedOrigins: ['https://trusted.example'] });
  assert.equal((await api('health', undefined, undefined, { headers: { Origin: 'https://evil.example' } })).status, 403);
  assert.equal((await api('health', undefined, undefined, { headers: { Origin: 'https://trusted.example' } })).headers.get('access-control-allow-origin'), 'https://trusted.example');
  const { token } = (await register()).body; await api('login', { nickname: '测试玩家', password: 'bad-password' }); assert.equal((await api('login', { nickname: '测试玩家', password }, undefined, { headers: { 'X-Forwarded-For': '1.2.3.4' } })).status, 429);
  setTime('2026-10-18T06:00:00.000Z'); assert.equal((await api('state', undefined, token)).status, 401);
});

test('backup refuses running service and existing destinations, restores database and files together', async (t) => {
  const { register, upload, api, app, directory } = await fixture(t); const { token } = (await register()).body; const photo = (await upload(token)).media;
  await api('claim', {}, token); await api('complete', { text: '备份记录', mediaIds: [photo.id], clientRecordId: 'backup-record' }, token);
  const options = { databasePath: join(directory,'test.sqlite'), mediaDirectory: join(directory,'media'), destination: join(directory,'backup') };
  await assert.rejects(createBackup(options), /in use/); await app.close();
  const backup = await createBackup(options); assert.ok(backup.files >= 3); verifyBackup(options.destination); await assert.rejects(createBackup(options), /already exists/);
  const restored = restoreBackup({ source: options.destination, destination: join(directory,'restored') });
  const server = createApp({ ...restored, mediaProcessor: fakeProcessor });
  assert.equal(server.db.prepare("SELECT text FROM entries WHERE id='backup-record'").get().text, '备份记录'); assert.ok(existsSync(join(restored.mediaDirectory,photo.id,'content.jpg'))); await server.close();
  writeFileSync(join(options.destination,'media',photo.id,'content.jpg'),'broken'); assert.throws(() => verifyBackup(options.destination), /verification failed/);
});

test('v1 database is rejected without migrating or changing its schema or bytes', async (t) => {
  const { app, directory } = await fixture(t); await app.close();
  const path = join(directory,'v1.sqlite'); const db = new DatabaseSync(path);
  db.exec("CREATE TABLE users(id TEXT PRIMARY KEY,nickname TEXT NOT NULL,normalized_nickname TEXT NOT NULL UNIQUE,password_salt TEXT NOT NULL,password_hash TEXT NOT NULL,role TEXT NOT NULL,preferences TEXT NOT NULL); CREATE TABLE quest_state(user_id TEXT PRIMARY KEY REFERENCES users(id),active_quest_id TEXT,recommended_quest_id TEXT NOT NULL DEFAULT 'green',replaced_on TEXT,draft TEXT NOT NULL DEFAULT '',day TEXT NOT NULL,can_request_next INTEGER NOT NULL DEFAULT 0); CREATE TABLE entries(id TEXT PRIMARY KEY,user_id TEXT NOT NULL REFERENCES users(id),quest_id TEXT NOT NULL,quest_title TEXT NOT NULL,text TEXT NOT NULL,created_at TEXT NOT NULL); INSERT INTO users VALUES('old','Old','old','salt','hash','student','[]'); INSERT INTO quest_state(user_id,day) VALUES('old','2026-10-10'); INSERT INTO entries VALUES('old-entry','old','green','三种绿色','旧记录','2026-10-10T00:00:00.000Z');"); db.close();
  const before=readFileSync(path);
  for (let i=0;i<2;i++) assert.throws(()=>createApp({databasePath:path,mediaDirectory:join(directory,'v1-media'),mediaProcessor:fakeProcessor}),/No migration/);
  assert.deepEqual(readFileSync(path),before);
  const original=new DatabaseSync(path,{readOnly:true});
  assert.equal(original.prepare("SELECT password_hash FROM users WHERE id='old'").get().password_hash,'hash');
  assert.equal(original.prepare('PRAGMA table_info(entries)').all().some(column=>column.name==='revision'),false);
  assert.equal(original.prepare("SELECT text FROM entries WHERE id='old-entry'").get().text,'旧记录'); original.close();
});

test('cleanup survives process restart and only touches registered private media directories', async (t) => {
  const { app, directory } = await fixture(t); const orphan = randomUUID(); mkdirSync(join(directory,'media',orphan)); writeFileSync(join(directory,'media',orphan,'source.part'),'partial');
  app.db.prepare('INSERT INTO media_cleanup(media_id,created_at) VALUES(?,0)').run(orphan); await app.close();
  const reopened = createApp({ databasePath:join(directory,'test.sqlite'),mediaDirectory:join(directory,'media'),mediaProcessor:fakeProcessor }); assert.equal(existsSync(join(directory,'media',orphan)),false); await reopened.close();
});

test('canceling or deleting an account during processing cannot resurrect ready media', async (t) => {
  let release;
  const gate = new Promise(resolve => { release=resolve; });
  const processor = { async process(...args) { await gate; return fakeProcessor.process(...args); } };
  const {register,api,base,app} = await fixture(t,{mediaProcessor:processor}); const {token}=(await register()).body;
  const reserved=await api('uploads',{kind:'image',byteSize:4,clientUploadId:'cancel-during-process'},token); const id=reserved.body.media.id;
  const uploaded=await fetch(`${base}/api/uploads/${id}/content`,{method:'PUT',headers:{'X-Sidequest-Protocol':'2',Authorization:`Bearer ${token}`},body:Buffer.from('abcd')}); assert.equal(uploaded.status,200); await uploaded.json();
  assert.equal((await api(`uploads/${id}`,undefined,token,{method:'DELETE'})).status,200); assert.equal(app.db.prepare('SELECT count(*) AS n FROM media_cleanup').get().n,1);
  release();
  for(let i=0;i<100 && app.media.activeProcessing.size;i++) await delay(10);
  assert.equal((await api(`uploads/${id}`,undefined,token)).status,404); assert.equal(existsSync(app.media.directory(id)),false); assert.equal(app.db.prepare('SELECT count(*) AS n FROM media_cleanup').get().n,0);
});

test('interrupted upload removes partial bytes and can retry with the same reservation', async (t) => {
  const {register,api,base,app}=await fixture(t); const {token}=(await register()).body;
  const reserved=await api('uploads',{kind:'image',byteSize:100,clientUploadId:'interrupted'},token); const id=reserved.body.media.id;
  const request=httpRequest(`${base}/api/uploads/${id}/content`,{method:'PUT',headers:{'X-Sidequest-Protocol':'2',Authorization:`Bearer ${token}`,'Content-Length':100}});
  request.on('error',()=>{}); request.write(Buffer.alloc(40));
  for(let i=0;i<100 && !app.media.activeUploads.has(id);i++) await delay(10);
  request.destroy();
  for(let i=0;i<100 && app.media.activeUploads.has(id);i++) await delay(10);
  assert.equal((await api(`uploads/${id}`,undefined,token)).body.media.status,'failed'); assert.equal(existsSync(join(app.media.directory(id),'source.part')),false);
  const retried=await fetch(`${base}/api/uploads/${id}/content`,{method:'PUT',headers:{'X-Sidequest-Protocol':'2',Authorization:`Bearer ${token}`},body:Buffer.alloc(100)}); assert.equal(retried.status,200); await retried.json();
  for(let i=0;i<100 && app.media.activeProcessing.size;i++) await delay(10);
  assert.equal((await api(`uploads/${id}`,undefined,token)).body.media.status,'ready');
});

test('sync rejects more than 16KiB even within ten-command limit without partial state', async(t)=>{
  const {register,sync,api}=await fixture(t); const {token}=(await register()).body;
  const commands=Array.from({length:10},(_,i)=>command('complete',completion(`large-${i}`,'green','😀'.repeat(500))));
  assert.equal((await sync(token,'large-json',999,commands)).status,413); assert.equal((await api('entries',undefined,token)).body.total,0);
});

test('client record IDs are scoped to accounts, but changed content in one account conflicts',async(t)=>{
  const {register,sync,api}=await fixture(t); const alice=(await register('Alice')).body,bob=(await register('Bob')).body;
  const a=await sync(alice.token,'branch',999,[command('complete',completion('same-id','green','Alice记录'))]);
  const b=await sync(bob.token,'branch',999,[command('complete',completion('same-id','green','Bob记录'))]);
  assert.equal(a.status,200); assert.equal(b.status,200);
  assert.equal((await api('entries/same-id',undefined,alice.token)).body.entry.text,'Alice记录');
  assert.equal((await api('entries/same-id',undefined,bob.token)).body.entry.text,'Bob记录');
  assert.equal((await sync(alice.token,'branch',999,[command('complete',completion('same-id','green','changed'))])).status,409);
  await api('delete-entry',{id:'same-id',requestId:'delete-same'},alice.token);
  assert.equal((await api('entries/same-id',undefined,bob.token)).status,200);
});

test('media directory ownership prevents cross-database reuse and unknown files are preserved',async(t)=>{
  const {app,directory}=await fixture(t);
  const unrelated=randomUUID(); mkdirSync(join(directory,'media',unrelated)); writeFileSync(join(directory,'media',unrelated,'keep.txt'),'unrelated');
  app.media.sweep(); assert.equal(readFileSync(join(directory,'media',unrelated,'keep.txt'),'utf8'),'unrelated');
  assert.throws(()=>createApp({databasePath:join(directory,'other.sqlite'),mediaDirectory:join(directory,'media'),mediaProcessor:fakeProcessor}),/另一个数据库/);
  assert.equal(readFileSync(join(directory,'media',unrelated,'keep.txt'),'utf8'),'unrelated');
  const existing=join(directory,'unmarked'); mkdirSync(existing); writeFileSync(join(existing,'keep.txt'),'keep');
  assert.throws(()=>createApp({databasePath:join(directory,'third.sqlite'),mediaDirectory:existing,mediaProcessor:fakeProcessor}),/已有未识别文件/);
  assert.equal(readFileSync(join(existing,'keep.txt'),'utf8'),'keep');
});

test('sync-status is read-only, verifies original hashes, and lists missing commands without creating a branch',async(t)=>{
  const {register,api,sync,app,setTime}=await fixture(t); const {token,state}=(await register()).body;
  const pending={branchId:'status-only',baseRevision:0,commands:[command('claim',{questId:'green'},'query-claim')]};
  const before=app.db.prepare('SELECT total_changes() AS n').get().n;
  const initial=await api('sync-status',pending,token); assert.equal(initial.status,200); assert.equal(initial.body.branchMode,'active'); assert.deepEqual(initial.body.missingCommandIds,['query-claim']); assert.deepEqual(initial.body.receipts,[]);
  assert.equal(app.db.prepare('SELECT total_changes() AS n').get().n,before); assert.equal(app.db.prepare('SELECT count(*) AS n FROM sync_branches').get().n,0);
  await sync(token,pending.branchId,pending.baseRevision,pending.commands);
  const replay=await api('sync-status',pending,token); assert.equal(replay.body.receipts.length,1); assert.deepEqual(replay.body.missingCommandIds,[]);
  const changed=structuredClone(pending); changed.commands[0].payload.questId='light'; assert.equal((await api('sync-status',changed,token)).status,409);
  assert.equal((await api('sync-status',{...pending,baseRevision:1},token)).status,409);
  await api('complete',{text:'完成',clientRecordId:'status-day-record'},token); setTime('2026-10-10T16:01:00.000Z');
  const beforeDay=app.db.prepare('SELECT * FROM quest_state WHERE user_id=?').get(state.profile.id);
  const status=await api('sync-status',pending,token); assert.equal(status.status,200); assert.equal(status.body.state.day,'2026-10-10');
  assert.deepEqual(app.db.prepare('SELECT * FROM quest_state WHERE user_id=?').get(state.profile.id),beforeDay);
  assert.equal((await api('sync-status',{...pending,commands:Array.from({length:11},()=>command('stop'))},token)).status,400);
  assert.equal((await api('sync-status',{branchId:'too-large-status',baseRevision:0,commands:Array.from({length:10},(_,i)=>command('complete',completion(`big-status-${i}`,'green','😀'.repeat(500))))},token)).status,413);
});

test('lost sync response then deletion on another device returns tombstone receipts without reupload or resurrection',async(t)=>{
  const {register,api,sync,upload,app}=await fixture(t); const {token}=(await register()).body;
  const second=(await api('login',{nickname:'测试玩家',password})).body.token;
  const photo=(await upload(token,'image',Buffer.from('original-photo'),'response-lost-photo')).media;
  const body={branchId:'response-lost-branch',baseRevision:0,commands:[command('claim',{questId:'green'},'lost-claim'),command('complete',completion('lost-record','green','服务器已收到，但客户端未收到回执',[photo.id]),'lost-complete')]};
  const committed=await sync(token,body.branchId,body.baseRevision,body.commands); assert.equal(committed.status,200);
  // Simulate a successful commit whose response was never durably recorded by the phone.
  await api('delete-entry',{id:'lost-record',requestId:'other-device-deletion'},second);
  assert.equal((await api(`uploads/${photo.id}`,undefined,token)).status,404);
  const status=await api('sync-status',body,token); assert.equal(status.status,200); assert.deepEqual(status.body.receipts,committed.body.receipts); assert.deepEqual(status.body.missingCommandIds,[]); assert.deepEqual(status.body.entries,[]);
  const repeated=await sync(token,body.branchId,body.baseRevision,body.commands); assert.equal(repeated.status,200); assert.equal(repeated.body.state.entryCount,0); assert.deepEqual(repeated.body.entries,[]);
  assert.equal(app.db.prepare('SELECT count(*) AS n FROM media').get().n,0); assert.equal(app.db.prepare('SELECT count(*) AS n FROM entries').get().n,0);
  const forbidden=structuredClone(body); forbidden.commands[1].payload.mediaIds=[randomUUID()]; assert.equal((await api('sync-status',forbidden,token)).status,409);
});

test('only an explicitly missing command may replace an expired unbound upload ID before first commit',async(t)=>{
  const {register,api,sync,upload,setTime,app}=await fixture(t); const {token}=(await register()).body;
  const original=(await upload(token,'image',Buffer.from('pending-photo'),'expiry-retry-photo')).media;
  const body={branchId:'never-sent-branch',baseRevision:99,commands:[command('complete',completion('expiry-record','green','离线记录',[original.id]),'expiry-command')]};
  setTime('2026-10-12T06:00:00.000Z'); app.media.sweep(); assert.equal((await api(`uploads/${original.id}`,undefined,token)).status,404);
  const status=await api('sync-status',body,token); assert.deepEqual(status.body.missingCommandIds,['expiry-command']); assert.deepEqual(status.body.receipts,[]);
  const replacement=(await upload(token,'image',Buffer.from('pending-photo'),'expiry-retry-photo')).media; assert.notEqual(replacement.id,original.id);
  body.commands[0].payload.mediaIds=[replacement.id];
  const saved=await sync(token,body.branchId,body.baseRevision,body.commands); assert.equal(saved.status,200); assert.equal(saved.body.entries[0].attachments[0].id,replacement.id);
  assert.equal((await api('sync-status',body,token)).body.missingCommandIds.length,0);
});
