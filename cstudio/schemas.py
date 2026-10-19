"""Checks and builders for the JSON files the parts of the studio pass to each other."""
from __future__ import annotations

from pathlib import Path

from .util import StudioError, now_iso, read_json, write_json

STATES = ("queued", "editing", "ready_for_review", "needs_you", "failed", "approved", "posted")
PLATFORMS = ("tiktok", "youtube_shorts", "reels", "youtube", "x", "linkedin", "threads")


def _problems(d, schema: str, required: dict, enums: dict | None = None) -> list[str]:
    if not isinstance(d, dict):
        return [f"{schema}: expected an object"]
    out = []
    if d.get("schema") != schema:
        out.append(f'"schema" must be "{schema}"')
    for key, typ in required.items():
        if key not in d:
            out.append(f'missing "{key}"')
        elif not isinstance(d[key], typ):
            out.append(f'"{key}" has the wrong type')
    for key, allowed in (enums or {}).items():
        if key in d and d[key] not in allowed:
            out.append(f'"{key}" must be one of {", ".join(map(str, allowed))}')
    return out


def check(d, schema: str) -> None:
    """Raise StudioError with every problem found. `schema` is e.g. "handoff/v1"."""
    spec = _TABLE.get(schema)
    if not spec:
        raise StudioError(f"Unknown schema {schema}")
    problems = _problems(d, schema, spec[0], spec[1])
    if schema == "kit/v1" and not problems:
        for i, item in enumerate(d["items"]):
            for key in ("id", "platform", "action", "file"):
                if key not in item:
                    problems.append(f'items[{i}] is missing "{key}"')
            if item.get("platform") not in PLATFORMS:
                problems.append(f'items[{i}] has an unknown platform')
    if problems:
        raise StudioError(f"Invalid {schema}: " + "; ".join(problems))


_TABLE = {
    "handoff/v1": ({"kind": str, "id": str, "title": str, "mode": str, "teleprompter": str, "points": list,
                    "out_dir": str, "created": str, "brand": str},
                   {"kind": ("short", "long"), "mode": ("cards", "script", "screen")}),
    "take/v1": ({"id": str, "kind": str, "take": int, "mode": str, "started": str, "duration_s": (int, float),
                 "fps": (int, float), "files": dict}, {"kind": ("short", "long")}),
    "edit-status/v1": ({"state": str, "updated": str, "notes": str, "checks": dict}, {"state": STATES}),
    "kit/v1": ({"date": str, "brand": str, "items": list}, {}),
    "cards/v1": ({"week": str, "cards": list}, {}),
    "creative/v1": ({"hook": dict, "beats": list, "keywords": list, "cover": dict}, {}),
    "short-spec/v1": ({"source": str, "segments": list, "words": list}, {}),
    "long-spec/v1": ({"source": str, "segments": list}, {}),
}


def make_handoff(kind: str, ident: str, title: str, mode: str, teleprompter: str, points: list,
                 out_dir: str, brand: str) -> dict:
    d = {"schema": "handoff/v1", "kind": kind, "id": ident, "title": title, "mode": mode,
         "teleprompter": teleprompter, "points": points, "out_dir": out_dir, "created": now_iso(), "brand": brand}
    check(d, "handoff/v1")
    return d


def status_path(edit_dir: Path) -> Path:
    return Path(edit_dir) / "status.json"


def read_status(edit_dir: Path) -> dict | None:
    p = status_path(edit_dir)
    return read_json(p) if p.exists() else None


def set_status(edit_dir: Path, state: str, notes: str = "", checks: dict | None = None) -> dict:
    """Write status.json. Existing checks are kept unless new ones are given."""
    old = read_status(edit_dir) or {}
    d = {"schema": "edit-status/v1", "state": state, "updated": now_iso(), "notes": notes,
         "checks": checks if checks is not None else old.get("checks", {})}
    check(d, "edit-status/v1")
    write_json(status_path(edit_dir), d)
    return d
