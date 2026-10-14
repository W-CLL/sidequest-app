import { createServer } from 'node:http';
import { randomBytes, randomUUID, createHash, scrypt, timingSafeEqual } from 'node:crypto';
import { promisify } from 'node:util';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { quests, questTitle, recommendQuest, appendRecommendation, firstEnabledId } from './catalog.mjs';
import { assert, canonical, fields, HttpError, identifier } from './errors.mjs';
import { openDatabase, transaction } from './database.mjs';
import { FfmpegProcessor, MediaStore, mediaJson } from './media.mjs';
import { OssClient, resolveOssConfig } from './oss.mjs';
import { acquireDataLock } from './service-lock.mjs';
import { createReadStream } from 'node:fs';
import { appendFile, readdir, readFile, stat } from 'node:fs/promises';

const serverDir = dirname(fileURLToPath(import.meta.url));
const deriveKey = promisify(scrypt);
const roles = new Set(['student','employee','freelancer','leader','caregiver','retired','transition','other']);
const preferenceChoices = new Set(['安静独处','熟人同行','观察细节','动手创作','尝试新鲜','熟悉安心']);
const passwordOptions = { N: 16384, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };
const SESSION_MS = 7 * 24 * 60 * 60 * 1000;
const SESSION_COOKIE = 'sidequest_session';
// 滑动续期节奏：距上次延长超过 24 小时才写库（活跃用户每天续，闲置用户仍会到期）
const SESSION_RENEW_AFTER_MS = 24 * 60 * 60 * 1000;
const SESSION_COOKIE_MAX_AGE = Math.floor(SESSION_MS / 1000);
const MAX_BODY_BYTES = 16 * 1024;
const dateFormatter = new Intl.DateTimeFormat('en-CA', { timeZone: 'Asia/Shanghai', year: 'numeric', month: '2-digit', day: '2-digit' });
const digest = (value) => createHash('sha256').update(value).digest('hex');
// 浏览器会话 Cookie（网页版）：HttpOnly + Secure + SameSite=Lax，7 天滑动续期与令牌一致。
const sessionCookie = (token, maxAge = SESSION_COOKIE_MAX_AGE) =>
  `${SESSION_COOKIE}=${token}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Lax`;
function cookieToken(request) {
  const header = request.headers.cookie;
  if (typeof header !== 'string') return null;
  for (const part of header.split(';')) {
    const piece = part.trim();
    if (piece.startsWith(`${SESSION_COOKIE}=`)) {
      const value = piece.slice(SESSION_COOKIE.length + 1);
      return /^[A-Za-z0-9_-]{43}$/.test(value) ? value : null;
    }
  }
  return null;
}
// 登录来源标记（仅登录/注册时记录一次）：如 android/0.2.0+3 或 web/0.2.0+3。
function clientTagOf(request) {
  const raw = request.headers['x-sidequest-client'];
  return typeof raw === 'string' && /^[a-z0-9][a-z0-9._+/-]{0,79}$/i.test(raw) ? raw : '';
}
const hashObject = (value) => digest(canonical(value));
const textLength = (value) => [...value].length;

