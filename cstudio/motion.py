"""Bridge to the motion graphics kit (node). Optional: everything else works without it."""
from __future__ import annotations

import json
import subprocess
from pathlib import Path

from .config import Config
from .util import StudioError, have, write_json


def available(cfg: Config) -> bool:
    return have("node") and (cfg.motion_dir / "render.mjs").exists() and (cfg.motion_dir / "node_modules").exists()


def list_comps(cfg: Config) -> list[dict] | None:
    """Comps as [{name, vars, ...}], or None when the kit cannot run."""
    if not available(cfg):
        return None
    r = subprocess.run(["node", str(cfg.motion_dir / "render.mjs"), "--list"], capture_output=True, text=True,
                       cwd=cfg.repo, timeout=60)
    if r.returncode != 0:
        return None
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return None
    return data["comps"] if isinstance(data, dict) and "comps" in data else data


def render(cfg: Config, comp: str, vars_: dict, out: Path, *, zone: str = "full", size: str = "1080x1920",
           duration: float = 2.0) -> Path:
    if not available(cfg):
        raise StudioError("The motion kit is not installed. Run ./studio setup (needs node).")
    if not (cfg.resolved_dir / "tokens.css").exists():
        raise StudioError("Brand not built yet. Run ./studio brand build.")
    out.parent.mkdir(parents=True, exist_ok=True)
    vars_path = write_json(out.with_suffix(".vars.json"), vars_ or {})
    r = subprocess.run(["node", str(cfg.motion_dir / "render.mjs"), "--comp", comp, "--vars", str(vars_path), "--out", str(out),
                        "--zone", zone, "--size", size, "--duration", f"{duration:.2f}"],
                       capture_output=True, text=True, cwd=cfg.repo, timeout=600)
    if r.returncode != 0 or not out.exists():
        raise StudioError(f"Motion comp {comp} failed: {(r.stderr or r.stdout)[-400:]}")
    return out
