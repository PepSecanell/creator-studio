"""The four Short layouts and how they rotate so no two cuts in a row look alike."""
from __future__ import annotations

import hashlib

ALL = ("face", "split", "graphic", "title")
SPLIT_SEAM = 0.5   # split layout: the face video starts this far down the frame


def assign(count: int, available: list[str] | None = None, seed: str = "", has_text: list[bool] | None = None) -> list[str]:
    """Pick a layout per segment. First is always face. Never the same twice in a row.
    Layouts that need text (graphic, title, split) are only used where text exists."""
    avail = [a for a in (available or list(ALL)) if a in ALL] or ["face"]
    out: list[str] = []
    h = int(hashlib.sha1(seed.encode()).hexdigest(), 16)
    for i in range(count):
        ok = [a for a in avail if a == "face" or has_text is None or has_text[i]]
        if i == 0:
            out.append("face")
            continue
        choices = [a for a in ok if a != out[-1]] or ok
        out.append(choices[(h + i) % len(choices)])
    return out


def video_rect(layout: str, size: tuple[int, int]) -> tuple[int, int, int, int] | None:
    """Where the face video sits for a layout: (x, y, w, h), or None for graphic."""
    W, H = size
    if layout in ("face", "title"):
        return 0, 0, W, H
    if layout == "split":
        # Graphic on top (the motion kit's split zone), face below.
        h = int(H * (1 - SPLIT_SEAM)) // 2 * 2
        return 0, H - h, W, h
    return None


def layout_at(segments: list[dict], t: float) -> str:
    """The layout on screen at output time t, from spec segments (source start/end, in order)."""
    out = 0.0
    for s in segments:
        d = s["end"] - s["start"]
        if out <= t < out + d:
            return s.get("layout", "face")
        out += d
    return "face"
