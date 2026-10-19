"""Cover for a Short (cover.jpg, 1080x1920) or thumbnail for a long video (thumbnail.jpg, 1280x720)."""
from __future__ import annotations

import tempfile
from pathlib import Path

from PIL import Image

from . import brand as brand_mod
from . import safezones
from .config import Config
from .render import captions
from .util import StudioError, ffmpeg, probe, read_json

SIZES = {"short": (1080, 1920), "long": (1280, 720)}


def grab_frame(video: Path, at: float, out: Path) -> Path:
    dur = probe(video)["duration"]
    ffmpeg(["-ss", f"{min(max(at, 0), max(dur - 0.1, 0)):.2f}", "-i", video, "-frames:v", "1", "-q:v", "2", out], what="frame grab")
    return out


def fill(img: Image.Image, size: tuple[int, int]) -> Image.Image:
    s = max(size[0] / img.width, size[1] / img.height)
    img = img.resize((int(img.width * s) + 1, int(img.height * s) + 1), Image.LANCZOS)
    x, y = (img.width - size[0]) // 2, (img.height - size[1]) // 2
    return img.crop((x, y, x + size[0], y + size[1]))


def make(cfg: Config, edit_dir: Path, kind: str = "short") -> Path:
    edit_dir = Path(edit_dir)
    final = edit_dir / "final.mp4"
    if not final.exists():
        raise StudioError("final.mp4 not found. Build the video first.")
    brand = brand_mod.load_cfg(cfg)
    spec = read_json(edit_dir / "spec.json") if (edit_dir / "spec.json").exists() else {}
    cov = spec.get("cover") or {}
    size = SIZES[kind]
    words = (cov.get("words") or spec.get("hook", {}).get("text") or brand["name"]).split()
    limit = int(brand["look"].get("cover", {}).get("max_words", 5))
    words = words[:limit]
    with tempfile.TemporaryDirectory() as tmp:
        frame = grab_frame(final, float(cov.get("frame_at", 1.0)), Path(tmp) / "f.jpg")
        base = fill(Image.open(frame).convert("RGBA"), size)
    look = dict(brand["look"])
    cap = dict(look.get("captions", {}))
    cap.update({"shape": "pill" if cap.get("shape") in (None, "plain", "underline") else cap["shape"],
                "size": 100 if kind == "short" else 120, "max_words": 99})
    look["captions"] = cap
    safe = safezones.safe_box(None, size) if kind == "short" else (40, 40, size[0] - 40, size[1] - 40)
    emph = [w.strip(".,!?") for w in str(cov.get("emphasis", "")).split()]
    y = int(size[1] * (0.31 if kind == "short" else 0.5))
    txt, _ = captions.render(size, words, emph, look, brand["palette"], brand["fonts"], brand["editing"]["caption_case"],
                             y_center=y, max_width=int(size[0] * 0.78))
    base.alpha_composite(txt)
    if brand.get("logo"):
        logo = Image.open(brand["logo"]).convert("RGBA")
        h = int(size[1] * 0.06)
        logo = logo.resize((int(logo.width * h / logo.height), h))
        base.alpha_composite(logo, (safe[0] + 10, safe[1] + 10))
    out = edit_dir / ("cover.jpg" if kind == "short" else "thumbnail.jpg")
    base.convert("RGB").save(out, quality=92)
    return out
