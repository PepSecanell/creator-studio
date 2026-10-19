"""Load brand/brand.json, merge it with the chosen look, and write the resolved files renderers read."""
from __future__ import annotations

import re
from pathlib import Path

from .config import Config
from .util import StudioError, read_json, write_json

ROLES = ("ground", "ink", "accent", "accent_2", "muted", "on_accent")
FONT_ROLES = ("title", "caption", "body", "hand")
HEX = re.compile(r"^#[0-9a-fA-F]{6}$")

DEFAULTS = {
    "tagline": "", "language": "en", "logo": None,
    "fonts": {"title": None, "caption": None, "body": None},
    "voice": {"who": "", "audience": "", "topics": [], "tone": [], "banned": [], "cta": "", "link": ""},
    "handles": {},
    "schedule": {"shorts_per_day": 2, "long_per_week": 1, "timezone": "UTC"},
    "editing": {"keep_pauses": False, "music": True, "sfx": True, "caption_case": "sentence",
                "max_short_seconds": 45, "word_fixes": {}, "cues": {}},
    "models": {"creative": "opus", "mechanical": "sonnet"},
}


def _merge(base: dict, over: dict) -> dict:
    out = dict(base)
    for k, v in (over or {}).items():
        out[k] = _merge(out[k], v) if isinstance(v, dict) and isinstance(out.get(k), dict) else v
    return out


def available_looks(looks_dir: Path) -> list[str]:
    if not looks_dir.is_dir():
        return []
    return sorted(p.name for p in looks_dir.iterdir() if (p / "look.json").exists())


def load_look(looks_dir: Path, style: str) -> dict:
    p = Path(looks_dir) / style / "look.json"
    if not p.exists():
        names = ", ".join(available_looks(Path(looks_dir))) or "none found"
        raise StudioError(f'brand.json asks for the look "{style}" but looks/{style}/look.json does not exist. '
                          f"Available looks: {names}.")
    look = read_json(p)
    if look.get("schema") != "creator-look/v1":
        raise StudioError(f'{p} must have "schema": "creator-look/v1".')
    look["_dir"] = str(p.parent)
    return look


def _check_hex(palette: dict, where: str) -> None:
    for role, value in palette.items():
        if role not in ROLES:
            raise StudioError(f'{where}: "{role}" is not a palette role. Roles are: {", ".join(ROLES)}.')
        if not isinstance(value, str) or not HEX.match(value):
            raise StudioError(f'{where}: palette "{role}" is "{value}". Use a hex colour like #FFD84D.')


def load(brand_dir: Path, looks_dir: Path) -> dict:
    """Return the merged brand: look defaults < brand values. Raises StudioError in plain words."""
    brand_dir = Path(brand_dir)
    p = brand_dir / "brand.json"
    if not p.exists():
        raise StudioError(f"No brand file at {p}. Copy brand/brand.json from the repo and edit it.")
    raw = read_json(p)
    if raw.get("schema") != "creator-brand/v1":
        raise StudioError('brand.json must have "schema": "creator-brand/v1".')
    if not str(raw.get("name", "")).strip():
        raise StudioError('brand.json needs a "name".')
    style = raw.get("style")
    if not style:
        raise StudioError('brand.json needs a "style" (the look to use).')
    look = load_look(Path(looks_dir), style)
    _check_hex(raw.get("palette", {}), "brand.json")
    _check_hex(look.get("palette_defaults", {}), f"looks/{style}/look.json")
    palette = {**look.get("palette_defaults", {}), **raw.get("palette", {})}
    missing = [r for r in ROLES if r not in palette]
    if missing:
        raise StudioError(f"No colour for: {', '.join(missing)}. Add them to the palette in brand.json.")

    fonts = {}
    brand_fonts = raw.get("fonts") or {}
    for role in FONT_ROLES:
        user = brand_fonts.get(role)
        if user:
            f = (brand_dir / user)
            if not f.exists():
                raise StudioError(f'Font file for "{role}" not found: {f}. Paths are relative to the brand folder.')
        else:
            rel = (look.get("fonts") or {}).get(role)
            f = Path(look["_dir"]) / rel if rel else None
            if f is not None and not f.exists():
                f = None   # a look may ship without its font files; renderers fall back to a system font
        fonts[role] = str(f) if f else None

    logo = None
    if raw.get("logo"):
        lp = brand_dir / raw["logo"]
        logo = str(lp) if lp.exists() else None

    voice = _merge(DEFAULTS["voice"], raw.get("voice") or {})
    for key in ("topics", "tone", "banned"):
        if not isinstance(voice[key], list):
            raise StudioError(f'brand.json voice "{key}" must be a list.')
    editing = _merge(DEFAULTS["editing"], raw.get("editing") or {})
    if editing["caption_case"] not in ("sentence", "lower", "upper", "title"):
        raise StudioError('editing "caption_case" must be sentence, lower, upper or title.')
    if not isinstance(editing["max_short_seconds"], (int, float)) or editing["max_short_seconds"] <= 0:
        raise StudioError('editing "max_short_seconds" must be a positive number.')

    return {
        "schema": "brand-resolved/v1", "name": raw["name"], "tagline": raw.get("tagline", ""),
        "language": raw.get("language", "en"), "style": style, "palette": palette, "fonts": fonts,
        "logo": logo, "voice": voice, "handles": raw.get("handles") or {},
        "schedule": _merge(DEFAULTS["schedule"], raw.get("schedule") or {}),
        "editing": editing, "models": _merge(DEFAULTS["models"], raw.get("models") or {}),
        "look": {k: v for k, v in look.items() if k != "fonts"},
        "brand_dir": str(brand_dir),
    }


