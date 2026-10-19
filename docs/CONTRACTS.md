# Contracts

Every part of the studio talks to every other part through files. This page is the single source of
truth for those files. If you change one, change it here first.

Working name of the project is `creator-studio` (final name chosen before launch, so never hardcode
the repo name in user facing text: read `brand.json` → `name` for anything the user sees).

## 0. Where things live

```
<repo>/
  brand/brand.json        the ONLY file a user edits (plus dropping a logo next to it)
  brand/logo.png          optional, transparent PNG
  looks/<style>/          look presets: look.json, tokens.css, fonts/ (OFL only)
  cstudio/                Python pipeline (package), CLI entry `./studio`
  motion/                 HyperFrames motion graphics kit (brand tokened components)
  apps/studio/            Tauri 2 desktop app: ideas, cards, scripts, film day, packaging
  apps/recorder/          Native macOS app (Swift): teleprompter, takes, screen + camera
  .claude/agents/         creative-director (Opus), editor (Sonnet), qa (Sonnet)
  .claude/skills/         edit-short, edit-long, package, motion
  workspace/              ALL user data (gitignored). Override with $CREATOR_STUDIO_WORKSPACE
```

`./studio setup` writes `~/.config/creator-studio/config.json`:

```json
{ "schema": "cs-config/v1", "repo": "/abs/path/to/repo", "workspace": "/abs/path/to/repo/workspace" }
```

Both desktop apps and the CLI find everything from this file (env `CREATOR_STUDIO_CONFIG` overrides
its path, `CREATOR_STUDIO_WORKSPACE` overrides the workspace). Nothing anywhere may contain an absolute
path to a specific person's machine.

## 1. brand/brand.json (`creator-brand/v1`)

```json
{
  "schema": "creator-brand/v1",
  "name": "Northwind",
  "tagline": "Small builds, explained in a minute",
  "language": "en",
  "style": "notebook",
  "palette": {
    "ground": "#F7F5EF", "ink": "#1F2433", "accent": "#FFD84D",
    "accent_2": "#2F6BFF", "muted": "#8A8F9C", "on_accent": "#1F2433"
  },
  "fonts": { "title": null, "caption": null, "body": null },
  "logo": "logo.png",
  "voice": {
    "who": "A designer who builds tiny tools at night",
    "audience": "People who want to make their first app",
    "topics": ["no-code", "AI tools", "side projects"],
    "tone": ["plain words", "warm", "a bit dry"],
    "banned": ["game changer", "unlock", "dive in"],
    "cta": "Follow for one small build a day",
    "link": "example.com"
  },
  "handles": { "youtube": "@northwind", "tiktok": "@northwind", "instagram": "@northwind", "x": "@northwind", "linkedin": "" },
  "schedule": { "shorts_per_day": 2, "long_per_week": 1, "timezone": "UTC" },
  "editing": { "keep_pauses": false, "music": true, "sfx": true, "caption_case": "sentence", "max_short_seconds": 45 }
}
```

Rules:
- `style` picks `looks/<style>/`. Shipped looks: `notebook`, `bold`, `editorial`.
- Font fields `null` mean "use the look's fonts". A path is relative to `brand/`.
- Palette keys are fixed (6 roles). Looks map roles to their parts; brands never name parts.
- Loader: `cstudio.brand.load()` returns a merged object (look defaults < brand values), validates hex
  colours and font files, and fails with a plain sentence if something is wrong.
- `voice` is injected into every LLM prompt (Studio app and agents) instead of any hardcoded persona.

## 2. looks/<style>/look.json (`creator-look/v1`)

