"""Caption renderer. One function covers every shape a look can ask for."""
from __future__ import annotations

from PIL import Image, ImageDraw

from .text import apply_case, font, measure, rgb, wrap

SHAPES = ("pill", "plain", "underline", "box")
EMPHASIS = ("marker", "colour", "box")
REF_W = 1080     # look sizes are written for a 1080 wide frame


def chunks(words: list[dict], max_words: int = 4, max_gap: float = 0.45) -> list[dict]:
    """Group output-time words into caption chunks. Breaks on sentence ends and long gaps."""
    out, cur = [], []
    for w in words:
        if cur and (len(cur) >= max_words or w["s"] - cur[-1]["e"] > max_gap or cur[-1]["w"][-1:] in ".?!"):
            out.append(cur)
            cur = []
        cur.append(w)
    if cur:
        out.append(cur)
    res = []
    for c in out:
        end = c[-1]["e"]
        res.append({"words": c, "s": c[0]["s"], "e": end})
    for a, b in zip(res, res[1:]):          # hold a chunk until the next starts if the gap is small
        if b["s"] - a["e"] < max_gap:
            a["e"] = b["s"]
    return res


def _is_key(word: str, keywords: set[str]) -> bool:
    return "".join(c for c in word.lower() if c.isalnum()) in keywords


def render(size: tuple[int, int], texts: list[str], keywords: list[str], look: dict, palette: dict,
           fonts: dict, case: str = "sentence", y_center: int | None = None, max_width: int | None = None, center_x: int | None = None):
    """Draw one caption. Returns (RGBA image of `size`, bbox of the drawn text including its backing)."""
    W, H = size
    cap = look["captions"]
    shape = cap.get("shape", "pill")
    emph_mode = cap.get("emphasis_mode", "marker")
    k = W / REF_W
    f = font(fonts.get("caption"), max(12, int(cap.get("size", 64) * k)))
    fill = rgb(palette[cap.get("fill", "ground")])
    ink = rgb(palette[cap.get("text", "ink")])
    emph = rgb(palette[cap.get("emphasis", "accent")])
    texts = [apply_case(t, case) for t in texts]
    keys = {"".join(c for c in w.lower() if c.isalnum()) for w in keywords}
    max_w = max_width or int(W * 0.84)
    lines = wrap(" ".join(texts), f, max_w)
    space = measure("a a", f)[0] - measure("aa", f)[0]
    line_h = int(measure("Ag", f)[1] * 1.45)
    pad_x, pad_y = (int(26 * k), int(14 * k)) if shape in ("pill", "box") else (0, 0)
    laid = []    # (word, x, y_line, w, is_key)
    widths = []
    for li, line in enumerate(lines):
        ws = line.split()
        x = 0
        for w in ws:
            wd = measure(w, f)[0]
            laid.append((w, x, li, wd, _is_key(w, keys)))
            x += wd + space
        widths.append(x - space)
    block_w = max(widths) if widths else 0
    block_h = line_h * len(lines)
    cy = y_center if y_center is not None else int(H * cap.get("y", 0.68))
    left = (center_x if center_x is not None else W // 2) - block_w // 2
    top = cy - block_h // 2
    img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    box = (left - pad_x, top - pad_y, left + block_w + pad_x, top + block_h + pad_y)
    if shape == "pill":
        d.rounded_rectangle(box, radius=(box[3] - box[1]) // 2 if len(lines) == 1 else int(36 * k), fill=fill)
    elif shape == "box":
        d.rectangle(box, fill=fill)
    for w, x, li, wd, is_key in laid:
        lx = left + (block_w - widths[li]) // 2 + x
        ly = top + li * line_h
        colour = ink
        if is_key:
            if emph_mode == "marker":
                d.rounded_rectangle((lx - 8 * k, ly + line_h * 0.18, lx + wd + 8 * k, ly + line_h * 0.86),
                                    radius=int(8 * k), fill=emph)
            elif emph_mode == "box":
                d.rectangle((lx - 8 * k, ly + line_h * 0.12, lx + wd + 8 * k, ly + line_h * 0.9),
                            outline=emph, width=max(2, int(5 * k)))
            else:
                colour = emph
            if shape == "underline":
                d.rectangle((lx, ly + line_h * 0.88, lx + wd, ly + line_h * 0.88 + max(3, int(7 * k))), fill=emph)
        stroke = 0 if shape in ("pill", "box") else max(2, int(5 * k))
        d.text((lx, ly + (line_h - measure("Ag", f)[1]) // 2 - 4 * k), w, font=f, fill=colour,
               stroke_width=stroke, stroke_fill=fill)
    return img, tuple(int(v) for v in box)
