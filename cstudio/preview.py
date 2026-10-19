"""./studio brand preview: one picture showing the brand on every part (captions, hook, end card, cover)."""
from __future__ import annotations

from pathlib import Path

from PIL import Image, ImageDraw

from . import brand as brand_mod
from . import safezones
from .config import Config
from .render import captions, cards
from .render.text import font, rgb

SHAPES = ("pill", "plain", "underline", "box")


def render(cfg: Config) -> Path:
    brand = brand_mod.build(cfg)
    pal, fonts, look = brand["palette"], brand["fonts"], brand["look"]
    size = (1080, 1920)
    safe = safezones.safe_box()
    cell_w, cell_h = 360, 640
    sheet = Image.new("RGB", (cell_w * 4 + 50, cell_h * 2 + 80), rgb(pal["muted"])[:3])
    d = ImageDraw.Draw(sheet)
    lab = font(fonts.get("body"), 20)

    def put(img: Image.Image, col: int, row: int, label: str, bg: str) -> None:
        base = Image.new("RGBA", size, rgb(pal[bg]))
        base.alpha_composite(img)
        thumb = base.convert("RGB").resize((cell_w, cell_h), Image.LANCZOS)
        x, y = 10 + col * (cell_w + 10), 10 + row * (cell_h + 40)
        sheet.paste(thumb, (x, y))
        d.text((x, y + cell_h + 8), label, font=lab, fill=rgb(pal["ink"]))

    for i, shape in enumerate(SHAPES):
        l = {**look, "captions": {**look.get("captions", {}), "shape": shape}}
        img, _ = captions.render(size, ["Make", "one", "small", "thing"], ["small"], l, pal, fonts, y_center=1000)
        put(img, i, 0, f"captions: {shape}", "ink" if shape in ("plain", "underline") else "muted")
    hook, _ = cards.hook_card(size, "Start with one clear goal", look, pal, fonts, safe)
    blank = Image.new("RGBA", size, (0, 0, 0, 0))
    put(hook or blank, 0, 1, "hook card", "ground")
    put(cards.end_card(size, brand, "See you tomorrow", ""), 1, 1, "end card", "ground")
    put(cards.panel(size, "graphic", "One clear goal", brand), 2, 1, "graphic layout", "ground")
    put(cards.panel(size, "title", "One clear goal", brand), 3, 1, "title layout", "ink")
    out = cfg.resolved_dir / "preview.png"
    sheet.save(out)
    return out
