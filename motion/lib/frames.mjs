// frames.mjs: read frames out of a rendered transparent webm (ffmpeg, with the VP9 alpha decoder).
import { spawnSync } from 'node:child_process';

function ffmpeg(args, opts = {}) {
  const r = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', ...args], { maxBuffer: 1 << 30, ...opts });
  if (r.error) throw new Error('ffmpeg is not installed or not on PATH');
  return r;
}

export function probe(file) {
  const r = spawnSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height:format=duration', '-of', 'json', file]);
  if (r.status !== 0) throw new Error(`cannot read ${file}`);
  const j = JSON.parse(String(r.stdout));
  return { w: j.streams[0].width, h: j.streams[0].height, duration: parseFloat(j.format.duration) };
}

// One RGBA frame at time t (seconds), as a raw Buffer of w*h*4 bytes.
export function frameAt(file, t, size) {
  const { w, h } = size || probe(file);
  const r = ffmpeg(['-c:v', 'libvpx-vp9', '-ss', String(t), '-i', file, '-frames:v', '1', '-f', 'rawvideo', '-pix_fmt', 'rgba', 'pipe:1']);
  if (r.status !== 0 || r.stdout.length < w * h * 4) throw new Error(`could not decode a frame of ${file} at ${t}s`);
  return { data: r.stdout.subarray(0, w * h * 4), w, h };
}

// Frames sampled at `fps` over the whole file, as raw RGBA buffers.
export function frames(file, fps = 4) {
  const { w, h } = probe(file);
  const r = ffmpeg(['-c:v', 'libvpx-vp9', '-i', file, '-vf', `fps=${fps}`, '-f', 'rawvideo', '-pix_fmt', 'rgba', 'pipe:1']);
  if (r.status !== 0) throw new Error(`could not decode ${file}`);
  const n = Math.floor(r.stdout.length / (w * h * 4)), out = [];
  for (let i = 0; i < n; i++) out.push(r.stdout.subarray(i * w * h * 4, (i + 1) * w * h * 4));
  return { w, h, frames: out };
}
