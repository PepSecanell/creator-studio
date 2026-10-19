"""./studio doctor: check the machine in plain words."""
from __future__ import annotations

import platform
import sys

from . import brand as brand_mod
from . import config, motion, words
from .util import StudioError, have


def checks() -> list[tuple[str, bool, str, bool]]:
    """(name, ok, how to fix, required)"""
    mac = platform.system() == "Darwin"
    cfg = config.load()
    res: list[tuple[str, bool, str, bool]] = []
    res.append(("Python 3.10 or newer", sys.version_info >= (3, 10), "Install Python 3.10+", True))
    for mod, pkg in (("PIL", "Pillow"), ("numpy", "numpy")):
        try:
            __import__(mod)
            ok = True
        except ImportError:
            ok = False
        res.append((f"Python package {pkg}", ok, "Run ./studio setup", True))
    try:
        import cv2  # noqa: F401
        cv = True
    except ImportError:
        cv = False
    res.append(("OpenCV (face tracking)", cv, "pip install opencv-python-headless. Without it, framing is centred.", False))
    res.append(("ffmpeg", have("ffmpeg"), "brew install ffmpeg" if mac else "sudo apt install ffmpeg", True))
    res.append(("ffprobe", have("ffprobe"), "It comes with ffmpeg.", True))
    res.append(("whisper-cli (speech to text)", have("whisper-cli") or _has_fw(),
                "brew install whisper-cpp, or pip install faster-whisper", True))
    res.append(("Whisper model", words.model_path().exists() or _has_fw(), f"Run ./studio setup (downloads {words.MODEL_NAME})", True))
    res.append(("claude CLI (Claude Code)", have("claude"), "Install Claude Code: https://claude.com/claude-code", False))
    res.append(("node (motion graphics)", have("node"), "brew install node", False))
    res.append(("motion kit installed", motion.available(cfg), "Run ./studio setup (npm install in motion/)", False))
    res.append(("config file", config.config_path().exists(), "Run ./studio setup", False))
    try:
        b = brand_mod.load_cfg(cfg)
        res.append((f"brand '{b['name']}' with look '{b['style']}'", True, "", True))
    except StudioError as e:
        res.append(("brand file", False, str(e), True))
    return res


def _has_fw() -> bool:
    try:
        import faster_whisper  # noqa: F401
        return True
    except ImportError:
        return False


def run() -> int:
    bad = 0
    for name, ok, fix, required in checks():
        mark = "ok     " if ok else ("MISSING" if required else "optional")
        print(f"[{mark}] {name}" + ("" if ok else f"\n           {fix}"))
        bad += (not ok) and required
    print("\nEverything needed is installed." if not bad else f"\n{bad} required thing(s) missing.")
    return 1 if bad else 0
