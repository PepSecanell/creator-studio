#!/usr/bin/env node
// lint.mjs: the motion kit's gate. Static checks only (no browser, no network), so it runs anywhere.
//
//   node motion/lint.mjs        (or ./motion/lint)
//
// Comps (motion/comps/<name>/):
//   L1 files: index.html, vars.schema.json, vars.example.json; the schema is valid; example keys exist in it
//   L2 colours come only from tokens: no #hex, rgb(), hsl() or named colours in a comp
//   L3 fonts come only from tokens: no font-family names in a comp
//   L4 nothing loads from the network: no http(s) URLs
//   L5 every var(--x) a comp uses is a --cs-* / --x-* / --t-* token or defined in that comp
//   L6 seekable: no Math.random, Date.now, setTimeout, setInterval or endless repeats (repeat: -1)
//   L7 no type below the floor (28 px) in a comp's CSS
//   L8 the comp registers through CS.comp and uses at least one masked reveal (surfaceIn, linesIn, reveal or swipe)
// Looks (looks/<id>/):
//   K1 look.json is creator-look/v1 with the required keys; every font it names exists
//   K2 tokens.css defines the 10 contract tokens; every url() it links exists
//   K3 each font family in fonts/ has its licence file next to it
// Everything (motion/, looks/, brand/):
//   S1 nothing names a real person, company, product handle or a path on someone's machine
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const MOTION = path.dirname(fileURLToPath(import.meta.url)), REPO = path.dirname(MOTION);
const problems = [];
const fail = (where, rule, msg) => problems.push(`FAIL ${rule} ${where}: ${msg}`);

