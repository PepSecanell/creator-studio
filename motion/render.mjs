#!/usr/bin/env node
// render.mjs: render one motion comp to a transparent VP9 webm with HyperFrames.
//
//   node motion/render.mjs --list
//   node motion/render.mjs --comp big-number --vars vars.json --out beat.webm \
//        --zone split|full --size 1080x1920|1920x1080 --duration 4 [--tokens tokens.css]
//
// A comp folder holds index.html, vars.schema.json and vars.example.json. The render is staged in a temp
// folder: the comp, the shared core (cs.css, cs.js, gsap, mono font), the tokens file with its fonts, and
// any image the vars point at. The vars are injected as window.__CS_VARS, merged over the schema defaults.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const MOTION = path.dirname(fileURLToPath(import.meta.url));
export const REPO = path.dirname(MOTION);
export const COMPS = path.join(MOTION, 'comps');
const SIZES = ['1080x1920', '1920x1080'];

function fail(msg) { console.error(`render: ${msg}`); process.exit(2); }

export function listComps() {
  return fs.readdirSync(COMPS, { withFileTypes: true })
    .filter((d) => d.isDirectory() && fs.existsSync(path.join(COMPS, d.name, 'vars.schema.json')))
    .map((d) => readSchema(d.name))
    .sort((a, b) => a.name.localeCompare(b.name));
}

export function readSchema(name) {
  const file = path.join(COMPS, name, 'vars.schema.json');
  if (!fs.existsSync(file)) fail(`no comp called "${name}". Run --list to see them.`);
  return JSON.parse(fs.readFileSync(file, 'utf8'));
}

// The workspace: $CREATOR_STUDIO_WORKSPACE, else the config file, else <repo>/workspace.
function workspaceDir() {
  if (process.env.CREATOR_STUDIO_WORKSPACE) return process.env.CREATOR_STUDIO_WORKSPACE;
  const cfg = process.env.CREATOR_STUDIO_CONFIG || path.join(os.homedir(), '.config', 'creator-studio', 'config.json');
  try { const c = JSON.parse(fs.readFileSync(cfg, 'utf8')); if (c.workspace) return c.workspace; } catch { /* no config yet */ }
  return path.join(REPO, 'workspace');
}

// The tokens to use: --tokens, else the resolved brand, else the look named in brand/brand.json.
export function resolveTokens(given) {
  if (given) { if (!fs.existsSync(given)) fail(`tokens file not found: ${given}`); return path.resolve(given); }
  const built = path.join(workspaceDir(), '.brand', 'tokens.css');
  if (fs.existsSync(built)) return built;
  let style = 'notebook';
  try { style = JSON.parse(fs.readFileSync(path.join(REPO, 'brand', 'brand.json'), 'utf8')).style || style; } catch { /* default look */ }
  const look = path.join(REPO, 'looks', style, 'tokens.css');
  if (!fs.existsSync(look)) fail(`no tokens found. Run "./studio brand build" or pass --tokens.`);
  console.error(`render: workspace/.brand/tokens.css not built yet, using looks/${style}/tokens.css`);
  return look;
}