function calendarDay(date) {
  const parts = Object.fromEntries(dateFormatter.formatToParts(date).map(({ type, value }) => [type, value]));
  return `${parts.year}-${parts.month}-${parts.day}`;
}
function nicknameInput(value) {
  assert(typeof value === 'string', 400, '请输入昵称');
  const display = value.normalize('NFKC').trim();
  assert(textLength(display) >= 2 && textLength(display) <= 20 && /^[\p{L}\p{N}_-]+$/u.test(display), 400, '昵称需为 2–20 个字母、汉字、数字、下划线或短横线');
  return { display, normalized: display.toLowerCase() };
}
function passwordInput(value) {
  assert(typeof value === 'string' && textLength(value) >= 8 && textLength(value) <= 128, 400, '密码需为 8–128 个字符');
  return value;
}
function profileInput(body) {
  assert(roles.has(body.role), 400, '请选择一个身份');
  const selected = body.preferences ?? [];
  assert(Array.isArray(selected) && selected.length <= 3 && selected.every((item) => preferenceChoices.has(item)) && new Set(selected).size === selected.length, 400, '探索偏好最多选择三个，且不能重复');
  return { role: body.role, preferences: selected };
}
function textInput(value, required) {
  assert(typeof value === 'string' && textLength(value) <= 500, 400, '文字记录最多 500 字');
  assert(!required || value.trim().length > 0, 400, '请先写一点记录，再完成并保存');
  return required ? value.trim() : value;
}
function questInput(value) {
  assert(typeof value === 'string' && quests.some((quest) => quest.id === value), 400, '活动不存在，请更新客户端');
  return value;
}
function dateInput(value) {
  assert(typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(value), 400, '记录时间无效');
  const date = new Date(value);
  assert(Number.isFinite(date.getTime()), 400, '记录时间无效');
  const [year, month, day] = value.slice(0, 10).split('-').map(Number);
  assert(month >= 1 && month <= 12 && day >= 1 && day <= new Date(Date.UTC(year, month, 0)).getUTCDate(), 400, '记录日期无效');
  return date.toISOString();
}
function readJson(request) {
  assert(/^application\/json(?:\s*;|$)/i.test(request.headers['content-type'] ?? ''), 415, '此接口仅支持 JSON 请求');
  assert(!request.headers['content-encoding'] || request.headers['content-encoding'] === 'identity', 415, '暂不支持压缩请求');
  assert(!request.headers['content-length'] || Number(request.headers['content-length']) <= MAX_BODY_BYTES, 413, '请求过大');
  return new Promise((resolveBody, rejectBody) => {
    let bytes = 0, ended = false;
    const chunks = [];
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

const HTML_ESCAPES = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const escapeHtml = (value) => String(value).replace(/[&<>"']/g, (char) => HTML_ESCAPES[char]);

// 极简 Markdown 渲染：只支持我们法律文档用到的子集（# / ## / - / **加粗** / 段落）。
function renderMarkdown(markdown) {
  const out = [];
  let inList = false;
  const inline = (text) => escapeHtml(text).replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>');
  const closeList = () => { if (inList) { out.push('</ul>'); inList = false; } };
  for (const raw of markdown.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line) { closeList(); continue; }
    if (line.startsWith('## ')) { closeList(); out.push(`<h2>${inline(line.slice(3))}</h2>`); continue; }
    if (line.startsWith('# ')) { closeList(); out.push(`<h1>${inline(line.slice(2))}</h1>`); continue; }
    if (line.startsWith('- ')) { if (!inList) { out.push('<ul>'); inList = true; } out.push(`<li>${inline(line.slice(2))}</li>`); continue; }
    closeList();
    out.push(`<p>${inline(line)}</p>`);
  }
  closeList();
  return out.join('\n');
}

function pageShell(title, body) {
  return `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${escapeHtml(title)}</title>
<style>
body { margin: 0; background: #f7f6f0; color: #203b31; font: 16px/1.8 -apple-system, "PingFang SC", "Microsoft YaHei", "Segoe UI", sans-serif; }
main { max-width: 640px; margin: 0 auto; padding: 36px 22px 72px; }
h1 { font-size: 24px; margin: 0 0 6px; }
h2 { font-size: 17px; margin: 30px 0 8px; }
p, li { color: #3a4a40; margin: 8px 0; }
ul { padding-left: 20px; }
a { color: #234d3c; }
.btn { display: block; margin: 26px 0 10px; padding: 14px 18px; border-radius: 14px; background: #234d3c; color: #ffffff; text-align: center; font-size: 17px; font-weight: 600; text-decoration: none; }
.meta { color: #69756c; font-size: 13px; }
strong { color: #203b31; }
</style>
</head>
<body>
<main>
${body}
</main>
</body>
</html>`;
}

function respondHtml(response, status, html, allowedOrigin) {
  response.writeHead(status, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store', ...(allowedOrigin ? { 'Access-Control-Allow-Origin': allowedOrigin, Vary: 'Origin' } : {}) });
  response.end(html);
}

function formatBytes(size) {
  if (size >= 1024 * 1024) return `${(size / (1024 * 1024)).toFixed(1)} MB`;
  return `${Math.max(1, Math.round(size / 1024))} KB`;
}

function downloadPage(apk) {
  const latest = apk
    ? `<a class="btn" href="/download/latest">下载安卓版本</a>
<p class="meta">${escapeHtml(apk.name)} · ${formatBytes(apk.size)} · 更新于 ${escapeHtml(new Date(apk.mtimeMs).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false }))}</p>`
    : '<p>暂时还没有可下载的版本，稍后再来看看。</p>';
  return pageShell('支线 · 下载', `<h1>支线</h1>
<p>每天一件 5–10 分钟的小事，重新看见平常的日子；把发现记进只属于你的探索册。</p>
<h2>安卓手机</h2>
${latest}
<h2>iPhone / 电脑</h2>
<a class="btn" href="/app/">打开网页版</a>
<p class="meta">在浏览器里直接使用；iPhone 上用 Safari 打开后，点分享「添加到主屏幕」，就能像应用一样打开。</p>
<h2>安装提示</h2>
<ul>
<li>手机提示「不允许安装未知应用」时，按提示允许一次，再重新安装即可。</li>
<li>装过旧版本：直接下载安装即可覆盖更新，已同步的记录不受影响。</li>
<li>更新前如果还有内容没同步完，先等它同步完再更新。</li>
</ul>
<h2>关于</h2>
<p><a href="/privacy">隐私政策</a> · <a href="/terms">用户条款</a></p>`);
}

export function createApp({ databasePath = './data/sidequest-v2.sqlite', mediaDirectory, now = () => new Date(), allowedOrigins = [],
  authLimit = 30, authWindowMs = 15 * 60 * 1000, maxConcurrentAuth = 4, mediaProcessor, mediaTools, accountMediaLimit, apkDirectory, oss: ossOption } = {}) {
  const processor = mediaProcessor ?? new FfmpegProcessor(mediaTools);
  const releaseLock = acquireDataLock(databasePath);
  let db;
  try { db = openDatabase(databasePath); } catch (error) { releaseLock(); throw error; }
  let media;
  try { media = new MediaStore({ db, root: mediaDirectory ?? join(dirname(resolve(databasePath)), 'media'), now, processor, accountLimit: accountMediaLimit }); }
  catch (error) { db.close(); releaseLock(); throw error; }

  // 客户端静默上报：只落盘诊断日志，绝不阻塞或打扰用户（客户端见 lib/silent_reporter.dart）。
  const diagnosticsPath = join(dirname(resolve(databasePath)), 'diagnostics.jsonl');
  const MAX_DIAGNOSTICS_BYTES = 4 * 1024 * 1024;
  async function recordDiagnostic(request, body) {
    try {
      let accountId = null;
      try { accountId = authenticate(request, true)?.id ?? null; } catch { accountId = null; }
      const clip = (value, max) => (typeof value === 'string' ? value.slice(0, max) : null);
      const info = await stat(diagnosticsPath).catch(() => null);
      if (info && info.size > MAX_DIAGNOSTICS_BYTES) return;
      await appendFile(diagnosticsPath, `${JSON.stringify({ at: now().toISOString(), scope: clip(body?.scope, 80), type: clip(body?.type, 120), message: clip(body?.message, 500), client: clip(body?.client, 80), accountId })}\n`);
    } catch { /* 上报失败不影响任何流程 */ }
  }
  // 下载统计：落地页访问与下载请求写 <数据目录>/downloads.jsonl（后台「下载统计」聚合展示）。
  // 只统计下载链接的公开访问；支线 App 不采集任何行为数据。
  const downloadsPath = join(dirname(resolve(databasePath)), 'downloads.jsonl');
  const MAX_DOWNLOADS_BYTES = 4 * 1024 * 1024;
  async function recordDownloadEvent(request, type, extra = {}) {
    try {
      const info = await stat(downloadsPath).catch(() => null);
      if (info && info.size > MAX_DOWNLOADS_BYTES) return;
      const clip = (value, max) => (typeof value === 'string' ? value.slice(0, max) : null);
      const forwarded = String(request.headers['x-forwarded-for'] ?? '').split(',')[0].trim();
      const ip = String(request.headers['x-real-ip'] ?? '').trim() || forwarded || String(request.socket.remoteAddress ?? '');
      const userAgent = clip(request.headers['user-agent'] ?? '', 220) ?? '';
      const referer = clip(request.headers.referer ?? null, 220);
      const source = /MicroMessenger/i.test(userAgent) ? 'wechat'
        : /QQ\//i.test(userAgent) ? 'qq'
        : userAgent ? 'browser' : 'other';
      await appendFile(downloadsPath, `${JSON.stringify({ at: now().toISOString(), type, ip: clip(ip, 64), source, referer, ua: userAgent, ...extra })}\n`);
    } catch { /* 统计失败不影响任何下载流程 */ }
  }
  // 分发：把新构建的 APK 放进此目录，/download 始终指向最新的一个（按修改时间）。
  const apkRoot = apkDirectory ?? join(dirname(resolve(databasePath)), 'apk');
  async function latestApk() {
    try {
      const entries = await readdir(apkRoot, { withFileTypes: true });
      let best = null;
      for (const entry of entries) {
        if (!entry.isFile() || !entry.name.toLowerCase().endsWith('.apk')) continue;
        const filePath = join(apkRoot, entry.name);
        const info = await stat(filePath);
        if (!best || info.mtimeMs > best.mtimeMs) best = { path: filePath, name: entry.name, size: info.size, mtimeMs: info.mtimeMs };
      }
      return best;
    } catch { return null; }
  }
  // 分发加速：最新 APK 自动同步到阿里云 OSS，/download/latest 302 到签名直链；
  // OSS 不可用（未配置 / 上传失败 / 探测超时）时无感回退服务器带宽，老链接始终有效。
  const oss = (() => {
    try {
      if (ossOption === null) return null;
      const config = ossOption?.config !== undefined ? ossOption.config : resolveOssConfig(process.env);
      return config ? new OssClient(config, { fetchImpl: ossOption?.fetchImpl ?? fetch, now: () => now().getTime() }) : null;
    } catch (error) {
      console.warn('[oss] 初始化失败，已禁用 OSS：', String(error?.message ?? error));
      return null;
    }
  })();
  const OSS_RECHECK_MS = 10 * 60 * 1000;
  const OSS_RETRY_COOLDOWN_MS = 5 * 60 * 1000;
  const APK_MIME = 'application/vnd.android.package-archive';
  const ossStates = new Map();
  const ossStateFor = (path) => {
    let state = ossStates.get(path);
    if (!state) { state = { ready: false, verifiedAt: 0, cooldownUntil: 0, uploading: false }; ossStates.set(path, state); }
    return state;
  };
  async function ossUploadApk(apk, state) {
    if (state.uploading) return;
    state.uploading = true;
    const key = oss.objectKey(apk.name);
    try {
      await oss.upload(key, apk.path, { contentType: APK_MIME, fileName: apk.name });
      const probe = await oss.probe(key);
      if (!probe.ok || probe.size !== apk.size) throw new Error(`上传后核验未通过（${probe.ok ? `大小 ${probe.size}` : '无响应'}）`);
      state.ready = true; state.verifiedAt = now().getTime(); state.cooldownUntil = 0;
      console.log(`[oss] 已同步 ${apk.name}（${apk.size} 字节）→ ${key}`);
    } catch (error) {
      state.ready = false; state.cooldownUntil = now().getTime() + OSS_RETRY_COOLDOWN_MS;
      console.warn('[oss] 同步失败，本次继续用服务器带宽：', String(error?.message ?? error));
    } finally { state.uploading = false; }
  }
  async function ossEnsureUploaded(apk) {
    if (!oss) return false;
    const state = ossStateFor(apk.path);
    if (state.ready) return true;
    if (state.uploading) return false;
    try {
      const probe = await oss.probe(oss.objectKey(apk.name));
      if (probe.ok && probe.size === apk.size) {
        state.ready = true; state.verifiedAt = now().getTime();
        return true;
      }
    } catch { /* 探测失败落回上传尝试（上传失败会进冷却） */ }
    void ossUploadApk(apk, state);
    return false;
  }
  async function ossUrlFor(apk, method) {
    if (!oss) return null;
    const state = ossStateFor(apk.path);
    const stamp = now().getTime();
    if (state.ready && stamp - state.verifiedAt < OSS_RECHECK_MS) return oss.signedUrl(oss.objectKey(apk.name), method);
    if (stamp < state.cooldownUntil) return null;
    try {
      const probe = await oss.probe(oss.objectKey(apk.name));
      if (probe.ok && probe.size === apk.size) {
        state.ready = true; state.verifiedAt = stamp;
        return oss.signedUrl(oss.objectKey(apk.name), method);
      }
      state.ready = false;
      if (!state.uploading) void ossUploadApk(apk, state);
      return null;
    } catch (error) {
      state.ready = false; state.cooldownUntil = stamp + OSS_RETRY_COOLDOWN_MS;
      console.warn('[oss] 探测失败，回退服务器带宽：', String(error?.message ?? error));
      return null;
    }
  }
  const tx = (fn) => transaction(db, fn);
  const authBuckets = new Map();
  let activeAuth = 0;

  function rateLimit(request, nickname) {
    const timestamp = now().getTime();
    for (const [key, bucket] of authBuckets) if (bucket.reset <= timestamp) authBuckets.delete(key);
    for (const key of [`ip:${request.socket.remoteAddress ?? 'unknown'}`, `name:${nickname}`]) {
      let bucket = authBuckets.get(key);
      if (!bucket) { assert(authBuckets.size < 10000, 429, '请求较多，请稍后再试'); bucket = { count: 0, reset: timestamp + authWindowMs }; authBuckets.set(key, bucket); }
      assert(bucket.count < authLimit, 429, '登录或注册尝试过多，请稍后再试'); bucket.count++;
    }
  }
  async function passwordKey(password, salt) {
    assert(activeAuth < maxConcurrentAuth, 429, '正在处理其他登录请求，请稍后再试');
    activeAuth++;
    try { return await deriveKey(password, salt, 64, passwordOptions); } finally { activeAuth--; }
  }
  function session(userId, client = '') {
    const token = randomBytes(32).toString('base64url');
    db.prepare('DELETE FROM sessions WHERE expires_at<=?').run(now().getTime());
    db.prepare('INSERT INTO sessions(token_hash,user_id,expires_at,client) VALUES(?,?,?,?)').run(digest(token), userId, now().getTime() + SESSION_MS, client);
    return token;
  }
  function authenticate(request, optional = false) {
    const header = request.headers.authorization;
    let token, viaCookie = false;
    if (header === undefined) {
      // 无 Bearer 时回退到浏览器 Cookie（网页版）；两者都无才按未登录处理。
      token = cookieToken(request);
      viaCookie = token !== null;
      if (token === null && optional) return null;
      if (token === null) throw new HttpError(401, '请先登录后再继续');
    } else {
      assert(typeof header === 'string' && /^Bearer [A-Za-z0-9_-]{43}$/.test(header), 401, '请先登录后再继续');
      token = header.slice(7);
    }
    const hash = digest(token);
    const found = db.prepare('SELECT user_id FROM sessions WHERE token_hash=? AND expires_at>?').get(hash, now().getTime());
    assert(found, 401, '登录已失效，请重新登录；本机待上传记录仍会保留');
    // 滑动续期：活跃使用自动延长有效期，避免"每天在用却被固定到期踢下线"。
    const renewed = db.prepare('UPDATE sessions SET expires_at=? WHERE token_hash=? AND expires_at<?')
      .run(now().getTime() + SESSION_MS, hash, now().getTime() + SESSION_MS - SESSION_RENEW_AFTER_MS).changes > 0;
    // Cookie 会话续期时同步刷新浏览器端有效期；应用走 Bearer，不受影响。
    if (viaCookie && renewed) request.sqCookieRefresh = token;
    return { id: found.user_id, hash };
  }
  const stateRow = (id) => db.prepare('SELECT * FROM quest_state WHERE user_id=?').get(id);
  function recommend(userId, state) {
    const user = db.prepare('SELECT preferences FROM users WHERE id=?').get(userId);
    return recommendQuest({ preferences: JSON.parse(user.preferences), history: JSON.parse(state.recommendation_history), currentId: state.recommended_quest_id });
  }
  function advance(userId, state) {
    const id = recommend(userId, state);
    db.prepare('UPDATE quest_state SET recommended_quest_id=?,recommendation_history=?,can_request_next=0,progress_revision=progress_revision+1 WHERE user_id=?')
      .run(id, JSON.stringify(appendRecommendation(JSON.parse(state.recommendation_history), id)), userId);
    return id;
  }
  function syncDay(userId) {
    const state = stateRow(userId), day = calendarDay(now());
    if (state.day === day) return;
    if (!state.active_quest_id && state.can_request_next) advance(userId, state);
    db.prepare('UPDATE quest_state SET day=? WHERE user_id=?').run(day, userId);
  }
  function snapshot(userId = null, { refreshDay = true } = {}) {
    const day = calendarDay(now());
    if (!userId) return { profile: null, activeQuestId: null, recommendedQuestId: firstEnabledId(), replacedOn: null, draft: '', draftAttachments: [], day,
      canRequestNext: false, progressRevision: 0, recommendationHistory: [], entryCount: 0 };
    if (refreshDay) syncDay(userId);
    const user = db.prepare('SELECT id,nickname,role,preferences FROM users WHERE id=?').get(userId), state = stateRow(userId);
    assert(user && state, 401, '账号已不可用');
    return { profile: { ...user, preferences: JSON.parse(user.preferences) }, activeQuestId: state.active_quest_id, recommendedQuestId: state.recommended_quest_id,
      replacedOn: state.replaced_on, draft: state.draft, draftAttachments: media.attachments(userId, 'draft', userId), day: state.day,
      canRequestNext: state.can_request_next === 1, progressRevision: state.progress_revision, recommendationHistory: JSON.parse(state.recommendation_history),
      entryCount: db.prepare('SELECT count(*) AS count FROM entries WHERE user_id=?').get(userId).count };
  }
  function entryJson(userId, row) {
    return { id: row.id, questId: row.quest_id, questTitle: row.quest_title, text: row.text, createdAt: row.created_at, updatedAt: row.updated_at,
      revision: row.revision, attachments: media.attachments(userId, 'entry', row.id) };
  }
  function entry(userId, id) {
    const row = db.prepare('SELECT * FROM entries WHERE user_id=? AND id=?').get(userId, id);
    assert(row, 404, '记录不存在');
    return entryJson(userId, row);
  }
  function listEntries(userId, params) {
    assert([...params.keys()].every((key) => ['q','cursor','limit'].includes(key)) && [...params.keys()].every((key) => params.getAll(key).length === 1), 400, '查询参数无效');
    const query = (params.get('q') ?? '').trim();
    assert(textLength(query) <= 100, 400, '搜索内容最多 100 字');
    const limit = Number(params.get('limit') ?? 20);
    assert(Number.isInteger(limit) && limit >= 1 && limit <= 100, 400, '分页大小无效');
    let cursor;
    if (params.get('cursor')) {
      try { cursor = JSON.parse(Buffer.from(params.get('cursor'), 'base64url').toString()); } catch { throw new HttpError(400, '分页标识无效'); }
      assert(cursor?.query === query && typeof cursor.at === 'string' && typeof cursor.id === 'string', 400, '分页标识无效');
      dateInput(cursor.at); identifier(cursor.id);
    }
    const search = '%'+query.replace(/[\\%_]/g, '\\$&')+'%';
    const where = "user_id=? AND (text LIKE ? ESCAPE '\\' OR quest_title LIKE ? ESCAPE '\\')";
    const total = db.prepare(`SELECT count(*) AS count FROM entries WHERE ${where}`).get(userId, search, search).count;
    const rows = db.prepare(`SELECT * FROM entries WHERE ${where} ${cursor ? 'AND (created_at<? OR (created_at=? AND id<?))' : ''} ORDER BY created_at DESC,id DESC LIMIT ?`)
      .all(userId, search, search, ...(cursor ? [cursor.at,cursor.at,cursor.id] : []), limit + 1);
    const more = rows.length > limit;
    if (more) rows.pop();
    const last = rows.at(-1);
    return { entries: rows.map((row) => entryJson(userId, row)), nextCursor: more ? Buffer.from(JSON.stringify({ at: last.created_at, id: last.id, query })).toString('base64url') : null, total };
  }
  function createEntry(userId, payload) {
    fields(payload, ['clientRecordId','questId','text','mediaIds','createdAt']);
    const id = identifier(payload.clientRecordId, '记录标识'), questId = questInput(payload.questId), text = textInput(payload.text, true), createdAt = dateInput(payload.createdAt);
    const ids = payload.mediaIds ?? [];
    assert(Array.isArray(ids), 400, '附件列表无效');
    const creationHash = hashObject({ id, questId, text, createdAt, mediaIds: ids });
    const tombstone = db.prepare('SELECT * FROM entry_tombstones WHERE user_id=? AND id=?').get(userId, id);
    if (tombstone) { assert(!tombstone.creation_hash || tombstone.creation_hash === creationHash, 409, '记录标识已用于其他内容'); return { id, deleted: true, existing: true }; }
    const existing = db.prepare('SELECT * FROM entries WHERE user_id=? AND id=?').get(userId,id);
    if (existing) { assert(existing.creation_hash === creationHash, 409, '记录标识已用于其他内容'); return { id, existing: true }; }
    media.validate(userId, ids);
    db.prepare('INSERT INTO entries(id,user_id,quest_id,quest_title,text,created_at,updated_at,revision,creation_hash) VALUES(?,?,?,?,?,?,?,1,?)')
      .run(id, userId, questId, questTitle(questId), text, createdAt, createdAt, creationHash);
    media.bind(userId, 'entry', id, ids);
    return { id, existing: false };
  }
  function progressAction(userId, type, payload) {
    const state = stateRow(userId);
    if (type === 'claim') {
      fields(payload, ['questId']); const quest = questInput(payload.questId);
      assert(!state.can_request_next && quest === state.recommended_quest_id, 409, '当前推荐已改变，请刷新后再开始');
      if (state.active_quest_id === quest) return false;
      assert(!state.active_quest_id, 409, '另一个活动正在进行中');
      db.prepare('UPDATE quest_state SET active_quest_id=?,progress_revision=progress_revision+1 WHERE user_id=?').run(quest, userId);
    } else if (type === 'stop') {
      fields(payload, []); if (!state.active_quest_id) return false;
      db.prepare('UPDATE quest_state SET active_quest_id=NULL,progress_revision=progress_revision+1 WHERE user_id=?').run(userId);
    } else if (type === 'draft') {
      fields(payload, ['questId','text','mediaIds']); const quest = questInput(payload.questId), text = textInput(payload.text, false);
      assert(state.active_quest_id === quest, 409, '活动已改变，草稿尚未覆盖云端内容');
      media.bind(userId, 'draft', userId, payload.mediaIds ?? []);
      db.prepare('UPDATE quest_state SET draft=?,progress_revision=progress_revision+1 WHERE user_id=?').run(text, userId);
    } else if (type === 'complete') {
      assert(state.active_quest_id === payload.questId, 409, '活动已改变，记录尚未保存');
      media.detach(userId, 'draft', userId);
      db.prepare("UPDATE quest_state SET active_quest_id=NULL,draft='',can_request_next=1,progress_revision=progress_revision+1 WHERE user_id=?").run(userId);
    } else if (type === 'next') {
      fields(payload, []); assert(!state.active_quest_id && state.can_request_next, 409, '完成当前活动后，可以继续探索'); advance(userId, state);
    } else throw new HttpError(400, '同步操作无效');
    return true;
  }
  function synchronize(userId, body) {
    fields(body, ['branchId','baseRevision','commands']); const branchId = identifier(body.branchId, '同步分支');
    assert(Number.isSafeInteger(body.baseRevision) && body.baseRevision >= 0, 400, '同步版本无效');
    assert(Array.isArray(body.commands) && body.commands.length >= 1 && body.commands.length <= 10, 400, '每次同步需包含 1–10 项操作');
    return tx(() => {
      syncDay(userId);
      let branch = db.prepare('SELECT * FROM sync_branches WHERE user_id=? AND id=?').get(userId, branchId);
      const revision = stateRow(userId).progress_revision;
      if (!branch) {
        db.prepare('INSERT INTO sync_branches(user_id,id,base_revision,last_revision,mode) VALUES(?,?,?,?,?)').run(userId, branchId, body.baseRevision, body.baseRevision, body.baseRevision === revision ? 'active' : 'records_only');
        branch = db.prepare('SELECT * FROM sync_branches WHERE user_id=? AND id=?').get(userId, branchId);
      } else assert(branch.base_revision === body.baseRevision, 409, '同步分支的起始版本不能改变');
      if (branch.mode === 'active' && branch.last_revision !== revision) { db.prepare("UPDATE sync_branches SET mode='records_only' WHERE user_id=? AND id=?").run(userId, branchId); branch.mode = 'records_only'; }
      const receipts = [], savedIds = new Set();
      for (const command of body.commands) {
        assert(command && typeof command === 'object' && !Array.isArray(command), 400, '同步操作无效'); fields(command, ['commandId','type','payload']);
        const commandId = identifier(command.commandId, '操作标识');
        assert(['claim','stop','draft','complete','next'].includes(command.type) && command.payload && typeof command.payload === 'object' && !Array.isArray(command.payload), 400, '同步操作无效');
        const requestHash = hashObject({ branchId, type: command.type, payload: command.payload });
        const previous = db.prepare('SELECT * FROM command_receipts WHERE user_id=? AND id=?').get(userId, commandId);
        if (previous) { assert(previous.request_hash === requestHash, 409, '操作标识已用于其他内容'); const receipt = JSON.parse(previous.receipt); receipts.push(receipt); if (receipt.entryId) savedIds.add(receipt.entryId); continue; }
        let result;
        if (command.type === 'complete') result = createEntry(userId, command.payload);
        else if (command.type === 'draft') { fields(command.payload, ['questId','text','mediaIds']); questInput(command.payload.questId); textInput(command.payload.text, false); }
        else if (command.type === 'claim') { fields(command.payload, ['questId']); questInput(command.payload.questId); }
        else fields(command.payload, []);
        const applied = branch.mode === 'active' && !result?.existing ? progressAction(userId, command.type, command.payload) : false;
        const receipt = { commandId, ...(result ? { entryId: result.id } : {}), progressApplied: applied };
        db.prepare('INSERT INTO command_receipts(user_id,id,branch_id,request_hash,receipt) VALUES(?,?,?,?,?)').run(userId, commandId, branchId, requestHash, JSON.stringify(receipt));
        receipts.push(receipt); if (result && !result.deleted) savedIds.add(result.id);
      }
      if (branch.mode === 'active') db.prepare('UPDATE sync_branches SET last_revision=? WHERE user_id=? AND id=?').run(stateRow(userId).progress_revision, userId, branchId);
      return { state: snapshot(userId), branchMode: branch.mode, receipts,
        entries: [...savedIds].map((id) => db.prepare('SELECT * FROM entries WHERE user_id=? AND id=?').get(userId, id)).filter(Boolean).map((row) => entryJson(userId, row)) };
    });
  }
  function syncStatus(userId, body) {
    fields(body, ['branchId','baseRevision','commands']);
    const branchId = identifier(body.branchId, '同步分支');
    assert(Number.isSafeInteger(body.baseRevision) && body.baseRevision >= 0, 400, '同步版本无效');
    assert(Array.isArray(body.commands) && body.commands.length >= 1 && body.commands.length <= 10, 400, '每次查询需包含 1–10 项操作');
    const branch = db.prepare('SELECT * FROM sync_branches WHERE user_id=? AND id=?').get(userId, branchId);
    if (branch) assert(branch.base_revision === body.baseRevision, 409, '同步分支的起始版本不能改变');
    // This endpoint is intentionally read-only: even date rollover is deferred
    // to normal state/sync operations, so recovery queries never advance work.
    const state = snapshot(userId, { refreshDay: false });
    const branchMode = branch
      ? branch.mode === 'records_only' || branch.last_revision !== state.progressRevision ? 'records_only' : 'active'
      : body.baseRevision === state.progressRevision ? 'active' : 'records_only';
    const receipts = [], missingCommandIds = [], entryIds = new Set();
    for (const command of body.commands) {
      assert(command && typeof command === 'object' && !Array.isArray(command), 400, '同步操作无效');
      fields(command, ['commandId','type','payload']);
      const commandId = identifier(command.commandId, '操作标识');
      assert(['claim','stop','draft','complete','next'].includes(command.type) && command.payload && typeof command.payload === 'object' && !Array.isArray(command.payload), 400, '同步操作无效');
      const previous = db.prepare('SELECT * FROM command_receipts WHERE user_id=? AND id=?').get(userId, commandId);
      if (!previous) { missingCommandIds.push(commandId); continue; }
      const requestHash = hashObject({ branchId, type: command.type, payload: command.payload });
      assert(previous.request_hash === requestHash, 409, '操作标识已用于其他内容');
      const receipt = JSON.parse(previous.receipt); receipts.push(receipt);
      if (receipt.entryId) entryIds.add(receipt.entryId);
    }
    return { state, branchMode, receipts, missingCommandIds,
      entries: [...entryIds].map(id => db.prepare('SELECT * FROM entries WHERE user_id=? AND id=?').get(userId,id)).filter(Boolean).map(row => entryJson(userId,row)) };
  }
  function mutateEntry(userId, action, body) {
    fields(body, action === 'update-entry' ? ['id','text','mediaIds','expectedRevision','requestId'] : ['id','requestId']);
    const id = identifier(body.id), requestId = identifier(body.requestId, '请求标识'), hash = hashObject({ action, ...body });
    return tx(() => {
      const previous = db.prepare('SELECT * FROM mutation_receipts WHERE user_id=? AND id=?').get(userId, requestId);
      if (previous) { assert(previous.request_hash === hash, 409, '请求标识已用于其他内容'); return { ...JSON.parse(previous.result), state: snapshot(userId) }; }
      const row = db.prepare('SELECT * FROM entries WHERE user_id=? AND id=?').get(userId, id); assert(row, 404, '记录不存在');
      let result = {};
      if (action === 'update-entry') {
        assert(Number.isSafeInteger(body.expectedRevision) && body.expectedRevision === row.revision, 409, '这条记录已在其他设备修改，请重新打开后编辑');
        const text = textInput(body.text, true); media.bind(userId, 'entry', id, body.mediaIds ?? []);
        db.prepare('UPDATE entries SET text=?,updated_at=?,revision=revision+1 WHERE user_id=? AND id=?').run(text, now().toISOString(), userId, id); result.entry = entry(userId, id);
      } else {
        db.prepare('INSERT OR IGNORE INTO entry_tombstones(user_id,id,creation_hash,deleted_at) VALUES(?,?,?,?)').run(userId, id, row.creation_hash, now().toISOString());
        media.detach(userId, 'entry', id); db.prepare('DELETE FROM entries WHERE user_id=? AND id=?').run(userId, id);
      }
      db.prepare('INSERT INTO mutation_receipts(user_id,id,request_hash,result) VALUES(?,?,?,?)').run(userId, requestId, hash, JSON.stringify(result));
      return { ...result, state: snapshot(userId) };
    });
  }
  function respond(response, status, body, origin) {
    const request = response.req;
    if (request) {
      if (request.sqCookieClear) response.setHeader('Set-Cookie', sessionCookie('', 0));
      else if (request.sqCookieNew) response.setHeader('Set-Cookie', sessionCookie(request.sqCookieNew));
      else if (request.sqCookieRefresh) response.setHeader('Set-Cookie', sessionCookie(request.sqCookieRefresh));
    }
    response.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', 'Content-Security-Policy': "default-src 'none'",
      ...(origin ? { 'Access-Control-Allow-Origin': origin, Vary: 'Origin' } : {}), ...(status === 429 ? { 'Retry-After': '60' } : {}), ...(status === 413 ? { Connection: 'close' } : {}) }); response.end(JSON.stringify(body));
  }
  const server = createServer(async (request, response) => {
    let allowedOrigin;
    try {
      const origin = request.headers.origin; assert(!origin || allowedOrigins.includes(origin), 403, '此来源未获允许'); allowedOrigin = origin;
      const { pathname, searchParams } = new URL(request.url, 'http://localhost');
      if (request.method === 'OPTIONS') {
        response.writeHead(204, { ...(allowedOrigin ? { 'Access-Control-Allow-Origin': allowedOrigin, Vary: 'Origin' } : {}), 'Access-Control-Allow-Methods': 'GET,HEAD,POST,PUT,DELETE,OPTIONS', 'Access-Control-Allow-Headers': 'Authorization,Content-Type,X-Sidequest-Protocol,X-Sidequest-Client,Range', 'Access-Control-Max-Age': '600' }); response.end(); return;
      }
      if (request.method === 'GET' && pathname === '/api/health') { respond(response, 200, { ok: true, version: '0.2.0', protocolVersion: 2, mode: 'private-multimedia', timezone: 'Asia/Shanghai', mediaReady: true }, allowedOrigin); return; }
      if (request.method === 'POST' && pathname === '/api/diagnostics') {
        try { await recordDiagnostic(request, await readJson(request)); } catch { /* 静默：诊断永不影响客户端 */ }
        response.writeHead(204, { ...(allowedOrigin ? { 'Access-Control-Allow-Origin': allowedOrigin, Vary: 'Origin' } : {}) }); response.end(); return;
      }
      if (request.method === 'POST' && pathname === '/internal/oss-warm') {
        // 仅限本机（后台「版本分发」上传完成后调用）：把最新 APK 预热到 OSS。
        // 注意：经 nginx 进来的请求 socket 也是 127.0.0.1，必须同时看 X-Real-IP
        // （nginx 会覆写它；直连本机时不带该头）。
        const remote = request.socket.remoteAddress ?? '';
        const proxyIp = String(request.headers['x-real-ip'] ?? '').trim();
        const local = (value) => ['127.0.0.1', '::1', '::ffff:127.0.0.1', ''].includes(value);
        if (!local(remote) || !local(proxyIp)) { respond(response, 404, { error: '接口不存在' }, allowedOrigin); return; }
        const apk = await latestApk();
        if (!oss || !apk) { respond(response, 200, { ossReady: false }, allowedOrigin); return; }
        void ossEnsureUploaded(apk);
        respond(response, 202, { ossReady: true, apk: apk.name }, allowedOrigin); return;
      }
      if ((request.method === 'GET' || request.method === 'HEAD') && pathname === '/') {
        response.writeHead(302, { Location: '/download', ...(allowedOrigin ? { 'Access-Control-Allow-Origin': allowedOrigin, Vary: 'Origin' } : {}) }); response.end(); return;
      }
      if ((request.method === 'GET' || request.method === 'HEAD') && (pathname === '/download' || pathname === '/download/')) {
        if (request.method === 'GET') void recordDownloadEvent(request, 'page');
        respondHtml(response, 200, downloadPage(await latestApk()), allowedOrigin); return;
      }
      if ((request.method === 'GET' || request.method === 'HEAD') && pathname === '/download/latest') {
        const apk = await latestApk();
        if (!apk) { respond(response, 404, { error: '暂时还没有可下载的版本' }, allowedOrigin); return; }
        let ossUrl = null;
        try { ossUrl = await ossUrlFor(apk, request.method === 'HEAD' ? 'HEAD' : 'GET'); }
        catch (error) { console.warn('[oss] 下载跳转失败，回退服务器带宽：', String(error?.message ?? error)); }
        if (request.method === 'GET') void recordDownloadEvent(request, 'apk', { via: ossUrl ? 'oss' : 'server', apk: apk.name });
        if (ossUrl) {
          response.writeHead(302, { Location: ossUrl, 'Cache-Control': 'no-store', ...(allowedOrigin ? { 'Access-Control-Allow-Origin': allowedOrigin, Vary: 'Origin' } : {}) });
          response.end(); return;
        }
        response.writeHead(200, { 'Content-Type': 'application/vnd.android.package-archive', 'Content-Length': apk.size, 'Content-Disposition': `attachment; filename="sidequest.apk"; filename*=UTF-8''${encodeURIComponent(apk.name)}`, 'Cache-Control': 'no-store', ...(allowedOrigin ? { 'Access-Control-Allow-Origin': allowedOrigin, Vary: 'Origin' } : {}) });
        createReadStream(apk.path).pipe(response); return;
      }
      if ((request.method === 'GET' || request.method === 'HEAD') && (pathname === '/privacy' || pathname === '/terms')) {
        const doc = pathname === '/privacy'
          ? { file: 'privacy.md', title: '支线 · 隐私政策' }
          : { file: 'terms.md', title: '支线 · 用户条款' };
        let html;
        try {
          const markdown = await readFile(join(serverDir, 'legal', doc.file), 'utf8');
          html = pageShell(doc.title, `${renderMarkdown(markdown)}\n<p class="meta"><a href="/download">← 返回下载页</a></p>`);
        } catch { html = pageShell(doc.title, '<h1>暂时打不开</h1><p>请稍后再试。</p>'); }
        respondHtml(response, 200, html, allowedOrigin); return;
      }
      assert(request.headers['x-sidequest-protocol'] === '2', 426, '客户端与服务版本不匹配，请升级至协议 2');
      assert(pathname === '/api/entries' || searchParams.size === 0, 400, '此接口不接受查询参数');
      if (request.method === 'GET' && pathname === '/api/state') { respond(response, 200, { state: snapshot(authenticate(request, true)?.id) }, allowedOrigin); return; }
      if (request.method === 'GET' && pathname === '/api/entries') { respond(response, 200, listEntries(authenticate(request).id, searchParams), allowedOrigin); return; }
      const entryMatch = /^\/api\/entries\/([A-Za-z0-9_-]{1,128})$/.exec(pathname);
      if (request.method === 'GET' && entryMatch) { respond(response, 200, { entry: entry(authenticate(request).id, entryMatch[1]) }, allowedOrigin); return; }
      const uploadMatch = /^\/api\/uploads\/([a-f0-9-]{36})(\/content)?$/.exec(pathname);
      if (uploadMatch) {
        const auth = authenticate(request), id = uploadMatch[1];
        if (request.method === 'PUT' && uploadMatch[2]) { const uploaded = await media.upload(auth.id, id, request); respond(response, 200, { media: uploaded }, allowedOrigin); return; }
        if (request.method === 'GET' && !uploadMatch[2]) { const row = media.get(auth.id, id); respond(response, 200, { media: mediaJson(row), ...(row.error ? { error: row.error } : {}) }, allowedOrigin); return; }
        if (request.method === 'DELETE' && !uploadMatch[2]) { media.cancel(auth.id, id); respond(response, 200, { ok: true }, allowedOrigin); return; }
      }
      const mediaMatch = /^\/api\/media\/([a-f0-9-]{36})\/(content|thumbnail)$/.exec(pathname);
      if (mediaMatch && ['GET','HEAD'].includes(request.method)) { await media.serve(authenticate(request).id, mediaMatch[1], mediaMatch[2] === 'thumbnail', request, response, allowedOrigin); return; }
      const action = pathname.startsWith('/api/') ? pathname.slice(5) : '';
      assert(request.method === 'POST' && ['register','login','logout','preferences','replace','delete-account','sync','sync-status','update-entry','delete-entry','uploads','claim','draft','complete','stop','next'].includes(action), 404, '接口不存在');
      const auth = ['register','login'].includes(action) ? null : authenticate(request);
      const body = await readJson(request);
      if (action === 'register' || action === 'login') {
        fields(body, action === 'register' ? ['nickname','password','role','preferences'] : ['nickname','password']);
        const nickname = nicknameInput(body.nickname), password = passwordInput(body.password); rateLimit(request, nickname.normalized);
        if (action === 'register') {
          const profile = profileInput(body), salt = randomBytes(16).toString('hex'), hash = (await passwordKey(password, salt)).toString('hex');
          try {
            const result = tx(() => {
              const id = randomUUID(), recommended = recommendQuest({ preferences: profile.preferences });
              db.prepare('INSERT INTO users(id,nickname,normalized_nickname,password_salt,password_hash,role,preferences) VALUES(?,?,?,?,?,?,?)').run(id, nickname.display, nickname.normalized, salt, hash, profile.role, JSON.stringify(profile.preferences));
              db.prepare('INSERT INTO quest_state(user_id,recommended_quest_id,day,recommendation_history) VALUES(?,?,?,?)').run(id, recommended, calendarDay(now()), JSON.stringify([recommended]));
              return { token: session(id, clientTagOf(request)), state: snapshot(id) };
            });
            request.sqCookieNew = result.token;
            respond(response, 201, result, allowedOrigin); return;
          } catch (error) { if (String(error.message).includes('UNIQUE constraint failed: users.normalized_nickname')) throw new HttpError(409, '这个昵称已被使用，请换一个'); throw error; }
        }
        const user = db.prepare('SELECT * FROM users WHERE normalized_nickname=?').get(nickname.normalized);
        const key = await passwordKey(password, user?.password_salt ?? '00000000000000000000000000000000');
        assert(timingSafeEqual(key, user ? Buffer.from(user.password_hash, 'hex') : Buffer.alloc(64)) && user && db.prepare('SELECT id FROM users WHERE id=?').get(user.id), 401, '昵称或密码不正确');
        const loginResult = tx(() => ({ token: session(user.id, clientTagOf(request)), state: snapshot(user.id) }));
        request.sqCookieNew = loginResult.token;
        respond(response, 200, loginResult, allowedOrigin); return;
      }
      if (action === 'uploads') { respond(response, 201, { media: media.reserve(auth.id, body) }, allowedOrigin); return; }
      if (action === 'sync') { const result = synchronize(auth.id, body); media.cleanup(); respond(response, 200, result, allowedOrigin); return; }
      if (action === 'sync-status') { respond(response, 200, syncStatus(auth.id, body), allowedOrigin); return; }
      if (action === 'update-entry' || action === 'delete-entry') { const result = mutateEntry(auth.id, action, body); media.cleanup(); respond(response, 200, result, allowedOrigin); return; }
      if (action === 'delete-account') {
        fields(body, ['password']); const password = passwordInput(body.password), user = db.prepare('SELECT * FROM users WHERE id=?').get(auth.id);
        rateLimit(request, user.normalized_nickname); const key = await passwordKey(password, user.password_salt);
        assert(timingSafeEqual(key, Buffer.from(user.password_hash, 'hex')), 401, '密码不正确，账号未删除'); authenticate(request);
        tx(() => { media.deleteAccount(auth.id); db.prepare('DELETE FROM users WHERE id=?').run(auth.id); }); media.cleanup();
        request.sqCookieClear = true;
        respond(response, 200, { state: snapshot() }, allowedOrigin); return;
      }
      const result = tx(() => {
        syncDay(auth.id); const state = stateRow(auth.id);
        if (action === 'logout') { fields(body, []); db.prepare('DELETE FROM sessions WHERE token_hash=?').run(auth.hash); return { state: snapshot() }; }
        if (action === 'preferences') {
          fields(body, ['role','preferences']); const profile = profileInput(body);
          db.prepare('UPDATE users SET role=?,preferences=? WHERE id=?').run(profile.role, JSON.stringify(profile.preferences), auth.id);
          db.prepare('UPDATE quest_state SET progress_revision=progress_revision+1 WHERE user_id=?').run(auth.id);
        } else if (action === 'replace') {
          fields(body, []); assert(!state.can_request_next, 409, '这次已完成，可以从首页继续探索');
          assert(state.replaced_on !== calendarDay(now()), 409, '今天已经更换过一次，也可以先放一放');
          const next = advance(auth.id, state); media.detach(auth.id, 'draft', auth.id);
          db.prepare("UPDATE quest_state SET active_quest_id=?,replaced_on=?,draft='' WHERE user_id=?").run(state.active_quest_id ? next : null, calendarDay(now()), auth.id);
        } else if (action === 'complete') {
          fields(body, ['text','mediaIds','clientRecordId','createdAt','questId']);
          const payload = { text: body.text, mediaIds: body.mediaIds ?? [], clientRecordId: body.clientRecordId ?? randomUUID(), createdAt: body.createdAt ?? now().toISOString(), questId: body.questId ?? state.active_quest_id };
          const created = createEntry(auth.id, payload); if (!created.existing) progressAction(auth.id, 'complete', payload);
          return { state: snapshot(auth.id), ...(created.deleted ? {} : { entry: entry(auth.id, created.id) }) };
        } else {
          let payload = body;
          if (action === 'claim') { fields(body, ['questId']); payload = { questId: body.questId ?? state.recommended_quest_id }; }
          if (action === 'draft') { fields(body, ['questId','text','mediaIds']); payload = { questId: body.questId ?? state.active_quest_id, text: body.text, mediaIds: body.mediaIds ?? [] }; }
          progressAction(auth.id, action, payload);
        }
        return { state: snapshot(auth.id) };
      }); media.cleanup();
      if (action === 'logout') request.sqCookieClear = true;
      respond(response, 200, result, allowedOrigin);
    } catch (error) {
      if (!response.headersSent && !response.destroyed) respond(response, error instanceof HttpError ? error.status : 500, { error: error instanceof HttpError ? error.message : '服务暂时不可用，请稍后再试' }, allowedOrigin);
      else if (!response.destroyed) response.end();
    }
  });
  server.requestTimeout = 120000; server.headersTimeout = 10000; server.timeout = 130000; server.maxHeadersCount = 50;
  server.on('clientError', (_error, socket) => { if (socket.writable) socket.end('HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n'); });
  let closed = false;
  return { server, db, media, snapshot, close: async () => {
    if (closed) return; closed = true;
    await new Promise((resolveClose, rejectClose) => { if (!server.listening) { resolveClose(); return; } server.close((error) => error ? rejectClose(error) : resolveClose()); server.closeIdleConnections(); });
    await media.close(); db.close(); releaseLock();
  } };
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  const host = process.env.HOST || '127.0.0.1', port = Number(process.env.PORT || 8787);
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('PORT must be 1–65535');
  const app = createApp({ databasePath: process.env.DATABASE_PATH || './data/sidequest-v2.sqlite', mediaDirectory: process.env.MEDIA_DIRECTORY, apkDirectory: process.env.APK_DIRECTORY,
    allowedOrigins: (process.env.ALLOWED_ORIGINS || '').split(',').map((item) => item.trim()).filter(Boolean) });
  app.server.listen(port, host, () => console.log(`Sidequest v0.2 API listening on ${host}:${port}; protocol 2; private media enabled. Local integration only, not a production deployment.`));
  let closing = false;
  const shutdown = () => { if (!closing) { closing = true; app.close().then(() => process.exit(0), () => process.exit(1)); } };
  process.on('SIGINT', shutdown); process.on('SIGTERM', shutdown);
}
