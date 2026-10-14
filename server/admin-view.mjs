#!/usr/bin/env node
// 支线服务端只读快照查看器（本地运维工具，不是生产管理后台）。
//
// 用法：
//   node admin-view.mjs <databasePath> <mediaDirectory> [out.html]
//
// 行为：把数据库（连同 WAL/SHM）复制到临时目录后只读打开，生成一个自包含
// 的 HTML 快照（含账号、活动进度、记录、媒体与缩略图 base64）。不写数据库、
// 不改媒体目录、不启动任何服务。数据库和媒体含隐私内容，快照文件请勿公开分发。
import { DatabaseSync } from 'node:sqlite';
import { copyFileSync, existsSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { tmpdir } from 'node:os';

const [, , dbArg, mediaArg, outArg] = process.argv;
if (!dbArg || !mediaArg) {
  console.error('用法: node admin-view.mjs <databasePath> <mediaDirectory> [out.html]');
  process.exit(1);
}
const dbPath = resolve(dbArg);
const mediaDir = resolve(mediaArg);
const outPath = resolve(outArg ?? join(dirname(dbPath), 'admin-view.html'));

const snap = join(tmpdir(), `sidequest-view-${process.pid}-${Date.now()}.sqlite`);
copyFileSync(dbPath, snap);
for (const ext of ['-wal', '-shm']) {
  if (existsSync(dbPath + ext)) copyFileSync(dbPath + ext, snap + ext);
}
const db = new DatabaseSync(snap);

const esc = (s) =>
  String(s ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c],
  );
const cst = (iso) => {
  try {
    return new Date(iso).toLocaleString('zh-CN', { timeZone: 'Asia/Shanghai', hour12: false });
  } catch {
    return iso;
  }
};
const ts = (ms) => cst(new Date(ms).toISOString());
const fmtBytes = (n) =>
  n >= 1024 * 1024 ? `${(n / (1024 * 1024)).toFixed(1)} MB` : n >= 1024 ? `${(n / 1024).toFixed(0)} KB` : `${n} B`;

const users = db.prepare('SELECT * FROM users').all();
const entries = db.prepare('SELECT * FROM entries').all();
const media = db.prepare('SELECT * FROM media').all();
const bindings = db.prepare('SELECT * FROM media_bindings').all();
const questStates = db.prepare('SELECT * FROM quest_state').all();
const branchCount = db.prepare('SELECT COUNT(*) c FROM sync_branches').get().c;
const sessionCount = db.prepare('SELECT COUNT(*) c FROM sessions').get().c;

const mediaById = new Map(media.map((m) => [m.id, m]));
const questByUser = new Map(questStates.map((q) => [q.user_id, q]));
const bindingsFor = (entryId) =>
  bindings
    .filter((b) => b.target_kind === 'entry' && b.target_id === entryId)
    .sort((a, b) => a.position - b.position);

function thumbnailDataUri(row) {
  if (!row?.thumbnail_name) return null;
  const p = join(mediaDir, row.id, row.thumbnail_name);
  if (!existsSync(p)) return null;
  return `data:image/jpeg;base64,${readFileSync(p).toString('base64')}`;
}

const kindLabel = { image: '图片', video: '视频', audio: '语音' };
const statusLabel = { ready: '就绪', processing: '处理中', failed: '失败', reserved: '已预约', uploading: '上传中' };

let html = `<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>支线 · 服务端数据快照</title>
<style>
:root { --paper:#F7F6F0; --forest:#234D3C; --ink:#203B31; --lime:#DFECAC; --muted:#69756C; --line:#E3E0D3; }
* { box-sizing:border-box; }
body { margin:0; background:var(--paper); color:var(--ink); font-family:"Microsoft YaHei","PingFang SC",system-ui,sans-serif; line-height:1.6; }
.wrap { max-width:980px; margin:0 auto; padding:28px 20px 60px; }
h1 { font-size:26px; color:var(--forest); margin:0 0 4px; }
h1 small { font-size:13px; color:var(--muted); font-weight:400; margin-left:10px; }
h2 { font-size:19px; color:var(--forest); margin:34px 0 10px; border-bottom:2px solid var(--lime); padding-bottom:6px; }
.stats { display:flex; flex-wrap:wrap; gap:10px; margin:14px 0; }
.stat { background:#fff; border:1px solid var(--line); border-radius:14px; padding:10px 16px; min-width:130px; }
.stat b { display:block; font-size:22px; color:var(--forest); }
.stat span { font-size:12px; color:var(--muted); }
.card { background:#fff; border:1px solid var(--line); border-radius:16px; padding:16px 18px; margin:12px 0; }
.card h3 { margin:0 0 2px; font-size:16px; }
.tag { display:inline-block; background:var(--lime); color:var(--forest); border-radius:999px; padding:1px 10px; font-size:12px; margin-right:6px; }
.meta { color:var(--muted); font-size:12.5px; }
.text { margin:8px 0; font-size:15px; white-space:pre-wrap; }
table { width:100%; border-collapse:collapse; font-size:13.5px; background:#fff; border-radius:14px; overflow:hidden; }
th,td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top; }
th { background:var(--lime); color:var(--forest); font-weight:600; }
code { background:var(--paper); padding:1px 6px; border-radius:6px; font-size:12px; }
.attach { display:flex; flex-wrap:wrap; gap:10px; margin:8px 0 0; }
.attach figure { margin:0; width:168px; }
.attach img { width:168px; border-radius:10px; border:1px solid var(--line); display:block; }
.attach figcaption { font-size:12px; color:var(--muted); margin-top:4px; }
.footer { margin-top:40px; color:var(--muted); font-size:12px; }
</style></head><body><div class="wrap">
<h1>支线 · 服务端数据快照 <small>${esc(cst(new Date().toISOString()))} 生成 · 只读视图</small></h1>
<div class="stats">
  <div class="stat"><b>${users.length}</b><span>账号</span></div>
  <div class="stat"><b>${entries.length}</b><span>记录</span></div>
  <div class="stat"><b>${media.filter((m) => m.status === 'ready').length} / ${media.length}</b><span>媒体（就绪/总数）</span></div>
  <div class="stat"><b>${fmtBytes(media.reduce((s, m) => s + (m.byte_size || 0), 0))}</b><span>媒体占用</span></div>
  <div class="stat"><b>${branchCount}</b><span>同步分支</span></div>
  <div class="stat"><b>${sessionCount}</b><span>有效会话</span></div>
</div>
`;

