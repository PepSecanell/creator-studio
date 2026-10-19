"""Hook card, end card, layout panels, lower third and chapter card."""
from __future__ import annotations


from PIL import Image, ImageDraw

from .text import balanced, font, measure, rgb

REF_W = 1080


def _k(size) -> float:
    return size[0] / REF_W


def hook_card(size, text: str, look: dict, palette: dict, fonts: dict, safe: tuple, emphasis: str = "") -> tuple:
    """Return (RGBA image, bbox) or (None, None) when the look has no hook card."""
    hc = look.get("hook_card", {})
    shape = hc.get("shape", "strip")
    if shape == "none" or not text:
        return None, None
    W, H = size
    k = _k(size)
    f = font(fonts.get("title"), int(70 * k))
    fill, ink = rgb(palette[hc.get("fill", "accent")]), rgb(palette[hc.get("text", "on_accent")])
    inner = int((safe[2] - safe[0]) * 0.86) if shape == "block" else W - int(120 * k)
    lines = balanced(text, f, inner)
    lh = int(measure("Ag", f)[1] * 1.35)
    tw = max(measure(ln, f)[0] for ln in lines)
    th = lh * len(lines)
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if shape == "strip":
        box = (0, safe[1], W, safe[1] + th + int(60 * k))
        d.rectangle(box, fill=fill)
    else:
        bw, bh = tw + int(90 * k), th + int(80 * k)
        x0 = (W - bw) // 2
        y0 = safe[1] + int(40 * k)
        box = (x0, y0, x0 + bw, y0 + bh)
        d.rounded_rectangle(box, radius=int(36 * k), fill=fill)
    y = box[1] + ((box[3] - box[1]) - th) // 2
    text_box = ((W - tw) // 2, y, (W + tw) // 2, y + th)      # the card may bleed off the edge, the words may not
    for ln in lines:
        w = measure(ln, f)[0]
        d.text(((W - w) // 2, y + (lh - measure("Ag", f)[1]) // 2 - 4 * k), ln, font=f, fill=ink)
        y += lh
    return img, text_box


def end_card(size, brand: dict, line: str = "", cta: str = "") -> Image.Image:
    W, H = size
    k = _k(size)
    look = brand["look"].get("end_card", {})
    pal, fonts = brand["palette"], brand["fonts"]
    img = Image.new("RGBA", size, rgb(pal[look.get("fill", "ground")]))
    d = ImageDraw.Draw(img)
    ink = rgb(pal[look.get("text", "ink")])
    y = int(H * 0.30)
    if look.get("show_logo", True) and brand.get("logo"):
        logo = Image.open(brand["logo"]).convert("RGBA")
        scale = min(int(360 * k) / logo.width, int(360 * k) / logo.height)
        logo = logo.resize((int(logo.width * scale), int(logo.height * scale)))
        img.alpha_composite(logo, ((W - logo.width) // 2, y))
        y += logo.height + int(50 * k)
    ft, fb = font(fonts.get("title"), int(84 * k)), font(fonts.get("body"), int(48 * k))
    for text, f in ((brand["name"], ft),):
        w = measure(text, f)[0]
        d.text(((W - w) // 2, y), text, font=f, fill=ink)
        y += int(130 * k)
    if line:
        for ln in balanced(line, fb, int(W * 0.8)):
            d.text(((W - measure(ln, fb)[0]) // 2, y), ln, font=fb, fill=ink)
            y += int(70 * k)
    cta = cta or brand["voice"].get("cta", "")
    if look.get("show_cta", True) and cta:
        y += int(30 * k)
        for ln in balanced(cta, ft if len(cta) < 28 else fb, int(W * 0.8)):
            f = ft if len(cta) < 28 else fb
            w = measure(ln, f)[0]
            pad = int(24 * k)
            d.rounded_rectangle(((W - w) // 2 - pad, y - pad // 2, (W + w) // 2 + pad, y + measure(ln, f)[1] + pad * 1.4),
                                radius=int(30 * k), fill=rgb(pal["accent"]))
            d.text(((W - w) // 2, y), ln, font=f, fill=rgb(pal["on_accent"]))
            y += int(110 * k)
    link = brand["voice"].get("link")
    if link:
        w = measure(link, fb)[0]
        d.text(((W - w) // 2, y + int(20 * k)), link, font=fb, fill=rgb(pal["muted"]))
    return img


def panel(size, layout: str, text: str, brand: dict, region: tuple | None = None) -> Image.Image:
    """Transparent overlay for a layout. graphic: full ground with big text. title: scrim and text over the face.
    split: text in the ground above `region` (the face video's rect), where the motion kit's split zone is."""
    W, H = size
    k = _k(size)
    pal, fonts = brand["palette"], brand["fonts"]
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if layout == "graphic":
        d.rectangle((0, 0, W, H), fill=rgb(pal["ground"]))
        box = (int(90 * k), int(H * 0.30), W - int(90 * k), int(H * 0.62))
        ink = rgb(pal["ink"])
    elif layout == "split":
        seam = region[1] if region else int(H * 0.5)
        d.rectangle((0, 0, W, seam), fill=rgb(pal["ground"]))
        box = (int(80 * k), int(H * 0.17), W - int(80 * k), seam - int(80 * k))
        ink = rgb(pal["ink"])
    else:
        # Above the head, on the shelf: a scrim across 0.38 to 0.62 sat on the eyes.
        d.rectangle((0, int(H * 0.13), W, int(H * 0.26)), fill=rgb(pal["ink"], 190))
        box = (int(80 * k), int(H * 0.13), W - int(80 * k), int(H * 0.26))
        ink = rgb(pal["ground"])
    if not text:
        return img
    size_px = int(110 * k) if layout != "split" else int(76 * k)
    f = font(fonts.get("title"), size_px)
    lines = balanced(text, f, box[2] - box[0])
    while len(lines) * measure("Ag", f)[1] * 1.3 > box[3] - box[1] and size_px > 30:
        size_px -= 6
        f = font(fonts.get("title"), size_px)
        lines = balanced(text, f, box[2] - box[0])
    lh = int(measure("Ag", f)[1] * 1.3)
    y = box[1] + ((box[3] - box[1]) - lh * len(lines)) // 2
    for ln in lines:
        w = measure(ln, f)[0]
        d.text(((W - w) // 2, y), ln, font=f, fill=ink)
        y += lh
    if layout != "title":
        bar_w = int(160 * k)
        d.rounded_rectangle(((W - bar_w) // 2, box[1] - int(30 * k), (W + bar_w) // 2, box[1] - int(30 * k) + int(10 * k)),
                            radius=5, fill=rgb(pal["accent"]))
    return img


def lower_third(size, title: str, subtitle: str, brand: dict) -> Image.Image:
    W, H = size
    k = _k(size)
    pal, fonts = brand["palette"], brand["fonts"]
    img = Image.new("RGBA", size, (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    ft, fb = font(fonts.get("title"), int(56 * k)), font(fonts.get("body"), int(34 * k))
    w = max(measure(title, ft)[0], measure(subtitle, fb)[0] if subtitle else 0) + int(70 * k)
    h = int(110 * k) + (int(50 * k) if subtitle else 0)
    x, y = int(90 * k), H - int(220 * k) - h
    d.rounded_rectangle((x, y, x + w, y + h), radius=int(14 * k), fill=rgb(pal["ground"], 235))
    d.rectangle((x, y, x + int(12 * k), y + h), fill=rgb(pal["accent"]))
    d.text((x + int(36 * k), y + int(20 * k)), title, font=ft, fill=rgb(pal["ink"]))
    if subtitle:
        d.text((x + int(36 * k), y + int(88 * k)), subtitle, font=fb, fill=rgb(pal["muted"]))
    return img


def chapter_card(size, number: int, title: str, brand: dict) -> Image.Image:
    W, H = size
    k = _k(size)
    pal, fonts = brand["palette"], brand["fonts"]
    img = Image.new("RGBA", size, rgb(pal["ground"]))
    d = ImageDraw.Draw(img)
    fn, ft = font(fonts.get("title"), int(150 * k)), font(fonts.get("title"), int(90 * k))
    num = f"{number:02d}"
    d.text(((W - measure(num, fn)[0]) // 2, int(H * 0.28)), num, font=fn, fill=rgb(pal["accent_2"]))
    y = int(H * 0.28) + int(210 * k)
    for ln in balanced(title, ft, int(W * 0.7)):
        d.text(((W - measure(ln, ft)[0]) // 2, y), ln, font=ft, fill=rgb(pal["ink"]))
        y += int(120 * k)
    return img