// Copy tokens.css into the stage and every font it links (url(...) relative to the tokens file).
function stageTokens(tokensPath, stage) {
  const dir = path.dirname(tokensPath);
  fs.mkdirSync(path.join(stage, 'tokens-fonts'), { recursive: true });
  const css = fs.readFileSync(tokensPath, 'utf8').replace(/url\((['"]?)([^'")]+)\1\)/g, (m, q, ref) => {
    if (/^(data:|https?:)/.test(ref)) return m;
    const src = path.resolve(dir, ref);
    if (!fs.existsSync(src)) { console.error(`render: font in tokens.css not found: ${ref}`); return m; }
    const name = path.basename(src);
    fs.copyFileSync(src, path.join(stage, 'tokens-fonts', name));
    return `url("tokens-fonts/${name}")`;
  });
  fs.writeFileSync(path.join(stage, 'tokens.css'), css);
}

// Merge the vars over the schema defaults; image vars that point at real files are copied into the stage.
export function resolveVars(schema, given, baseDir, stage) {
  const v = {};
  for (const [k, spec] of Object.entries(schema.vars)) v[k] = spec.default ?? '';
  Object.assign(v, given);
  for (const [k, spec] of Object.entries(schema.vars)) {
    if (spec.type !== 'image' && spec.type !== 'images') continue;
    const refs = spec.type === 'images' ? String(v[k] || '').split('|') : [String(v[k] || '')];
    const out = refs.map((ref, i) => {
      ref = ref.trim(); if (!ref) return '';
      const src = path.isAbsolute(ref) ? ref : path.resolve(baseDir, ref);
      if (!fs.existsSync(src)) { console.error(`render: image for "${k}" not found: ${ref} (left blank)`); return ''; }
      if (!stage) return src;
      fs.mkdirSync(path.join(stage, 'assets'), { recursive: true });
      const name = `${k}-${i}${path.extname(src).toLowerCase()}`;
      fs.copyFileSync(src, path.join(stage, 'assets', name));
      return `assets/${name}`;
    });
    v[k] = out.join('|');
  }
  return v;
}

export function stageComp({ comp, vars, varsDir, zone, size, duration, tokens }) {
  const schema = readSchema(comp);
  const [W, H] = size.split('x').map(Number);
  const stage = fs.mkdtempSync(path.join(os.tmpdir(), `cs-${comp}-`));
  fs.cpSync(path.join(COMPS, comp), stage, { recursive: true });
  fs.mkdirSync(path.join(stage, 'core', 'fonts'), { recursive: true });
  for (const f of ['cs.css', 'cs.js']) fs.copyFileSync(path.join(MOTION, 'core', f), path.join(stage, 'core', f));
  for (const f of fs.readdirSync(path.join(MOTION, 'core', 'fonts'))) if (f.endsWith('.ttf')) fs.copyFileSync(path.join(MOTION, 'core', 'fonts', f), path.join(stage, 'core', 'fonts', f));
  fs.copyFileSync(path.join(MOTION, 'node_modules', 'gsap', 'dist', 'gsap.min.js'), path.join(stage, 'core', 'gsap.min.js'));
  stageTokens(tokens, stage);
  const v = resolveVars(schema, vars, varsDir, stage);
  v.zone = zone;
  let html = fs.readFileSync(path.join(stage, 'index.html'), 'utf8');
  html = html.replace(/data-width="\d+"/, `data-width="${W}"`).replace(/data-height="\d+"/, `data-height="${H}"`)
    .replace(/data-duration="[\d.]+"/, `data-duration="${duration}"`)
    .replace('<script src="core/cs.js"></script>', `<script>window.__CS_VARS = ${JSON.stringify(v).replace(/</g, '\\u003c')};</script>\n<script src="core/cs.js"></script>`);
  fs.writeFileSync(path.join(stage, 'index.html'), html);
  return stage;
}

function parseArgs(argv) {
  const a = {};
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (!k.startsWith('--')) fail(`unexpected argument: ${k}`);
    const key = k.slice(2);
    if (['list', 'keep'].includes(key)) a[key] = true; else a[key] = argv[++i];
  }
  return a;
}

// Check the options and stage the comp. Returns what a HyperFrames run needs.
export function prepare(opts) {
  const schema = readSchema(opts.comp);
  const zone = opts.zone || schema.zones[0];
  if (!schema.zones.includes(zone)) fail(`${opts.comp} has no zone "${zone}" (it has ${schema.zones.join(', ')})`);
  const size = opts.size || (schema.kind === 'long' ? '1920x1080' : '1080x1920');
  if (!SIZES.includes(size)) fail(`--size must be ${SIZES.join(' or ')}`);
  const duration = parseFloat(opts.duration || schema.duration || 4);
  if (!(duration > 0 && duration <= 120)) fail('--duration must be between 0 and 120 seconds');
  let vars = opts.varsObject || {}, varsDir = opts.varsDir || process.cwd();
  if (opts.vars) {
    if (!fs.existsSync(opts.vars)) fail(`vars file not found: ${opts.vars}`);
    vars = JSON.parse(fs.readFileSync(opts.vars, 'utf8')); varsDir = path.dirname(path.resolve(opts.vars));
  }
  const out = path.resolve(opts.out || `${opts.comp}.webm`);
  const stage = stageComp({ comp: opts.comp, vars, varsDir, zone, size, duration, tokens: resolveTokens(opts.tokens) });
  fs.mkdirSync(path.dirname(out), { recursive: true });
  const bin = path.join(MOTION, 'node_modules', '.bin', 'hyperframes');
  if (!fs.existsSync(bin)) fail('HyperFrames is not installed. Run "npm install" in motion/.');
  const args = ['render', stage, '-o', out, '--format', 'webm', '--fps', String(opts.fps || 30), '--quality', opts.quality || 'high', '--quiet'];
  return { bin, args, out, stage, env: { ...process.env, HYPERFRAMES_NO_TELEMETRY: '1' } };
}

function finish(p, status, log, keep) {
  if (!keep) fs.rmSync(p.stage, { recursive: true, force: true });
  const ok = status === 0 && fs.existsSync(p.out) && fs.statSync(p.out).size > 1000;
  if (!ok) console.error(String(log || '').slice(-1200));
  return { ok, out: p.out, stage: keep ? p.stage : null };
}

export function render(opts) {
  const p = prepare(opts);
  const res = spawnSync(p.bin, p.args, { env: p.env, maxBuffer: 1 << 26 });
  return finish(p, res.status, String(res.stdout || '') + String(res.stderr || ''), opts.keep);
}

export function renderAsync(opts) {
  const p = prepare(opts);
  return new Promise((resolve) => {
    const child = spawn(p.bin, p.args, { env: p.env });
    let log = '';
    child.stdout.on('data', (d) => { log = (log + d).slice(-4000); });
    child.stderr.on('data', (d) => { log = (log + d).slice(-4000); });
    child.on('close', (code) => resolve(finish(p, code, log, opts.keep)));
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const a = parseArgs(process.argv.slice(2));
  if (a.list) { console.log(JSON.stringify(listComps(), null, 2)); process.exit(0); }
  if (!a.comp) fail('pass --comp <name> (or --list)');
  const r = render(a);
  if (!r.ok) fail(`render failed for ${a.comp}`);
  console.log(r.out);
  if (r.stage) console.error(`render: staged files kept in ${r.stage}`);
}
