"""long-spec/v1 -> final.mp4 (1920x1080, 30 fps) plus chapters.txt.

Camera only: the face fills the frame. With a screen recording: the screen is the picture and the camera sits in
a round bubble in a corner. Lower thirds and chapter cards come from the spec. Captions are optional.
"""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

from . import brand as brand_mod
from . import conform, reframe, schemas, spec as spec_mod
from .build_short import FPS, finish, resolve
from .config import Config
from .render import cards, captions
from .util import StudioError, ffmpeg, probe, read_json, write_json
from .words import to_output_time

SIZE = (1920, 1080)
BUBBLE = 360
CHAPTER_SECONDS = 2.0


def fmt_time(t: float) -> str:
    t = int(t)
    h, m, s = t // 3600, (t % 3600) // 60, t % 60
    return f"{h}:{m:02d}:{s:02d}" if h else f"{m}:{s:02d}"


def chapters_text(chapters: list[dict]) -> str:
    """YouTube chapter lines. The first chapter must start at 0:00."""
    ch = sorted(chapters, key=lambda c: c["at"])
    if not ch or ch[0]["at"] > 0.5:
        ch = [{"title": "Intro", "at": 0.0}] + ch
    ch[0] = {**ch[0], "at": 0.0}
    return "\n".join(f"{fmt_time(c['at'])} {c['title']}" for c in ch) + "\n"


def _circle_mask(path: Path, size: int) -> Path:
    m = Image.new("L", (size * 4, size * 4), 0)
    ImageDraw.Draw(m).ellipse((0, 0, size * 4 - 1, size * 4 - 1), fill=255)
    m.resize((size, size), Image.LANCZOS).save(path)
    return path


def build(cfg: Config, edit_dir: Path, spec_path: Path | None = None) -> dict:
    edit_dir = Path(edit_dir)
    spec_path = spec_path or edit_dir / "spec.json"
    spec = read_json(spec_path)
    schemas.check(spec, "long-spec/v1")
    brand = brand_mod.build(cfg)
    work = edit_dir / "work"
    work.mkdir(parents=True, exist_ok=True)
    W, H = SIZE
    cam_src = resolve(spec_path.parent, spec["source"])
    if not cam_src.exists():
        raise StudioError(f"Camera video not found: {cam_src}")
    cam = conform.conform(cam_src, work / "conformed.mp4", unmirror=spec.get("unmirror", False),
                          audio=resolve(spec_path.parent, spec["audio"]) if spec.get("audio") else None)
    cinfo = probe(cam)
    screen = None
    if spec.get("screen"):
        sp = resolve(spec_path.parent, spec["screen"])
        if not sp.exists():
            raise StudioError(f"Screen recording not found: {sp}")
        screen = conform.conform(sp, work / "screen_conformed.mp4")
    trk = reframe.face_track(cam)
    bubble = spec.get("bubble", {})
    corner = bubble.get("corner", "bottom-right")
    bsize = int(bubble.get("size", BUBBLE))
    mask = _circle_mask(work / "bubble_mask.png", bsize)
    margin = 48
    bx = W - bsize - margin if "right" in corner else margin
    by = H - bsize - margin if "bottom" in corner else margin

    segs = []
    for s in spec["segments"]:
        d = spec_mod.snap(s["end"] - s["start"])
        segs.append({**s, "end": round(s["start"] + d, 3)})
    clips = []
    for i, s in enumerate(segs):
        d = s["end"] - s["start"]
        out = work / f"clip_{i:02d}.mp4"
        zoom = s.get("zoom", 1.0)
        if screen:
            x, y, cw, ch = reframe.window(trk, s["start"], s["end"], cinfo["width"], cinfo["height"], 1.0, 1.3 * zoom)
            fg = (f"[0:v]scale={W}:{H}:force_original_aspect_ratio=decrease,pad={W}:{H}:(ow-iw)/2:(oh-ih)/2,setsar=1[scr];"
                  f"[1:v]crop={cw}:{ch}:{x}:{y},scale={bsize}:{bsize}:flags=lanczos,format=rgba[cam];"
                  f"[2:v]format=gray[m];[cam][m]alphamerge[bub];[scr][bub]overlay={bx}:{by},fps={FPS},format=yuv420p[v]")
            args = ["-ss", f"{s['start']:.3f}", "-t", f"{d:.3f}", "-i", screen, "-ss", f"{s['start']:.3f}", "-t", f"{d:.3f}",
                    "-i", cam, "-loop", "1", "-i", mask]
        else:
            x, y, cw, ch = reframe.window(trk, s["start"], s["end"], cinfo["width"], cinfo["height"], W / H, zoom)
            fg = f"[0:v]crop={cw}:{ch}:{x}:{y},scale={W}:{H}:flags=lanczos,setsar=1,fps={FPS},format=yuv420p[v]"
            args = ["-ss", f"{s['start']:.3f}", "-t", f"{d:.3f}", "-i", cam]
        ffmpeg([*args, "-filter_complex", fg, "-map", "[v]", "-an", "-t", f"{d:.3f}", "-r", str(FPS), "-c:v", "libx264",
                "-preset", "veryfast", "-crf", "14", "-pix_fmt", "yuv420p", out], what=f"segment {i}")
        clips.append(out)
    total = sum(s["end"] - s["start"] for s in segs)
    lst = work / "clips.txt"
    lst.write_text("".join(f"file '{c}'\n" for c in clips))
    base = work / "base.mp4"
    ffmpeg(["-f", "concat", "-safe", "0", "-i", lst, "-c", "copy", base], what="join segments")

    layers = []
    look, pal, fonts = brand["look"], brand["palette"], brand["fonts"]
    for lt in spec.get("lower_thirds", []):
        layers.append((lt["at"], lt["at"] + lt.get("duration", 4.0), cards.lower_third(SIZE, lt["text"], lt.get("subtitle", ""), brand)))
    chapters = spec.get("chapters", [])
    for n, c in enumerate(sorted(chapters, key=lambda c: c["at"]), start=1):
        layers.append((c["at"], c["at"] + CHAPTER_SECONDS, cards.chapter_card(SIZE, n, c["title"], brand)))
    if spec.get("captions", False) and look.get("captions"):
        cap = look["captions"]
        for ch in captions.chunks(to_output_time(spec.get("words", []), segs), int(cap.get("max_words", 4))):
            img, _ = captions.render(SIZE, [w["w"] for w in ch["words"]], spec.get("keywords", []), look, pal, fonts,
                                     brand["editing"]["caption_case"], y_center=int(H * 0.86))
            layers.append((ch["s"], ch["e"], img))
    report = finish(cfg, brand, spec, edit_dir, cam, segs, base, total, layers, SIZE, [], edit_dir)
    (edit_dir / "chapters.txt").write_text(chapters_text(chapters), encoding="utf-8")
    report["chapters"] = chapters_text(chapters).splitlines()
    write_json(work / "build_report.json", report)
    return report
