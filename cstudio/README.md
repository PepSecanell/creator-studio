# cstudio

The Python pipeline behind `./studio`. It turns raw takes into finished Shorts and long videos in your brand.
Files it reads and writes are described in `docs/CONTRACTS.md`.

## The editing loop (one Short)

```
./studio words <take>            transcribe -> edit/work/words.json, work/take_ref.json
./studio cut <take>              pauses, fillers, retakes, spoken cues out -> edit/work/cut.json
(creative director writes edit/creative.json)
./studio check creative <edit>/creative.json
./studio spec from-creative <edit>
./studio render motion <edit> [--only <comp>]
./studio build short <edit>      -> final.mp4
./studio cover <edit>            -> cover.jpg
./studio package <edit>          -> POSTING.md, posting.json
./studio check edit <edit>       self checks, written into status.json
./studio frames <edit> --every 1 PNG frames into <edit>/checks/ for review
./studio kit [date]              posting kit
```

`<take>` is a take folder or a card id. `<edit>` is `workspace/edits/shorts/<id>/` (or a card id).
Add `--long` (or use `build long`) for long videos. The same commands work with `edits/long/<slug>/`.

Cut cues you can say while filming: "scratch that" (drops the sentence before it) and "from the top"
(drops everything before it). Add your own under `editing.cues` in `brand.json`:
`{"undo": ["oops"], "restart": ["again from the start"]}`.

## Sources picked from a take

Shorts use `files.preview` (the framed 9:16 export) when present, else the camera file. Long videos use
`files.composite` when present, else camera plus `screen.mov` with a round camera bubble. `mic.wav` is used
for sound and transcription when present.

## creative.json (`creative/v1`)

```
vision, hook{text (max 7 words), emphasis, take}, keywords[],
beats[{from, to, layout, caption (bool), motion null|{comp, zone, vars}, text?, why}]  output time, increasing
cover{frame_at, words, emphasis}, end{line, cta}, music (bool), notes
```

## spec.json (`short-spec/v1`, `long-spec/v1`)

Built by `spec from-creative`. Times in `segments` and `words` are SOURCE seconds. Times in `overlays`,
`caption_off`, `hook`, `chapters` and `lower_thirds` are OUTPUT seconds.

| field | meaning |
| --- | --- |
| `source` | video file (absolute, or relative to the spec) |
| `audio` | optional separate sound file |
| `unmirror` | flip the picture back |
| `segments[]` | `{start, end, layout, text, zoom}`. layout is face, split, graphic or title. `text` shows on the layout panel |
| `words[]` | `{w, s, e}` word timings for captions |
| `keywords[]` | words drawn with the look's emphasis |
| `captions` | false to hide all captions |
| `caption_off[]` | `[from, to]` windows with no captions |
| `hook` | `{text, seconds, emphasis}` hook card at the start |
| `overlays[]` | `{comp, vars, zone, at, duration, file}` motion comps. `file` is the rendered webm |
| `end` | `{line, cta}` end card. `null` for no end card |
| `cover` | `{words, frame_at, emphasis}` |
| `music` | false to skip the music bed |
| `platforms` | optional list to restrict safe zones |

Long only: `screen`, `bubble{corner,size}`, `chapters[{title, at}]`, `lower_thirds[{text, subtitle, at, duration}]`.
A long build also writes `chapters.txt` in YouTube format.

## Sound

SFX are synthesised with ffmpeg. Music is never bundled: put your own files in `brand/sounds/` and set
`editing.music` to true. Output is normalised to -14 LUFS.

## Tests

`pytest` runs offline. Tests marked `slow` need ffmpeg and render video (`pytest -m "not slow"` skips them).

## Quirk: end.cta in creative.json
`creative.json` may set `end.cta` to `true`, meaning "use the brand call to action". `build short`
used to crash (`object of type 'bool' has no len()`). It now maps `true` to `brand.voice.cta` and
ignores any other non-string value.
