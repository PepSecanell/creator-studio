#!/usr/bin/env node
// zone-check.mjs: does a rendered comp stay inside its zone?
//
//   node motion/zone-check.mjs beat.webm split|full
//
// Content = a pixel with alpha > 110. More than 40 content pixels in a reserved area on any sampled
// frame is a FAIL (exit 1). Reserved = everything outside the zone box, plus, for vertical full, the
// like and comment column (x > 900, y > 900) that the platforms draw over the video.
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { frames } from './lib/frames.mjs';

const BOXES = {
  '1080x1920': { split: [60, 240, 1020, 880], full: [60, 240, 1020, 1150], column: [900, 900, 1080, 1920] },
  '1920x1080': { split: [96, 72, 1000, 1008], full: [96, 72, 1824, 1008] },
};
const ALPHA = 110, LIMIT = 40;

export function zoneCheck(file, zone, fps = 4) {
  const f = frames(file, fps), key = `${f.w}x${f.h}`, b = BOXES[key];
  if (!b) return { ok: false, msg: `unknown frame size ${key}` };
  if (!f.frames.length) return { ok: false, msg: 'no frames decoded' };
  const box = b[zone], col = zone === 'full' ? b.column : null;
  let worst = { n: 0, t: 0 };
  f.frames.forEach((buf, i) => {
    let n = 0;
    for (let y = 0; y < f.h; y++) {
      const inY = y >= box[1] && y < box[3];
      for (let x = 0; x < f.w; x++) {
        if (buf[(y * f.w + x) * 4 + 3] <= ALPHA) continue;
        const inBox = inY && x >= box[0] && x < box[2];
        const inCol = col && x >= col[0] && y >= col[1];
        if (!inBox || inCol) n++;
      }
    }
    if (n > worst.n) worst = { n, t: i / fps };
  });
  const ok = worst.n <= LIMIT;
  return { ok, msg: ok ? `ok (${f.frames.length} frames)` : `${worst.n} px outside the ${zone} zone at ${worst.t.toFixed(2)}s` };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [file, zone] = process.argv.slice(2);
  if (!file || !['split', 'full'].includes(zone)) { console.error('usage: node zone-check.mjs <file.webm> split|full'); process.exit(2); }
  const r = zoneCheck(file, zone);
  console.log(`${r.ok ? 'PASS' : 'FAIL'} ${path.basename(file)}: ${r.msg}`);
  process.exit(r.ok ? 0 : 1);
}
