import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, copyFileSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve, dirname, basename } from 'node:path';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import { createApp } from './server.mjs';

// Explicit test-only media processing; real decoder coverage lives in media.test.mjs.
export const password = 'Test-Pass-1234';
export const fakeProcessor = { async process(kind, source, directory) {
  const contentName = kind === 'image' ? 'content.jpg' : kind === 'video' ? 'content.mp4' : 'content.m4a';
  copyFileSync(source, join(directory, contentName));
  const thumbnailName = kind === 'audio' ? null : 'thumbnail.jpg';
  if (thumbnailName) copyFileSync(source, join(directory, thumbnailName));
  return { contentName, thumbnailName, thumbnailBytes: thumbnailName ? statSync(source).size : 0, byteSize: statSync(source).size,
    mimeType: kind === 'image' ? 'image/jpeg' : kind === 'video' ? 'video/mp4' : 'audio/mp4', durationMs: kind === 'image' ? null : 1000, width: kind === 'audio' ? null : 32, height: kind === 'audio' ? null : 32 };
} };
export async function fixture(t, options = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'sidequest-v2-test-'));
  let time = new Date('2026-10-10T06:00:00.000Z');
  const app = createApp({ databasePath: join(directory, 'test.sqlite'), mediaDirectory: join(directory, 'media'), now: () => time, authLimit: 1000,
    mediaProcessor: fakeProcessor, ...options });
  app.server.listen(0, '127.0.0.1'); await once(app.server, 'listening');
  const base = `http://127.0.0.1:${app.server.address().port}`;
  t.after(async () => {
    await app.close();
    assert.equal(dirname(resolve(directory)), resolve(tmpdir())); assert.ok(basename(directory).startsWith('sidequest-v2-test-'));
    rmSync(directory, { recursive: true, force: true });
  });
  async function api(action, body, token, extra = {}) {
    const response = await fetch(`${base}/api/${action}`, { method: extra.method ?? (body === undefined ? 'GET' : 'POST'),
      headers: { 'X-Sidequest-Protocol': '2', ...(body === undefined ? {} : { 'Content-Type': 'application/json' }), ...(token ? { Authorization: `Bearer ${token}` } : {}), ...extra.headers },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }) });
    return { status: response.status, body: await response.json(), headers: response.headers };
  }
  const register = (nickname = '测试玩家') => api('register', { nickname, password, role: 'student', preferences: [] });
  async function upload(token, kind = 'image', bytes = Buffer.from('test-media'), clientUploadId = `upload-${Math.random().toString(36).slice(2)}`) {
    const reserved = await api('uploads', { kind, byteSize: bytes.length, clientUploadId }, token); assert.equal(reserved.status, 201, JSON.stringify(reserved.body));
    const id = reserved.body.media.id;
    const response = await fetch(`${base}/api/uploads/${id}/content`, { method: 'PUT', headers: { 'X-Sidequest-Protocol': '2', Authorization: `Bearer ${token}`, 'Content-Type': 'application/octet-stream' }, body: bytes });
    assert.equal(response.status, 200, await response.text());
    for (let i=0; i<300; i++) {
      const result = await api(`uploads/${id}`, undefined, token);
      if (['ready','failed'].includes(result.body.media?.status)) return result.body;
      await delay(20);
    }
    throw new Error('Media processing did not finish');
  }
  const sync = (token, branchId, baseRevision, commands) => api('sync', { branchId, baseRevision, commands }, token);
  return { app, api, register, base, directory, upload, sync, setTime: (value) => { time = new Date(value); } };
}
export const command = (type, payload = {}, commandId = `${type}-${Math.random().toString(36).slice(2)}`) => ({ commandId, type, payload });
export const completion = (id, questId = 'green', text = '记录内容', mediaIds = [], createdAt = '2026-10-10T06:00:00.000Z') => ({ clientRecordId: id, questId, text, mediaIds, createdAt });
