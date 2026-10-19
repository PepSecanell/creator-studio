"""Posting kit: finished edits copied into kits/<date>/ with a kit.json. Nothing here posts anything."""
from __future__ import annotations

import datetime as dt
import shutil
from pathlib import Path

from . import brand as brand_mod
from . import schemas
from .config import Config
from .util import read_json, write_json

READY = ("ready_for_review", "approved")
SHORT_PLATFORMS = ("tiktok", "youtube_shorts", "reels")


def post_times(per_day: int) -> list[str]:
    """Spread posting slots between 08:00 and 20:00."""
    per_day = max(1, int(per_day))
    if per_day == 1:
        return ["12:00"]
    step = 12 * 60 / (per_day - 1)
    return [f"{(8 * 60 + round(i * step)) // 60:02d}:{(8 * 60 + round(i * step)) % 60:02d}" for i in range(per_day)]


def build(cfg: Config, date: str | None = None, *, include_review: bool = True) -> Path:
    date = date or dt.date.today().isoformat()
    brand = brand_mod.load_cfg(cfg)
    states = READY if include_review else ("approved",)
    kit_dir = cfg.workspace / "kits" / date
    kit_dir.mkdir(parents=True, exist_ok=True)
    slots = post_times(brand["schedule"].get("shorts_per_day", 2))
    items: list[dict] = []
    n = 0
    for kind, folder in (("short", "shorts"), ("long", "long")):
        root = cfg.workspace / "edits" / folder
        for ed in sorted(p for p in root.glob("*") if p.is_dir()):
            st = schemas.read_status(ed)
            if not st or st["state"] not in states or not (ed / "final.mp4").exists():
                continue
            ident = ed.name
            if kind == "short":
                post = read_json(ed / "posting.json") if (ed / "posting.json").exists() else {}
                cover = ed / "cover.jpg"
                if cover.exists():
                    shutil.copy2(cover, kit_dir / f"{ident}-cover.jpg")
                for plat in SHORT_PLATFORMS:
                    fname = f"{ident}-{plat}.mp4"
                    shutil.copy2(ed / "final.mp4", kit_dir / fname)
                    p = post.get(plat, {})
                    items.append({"id": ident, "platform": plat, "action": "post", "file": fname,
                                  "cover": f"{ident}-cover.jpg" if cover.exists() else "", "title": p.get("title", ""),
                                  "caption": p.get("caption", ""), "hashtags": p.get("hashtags", []),
                                  "pinned_comment": p.get("pinned_comment", ""), "post_at": slots[n % len(slots)]})
                n += 1
            else:
                desc = read_json(ed / "description.json") if (ed / "description.json").exists() else {}
                fname = f"{ident}-youtube.mp4"
                shutil.copy2(ed / "final.mp4", kit_dir / fname)
                thumb = ed / "thumbnail.jpg"
                if thumb.exists():
                    shutil.copy2(thumb, kit_dir / f"{ident}-thumbnail.jpg")
                titles = desc.get("title_options") or [""]
                items.append({"id": ident, "platform": "youtube", "action": "post", "file": fname,
                              "cover": f"{ident}-thumbnail.jpg" if thumb.exists() else "", "title": titles[0],
                              "caption": desc.get("description", ""), "hashtags": desc.get("tags", []),
                              "pinned_comment": "", "post_at": "12:00"})
    kit = {"schema": "kit/v1", "date": date, "brand": brand["name"], "items": items}
    schemas.check(kit, "kit/v1")
    write_json(kit_dir / "kit.json", kit)
    return kit_dir
