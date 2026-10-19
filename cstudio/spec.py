"""Build spec.json (the mechanical build recipe) from creative.json + cut.json + words.json.

The creative director decides the design. This module only translates it, so the result is the same every time.
"""
from __future__ import annotations

from pathlib import Path

from . import layouts as lay
from .config import Config
from .util import StudioError, read_json, write_json

FPS = 30


def snap(seconds: float) -> float:
    return round(seconds * FPS) / FPS


def split_at(segments: list[dict], boundaries: list[float]) -> list[dict]:
    """Split cut segments where an output-time boundary falls inside them."""
    out, offset = [], 0.0
    bounds = sorted(set(round(b, 3) for b in boundaries))
    for seg in segments:
        d = seg["end"] - seg["start"]
        cut_points = [b - offset for b in bounds if 0.15 < b - offset < d - 0.15]
        edges = [0.0, *cut_points, d]
        for a, b in zip(edges, edges[1:]):
            out.append({**seg, "start": round(seg["start"] + a, 3), "end": round(seg["start"] + b, 3)})
        offset += d
    return out


def beat_at(beats: list[dict], t: float) -> dict | None:
    hit = None
    for b in beats:
        if b["from"] <= t + 1e-6:
            hit = b
    return hit


def from_creative(cfg: Config, edit_dir: Path, kind: str = "short", brand: dict | None = None) -> dict:
    edit_dir = Path(edit_dir)
    work = edit_dir / "work"
    creative = read_json(edit_dir / "creative.json")
    cut = read_json(work / "cut.json")
    words = read_json(work / "words.json")
    ref = read_json(work / "take_ref.json")
    brand = brand or {}
    layouts_ok = (brand.get("look") or {}).get("layouts") or list(lay.ALL)
    beats = creative.get("beats", [])
    prev = 0.0
    for b in beats:
        if b["to"] <= b["from"] or b["from"] < prev - 1e-6:
            raise StudioError(f"Beat times must increase: beat starting at {b['from']}s is out of order.")
        prev = b["to"]

    segs = split_at(cut["segments"], [b["from"] for b in beats])
    out_t = 0.0
    spec_segs, zoom_flip = [], False
    for seg in segs:
        d = snap(seg["end"] - seg["start"])
        # the beat covering the middle of the segment: edges can sit up to 0.15 s off a beat edge
        beat = beat_at(beats, out_t + d / 2)
        layout = (beat or {}).get("layout")
        if not layout:
            layout = lay.assign(len(spec_segs) + 1, layouts_ok, creative.get("hook", {}).get("text", ""))[-1]
        if layout not in layouts_ok and layout != "face":
            layout = "face"
        s = {"start": seg["start"], "end": round(seg["start"] + d, 3), "layout": layout,
             # a beat with a motion graphic lets the graphic carry the words
             "text": "" if (beat or {}).get("motion") else (beat or {}).get("text", "")}
        if layout in ("face", "title"):
            s["zoom"] = 1.1 if zoom_flip else 1.0
            zoom_flip = not zoom_flip
        spec_segs.append(s)
        out_t += d

    overlays = []
    for i, b in enumerate(beats):
        m = b.get("motion")
        if m and m.get("comp"):
            zone = m.get("zone") or ("split" if b.get("layout") == "split" else "full")
            overlays.append({"comp": m["comp"], "vars": m.get("vars", {}), "zone": zone, "at": b["from"],
                             "duration": round(b["to"] - b["from"], 3),
                             "file": f"work/motion/{i:02d}-{m['comp']}.webm"})
    caption_off = [[b["from"], b["to"]] for b in beats if b.get("caption") is False]
    hook = creative.get("hook", {})
    spec = {
        "schema": "short-spec/v1" if kind == "short" else "long-spec/v1",
        "id": edit_dir.name, "source": ref["source"], "unmirror": bool(ref.get("unmirror", False)),
        "audio": ref.get("audio"), "screen": ref.get("screen"),
        "segments": spec_segs, "words": words, "keywords": creative.get("keywords", []),
        "captions": True, "caption_off": caption_off,
        "hook": {"text": hook.get("text", ""), "seconds": 2.5, "emphasis": hook.get("emphasis", "")},
        "overlays": overlays, "end": creative.get("end") or {}, "cover": creative.get("cover") or {},
        "music": bool(creative.get("music", True)),
    }
    write_json(edit_dir / "spec.json", spec)
    return spec
