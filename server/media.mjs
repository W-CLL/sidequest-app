import { spawn, spawnSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createReadStream, createWriteStream, existsSync, mkdirSync, readFileSync, realpathSync, readdirSync, statSync, rmSync, writeFileSync } from 'node:fs';
import { open, rename, rm } from 'node:fs/promises';
import { dirname, join, resolve } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import { assert, fields, HttpError, identifier } from './errors.mjs';
import { transaction } from './database.mjs';

export const MiB = 1024 * 1024;
export const SOURCE_LIMITS = Object.freeze({ image: 10 * MiB, video: 50 * MiB, audio: 2 * MiB });
export const OUTPUT_LIMITS = Object.freeze({ image: 5 * MiB, video: 30 * MiB, audio: 2 * MiB });
const ACCOUNT_LIMIT = 1024 * MiB;
const THUMB_LIMIT = MiB;
const UUID = /^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/;
const SAFE_FORMATS = 'mov,mp4,m4a,3gp,3g2,mj2,matroska,webm,jpeg_pipe,png_pipe,webp_pipe,aac,wav';

export function checkMediaTools({ ffmpeg = process.env.FFMPEG_PATH || 'ffmpeg', ffprobe = process.env.FFPROBE_PATH || 'ffprobe' } = {}) {
  for (const [name, executable] of [['ffmpeg', ffmpeg], ['ffprobe', ffprobe]]) {
    const result = spawnSync(executable, ['-version'], { encoding: 'utf8', timeout: 10000, windowsHide: true, maxBuffer: MiB });
    if (result.error || result.status !== 0 || !result.stdout.startsWith(`${name} version`)) {
      throw new Error(`${name} is required. Set ${name.toUpperCase()}_PATH or install it on PATH; ${result.error?.message ?? 'version check failed'}`);
    }
  }
  const encoders = spawnSync(ffmpeg, ['-hide_banner', '-encoders'], { encoding: 'utf8', timeout: 10000, windowsHide: true, maxBuffer: MiB });
  if (encoders.status !== 0 || !['libx264', 'mjpeg', 'aac'].every((codec) => encoders.stdout.includes(codec))) {
    throw new Error('FFmpeg must provide libx264, mjpeg and aac encoders.');
  }
  return { ffmpeg, ffprobe };
}

