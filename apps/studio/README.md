# Studio

The desktop app for planning, writing and filming short and long videos for your brand. It reads
and writes the workspace described in `docs/CONTRACTS.md`, so the Recorder app, the editing agents
and `./studio` all see the same files. Everything you see is themed from your brand: name, colours
and fonts.

Built with Tauri 2 and plain JavaScript (no framework, no bundler).

## Run it

First run `./studio setup` in the repo root. It writes `~/.config/creator-studio/config.json`,
which tells the app where the repo and the workspace are. Without that file the app shows
"Run ./studio setup first".

Build the app:

```bash
./apps/studio/build.sh
```

The script runs `npm install` and `npx tauri build` and prints the bundle path. It never installs
into `/Applications`. Open the app from the printed path.

For development, run `npx tauri dev` inside `apps/studio`.

Needs Rust, Node 18 or newer, and the `claude` command (Claude Code) logged in. On Linux you also
need the [Tauri system libraries](https://v2.tauri.app/start/prerequisites/#linux).

## Screens

| Screen | What it does |
| --- | --- |
| Shorts | **Ideas**: generate from your brand voice and topics, keep or kill. **Week pack**: writes `shorts_per_day x 7` cards for a week, shown as a calendar with posting slots. The card editor changes any part, rewrites a part with Claude, or writes a word for word script. |
| Long videos | Idea, then 3 title options, then a map (talking points, two lines each) or a script, then 3 thumbnail ideas in different shapes, then a description with chapters. |
| Film day | What to film today, grouped so the screen and apps change as rarely as possible. **Record** writes the handoff file and opens the Recorder. **Card page** shows the card full screen, or prints it. |
| Edits | Every `workspace/edits/*/status.json` with its state, a preview, **Edit now** (runs `./studio edit short <id>` or `edit long <slug>` with a live log and a Stop button) and **Approve**. |
| Kit | The posting kit for a day: copy captions, titles and pinned comments, show the files. Nothing is posted for you. |
| Brand | The resolved brand, read only. A button runs `./studio brand preview`. |

## Cards, not scripts

A Short is a card by default (`mode: "cards"`): a hook idea, two different openings you say three
times, two or three short points, a payoff and an end line. You talk from it, so you do not sound
like you are reading. Switch a card to `script` mode when you want every word written.

## Formats live in `formats.json`

The short, long and thumbnail formats are in `apps/studio/formats.json`, not in the code. To use
your own, copy that file to `workspace/formats.json` and edit it. The workspace copy wins. Each
format has an `id`, a `name`, a `blurb`, `points: [min, max]` and a `structure` text that goes into
the prompt as is.

## How the writing is checked

Every prompt starts from `brand.resolved.json` (who is talking, who listens, topics, tone, banned
words, call to action, link, language). Every answer then goes through these checks:

- No em dashes, en dashes or " - " used as a dash.
- A list of phrases that sound written by an AI, plus the brand's own banned words.
- Numbers must be backed by the card's `facts` (small counting numbers like "3 ways" pass).
- Card shape: 2 hook takes in different shapes, the right number of points, short points, no
  script in cards mode, a script that fits the maximum Short length.

If a check fails there is one repair call. What still fails is shown on the card so you can fix it.

## The handoff to the Recorder

**Record** writes `workspace/handoff/next_take.json` (Shorts) or `next_recording.json` (long
videos) in the `handoff/v1` format, then opens the Recorder (`open -b io.github.creatorstudio.recorder`
on macOS, with the built app under `apps/recorder/build` as a fallback). On Linux it only writes
the file. The extra `setup` field carries the websites and apps the Recorder should open first.

## Tests

```bash
cd apps/studio/src-tauri
cargo test
```

They run offline. A fake `claude` script (`tests/fake_claude.sh`, chosen with
`STUDIO_CLAUDE_BIN`) stands in for Claude Code, so no account or network is needed. They cover
reading and writing the workspace files, the merge write with its conflict check, the handoff
files, card validation, prompt building from a sample brand, the gates, the repair call, the
long-video chain and the edit job runner.

## Environment variables

| Variable | Use |
| --- | --- |
| `CREATOR_STUDIO_CONFIG` | Another path for the config file. |
| `CREATOR_STUDIO_WORKSPACE` | Another workspace folder. |
| `STUDIO_CLAUDE_BIN` | Use this program instead of `claude` (tests). |
| `STUDIO_BIN` | Use this program instead of `<repo>/studio` (tests). |

## Renaming

The bundle id `io.github.creatorstudio.studio` and the product name `Studio` are only in
`src-tauri/tauri.conf.json`. The window title is set at runtime to "<brand name> Studio".
The Recorder's bundle id is the constant `RECORDER_BUNDLE_ID` in `src-tauri/src/plan.rs`.
