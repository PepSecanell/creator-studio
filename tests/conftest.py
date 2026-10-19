import json
import shutil
from pathlib import Path

import pytest

from cstudio.config import Config

FIX = Path(__file__).parent / "fixtures"
HAVE_FFMPEG = shutil.which("ffmpeg") is not None and shutil.which("ffprobe") is not None
needs_ffmpeg = pytest.mark.skipif(not HAVE_FFMPEG, reason="ffmpeg not installed")


@pytest.fixture
def cfg(tmp_path):
    """A throwaway repo: brand + the test look, empty workspace."""
    repo = tmp_path / "repo"
    (repo / "brand").mkdir(parents=True)
    shutil.copy(FIX / "brand.json", repo / "brand" / "brand.json")
    shutil.copytree(FIX / "looks", repo / "looks")
    return Config(repo=repo, workspace=tmp_path / "ws").ensure()


@pytest.fixture
def brand(cfg):
    from cstudio import brand as b
    return b.load_cfg(cfg)


def write_brand(cfg, **changes):
    p = cfg.brand_dir / "brand.json"
    d = json.loads(p.read_text())
    for k, v in changes.items():
        d[k] = v
    p.write_text(json.dumps(d))
