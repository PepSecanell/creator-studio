"""Turn timed image layers into one ffmpeg input (a concat list of PNGs), so a video needs one overlay pass."""
from __future__ import annotations

from pathlib import Path

from PIL import Image


def build(workdir: Path, size: tuple[int, int], duration: float, layers: list[tuple[float, float, Image.Image]]) -> Path:
    """layers: (start, end, RGBA image of `size`), drawn in list order. Returns the concat list path."""
    workdir.mkdir(parents=True, exist_ok=True)
    cuts = {0.0, round(duration, 3)}
    for s, e, _ in layers:
        cuts.update({round(max(0.0, s), 3), round(min(duration, e), 3)})
    times = sorted(cuts)
    blank = Image.new("RGBA", size, (0, 0, 0, 0))
    blank_path = workdir / "g_blank.png"
    blank.save(blank_path)
    lines, cache, n = [], {}, 0
    last = blank_path
    for a, b in zip(times, times[1:]):
        if b - a < 0.001:
            continue
        mid = (a + b) / 2
        active = tuple(i for i, (s, e, _) in enumerate(layers) if s <= mid < e)
        if not active:
            path = blank_path
        elif active in cache:
            path = cache[active]
        else:
            comp = blank.copy()
            for i in active:
                comp.alpha_composite(layers[i][2])
            path = workdir / f"g_{n:03d}.png"
            comp.save(path)
            cache[active] = path
            n += 1
        lines.append(f"file '{path}'\nduration {b - a:.3f}")
        last = path
    lines.append(f"file '{last}'")
    lst = workdir / "graphics.txt"
    lst.write_text("\n".join(lines) + "\n")
    return lst
