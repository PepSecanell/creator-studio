"""spec.json -> final.mp4 (1080x1920, 30 fps, AAC 48 kHz, -14 LUFS)."""
from __future__ import annotations

from pathlib import Path


from . import brand as brand_mod
from . import conform, layouts, reframe, safezones, schemas, sound, spec as spec_mod
from .config import Config
from .render import cards, captions, track
from .util import StudioError, ffmpeg, probe, read_json, write_json
from .words import to_output_time

SIZE = (1080, 1920)
FPS = 30
END_SECONDS = 1.8


def resolve(base: Path, p: str) -> Path:
    q = Path(p)
    return q if q.is_absolute() else (base / q)


def _seg_clip(seg: dict, src: Path, info: dict, trk, brand: dict, out: Path, work: Path, idx: int) -> None:
    W, H = SIZE
    d = seg["end"] - seg["start"]
    layout = seg.get("layout", "face")
    rect = layouts.video_rect(layout, SIZE)
    ground = brand["palette"]["ground"].lstrip("#")
    args: list = []
    fg: list[str] = []
    inputs_after = 0
    if rect:
        x, y, cw, ch = reframe.window(trk, seg["start"], seg["end"], info["width"], info["height"],
                                      rect[2] / rect[3], seg.get("zoom", 1.0))
        args += ["-ss", f"{seg['start']:.3f}", "-t", f"{d:.3f}", "-i", src]
        fg.append(f"[0:v]crop={cw}:{ch}:{x}:{y},scale={rect[2]}:{rect[3]}:flags=lanczos,setsar=1,fps={FPS},format=yuv420p[v]")
        inputs_after = 1
    panel_img = None
    if layout in ("graphic", "title", "split"):
        panel_img = cards.panel(SIZE, layout, seg.get("text", ""), brand, region=rect)
        pp = work / f"panel_{idx:02d}.png"
        panel_img.save(pp)
        args += ["-loop", "1", "-framerate", str(FPS), "-t", f"{d:.3f}", "-i", pp]
    if layout == "graphic":
        fg.append(f"[0:v]fps={FPS},format=yuv420p[v]")
    elif layout == "split":
        fg.append(f"color=c=0x{ground}:s={W}x{H}:r={FPS}:d={d:.3f}[bg];[bg][v]overlay=0:{rect[1]}[b];"
                  f"[b][{inputs_after}:v]overlay=0:0,format=yuv420p[v]")
    elif layout == "title":
        fg.append(f"[v][{inputs_after}:v]overlay=0:0,format=yuv420p[v]")
    ffmpeg([*args, "-filter_complex", ";".join(fg), "-map", "[v]", "-an", "-t", f"{d:.3f}", "-r", str(FPS),
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-pix_fmt", "yuv420p", out], what=f"segment {idx}")


def _graphics(spec: dict, brand: dict, out_words: list[dict], total: float, safe: tuple) -> tuple[list, list[str], list]:
    """Layers for the graphics track plus warnings and the text boxes drawn (for the safe zone report)."""
    look, pal, fonts = brand["look"], brand["palette"], brand["fonts"]
    layers, warns, boxes = [], [], {}
    hook = spec.get("hook") or {}
    if hook.get("text"):
        img, box = cards.hook_card(SIZE, hook["text"], look, pal, fonts, safe, hook.get("emphasis", ""))
        if img is not None:
            layers.append((0.0, min(float(hook.get("seconds", 2.5)), total), img))
            boxes["hook card"] = box
    if spec.get("captions", True) and look.get("captions"):
        cap = look["captions"]
        off = spec.get("caption_off", [])
        case = brand["editing"]["caption_case"]
        for ch in captions.chunks(out_words, int(cap.get("max_words", 4))):
            if any(a - 0.01 <= ch["s"] and ch["e"] <= b + 0.01 for a, b in off):
                continue
            texts = [w["w"] for w in ch["words"]]
            if layouts.layout_at(spec.get("segments", []), ch["s"]) == "split":
                y = int(SIZE[1] * layouts.SPLIT_SEAM)   # on the seam, never over the face
            else:
                y = int(SIZE[1] * cap.get("y", 0.68))
            cx, mw = (safe[0] + safe[2]) // 2, safe[2] - safe[0]
            img, box = captions.render(SIZE, texts, spec.get("keywords", []), look, pal, fonts, case, y_center=y, center_x=cx, max_width=mw)
            dx, dy = safezones.clamp(box, safe)
            if dy:
                img, box = captions.render(SIZE, texts, spec.get("keywords", []), look, pal, fonts, case, y_center=y + dy, center_x=cx, max_width=mw)
            layers.append((ch["s"], ch["e"], img))
            boxes["captions"] = box
    return layers, warns, boxes


def build(cfg: Config, edit_dir: Path, spec_path: Path | None = None) -> dict:
    """Render final.mp4 into edit_dir. Returns a report dict (also saved to work/build_report.json)."""
    edit_dir = Path(edit_dir)
    spec_path = spec_path or edit_dir / "spec.json"
    spec = read_json(spec_path)
    schemas.check(spec, "short-spec/v1")
    brand = brand_mod.build(cfg)
    work = edit_dir / "work"
    work.mkdir(parents=True, exist_ok=True)
    warnings: list[str] = []

    src = resolve(spec_path.parent, spec["source"])
    if not src.exists():
        raise StudioError(f"Source video not found: {src}")
    conformed = conform.conform(src, work / "conformed.mp4", unmirror=spec.get("unmirror", False),
                              audio=resolve(spec_path.parent, spec["audio"]) if spec.get("audio") else None)
    info = probe(conformed)
    trk = reframe.face_track(conformed)
    if not trk:
        warnings.append("No face tracking (opencv missing or no face found): framing is centred.")

    segs = []
    for s in spec["segments"]:
        d = spec_mod.snap(s["end"] - s["start"])
        segs.append({**s, "end": round(s["start"] + d, 3)})
    clips = []
    for i, s in enumerate(segs):
        clip = work / f"clip_{i:02d}.mp4"
        _seg_clip(s, conformed, info, trk, brand, clip, work, i)
        clips.append(clip)

    content = sum(s["end"] - s["start"] for s in segs)
    end = spec.get("end")
    end_on = end is not None and brand["look"].get("end_card") is not None
    if end_on:
        ep = work / "end_card.png"
        cta = (end or {}).get("cta", "")
        if cta is True:  # creative.json may say cta: true, meaning the brand call to action
            cta = brand["voice"].get("cta", "")
        elif not isinstance(cta, str):
            cta = ""
        cards.end_card(SIZE, brand, (end or {}).get("line", ""), cta).convert("RGB").save(ep)
        ec = work / "clip_end.mp4"
        ffmpeg(["-loop", "1", "-framerate", str(FPS), "-t", f"{END_SECONDS}", "-i", ep, "-vf", f"fps={FPS},format=yuv420p",
                "-c:v", "libx264", "-preset", "veryfast", "-crf", "14", "-pix_fmt", "yuv420p", ec], what="end card")
        clips.append(ec)
    total = content + (END_SECONDS if end_on else 0.0)

    lst = work / "clips.txt"
    lst.write_text("".join(f"file '{c}'\n" for c in clips))
    base = work / "base.mp4"
    ffmpeg(["-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", base], what="join segments")

    out_words = to_output_time(spec["words"], segs)
    safe = safezones.safe_box(spec.get("platforms"))
    layers, gwarn, boxes = _graphics(spec, brand, out_words, total, safe)
    warnings += gwarn
    warnings += safezones.violations(boxes, spec.get("platforms"))
    sfx_list: list[tuple[str, float]] = []
    if brand["editing"]["sfx"]:
        if spec.get("hook", {}).get("text"):
            sfx_list.append(("pop", 0.05))
        t = 0.0
        for a, b in zip(segs, segs[1:]):
            t += a["end"] - a["start"]
            if a.get("layout") != b.get("layout"):
                sfx_list.append(("whoosh", max(0.0, t - 0.15)))
    report = finish(cfg, brand, spec, edit_dir, conformed, segs, base, total, layers, SIZE, sfx_list, edit_dir)
    report["warnings"] = warnings + report["warnings"]
    report["layouts"] = [s.get("layout") for s in segs]
    if total > brand["editing"]["max_short_seconds"]:
        report["warnings"].append(f"Video is {total:.0f}s, over the {brand['editing']['max_short_seconds']}s limit in brand.json.")
    report["warnings"] += safezones.length_ok(total, spec.get("platforms"))
    write_json(work / "build_report.json", report)
    return report


def finish(cfg, brand, spec, edit_dir, voice_src, segs, base, total, layers, size, sfx_list, out_dir) -> dict:
    """Shared tail of every build: graphics + motion overlays on the joined video, audio mix, loudness, final mux."""
    work = Path(edit_dir) / "work"
    warnings: list[str] = []
    glist = track.build(work / "graphics", size, total, layers)
    inputs = ["-i", base, "-f", "concat", "-safe", "0", "-i", glist]
    fc = [f"[1:v]fps={FPS},format=rgba[g];[0:v][g]overlay=eof_action=pass[v0]"]
    last, used = "v0", []
    for n, o in enumerate(spec.get("overlays", [])):
        f = resolve(Path(edit_dir), o["file"]) if o.get("file") else None
        if not f or not f.exists():
            warnings.append(f"Motion comp {o.get('comp')} has no rendered file; skipped. Run ./studio render motion.")
            continue
        inputs += ["-c:v", "libvpx-vp9", "-i", f] if f.suffix == ".webm" else ["-i", f]
        k = 2 + len(used)
        at, dur = o["at"], o["duration"]
        fc.append(f"[{k}:v]format=yuva420p,setpts=PTS-STARTPTS+{at}/TB[o{n}];"
                  f"[{last}][o{n}]overlay=enable='between(t,{at},{at + dur})':eof_action=pass[v{n + 1}]")
        last = f"v{n + 1}"
        used.append(o["comp"])
    video = work / "video.mp4"
    ffmpeg([*inputs, "-filter_complex", ";".join(fc), "-map", f"[{last}]", "-t", f"{total:.3f}", "-an", "-r", str(FPS),
            "-c:v", "libx264", "-preset", "medium", "-crf", "17", "-pix_fmt", "yuv420p", video], what="compose")
    ed = brand["editing"]
    music = sound.pick_music(Path(brand["brand_dir"]), spec.get("id", "")) if (ed["music"] and spec.get("music", True)) else None
    raw_audio = sound.mix(voice_src, segs, total, work / "audio_raw.wav", music=music, sfx=sfx_list,
                          sfx_dir=cfg.workspace / ".cache" / "sfx")
    audio = sound.normalise(raw_audio, work / "audio.wav")
    final = Path(out_dir) / "final.mp4"
    ffmpeg(["-i", video, "-i", audio, "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
            "-ar", "48000", "-shortest", "-movflags", "+faststart", final], what="final mux")
    return {"out": str(final), "duration": round(total, 2), "overlays_used": used, "music": bool(music), "warnings": warnings}