function run(executable, args, { timeout = 60000, maxOutput = 2 * MiB } = {}) {
  return new Promise((resolveRun, rejectRun) => {
    const child = spawn(executable, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'], shell: false });
    let output = '', error = '', bytes = 0, failure;
    const timer = setTimeout(() => { failure = new HttpError(422, '媒体处理超时，请换一个较小的文件'); child.kill('SIGKILL'); }, timeout);
    child.stdout.on('data', (chunk) => {
      bytes += chunk.length;
      if (bytes > maxOutput) { failure = new HttpError(422, '媒体信息过大'); child.kill('SIGKILL'); }
      else output += chunk.toString();
    });
    child.stderr.on('data', (chunk) => { error = (error + chunk.toString()).slice(-8000); });
    child.on('error', (cause) => { clearTimeout(timer); rejectRun(cause); });
    child.on('close', (code) => {
      clearTimeout(timer);
      if (failure) rejectRun(failure);
      else if (code !== 0) rejectRun(new HttpError(422, '无法读取此媒体，请选择有效的图片、视频或录音'));
      else resolveRun(output);
    });
  });
}

export class FfmpegProcessor {
  constructor(options) { this.tools = checkMediaTools(options); }
  async probe(path) {
    const raw = await run(this.tools.ffprobe, ['-v', 'error', '-protocol_whitelist', 'file,pipe', '-format_whitelist', SAFE_FORMATS,
      '-show_entries', 'stream=codec_type,codec_name,width,height,duration:format=format_name,duration', '-of', 'json', path], { timeout: 15000 });
    let info;
    try { info = JSON.parse(raw); } catch { throw new HttpError(422, '媒体信息无法识别'); }
    assert(Array.isArray(info.streams) && info.streams.length <= 8, 422, '媒体轨道无效');
    return info;
  }
  async process(kind, source, directory) {
    const info = await this.probe(source);
    const video = info.streams.find((stream) => stream.codec_type === 'video');
    const audio = info.streams.find((stream) => stream.codec_type === 'audio');
    const duration = Number(info.format?.duration ?? (kind === 'audio' ? audio?.duration : video?.duration));
    if (kind === 'image') {
      assert(video && ['mjpeg', 'png', 'webp'].includes(video.codec_name) && !audio && /^(jpeg_pipe|png_pipe|webp_pipe)$/.test(info.format?.format_name ?? ''), 422, '图片仅支持 JPEG、PNG 或 WebP');
    } else {
      assert(Number.isFinite(duration) && duration > 0 && duration * 1000 <= (kind === 'video' ? 15000 : 60000), 422,
        kind === 'video' ? '视频最多 15 秒' : '语音最多 60 秒');
      assert(kind === 'video' ? !!video : !!audio && !video, 422, '媒体类型与内容不一致');
    }
    if (video) assert(Number.isInteger(video.width) && Number.isInteger(video.height) && video.width > 0 && video.height > 0 && video.width <= 12000 && video.height <= 12000 && video.width * video.height <= 40000000, 422, '图片或视频分辨率过大');
    const contentName = kind === 'image' ? 'content.jpg' : kind === 'video' ? 'content.mp4' : 'content.m4a';
    const contentPath = join(directory, contentName);
    const input = ['-nostdin', '-hide_banner', '-v', 'error', '-y', '-xerror', '-threads', '1', '-err_detect', 'explode', '-protocol_whitelist', 'file,pipe', '-format_whitelist', SAFE_FORMATS, '-i', source];
    let encoding;
    if (kind === 'image') encoding = ['-map', '0:v:0', '-frames:v', '1', '-vf', "scale='min(1920,iw)':'min(1920,ih)':force_original_aspect_ratio=decrease", '-c:v', 'mjpeg', '-q:v', '3', '-threads', '1'];
    else if (kind === 'video') encoding = ['-map', '0:v:0', '-map', '0:a:0?', '-vf', "scale='min(1280,iw)':'min(1280,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2,setsar=1", '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'veryfast', '-crf', '24', '-threads', '1', '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart'];
    else encoding = ['-map', '0:a:0', '-vn', '-c:a', 'aac', '-b:a', '96k', '-ac', '1', '-ar', '44100', '-movflags', '+faststart'];
    // The emergency output cap is deliberately above the accepted size, so a -fs truncation is never accepted as a small valid file.
    await run(this.tools.ffmpeg, [...input, ...encoding, ...(kind === 'image' ? [] : ['-t', String(duration)]), '-map_metadata', '-1', '-map_metadata:s', '-1', '-map_chapters', '-1', '-fs', String(OUTPUT_LIMITS[kind] + MiB), contentPath]);
    const byteSize = statSync(contentPath).size;
    assert(byteSize > 0 && byteSize <= OUTPUT_LIMITS[kind], 413, '处理后的媒体文件过大');
    const output = await this.probe(contentPath);
    const outputVideo = output.streams.find((stream) => stream.codec_type === 'video');
    const outputDuration = Number(output.format?.duration);
    if (kind !== 'image') assert(Number.isFinite(outputDuration) && Math.abs(outputDuration - duration) < 0.1 && outputDuration * 1000 <= (kind === 'video' ? 15000 : 60000), 422, '媒体处理不完整或超过时长限制，请重试');
    let thumbnailName = null, thumbnailBytes = 0;
    if (kind !== 'audio') {
      thumbnailName = 'thumbnail.jpg';
      await run(this.tools.ffmpeg, ['-nostdin', '-hide_banner', '-v', 'error', '-y', '-threads', '1', '-i', contentPath, '-map', '0:v:0', '-frames:v', '1', '-vf', "scale='min(480,iw)':'min(480,ih)':force_original_aspect_ratio=decrease", '-c:v', 'mjpeg', '-q:v', '5', '-threads', '1', '-map_metadata', '-1', '-fs', String(THUMB_LIMIT + 1), join(directory, thumbnailName)]);
      thumbnailBytes = statSync(join(directory, thumbnailName)).size;
      assert(thumbnailBytes <= THUMB_LIMIT, 413, '缩略图过大');
    }
    return { contentName, thumbnailName, thumbnailBytes, byteSize, mimeType: kind === 'image' ? 'image/jpeg' : kind === 'video' ? 'video/mp4' : 'audio/mp4',
      durationMs: kind === 'image' ? null : Math.round(duration * 1000), width: outputVideo?.width ?? null, height: outputVideo?.height ?? null };
  }
}

export function mediaJson(row) {
  return { id: row.id, kind: row.kind, mimeType: row.mime_type, byteSize: row.byte_size, durationMs: row.duration_ms, width: row.width, height: row.height, status: row.status };
}

export class MediaStore {
  constructor({ db, root, now, processor, accountLimit = ACCOUNT_LIMIT }) {
    this.db = db; this.root = resolve(root); this.now = now; this.processor = processor; this.accountLimit = accountLimit;
    mkdirSync(this.root, { recursive: true, mode: 0o700 });
    this.root = realpathSync(this.root);
    const ownerPath = join(this.root, '.sidequest-media-owner');
    const owner = db.prepare("SELECT value FROM server_metadata WHERE key='media_owner'").get().value;
    if (existsSync(ownerPath)) {
      assert(readFileSync(ownerPath, 'utf8') === owner, 500, '媒体目录属于另一个数据库，请配置匹配的路径');
    } else {
      assert(readdirSync(this.root).length === 0, 500, '媒体目录已有未识别文件；不会删除，请配置新的空目录');
      writeFileSync(ownerPath, owner, { flag: 'wx', mode: 0o600 });
    }
    this.activeUploads = new Set(); this.activeProcessing = new Set(); this.closed = false;
    // A process restart cannot resume a half-written stream. Keep its reservation for an explicit same-ID retry.
    db.prepare("UPDATE media SET status = 'failed', error = '上次上传被中断，请重试' WHERE status IN ('uploading','processing')").run();
    this.sweep();
    this.timer = setInterval(() => this.sweep(), 60000); this.timer.unref();
  }
  directory(id) {
    assert(UUID.test(id), 400, '媒体标识无效');
    const path = resolve(this.root, id);
    assert(dirname(path) === this.root, 400, '媒体路径无效');
    return path;
  }
  get(userId, id) {
    const row = this.db.prepare('SELECT * FROM media WHERE id = ? AND user_id = ?').get(id, userId);
    assert(row, 404, '附件不存在');
    return row;
  }
  usage(userId) { return this.db.prepare('SELECT COALESCE(sum(reserved_bytes),0) AS total FROM media WHERE user_id = ?').get(userId).total; }
  reserve(userId, body) {
    fields(body, ['kind', 'byteSize', 'clientUploadId']);
    const { kind, byteSize } = body;
    identifier(body.clientUploadId, '上传标识');
    assert(Object.hasOwn(SOURCE_LIMITS, kind) && Number.isInteger(byteSize) && byteSize > 0 && byteSize <= SOURCE_LIMITS[kind], 413, '媒体大小或类型超出限制');
    return transaction(this.db, () => {
      const previous = this.db.prepare('SELECT * FROM media WHERE user_id = ? AND client_upload_id = ?').get(userId, body.clientUploadId);
      if (previous) {
        assert(previous.kind === kind && previous.source_bytes === byteSize, 409, '上传标识已用于其他文件');
        return mediaJson(previous);
      }
      const pending = this.db.prepare("SELECT count(*) AS count FROM media WHERE user_id = ? AND NOT EXISTS(SELECT 1 FROM media_bindings b WHERE b.media_id = media.id)").get(userId).count;
      assert(pending < 160, 429, '待处理附件过多，请先完成或删除未使用的附件');
      // Reserve source + worst-case output + thumbnail while processing, not merely client-reported bytes.
      const reserved = byteSize + OUTPUT_LIMITS[kind] + MiB + (kind === 'audio' ? 0 : THUMB_LIMIT);
      assert(this.usage(userId) + reserved <= this.accountLimit, 413, '账号媒体空间不足，请先删除不需要的记录');
      const id = randomUUID();
      this.db.prepare("INSERT INTO media(id,user_id,client_upload_id,kind,status,source_bytes,reserved_bytes,created_at) VALUES(?,?,?,?,'reserved',?,?,?)")
        .run(id, userId, body.clientUploadId, kind, byteSize, reserved, this.now().getTime());
      return mediaJson(this.get(userId, id));
    });
  }
  async upload(userId, id, request) {
    const row = this.get(userId, id);
    if (row.status === 'ready' || row.status === 'processing') { request.resume(); return mediaJson(row); }
    assert(!this.activeUploads.has(id) && !this.activeProcessing.has(id), 409, '此附件正在上传');
    assert(this.activeUploads.size < 4, 429, '正在上传其他附件，请稍后重试');
    assert(!request.headers['content-encoding'] || request.headers['content-encoding'] === 'identity', 415, '上传不支持压缩请求');
    assert(!request.headers['content-length'] || Number(request.headers['content-length']) === row.source_bytes, 413, '文件大小与上传申请不一致');
    this.activeUploads.add(id);
    const directory = this.directory(id);
    mkdirSync(directory, { recursive: true, mode: 0o700 });
    const partial = join(directory, 'source.part'), source = join(directory, 'source.bin');
    this.db.prepare("UPDATE media SET status = 'uploading', error = NULL WHERE id = ?").run(id);
    try {
      let bytes = 0;
      const counter = new Transform({ transform(chunk, _encoding, callback) {
        bytes += chunk.length;
        callback(bytes > row.source_bytes ? new HttpError(413, '上传内容超出申请大小') : null, chunk);
      } });
      await pipeline(request, counter, createWriteStream(partial, { flags: 'w', mode: 0o600 }));
      assert(bytes === row.source_bytes, 400, '上传未完成，请重试');
      const handle = await open(partial, 'r+');
      try { await handle.sync(); } finally { await handle.close(); }
      await rename(partial, source);
      this.get(userId, id); // Account/file may have been canceled while the stream was open.
      this.db.prepare("UPDATE media SET status = 'processing' WHERE id = ?").run(id);
      this.processPending();
      return mediaJson(this.get(userId, id));
    } catch (error) {
      this.db.prepare("UPDATE media SET status = 'failed', error = ? WHERE id = ?").run(error instanceof HttpError ? error.message : '上传失败，请重试', id);
      await rm(partial, { force: true }).catch(() => {});
      throw error;
    } finally { this.activeUploads.delete(id); }
  }
  processPending() {
    if (this.closed || this.activeProcessing.size) return;
    const row = this.db.prepare("SELECT * FROM media WHERE status = 'processing' ORDER BY created_at,id LIMIT 1").get();
    if (!row) return;
    this.activeProcessing.add(row.id);
    const directory = this.directory(row.id);
    const job = this.processor.process(row.kind, join(directory, 'source.bin'), directory)
      .then(async (result) => {
        const { contentName, thumbnailName, thumbnailBytes = 0, byteSize, mimeType, durationMs, width, height } = result;
        assert(byteSize > 0 && byteSize <= OUTPUT_LIMITS[row.kind], 413, '处理后的媒体文件过大');
        for (const name of [contentName, thumbnailName].filter(Boolean)) {
          const handle = await open(join(directory, name), 'r+');
          try { await handle.sync(); } finally { await handle.close(); }
        }
        await rm(join(directory, 'source.bin'), { force: true });
        this.db.prepare("UPDATE media SET status='ready',content_name=?,thumbnail_name=?,byte_size=?,reserved_bytes=?,mime_type=?,duration_ms=?,width=?,height=?,error=NULL WHERE id=? AND status='processing'")
          .run(contentName, thumbnailName ?? null, byteSize, byteSize + thumbnailBytes, mimeType, durationMs ?? null, width ?? null, height ?? null, row.id);
      }).catch(async (error) => {
        this.db.prepare("UPDATE media SET status='failed', error=? WHERE id=?").run(error instanceof HttpError ? error.message : '媒体处理失败，请重试', row.id);
        // A failed decode keeps only the retryable reservation, never its large source/partial output files.
        if (existsSync(directory) && dirname(realpathSync(directory)) === this.root) await rm(directory, { recursive: true, force: true }).catch(() => {});
      }).finally(() => { this.activeProcessing.delete(row.id); this.jobs.delete(job); if (!this.closed) { this.processPending(); this.cleanup(); } });
    this.jobs ??= new Set(); this.jobs.add(job);
  }
  attachments(userId, kind, target) {
    return this.db.prepare('SELECT m.* FROM media m JOIN media_bindings b ON b.media_id=m.id WHERE b.user_id=? AND b.target_kind=? AND b.target_id=? ORDER BY b.position')
      .all(userId, kind, target).map(mediaJson);
  }
  validate(userId, ids) {
    assert(Array.isArray(ids) && ids.length <= 7 && ids.every((id) => typeof id === 'string') && new Set(ids).size === ids.length, 400, '附件列表无效');
    const rows = ids.map((id) => this.get(userId, id));
    assert(rows.every((row) => row.status === 'ready'), 409, '请等待所有附件上传并处理完成');
    assert(rows.filter((row) => row.kind === 'image').length <= 5 && rows.filter((row) => row.kind === 'video').length <= 1 && rows.filter((row) => row.kind === 'audio').length <= 1, 400, '每条记录最多 5 张图片、1 段视频和 1 段语音');
    assert(rows.reduce((sum, row) => sum + row.byte_size, 0) <= 45 * MiB, 413, '本条记录的媒体总大小超过 45 MiB');
    return rows;
  }
  bind(userId, kind, target, ids) {
    this.validate(userId, ids);
    const previous = this.db.prepare('SELECT media_id FROM media_bindings WHERE user_id=? AND target_kind=? AND target_id=?').all(userId, kind, target);
    this.db.prepare('DELETE FROM media_bindings WHERE user_id=? AND target_kind=? AND target_id=?').run(userId, kind, target);
    ids.forEach((id, index) => this.db.prepare('INSERT INTO media_bindings(media_id,user_id,target_kind,target_id,position) VALUES(?,?,?,?,?)').run(id, userId, kind, target, index));
    for (const { media_id: id } of previous) if (!ids.includes(id)) this.queueIfUnbound(id);
  }
  detach(userId, kind, target) {
    const rows = this.db.prepare('SELECT media_id FROM media_bindings WHERE user_id=? AND target_kind=? AND target_id=?').all(userId, kind, target);
    this.db.prepare('DELETE FROM media_bindings WHERE user_id=? AND target_kind=? AND target_id=?').run(userId, kind, target);
    for (const row of rows) this.queueIfUnbound(row.media_id);
  }
  queueIfUnbound(id) {
    if (this.db.prepare('SELECT 1 FROM media_bindings WHERE media_id=?').get(id)) return;
    this.db.prepare('INSERT OR IGNORE INTO media_cleanup(media_id,created_at) VALUES(?,?)').run(id, this.now().getTime());
    this.db.prepare('DELETE FROM media WHERE id=?').run(id);
  }
  cancel(userId, id) {
    this.get(userId, id);
    assert(!this.db.prepare('SELECT 1 FROM media_bindings WHERE media_id=?').get(id), 409, '此附件仍属于草稿或记录，不能单独删除');
    transaction(this.db, () => this.queueIfUnbound(id));
    this.cleanup();
  }
  deleteAccount(userId) {
    for (const row of this.db.prepare('SELECT id FROM media WHERE user_id=?').all(userId)) {
      this.db.prepare('INSERT OR IGNORE INTO media_cleanup(media_id,created_at) VALUES(?,?)').run(row.id, this.now().getTime());
    }
  }
  cleanup() {
    for (const row of this.db.prepare('SELECT media_id FROM media_cleanup LIMIT 100').all()) {
      if (this.activeUploads.has(row.media_id) || this.activeProcessing.has(row.media_id)) continue;
      try {
        const directory = this.directory(row.media_id);
        // Never follow a symbolic-link directory or operate outside this exact private root.
        if (existsSync(directory)) assert(dirname(realpathSync(directory)) === this.root, 500, '媒体清理路径无效');
        rmSync(directory, { recursive: true, force: true });
        this.db.prepare('DELETE FROM media_cleanup WHERE media_id=?').run(row.media_id);
      } catch (error) {
        this.db.prepare('UPDATE media_cleanup SET attempts=attempts+1,last_error=? WHERE media_id=?').run(String(error.message).slice(0, 200), row.media_id);
      }
    }
  }
  sweep() {
    const cutoff = this.now().getTime() - 24 * 60 * 60 * 1000;
    transaction(this.db, () => {
      for (const row of this.db.prepare('SELECT id FROM media WHERE created_at<? AND NOT EXISTS(SELECT 1 FROM media_bindings b WHERE b.media_id=media.id)').all(cutoff)) {
        if (!this.activeUploads.has(row.id) && !this.activeProcessing.has(row.id)) this.queueIfUnbound(row.id);
      }
      // Reservation is committed before a media directory is created. Unknown
      // directories are never inferred to be ours and are deliberately untouched.
    });
    for (const row of this.db.prepare("SELECT id FROM media WHERE status='failed'").all()) {
      if (this.activeUploads.has(row.id) || this.activeProcessing.has(row.id)) continue;
      const directory = this.directory(row.id);
      try {
        if (existsSync(directory) && dirname(realpathSync(directory)) === this.root) rmSync(directory, { recursive: true, force: true });
      } catch { /* A later sweep or explicit cancellation retries a locked file. */ }
    }
    this.cleanup();
  }
  async serve(userId, id, thumbnail, request, response, origin) {
    const row = this.get(userId, id);
    assert(row.status === 'ready', 409, '附件仍在处理');
    const name = thumbnail ? row.thumbnail_name : row.content_name;
    assert(name && ['content.jpg','content.mp4','content.m4a','thumbnail.jpg'].includes(name), 404, '附件没有缩略图');
    const path = join(this.directory(id), name);
    assert(existsSync(path), 404, '附件文件暂时无法读取');
    const size = statSync(path).size;
    const headers = { 'Content-Type': thumbnail ? 'image/jpeg' : row.mime_type, 'Cache-Control': 'private, no-store', 'X-Content-Type-Options': 'nosniff', 'Accept-Ranges': 'bytes',
      ...(origin ? { 'Access-Control-Allow-Origin': origin, Vary: 'Origin', 'Access-Control-Expose-Headers': 'Content-Length,Content-Range,Accept-Ranges' } : {}) };
    let start = 0, end = size - 1, status = 200;
    if (request.headers.range) {
      const match = /^bytes=(\d*)-(\d*)$/.exec(request.headers.range);
      if (!match || (!match[1] && !match[2])) { response.writeHead(416, { ...headers, 'Content-Range': `bytes */${size}` }); response.end(); return; }
      if (!match[1]) { const suffix = Number(match[2]); start = Math.max(0, size - suffix); if (!Number.isSafeInteger(suffix) || suffix <= 0) start = size; }
      else { start = Number(match[1]); if (match[2]) end = Math.min(Number(match[2]), size - 1); }
      if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) { response.writeHead(416, { ...headers, 'Content-Range': `bytes */${size}` }); response.end(); return; }
      status = 206; headers['Content-Range'] = `bytes ${start}-${end}/${size}`;
    }
    headers['Content-Length'] = end - start + 1;
    response.writeHead(status, headers);
    if (request.method === 'HEAD') response.end();
    else await pipeline(createReadStream(path, { start, end }), response);
  }
  async close() { this.closed = true; clearInterval(this.timer); await Promise.allSettled(this.jobs ?? []); this.cleanup(); }
}
