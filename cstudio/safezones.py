"""Safe zones: keep text out of the parts of the screen each app covers with its own buttons."""
from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

FRAME = (1080, 1920)


@lru_cache(maxsize=1)
def load_profiles() -> dict:
    return json.loads((Path(__file__).parent / "platforms.json").read_text(encoding="utf-8"))


def safe_box(platforms: list[str] | None = None, frame: tuple[int, int] = FRAME) -> tuple[int, int, int, int]:
    """The rectangle no listed platform covers. Bars and strips along an edge shrink the box away from them,
    and so does the right-hand action column, so centred text should be centred in this box."""
    prof = load_profiles()
    names = platforms or prof["default_set"]
    w, h = FRAME
    x0, y0, x1, y1 = 0, 0, w, h
    for n in names:
        for z in prof["platforms"][n]["ui"]:
            bx0, by0, bx1, by1 = z["box"]
            if bx1 - bx0 >= w * 0.9:             # a full-width bar
                if by0 == 0:
                    y0 = max(y0, by1)
                elif by1 >= h:
                    y1 = min(y1, by0)
            elif by1 - by0 >= h * 0.9:            # a full-height edge strip
                if bx0 == 0:
                    x0 = max(x0, bx1)
                elif bx1 >= w:
                    x1 = min(x1, bx0)
            elif bx1 >= w:                        # the action column: text is centred in what is left
                x1 = min(x1, bx0)
    m = prof["margin_px"]
    box = (x0 + m, y0 + m, x1 - m, y1 - m)
    sx, sy = frame[0] / FRAME[0], frame[1] / FRAME[1]
    return (round(box[0] * sx), round(box[1] * sy), round(box[2] * sx), round(box[3] * sy))


def _overlap(a, b) -> bool:
    return a[0] < b[2] and b[0] < a[2] and a[1] < b[3] and b[1] < a[3]


def violations(boxes: dict[str, tuple], platforms: list[str] | None = None) -> list[str]:
    """Plain sentences for every text box that touches a platform's interface zone."""
    prof = load_profiles()
    out = []
    for label, box in boxes.items():
        for n in platforms or prof["default_set"]:
            for z in prof["platforms"][n]["ui"]:
                if _overlap(box, z["box"]):
                    out.append(f'{label} overlaps the {z["name"]} on {prof["platforms"][n]["name"]}')
    return out


def clamp(box, safe) -> tuple[int, int]:
    """Offset (dx, dy) that moves `box` inside `safe` (top-left wins if the box is larger)."""
    dx = dy = 0
    if box[2] + 0 > safe[2]:
        dx = safe[2] - box[2]
    if box[0] + dx < safe[0]:
        dx = safe[0] - box[0]
    if box[3] > safe[3]:
        dy = safe[3] - box[3]
    if box[1] + dy < safe[1]:
        dy = safe[1] - box[1]
    return dx, dy


def length_ok(seconds: float, platforms: list[str] | None = None) -> list[str]:
    prof = load_profiles()
    out = []
    for n in platforms or prof["default_set"]:
        lim = prof["platforms"][n]["length_s"]
        if seconds < lim["min"] or seconds > lim["max"]:
            out.append(f'{seconds:.0f}s is outside {prof["platforms"][n]["name"]} limits ({lim["min"]} to {lim["max"]}s)')
    return out
