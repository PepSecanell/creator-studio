"""Where the repo and the workspace live. Read from ~/.config/creator-studio/config.json."""
from __future__ import annotations

import json
import os
from dataclasses import dataclass
from pathlib import Path

from .util import StudioError

CONFIG_ENV = "CREATOR_STUDIO_CONFIG"
WORKSPACE_ENV = "CREATOR_STUDIO_WORKSPACE"
SCHEMA = "cs-config/v1"


def config_path() -> Path:
    env = os.environ.get(CONFIG_ENV)
    return Path(env).expanduser() if env else Path.home() / ".config" / "creator-studio" / "config.json"


@dataclass(frozen=True)
class Config:
    repo: Path
    workspace: Path

    @property
    def brand_dir(self) -> Path:
        return self.repo / "brand"

    @property
    def looks_dir(self) -> Path:
        return self.repo / "looks"

    @property
    def motion_dir(self) -> Path:
        return self.repo / "motion"

    @property
    def resolved_dir(self) -> Path:
        return self.workspace / ".brand"

    def edit_dir(self, kind: str, ident: str) -> Path:
        return self.workspace / "edits" / kind / ident

    def takes_dir(self, kind: str) -> Path:
        return self.workspace / "takes" / kind

    def ensure(self) -> "Config":
        for sub in ("ideas", "handoff", "takes/shorts", "takes/long", "edits/shorts", "edits/long", "kits", "logs"):
            (self.workspace / sub).mkdir(parents=True, exist_ok=True)
        return self


def write(repo: Path, workspace: Path | None = None) -> Path:
    repo = Path(repo).resolve()
    ws = Path(workspace).resolve() if workspace else repo / "workspace"
    p = config_path()
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps({"schema": SCHEMA, "repo": str(repo), "workspace": str(ws)}, indent=2) + "\n")
    return p


def load() -> Config:
    """Config file first, then the repo this package sits in. Env vars override the workspace."""
    repo = Path(__file__).resolve().parent.parent
    workspace = None
    p = config_path()
    if p.exists():
        try:
            d = json.loads(p.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            raise StudioError(f"{p} is not valid JSON. Run ./studio setup to rewrite it.")
        repo = Path(d.get("repo") or repo)
        workspace = Path(d["workspace"]) if d.get("workspace") else None
    env_ws = os.environ.get(WORKSPACE_ENV)
    if env_ws:
        workspace = Path(env_ws).expanduser()
    return Config(repo=repo, workspace=workspace or repo / "workspace")