```json
{
  "schema": "creator-look/v1", "id": "notebook", "label": "Notebook",
  "fonts": { "title": "fonts/Newsreader-SemiBold.ttf", "caption": "fonts/Inter-Bold.ttf", "body": "fonts/Inter-Regular.ttf", "hand": "fonts/Caveat-Bold.ttf" },
  "palette_defaults": { "ground": "#F7F5EF", "ink": "#22305A", "accent": "#FBE27A", "accent_2": "#E8553D", "muted": "#8A8F9C", "on_accent": "#22305A" },
  "captions": { "shape": "pill|plain|underline|box", "fill": "ground", "text": "ink", "emphasis": "accent", "emphasis_mode": "marker|colour|box", "size": 64, "y": 0.68, "max_words": 4 },
  "hook_card": { "shape": "strip|block|none", "fill": "accent", "text": "on_accent" },
  "end_card": { "fill": "ground", "text": "ink", "show_logo": true, "show_cta": true },
  "layouts": ["face", "split", "graphic", "title"],
  "cover": { "layout": "face_words", "max_words": 5 },
  "motion": "tokens.css"
}
```

`tokens.css` defines CSS custom properties consumed by `motion/`:
`--cs-ground --cs-ink --cs-accent --cs-accent-2 --cs-muted --cs-on-accent --cs-font-title --cs-font-body --cs-radius --cs-stroke`.
`./studio brand build` writes `workspace/.brand/tokens.css` (look tokens with the brand palette and
fonts applied) and `workspace/.brand/brand.resolved.json`. Every renderer reads those two files.

## 3. Workspace layout

```
workspace/
  .brand/                         resolved brand (generated, never edited)
  ideas/shorts.json               {"schema":"ideas/v1","items":[{id,title,angle,format,created,status}]}
  ideas/long.json
  shorts/week-NN/cards.json       {"schema":"cards/v1","week":"2026-W42","cards":[CARD...]}
  long/<slug>/video.json          {"schema":"long-video/v1", slug,title,format,mode,map[],script,thumbnail_ideas[],description,status}
  handoff/next_take.json          HANDOFF (Studio writes, Recorder reads)
  handoff/next_recording.json     HANDOFF for long videos
  takes/shorts/<YYYY-MM-DD>-<card_id>-take-<n>/   Recorder output for Shorts
  takes/long/<slug>/take-<n>/                     Recorder output for long videos
  edits/shorts/<card_id>/         editor output
  edits/long/<slug>/
  kits/<YYYY-MM-DD>/              posting kit
  logs/
```

### CARD (one Short)

```json
{
  "id": "w42-03", "title": "Ship it ugly", "format": "same-idea-3-ways",
  "mode": "cards",                         // "cards" = scriptless talking points, "script" = word for word
  "hook": { "idea": "...", "takes": ["first words A", "first words B"] },
  "points": ["...", "..."], "payoff": "...", "end_line": "...",
  "script": null,                          // full text when mode == "script"
  "facts": [],                             // things that must be true, checked at edit time
  "status": "to_film|filmed|editing|ready|posted",
  "setup": { "urls": [], "apps": [] }      // what the Recorder opens before the take (optional)
}
```

Statuses: ideas `new|kept|killed|used`; long videos `draft|to_film|filmed|editing|ready|posted`,
long `mode` is `map|script|screen`. `long-video/v1` may also carry `idea`, `title_options`,
`chapters` (`[{start, time, title}]`), `facts`, `setup`; `map` items are `{title, detail}` (plain
strings are accepted too).

`workspace/.brand/brand.resolved.json` (`brand-resolved/v1`) is the merged brand: brand.json values
over look defaults, with font paths made absolute, plus the look's `captions`, `hook_card`,
`end_card`, `layouts`, `cover`. `workspace/.brand/preview.png` is the preview sheet.

### HANDOFF (`handoff/v1`)

```json
{
  "schema": "handoff/v1", "kind": "short|long", "id": "w42-03", "title": "Ship it ugly",
  "mode": "cards|script|screen", "teleprompter": "text shown in the prompter",
  "points": ["..."], "out_dir": "/abs/workspace/takes/shorts/2026-10-19-w42-03-take-1",
  "created": "2026-10-19T09:00:00Z", "brand": "Northwind",
  "setup": { "urls": [], "apps": [] }
}
```

The Recorder polls `handoff/` every 2 s, ignores files older than 6 h or with an `id`+`created`
pair it already used, and writes into `out_dir` (creating it).

### TAKE folder (`take/v1`), written by the Recorder

