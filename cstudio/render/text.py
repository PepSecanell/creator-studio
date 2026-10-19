"""Font loading and text measuring helpers."""
from __future__ import annotations

from functools import lru_cache

from PIL import Image, ImageDraw, ImageFont

_SYSTEM = ["/System/Library/Fonts/Helvetica.ttc", "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
           "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
           "C:/Windows/Fonts/arialbd.ttf"]


@lru_cache(maxsize=64)
def font(path: str | None, size: int) -> ImageFont.FreeTypeFont:
    for p in ([path] if path else []) + _SYSTEM:
        try:
            return ImageFont.truetype(p, size)
        except OSError:
            continue
    return ImageFont.load_default(size)


def measure(text: str, f) -> tuple[int, int]:
    d = ImageDraw.Draw(Image.new("L", (1, 1)))
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    return r - l, b - t


def wrap(text: str, f, max_w: int) -> list[str]:
    lines, cur = [], ""
    for word in text.split():
        trial = (cur + " " + word).strip()
        if cur and measure(trial, f)[0] > max_w:
            lines.append(cur)
            cur = word
        else:
            cur = trial
    if cur:
        lines.append(cur)
    return lines


def balanced(text: str, f, max_w: int) -> list[str]:
    """Wrap, then shrink the width until the line count stops growing so lines are even."""
    lines = wrap(text, f, max_w)
    n = len(lines)
    if n < 2:
        return lines
    lo, hi = max_w // 2, max_w
    best = lines
    while hi - lo > 8:
        mid = (lo + hi) // 2
        trial = wrap(text, f, mid)
        if len(trial) <= n:
            best, hi = trial, mid
        else:
            lo = mid
    return best


def apply_case(text: str, mode: str) -> str:
    if mode == "lower":
        return text.lower()
    if mode == "upper":
        return text.upper()
    if mode == "title":
        return text.title()
    return text


def rgb(h: str, a: int = 255) -> tuple[int, int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), a
