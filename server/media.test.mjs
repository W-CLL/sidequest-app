import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { fixture, command, completion } from './fixtures.mjs';
import { FfmpegProcessor, checkMediaTools } from './media.mjs';

function generate(ffmpeg, args, destination) {
  const result = spawnSync(ffmpeg, ['-nostdin','-hide_banner','-v','error','-y',...args,destination], { windowsHide: true, timeout: 30000, encoding:'utf8' });
  assert.equal(result.status,0,result.stderr); return readFileSync(destination);
}

test('startup refuses missing FFmpeg rather than silently bypassing validation', () => {
  assert.throws(() => checkMediaTools({ffmpeg:'sidequest-deliberately-missing-ffmpeg',ffprobe:'sidequest-deliberately-missing-ffprobe'}), /required/);
});

test('real image/video/audio upload, metadata stripping, playback ranges and mixed record', async (t) => {
  const processor = new FfmpegProcessor();
  const { api, register, upload, directory, base, sync, app } = await fixture(t,{mediaProcessor:processor});
  const {token} = (await register()).body;
  const image = generate(processor.tools.ffmpeg,['-f','lavfi','-i','color=c=green:s=128x96','-frames:v','1','-threads','1','-metadata','comment=private-location'],join(directory,'source.jpg'));
  const video = generate(processor.tools.ffmpeg,['-f','lavfi','-i','color=c=blue:s=128x96:r=15','-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','1','-c:v','libx264','-pix_fmt','yuv420p','-c:a','aac','-threads','1','-metadata','comment=private-location'],join(directory,'source.mp4'));
  const audio = generate(processor.tools.ffmpeg,['-f','lavfi','-i','sine=frequency=440:sample_rate=44100','-t','1','-c:a','aac','-metadata','comment=private-location'],join(directory,'source.m4a'));
  const attachments = [];
  for (const [kind,bytes] of [['image',image],['video',video],['audio',audio]]) {
    const result = await upload(token,kind,bytes); assert.equal(result.media.status,'ready',JSON.stringify(result)); attachments.push(result.media);
    assert.ok(result.media.byteSize>0); assert.ok(!Object.keys(result.media).some(key=>key.toLowerCase().includes('path')));
    const response = await fetch(`${base}/api/media/${result.media.id}/content`,{headers:{'X-Sidequest-Protocol':'2',Authorization:`Bearer ${token}`,Range:'bytes=0-31'}});
    assert.equal(response.status,206); assert.equal((await response.arrayBuffer()).byteLength,32);
    const row = app.db.prepare('SELECT * FROM media WHERE id=?').get(result.media.id);
    const inspect = spawnSync(processor.tools.ffprobe,['-v','error','-show_entries','format_tags','-of','json',join(app.media.directory(row.id),row.content_name)],{encoding:'utf8',windowsHide:true});
    assert.equal(inspect.status,0); assert.ok(!inspect.stdout.includes('private-location'));
    assert.equal(existsSync(join(app.media.directory(row.id),'source.bin')),false);
  }
  assert.equal(attachments[0].mimeType,'image/jpeg'); assert.equal(attachments[1].mimeType,'video/mp4'); assert.equal(attachments[2].mimeType,'audio/mp4');
  const result = await sync(token,'media-branch',0,[command('claim',{questId:'green'}),command('complete',completion('mixed-media','green','混合记录',attachments.map(media=>media.id)))]);
  assert.equal(result.status,200,JSON.stringify(result.body)); assert.equal(result.body.entries[0].attachments.length,3);
  assert.equal((await api('entries/mixed-media',undefined,token)).body.entry.attachments.length,3);
});

test('real decoder rejects disguised, malformed, over-duration and mismatched media', async (t) => {
  const processor = new FfmpegProcessor();
  const { register, upload, directory, app } = await fixture(t,{mediaProcessor:processor}); const {token} = (await register()).body;
  const failedImage = await upload(token,'image',Buffer.from('this is not an image')); assert.equal(failedImage.media.status,'failed');
  app.media.sweep(); assert.equal(existsSync(app.media.directory(failedImage.media.id)),false);
  const video = generate(processor.tools.ffmpeg,['-f','lavfi','-i','color=c=black:s=32x32:r=1','-t','16','-c:v','libx264','-pix_fmt','yuv420p','-threads','1'],join(directory,'long.mp4'));
  const rejectedVideo = await upload(token,'video',video); assert.equal(rejectedVideo.media.status,'failed'); assert.match(rejectedVideo.error,/15 秒/);
  assert.equal((await upload(token,'image',video)).media.status,'failed');
  const audio = generate(processor.tools.ffmpeg,['-f','lavfi','-i','anullsrc=r=8000:cl=mono','-t','61','-c:a','aac','-b:a','16k'],join(directory,'long.m4a'));
  const rejectedAudio = await upload(token,'audio',audio); assert.equal(rejectedAudio.media.status,'failed'); assert.match(rejectedAudio.error,/60 秒/);
});

test('real exact 15-second video and 60-second recording boundaries remain usable',async(t)=>{
  const processor=new FfmpegProcessor(); const {register,upload,directory}=await fixture(t,{mediaProcessor:processor}); const {token}=(await register()).body;
  const video=generate(processor.tools.ffmpeg,['-f','lavfi','-i','color=c=green:s=32x32:r=10','-t','15','-c:v','libx264','-pix_fmt','yuv420p','-threads','1'],join(directory,'limit.mp4'));
  const recorded=generate(processor.tools.ffmpeg,['-f','lavfi','-i','anullsrc=r=44100:cl=mono','-t','60','-c:a','aac','-b:a','64k'],join(directory,'limit.m4a'));
  const v=await upload(token,'video',video); assert.equal(v.media.status,'ready',JSON.stringify(v)); assert.equal(v.media.durationMs,15000);
  const a=await upload(token,'audio',recorded); assert.equal(a.media.status,'ready',JSON.stringify(a)); assert.equal(a.media.durationMs,60000);
});
