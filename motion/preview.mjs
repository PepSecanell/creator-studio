#!/usr/bin/env node
// preview.mjs: render every comp in one look and lay the hold frames out on contact sheets.
//
//   node motion/preview.mjs <look> [--comps a,b] [--out motion/_previews] [--frames <dir>] [--workers 3]
//   node motion/preview.mjs --tokens workspace/.brand/tokens.css --name mybrand
//
// Jobs come from motion/previews.json (one entry per variant worth seeing), or, for a comp that has no
// entry there, from its vars.example.json. Each frame is laid on the look's ground with a stand in for the
// camera, the way the video builder shows it. Every render also runs the zone check.
// Writes <out>/<name>-shorts.png and <out>/<name>-long.png.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import sharp from 'sharp';
import { MOTION, REPO, listComps, renderAsync } from './render.mjs';
import { frameAt } from './lib/frames.mjs';
import { zoneCheck } from './zone-check.mjs';

const args = process.argv.slice(2), opt = {};
for (let i = 0; i < args.length; i++) {
  if (args[i].startsWith('--')) opt[args[i].slice(2)] = args[i + 1], i++;
  else opt.look = args[i];
}
const look = opt.look || 'notebook';
const tokens = opt.tokens ? path.resolve(opt.tokens) : path.join(REPO, 'looks', look, 'tokens.css');
if (!fs.existsSync(tokens)) { console.error(`preview: no look called "${look}" (looks/${look}/tokens.css is missing)`); process.exit(2); }
const name = opt.name || look;
const outDir = path.resolve(opt.out || path.join(MOTION, '_previews'));
const framesDir = opt.frames ? path.resolve(opt.frames) : null;
const workers = Math.max(1, parseInt(opt.workers || '3', 10));
const only = opt.comps ? opt.comps.split(',') : null;

const css = fs.readFileSync(tokens, 'utf8');
const role = (k, d) => (css.match(new RegExp(`--cs-${k}:\\s*(#[0-9a-fA-F]{6})`)) || [])[1] || d;
const GROUND = role('ground', '#F5F3EE'), INK = role('ink', '#222222'), MUTED = role('muted', '#8A8A8A');

function jobs() {
  const comps = listComps().filter((c) => !only || only.includes(c.name));
  const file = path.join(MOTION, 'previews.json');
  const listed = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, 'utf8')) : [];
  const out = [];
  for (const c of comps) {
    const mine = listed.filter((j) => j.comp === c.name);
    const base = { zone: c.zones[0], size: c.kind === 'long' ? '1920x1080' : '1080x1920', duration: c.duration || 4 };
    if (mine.length) mine.forEach((j) => out.push({ ...base, ...j }));
    else out.push({ ...base, comp: c.name, vars: JSON.parse(fs.readFileSync(path.join(MOTION, 'comps', c.name, 'vars.example.json'), 'utf8')) });
  }
  return out.map((j, i) => ({ ...j, id: `${String(i).padStart(2, '0')}-${j.comp}${j.vars && j.vars.variant ? '-' + j.vars.variant : ''}-${j.zone}` }));
}

// the ground plus a soft stand in for the camera area the zone leaves free
function backdrop(w, h, zone) {
  const cam = w < h
    ? (zone === 'split' ? `<rect x="40" y="1000" width="1000" height="860" rx="44" fill="${MUTED}" fill-opacity="0.16"/>` : '')
    : (zone === 'split' ? `<rect x="1060" y="72" width="800" height="936" rx="36" fill="${MUTED}" fill-opacity="0.16"/>` : '');
  return Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}"><rect width="100%" height="100%" fill="${GROUND}"/>${cam}</svg>`);
}

async function composite(job, webm) {
  // the hold: late enough that everything has landed, early enough that nothing has started to leave
  const t = job.at != null ? job.at : Math.max(0, job.duration - 0.8);
  const f = frameAt(webm, t);
  const fg = await sharp(f.data, { raw: { width: f.w, height: f.h, channels: 4 } }).png().toBuffer();
  return sharp(backdrop(f.w, f.h, job.zone)).composite([{ input: fg }]).png().toBuffer();
}

async function sheet(items, file, cellW) {
  if (!items.length) return;
  const meta = await sharp(items[0].png).metadata();
  const cellH = Math.round(cellW * meta.height / meta.width), cols = Math.min(items.length, meta.width < meta.height ? 6 : 3);
  const pad = 16, lab = 34, rows = Math.ceil(items.length / cols);
  const W = cols * (cellW + pad) + pad, H = rows * (cellH + lab + pad) + pad;
  const layers = [];
  for (const [i, it] of items.entries()) {
    const x = pad + (i % cols) * (cellW + pad), y = pad + Math.floor(i / cols) * (cellH + lab + pad);
    layers.push({ input: await sharp(it.png).resize(cellW, cellH).png().toBuffer(), left: x, top: y });
    const text = `${it.job.comp}${it.job.vars && it.job.vars.variant ? ' / ' + it.job.vars.variant : ''} / ${it.job.zone}${it.ok ? '' : ' / ZONE FAIL'}`;
    layers.push({ input: Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="${cellW}" height="${lab}"><text x="2" y="24" font-family="Helvetica, Arial, sans-serif" font-size="19" font-weight="600" fill="${it.ok ? INK : '#C0392B'}">${text.replace(/&/g, '&amp;').replace(/</g, '&lt;')}</text></svg>`), left: x, top: y + cellH + 4 });
  }
  await sharp({ create: { width: W, height: H, channels: 3, background: '#FFFFFF' } }).composite(layers).png({ palette: true, quality: 90, effort: 8 }).toFile(file);
  console.log(`preview: wrote ${path.relative(process.cwd(), file)} (${Math.round(fs.statSync(file).size / 1024)} KB)`);
}

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), `cs-preview-${name}-`));
fs.mkdirSync(outDir, { recursive: true });
if (framesDir) fs.mkdirSync(framesDir, { recursive: true });
const all = jobs(), done = [];
let next = 0, failed = 0;
async function worker() {
  while (next < all.length) {
    const job = all[next++], webm = path.join(tmp, `${job.id}.webm`);
    const r = await renderAsync({ comp: job.comp, varsObject: job.vars || {}, varsDir: MOTION, zone: job.zone, size: job.size, duration: job.duration, tokens, out: webm });
    if (!r.ok) { failed++; console.log(`FAIL render ${job.id}`); continue; }
    const z = zoneCheck(webm, job.zone);
    const png = await composite(job, webm);
    if (framesDir) fs.writeFileSync(path.join(framesDir, `${name}-${job.id}.png`), png);
    done.push({ job, png, ok: z.ok });
    console.log(`${z.ok ? 'ok  ' : 'ZONE'} ${job.id}${z.ok ? '' : ': ' + z.msg}`);
    if (!z.ok) failed++;
  }
}
await Promise.all(Array.from({ length: Math.min(workers, all.length) }, worker));
done.sort((a, b) => a.job.id.localeCompare(b.job.id));
await sheet(done.filter((d) => d.job.size === '1080x1920'), path.join(outDir, `${name}-shorts.png`), 240);
await sheet(done.filter((d) => d.job.size === '1920x1080'), path.join(outDir, `${name}-long.png`), 480);
fs.rmSync(tmp, { recursive: true, force: true });
console.log(`preview: ${done.length} rendered, ${failed} problem(s)`);
process.exit(failed ? 1 : 0);