for (const user of users) {
  const q = questByUser.get(user.id);
  const prefs = (() => { try { return JSON.parse(user.preferences).join('、') || '未选择'; } catch { return user.preferences; } })();
  html += `<section class="card"><h3>${esc(user.nickname)} <span class="tag">${esc(user.role)}</span><span class="tag">${esc(prefs)}</span></h3>
<div class="meta">ID <code>${esc(user.id)}</code> · 进度版本 ${q?.progress_revision ?? '-'} · 当前活动 ${esc(q?.active_quest_id ?? '无')} · 推荐 ${esc(q?.recommended_quest_id ?? '-')} · 日 ${esc(q?.day ?? '-')} · 可换活动 ${q?.can_request_next ? '是' : '否'}</div>`;
  const own = entries.filter((e) => e.user_id === user.id).sort((a, b) => b.created_at.localeCompare(a.created_at));
  if (own.length === 0) html += `<p class="meta">（暂无记录）</p>`;
  for (const e of own) {
    html += `<div class="card" style="margin:10px 0 0"><h3>${esc(e.quest_title)} <span class="tag">${esc(e.quest_id)}</span></h3>
<div class="meta">${esc(cst(e.created_at))} · 修订 ${e.revision} · ID <code>${esc(e.id)}</code></div>
<div class="text">${esc(e.text)}</div>`;
    const atts = bindingsFor(e.id);
    if (atts.length) {
      html += `<div class="attach">`;
      for (const b of atts) {
        const m = mediaById.get(b.media_id);
        const thumb = thumbnailDataUri(m);
        const label = `${kindLabel[m?.kind] ?? m?.kind} · ${fmtBytes(m?.byte_size || 0)}${m?.duration_ms ? ` · ${(m.duration_ms / 1000).toFixed(1)}s` : ''}${m?.width ? ` · ${m.width}×${m.height}` : ''}`;
        html += `<figure>${thumb ? `<img src="${thumb}" alt="">` : `<div style="width:168px;height:100px;border:1px dashed var(--line);border-radius:10px;display:flex;align-items:center;justify-content:center;color:var(--muted);font-size:12px">${esc(kindLabel[m?.kind] ?? '媒体')}</div>`}<figcaption>${esc(label)}</figcaption></figure>`;
      }
      html += `</div>`;
    }
    html += `</div>`;
  }
  html += `</section>`;
}

html += `<h2>媒体明细</h2><table><tr><th>ID</th><th>账号</th><th>类型</th><th>状态</th><th>大小</th><th>尺寸/时长</th><th>错误</th><th>创建</th></tr>`;
for (const m of media) {
  const nick = users.find((u) => u.id === m.user_id)?.nickname ?? m.user_id.slice(0, 8);
  html += `<tr><td><code>${esc(m.id.slice(0, 8))}</code></td><td>${esc(nick)}</td><td>${esc(kindLabel[m.kind] ?? m.kind)}</td><td>${esc(statusLabel[m.status] ?? m.status)}</td><td>${fmtBytes(m.byte_size || 0)}</td><td>${m.width ? `${m.width}×${m.height}` : ''}${m.duration_ms ? ` ${(m.duration_ms / 1000).toFixed(1)}s` : ''}</td><td>${esc(m.error ?? '')}</td><td class="meta">${esc(ts(m.created_at))}</td></tr>`;
}
html += `</table>
<p class="footer">由 <code>server/admin-view.mjs</code> 生成的只读快照。数据库与媒体含私人内容，请勿公开分发。重新生成：<code>node server/admin-view.mjs &lt;databasePath&gt; &lt;mediaDirectory&gt; [out.html]</code></p>
</div></body></html>`;

db.close();
for (const ext of ['', '-wal', '-shm']) { try { rmSync(snap + ext); } catch {} }
writeFileSync(outPath, html);
console.log(`snapshot written: ${outPath}`);