```
take.mov            camera (Shorts: 9:16 crop source; long: camera track)
screen.mov          optional, screen capture (long / screen mode)
mic.wav             optional, separate mic track
take.json           {"schema":"take/v1","id":"w42-03","kind":"short","take":1,"mode":"cards",
                     "started":"iso","duration_s":41.2,"fps":30,"files":{"camera":"take.mov","screen":null},
                     "crop":{"x":0,"y":0,"w":1080,"h":1920,"mirrored":false},"clicks":"clicks.json|null"}
```

Optional keys the Recorder also writes: `title`, `stopped_by`, `files.mic` (`mic.wav`, written a few
seconds after the take ends), `files.composite` (`composite.mov`: screen with the camera bubble,
phone and zoom painted in), `files.preview` (`short.mov`: the framed 9:16 export of a Short).
Extra files that may appear: `iphone.mov`, `cursor.json`, `zoom.json`, `layout.json`.

For Shorts the pipeline uses `files.preview` when present, otherwise `take.mov` plus `crop`.
`take.mov` is always the camera only, and `files.camera` is null on a screen take with no camera.

### EDIT folder, written by the editing agents

```
creative.json       creative director output (layouts per beat, motion comps, hook, keywords, cover)
spec.json           build spec for cstudio.build_short / build_long (mechanical, derived from creative.json)
final.mp4           1080x1920 30 fps (Shorts) or 1920x1080 (long), AAC 48 kHz, -14 LUFS
cover.jpg           1080x1920 (Shorts) / thumbnail.jpg 1280x720 (long)
POSTING.md          per platform title, caption, hashtags, pinned comment (no dashes in text)
status.json         {"schema":"edit-status/v1","state":"queued|editing|ready_for_review|needs_you|failed|approved|posted","updated":"iso","notes":"","checks":{}}
checks/             frames the QA agent looked at
```

### Work files and specs

Inside an edit folder, `work/` holds the intermediate files: `words.json` (word timings),
`cut.json` (`cut/v1`: kept segments in source time and the output duration), `take_ref.json`
(`source`, `screen`, `audio`, `unmirror`: which take files the build uses). `creative.json` is
`creative/v1` (see `.claude/agents/creative-director.md`; beats may carry `text` for split, graphic
and title layouts). `spec.json` is `short-spec/v1` or `long-spec/v1`, generated by
`./studio spec from-creative` and documented field by field in `cstudio/README.md`.

### POSTING KIT (`kit/v1`), `kits/<date>/kit.json`

```json
{ "schema": "kit/v1", "date": "2026-10-19", "brand": "Northwind",
  "items": [ { "id": "w42-03", "platform": "tiktok|youtube_shorts|reels|youtube|x|linkedin|threads",
               "action": "post", "file": "w42-03-tiktok.mp4", "cover": "w42-03-cover.jpg",
               "title": "", "caption": "", "hashtags": [], "pinned_comment": "", "post_at": "17:00" } ] }
```

Nothing in this project posts anything to any platform. The kit is files for a human to post.

## 4. CLI (`./studio`)

```
./studio setup            install deps (brew/apt), venv, whisper model, hyperframes, writes config
./studio doctor           checks everything, prints what is missing in plain words
./studio brand build      resolve brand → workspace/.brand/
./studio brand preview    renders a preview sheet (captions, hook, end card, cover, 3 motion comps)
./studio edit short <id>  runs the edit agents headless on that Short (claude -p)
./studio edit long <slug>
./studio edit pending     every take without a finished edit
./studio kit [date]       builds the posting kit
./studio demo             runs the bundled demo take end to end
```

## 5. Models

Creative calls (design vision, beat plan, cover idea) use Opus. Everything mechanical uses Sonnet.
Both are configurable in `brand.json` → `models` (optional: `{"creative": "opus", "mechanical": "sonnet"}`).
All LLM work goes through the user's own Claude Code login (`claude -p`). No API keys are stored.

## 6. Unattended runs

Overnight batch editing is out of scope here. Any scheduler (cron, launchd) can run
`./studio edit pending`.
