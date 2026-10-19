# Motion kit

Motion graphics for Shorts and long videos, rendered with [HyperFrames](https://github.com/heygen-com/hyperframes)
(Apache 2.0) to transparent VP9 webm. The video builder lays them over the footage.

Every comp reads only the `--cs-*` tokens of the brand. Change the brand's six palette roles, or pick
another look, and every graphic follows. No comp names a colour or a font of its own.

## Setup

Node 22 or newer and ffmpeg on your PATH.

```bash
cd motion && npm install
```

## Render one

```bash
node motion/render.mjs --comp big-number --vars vars.json --out beat.webm \
     --zone split --size 1080x1920 --duration 4 [--tokens tokens.css]
```

- `--zone` is `split` (the top part, the face card sits below) or `full` (most of the frame).
- `--size` is `1080x1920` (Shorts) or `1920x1080` (long videos).
- `--duration` is the beat length in seconds. Every `*_at` var is seconds from the start of the beat.
- `--tokens` defaults to `workspace/.brand/tokens.css` (written by `./studio brand build`), then to the look
  named in `brand/brand.json`.
- Vars you leave out take the schema default. Image vars are paths, relative to the vars file.

`node motion/render.mjs --list` prints every comp as JSON: `[{name, label, kind, zones, duration, vars}]`, where
`vars` is the full schema (type, default, label, and the values of an enum).

## The comps

| comp | kind | for | variants |
|---|---|---|---|
| `big-number` | both | one number that lands | hero, odometer, bar |
| `source-card` | both | a headline or a sentence someone wrote | card, push, quote |
| `logo-row` | both | the things involved, on their words | row, hub, chips |
| `app-screen` | both | one thing changing in an app | phone, sheet, browser |
| `terminal` | both | a command and what it printed | window, light, bare |
| `bill` | both | money adding up | receipt, invoice, usage |
| `compare` | both | two options, one decision | strike, split, race |
| `chat` | both | a short exchange with an assistant | bubbles, app, prompt |
| `flow` | both | steps passing something along | line, column, loop |
| `stamp` | both | the verdict word | ink, sticker, tape |
| `lower-third` | long | who is talking | plate, dark, tag |
| `chapter-card` | long | a chapter opens | number, stack, panel |
| `progress` | long | where we are in the video | rail, corner, list |
| `callout` | long | point at a region of a screen recording | box, spotlight, arrow |
| `quote` | long | a pull quote | center, side, card |

Each comp folder holds `index.html`, `vars.schema.json` and `vars.example.json`. Images are always yours:
without one, an item shows its initial on a tile. The kit ships no logos.

## Zones

| frame | zone | graphic lives in | kept free |
|---|---|---|---|
| 1080x1920 | split | x 60 to 1020, y 240 to 880 | the platform header (y < 240), the face card and captions below |
| 1080x1920 | full | x 60 to 1020, y 240 to 1150 | the like and comment column (x > 900, y > 900), the captions below |
| 1920x1080 | split | x 96 to 1000 | the right half, for the speaker |
| 1920x1080 | full | x 96 to 1824, y 72 to 1008 | a title safe margin |

`CS.place()` fits a graphic into its zone at no more than its design size. `CS.anchor()` pins an overlay
(a lower third, the progress rail) to an edge of the zone. Check a render:

```bash
node motion/zone-check.mjs beat.webm split     # FAIL (exit 1) if more than 40 strong pixels leave the zone
```

## Craft rules the core enforces

- Six gestures only: enter, settle, reveal, emphasis, drift, exit. One ease each (`core/cs.js`).
- Surfaces and lines arrive by a masked edge, never a plain fade.
- One thing to read at a time. Comps cap their own lists (at most 4 items, short lines).
- No dead holds: the camera breathes 1 to 2 percent over a hold, and overlays drift.
- Seekable: no clocks, no randomness, no endless repeats. Any frame renders the same every time.

## Gates

```bash
./motion/lint                 # static checks on every comp and look (offline, no browser)
./motion/preview notebook     # renders every preview job in a look, runs the zone check, writes contact sheets
```

`lint` checks that comps use only tokens (no colour or font literals), load nothing from the network, stay
seekable, keep type above the floor, and that each look has its tokens, fonts and licence files. Set
`CS_SCRUB_WORDS` to a file of words (one per line) that must never appear in the kit, and lint checks them too.

`preview <look>` renders the jobs in `previews.json` (one per variant worth seeing) and writes
`_previews/<look>-shorts.png` and `_previews/<look>-long.png`. Pass `--frames <dir>` to keep every full size
frame, `--comps a,b` to render a few, `--tokens <file> --name <name>` to preview your own brand.

## Add a comp

1. Copy a comp folder. Keep the `#stage` attributes and the three script tags as they are: the renderer
   patches the size and duration and injects the vars.
2. Write the schema first. Every var has a type (`string`, `number`, `time`, `enum`, `image`, `images`), a
   default and a plain label.
3. Build inside `CS.comp('<name>', function (v, c, tl) { ... })`. Colours and fonts only from `var(--cs-*)`
   or the derived `var(--x-*)` in `core/cs.css`.
4. Add a job to `previews.json`, run `./motion/preview <look> --comps <name> --frames /tmp/f`, and look at
   the frames. Then `./motion/lint`.

## Licences

The kit is MIT. HyperFrames (Apache 2.0) and GSAP (its standard no charge licence) are npm dependencies,
not copied in. The mono face in `core/fonts/` is JetBrains Mono (SIL OFL 1.1, licence next to it).