def load_cfg(cfg: Config) -> dict:
    return load(cfg.brand_dir, cfg.looks_dir)


_TOKEN_RE = re.compile(r"(--cs-[a-z0-9-]+)\s*:\s*[^;]+;")
_URL_RE = re.compile(r"url\((['\"]?)([^'\")]+)\1\)")


def _absolute_url(m, base: Path) -> str:
    ref = m.group(2)
    if re.match(r"^(data:|https?:|file:|/)", ref):
        return m.group(0)
    return f'url("{(base / ref).resolve()}")'


def tokens_css(brand: dict) -> str:
    """The look's tokens.css with brand colours and fonts filled in.

    The look's own @font-face blocks are kept with their url() paths made absolute, so the motion
    renderer can copy the files. Title and body fonts are only overridden when the brand ships its own.
    """
    values = {f"--cs-{r.replace('_', '-')}": brand["palette"][r] for r in ROLES}
    brand_dir = Path(brand.get("brand_dir", ""))
    faces = []
    for role, name in (("title", "CS Title"), ("body", "CS Body")):
        path = brand["fonts"].get(role)
        if path and brand_dir.parts and Path(path).is_relative_to(brand_dir):
            faces.append(f'@font-face {{ font-family: "{name}"; src: url("{path}"); font-display: block; }}')
            values[f"--cs-font-{role}"] = f'"{name}", sans-serif'
    base = ""
    look_dir = Path(brand["look"].get("_dir", brand["look"].get("dir", "")))
    ref = look_dir / brand["look"].get("motion", "tokens.css")
    if brand["look"].get("_dir") and ref.exists():
        base = _URL_RE.sub(lambda m: _absolute_url(m, look_dir), ref.read_text(encoding="utf-8"))
    seen = set()

    def fill(m):
        seen.add(m.group(1))
        return f"{m.group(1)}: {values[m.group(1)]};" if m.group(1) in values else m.group(0)

    css = _TOKEN_RE.sub(fill, base)
    extra = {k: v for k, v in values.items() if k not in seen}
    defaults = {"--cs-radius": "16px", "--cs-stroke": "4px", "--cs-font-title": "sans-serif",
                "--cs-font-body": "sans-serif"}
    for k, v in defaults.items():
        if k not in seen and k not in extra:
            extra[k] = v
    block = ":root {\n" + "".join(f"  {k}: {v};\n" for k, v in extra.items()) + "}\n" if extra else ""
    return "\n".join(faces) + ("\n" if faces else "") + css + ("\n" if css else "") + block


def build(cfg: Config) -> dict:
    """Write workspace/.brand/brand.resolved.json and tokens.css. Returns the resolved brand."""
    brand = load_cfg(cfg)
    out = cfg.resolved_dir
    out.mkdir(parents=True, exist_ok=True)
    write_json(out / "brand.resolved.json", brand)
    (out / "tokens.css").write_text(tokens_css(brand), encoding="utf-8")
    return brand