const REQUIRED_TOKENS = ['--cs-ground', '--cs-ink', '--cs-accent', '--cs-accent-2', '--cs-muted', '--cs-on-accent', '--cs-font-title', '--cs-font-body', '--cs-radius', '--cs-stroke'];
const LOOK_KEYS = ['schema', 'id', 'label', 'fonts', 'palette_defaults', 'captions', 'hook_card', 'end_card', 'layouts', 'cover', 'motion'];
const VAR_TYPES = ['string', 'number', 'time', 'enum', 'image', 'images'];
const NAMED = /(?<![-\w#])(white|black|red|blue|green|yellow|orange|purple|pink|gray|grey|navy|teal|gold|silver)(?![-\w])/;

function lintComp(name) {
  const dir = path.join(MOTION, 'comps', name), where = `comps/${name}`;
  for (const f of ['index.html', 'vars.schema.json', 'vars.example.json']) if (!fs.existsSync(path.join(dir, f))) fail(where, 'L1', `missing ${f}`);
  let schema = null;
  try {
    schema = JSON.parse(fs.readFileSync(path.join(dir, 'vars.schema.json'), 'utf8'));
    if (schema.name !== name) fail(where, 'L1', `schema name "${schema.name}" is not the folder name`);
    if (!['short', 'long', 'both'].includes(schema.kind)) fail(where, 'L1', 'kind must be short, long or both');
    if (!Array.isArray(schema.zones) || !schema.zones.every((z) => ['split', 'full'].includes(z))) fail(where, 'L1', 'zones must be split and/or full');
    for (const [k, s] of Object.entries(schema.vars || {})) {
      if (!VAR_TYPES.includes(s.type)) fail(where, 'L1', `var ${k} has unknown type ${s.type}`);
      if (!s.label) fail(where, 'L1', `var ${k} has no label`);
      if (s.type === 'enum' && !(s.values || []).includes(s.default)) fail(where, 'L1', `var ${k} default is not one of its values`);
    }
    const ex = JSON.parse(fs.readFileSync(path.join(dir, 'vars.example.json'), 'utf8'));
    for (const k of Object.keys(ex)) if (!(k in schema.vars)) fail(where, 'L1', `example key ${k} is not in the schema`);
  } catch (e) { fail(where, 'L1', `bad json: ${e.message}`); }
  const html = fs.readFileSync(path.join(dir, 'index.html'), 'utf8');
  const css = (html.match(/<style>([\s\S]*?)<\/style>/g) || []).join('\n').replace(/\/\*[\s\S]*?\*\//g, '');
  const js = (html.match(/<script>([\s\S]*?)<\/script>/g) || []).join('\n');
  const code = css + '\n' + js.replace(/\/\/.*$/gm, '');
  // url(...) data URIs carry their own SVG markup (a mask or a texture), not page colours
  const plain = code.replace(/url\("data:[^"]*"\)/g, 'url()').replace(/'#[\w-]+[^']*'/g, "''");
  let m;
  // a hex colour inside a CSS declaration value, or inside a style string in the script
  for (const [, val] of (plain.match(/[a-z-]+\s*:\s*[^;{}]+/g) || []).map((d) => [d, d.split(':').slice(1).join(':')]))
    if ((m = val.match(/(^|[\s,(])#[0-9a-fA-F]{3,8}\b/))) fail(where, 'L2', `colour literal ${m[0].trim()}`);
  if ((m = plain.match(/\b(rgba?|hsla?)\(/))) fail(where, 'L2', `colour function ${m[0]}`);
  for (const line of css.split('\n')) {
    const decl = line.match(/(?:^|[;{\s])(?:color|background(?:-color)?|fill|stroke|border(?:-[a-z]+)?)\s*:\s*([^;}]*)/g) || [];
    for (const d of decl) if (NAMED.test(d.replace(/var\([^)]*\)/g, ''))) fail(where, 'L2', `named colour in "${d.trim()}"`);
  }
  if (/font-family\s*:(?!\s*var\()/.test(css)) fail(where, 'L3', 'font-family set without a token');
  if (/https?:\/\//.test(html.replace(/http:\/\/www\.w3\.org\/2000\/svg/g, ''))) fail(where, 'L4', 'loads something from the network');
  const defined = new Set((css.match(/--[\w-]+(?=\s*:)/g) || []));
  for (const u of new Set(code.match(/var\((--[\w-]+)/g) || [])) {
    const t = u.slice(4);
    if (!/^--(cs|x|t)-/.test(t) && !['--gap', '--pad'].includes(t) && !defined.has(t)) fail(where, 'L5', `uses ${t}, which is not a token`);
  }
  if (/Math\.random|Date\.now|setTimeout|setInterval|repeat:\s*-1/.test(js)) fail(where, 'L6', 'not seekable (clock, randomness or an endless repeat)');
  for (const fs_ of css.match(/font-size:\s*(\d+)px/g) || []) if (parseInt(fs_.match(/\d+/)[0], 10) < 28) fail(where, 'L7', `${fs_} is below the 28 px floor`);
  if (!/CS\.comp\(/.test(js)) fail(where, 'L8', 'does not register with CS.comp');
  if (!/CS\.(surfaceIn|linesIn|reveal|swipe)|strokeDashoffset/.test(js)) fail(where, 'L8', 'no masked reveal');
}

function lintLook(id) {
  const dir = path.join(REPO, 'looks', id), where = `looks/${id}`;
  let look;
  try { look = JSON.parse(fs.readFileSync(path.join(dir, 'look.json'), 'utf8')); } catch (e) { fail(where, 'K1', `look.json: ${e.message}`); return; }
  if (look.schema !== 'creator-look/v1') fail(where, 'K1', 'schema is not creator-look/v1');
  for (const k of LOOK_KEYS) if (!(k in look)) fail(where, 'K1', `look.json has no ${k}`);
  if (look.id !== id) fail(where, 'K1', 'id does not match the folder');
  for (const [role, f] of Object.entries(look.fonts || {})) if (f && !fs.existsSync(path.join(dir, f))) fail(where, 'K1', `font for ${role} not found: ${f}`);
  for (const [role, hex] of Object.entries(look.palette_defaults || {})) if (!/^#[0-9A-Fa-f]{6}$/.test(hex)) fail(where, 'K1', `palette ${role} is not a #RRGGBB colour`);
  const tokFile = path.join(dir, look.motion || 'tokens.css');
  if (!fs.existsSync(tokFile)) { fail(where, 'K2', 'tokens.css is missing'); return; }
  const tok = fs.readFileSync(tokFile, 'utf8');
  for (const t of REQUIRED_TOKENS) if (!new RegExp(`${t}\\s*:`).test(tok)) fail(where, 'K2', `tokens.css does not define ${t}`);
  for (const [, ref] of tok.matchAll(/url\((?!["']?data:)["']?([^"')]+)["']?\)/g)) if (!fs.existsSync(path.join(dir, ref))) fail(where, 'K2', `tokens.css links a missing file: ${ref}`);
  const fonts = fs.existsSync(path.join(dir, 'fonts')) ? fs.readdirSync(path.join(dir, 'fonts')) : [];
  for (const f of fonts.filter((x) => /\.(ttf|otf|woff2?)$/.test(x))) {
    const family = f.split('-')[0];
    if (!fonts.some((x) => x.toLowerCase() === `${family.toLowerCase()}-ofl.txt` || x.toLowerCase() === `${family.toLowerCase()}-license.txt`)) fail(where, 'K3', `${f} has no licence file (${family}-OFL.txt)`);
  }
}

// S1: no absolute path to someone's machine and no email address. Extra words to keep out (names from the
// setup a project was extracted from, for example) go one per line in a file named by $CS_SCRUB_WORDS,
// which lives outside the repo so the words themselves never ship.
const BANNED = [/\/(Users|home)\/[a-z][\w.-]+\//i, /[\w.+-]+@[\w-]+\.[a-z]{2,}/i];
if (process.env.CS_SCRUB_WORDS && fs.existsSync(process.env.CS_SCRUB_WORDS)) {
  for (const w of fs.readFileSync(process.env.CS_SCRUB_WORDS, 'utf8').split('\n').map((x) => x.trim()).filter(Boolean))
    BANNED.push(new RegExp(w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'i'));
}
function scrub(dir) {
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (['node_modules', '_previews', '.git'].includes(e.name)) continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) { scrub(p); continue; }
    if (!/\.(html|js|mjs|css|json|md|svg|txt)$/.test(e.name) || /OFL\.txt$/.test(e.name) || e.name === 'package-lock.json') continue;
    const s = fs.readFileSync(p, 'utf8');
    for (const re of BANNED) if (re.test(s)) fail(path.relative(REPO, p), 'S1', `contains ${re}`);
  }
}

const comps = fs.readdirSync(path.join(MOTION, 'comps'), { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
comps.forEach(lintComp);
const looks = fs.readdirSync(path.join(REPO, 'looks'), { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
looks.forEach(lintLook);
[MOTION, path.join(REPO, 'looks'), path.join(REPO, 'brand')].forEach(scrub);

problems.forEach((p) => console.log(p));
console.log(`lint: ${comps.length} comps, ${looks.length} looks, ${problems.length} problem(s)`);
process.exit(problems.length ? 1 : 0);
