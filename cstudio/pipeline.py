"""Glue between a take folder and its edit folder: words, cut, motion renders."""
from __future__ import annotations

import re
from pathlib import Path

from . import brand as brand_mod
from . import cut as cut_mod
from . import motion, words as words_mod
from .config import Config
from .util import StudioError, read_json, write_json

CAMERA_NAMES = ("take.mov", "take.mp4", "camera.mov", "camera.mp4")


def kind_dir(kind: str) -> str:
    return {"short": "shorts", "long": "long"}[kind]


def take_info(take_dir: Path) -> dict:
    p = take_dir / "take.json"
    return read_json(p) if p.exists() else {}


def _take_number(p: Path) -> int:
    m = re.search(r"take-(\d+)$", p.name)
    return int(m.group(1)) if m else 0


def list_takes(cfg: Config, kind: str) -> dict[str, Path]:
    """Latest take folder per id."""
    root = cfg.takes_dir(kind_dir(kind))
    found: dict[str, Path] = {}
    if not root.is_dir():
        return found
    candidates = [p for p in root.rglob("*") if p.is_dir() and (p / "take.json").exists()]
    for p in sorted(candidates, key=_take_number):
        ident = take_info(p).get("id") or p.name
        found[ident] = p
    return found


def resolve_take(cfg: Config, kind: str, ref: str) -> Path:
    """`ref` is a take folder path or a card id / slug."""
    takes = list_takes(cfg, kind)
    if ref in takes:
        return takes[ref]
    p = Path(ref).expanduser()
    if (p / "take.json").exists():
        return p.resolve()
    raise StudioError(f"No take found for {ref!r}. Looked in {cfg.takes_dir(kind_dir(kind))}.")


def _file(take_dir: Path, key: str) -> Path | None:
    name = (take_info(take_dir).get("files") or {}).get(key)
    return take_dir / name if name and (take_dir / name).exists() else None


def sources(take_dir: Path, kind: str) -> dict:
    """Pick the picture and sound for an edit: {"source", "screen", "audio", "unmirror"}.

    Shorts use the framed export (files.preview) when there is one, else the camera file. Long videos use the
    composite (screen with camera bubble painted in) when there is one, else camera plus screen. A separate
    mic.wav is preferred for sound when it exists."""
    info = take_info(take_dir)
    mirrored = bool((info.get("crop") or {}).get("mirrored", False))
    camera = _file(take_dir, "camera") or next((take_dir / n for n in CAMERA_NAMES if (take_dir / n).exists()), None)
    screen = _file(take_dir, "screen") or ((take_dir / "screen.mov") if (take_dir / "screen.mov").exists() else None)
    out = {"source": camera, "screen": None, "unmirror": mirrored}
    if kind == "short":
        preview = _file(take_dir, "preview")
        if preview:
            out.update(source=preview, unmirror=False)
    else:
        comp = _file(take_dir, "composite")
        if comp:
            out.update(source=comp, unmirror=False)
        elif screen:
            out["screen"] = screen
            if camera is None:
                out["source"], out["screen"] = screen, None
    if out["source"] is None:
        raise StudioError(f"No camera or screen file in {take_dir}. Expected take.mov.")
    mic = _file(take_dir, "mic") or ((take_dir / "mic.wav") if (take_dir / "mic.wav").exists() else None)
    out["audio"] = mic
    return {k: (str(v) if isinstance(v, Path) else v) for k, v in out.items()}


def camera_file(take_dir: Path, kind: str = "short") -> Path:
    return Path(sources(take_dir, kind)["source"])


def edit_dir_for_take(cfg: Config, kind: str, take_dir: Path) -> Path:
    ident = take_info(take_dir).get("id") or take_dir.name
    d = cfg.edit_dir(kind_dir(kind), ident)
    (d / "work").mkdir(parents=True, exist_ok=True)
    return d


def run_words(cfg: Config, kind: str, take_dir: Path) -> Path:
    """Transcribe the take into <edit>/work/words.json and note which file the edit is built from."""
    edit = edit_dir_for_take(cfg, kind, take_dir)
    src = sources(take_dir, kind)
    brand = brand_mod.load_cfg(cfg)
    words = words_mod.transcribe(src["audio"] or src["source"], brand["language"], brand["editing"].get("word_fixes"))
    write_json(edit / "work" / "words.json", words)
    write_json(edit / "work" / "take_ref.json", {"take": str(take_dir), **src})
    return edit / "work" / "words.json"


def run_cut(cfg: Config, kind: str, take_dir: Path) -> tuple[Path, "cut_mod.CutPlan"]:
    edit = edit_dir_for_take(cfg, kind, take_dir)
    wp = edit / "work" / "words.json"
    if not wp.exists():
        run_words(cfg, kind, take_dir)
    brand = brand_mod.load_cfg(cfg)
    plan = cut_mod.cut_take(Path(sources(take_dir, kind)["audio"] or camera_file(take_dir, kind)), read_json(wp), brand)
    write_json(edit / "work" / "cut.json", plan.to_json())
    return edit / "work" / "cut.json", plan


def render_motion(cfg: Config, edit_dir: Path, only: str | None = None, kind: str = "short") -> list[str]:
    """Render every motion comp named in creative.json into <edit>/work/motion/. Returns messages."""
    from . import spec as spec_mod
    brand_mod.build(cfg)
    spec = spec_mod.from_creative(cfg, edit_dir, kind)
    size = "1080x1920" if kind == "short" else "1920x1080"
    msgs = []
    for o in spec["overlays"]:
        if only and o["comp"] != only:
            continue
        out = edit_dir / o["file"]
        motion.render(cfg, o["comp"], o["vars"], out, zone=o["zone"], size=size, duration=o["duration"])
        msgs.append(f"rendered {o['comp']} -> {o['file']}")
    if not msgs:
        msgs.append("no motion comps to render" + (f" named {only}" if only else ""))
    return msgs
