"""Small helpers shared by every module."""
from __future__ import annotations

import datetime as dt
import json
import re
import shutil
import subprocess
from pathlib import Path


class StudioError(Exception):
    """A problem the user can fix. The message is a plain sentence."""


def now_iso() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_json(path: Path | str):
    p = Path(path)
    try:
        return json.loads(p.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise StudioError(f"File not found: {p}")
    except json.JSONDecodeError as e:
        raise StudioError(f"{p.name} is not valid JSON (line {e.lineno}: {e.msg}).")


def write_json(path: Path | str, data) -> Path:
    p = Path(path)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    return p


def have(tool: str) -> bool:
    return shutil.which(tool) is not None


def run(cmd: list[str], *, what: str = "", cwd=None, timeout=None) -> subprocess.CompletedProcess:
    """Run a command, raise StudioError with the tail of stderr on failure."""
    try:
        r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True, cwd=cwd, timeout=timeout)
    except FileNotFoundError:
        raise StudioError(f"{cmd[0]} is not installed. Run ./studio doctor.")
    if r.returncode != 0:
        tail = (r.stderr or r.stdout or "").strip()[-600:]
        raise StudioError(f"{what or cmd[0]} failed: {tail}")
    return r


def ffmpeg(args: list, *, what: str = "ffmpeg") -> None:
    run(["ffmpeg", "-v", "error", "-y", *args], what=what)


def probe(path: Path | str) -> dict:
    """Return width, height, fps, duration, has_audio, hdr, rotation for a media file."""
    r = run(["ffprobe", "-v", "error", "-show_streams", "-show_format", "-of", "json", path], what="ffprobe")
    j = json.loads(r.stdout)
    v = next((s for s in j.get("streams", []) if s.get("codec_type") == "video"), None)
    a = [s for s in j.get("streams", []) if s.get("codec_type") == "audio"]
    info = {"duration": float(j.get("format", {}).get("duration") or 0), "has_audio": bool(a),
            "audio_codecs": [s.get("codec_name") for s in a]}
    if v:
        num, _, den = (v.get("avg_frame_rate") or "0/1").partition("/")
        fps = float(num) / float(den or 1) if float(den or 1) else 0.0
        rot = 0
        for sd in v.get("side_data_list", []) or []:
            if "rotation" in sd:
                rot = int(sd["rotation"]) % 360
        w, h = int(v["width"]), int(v["height"])
        if rot in (90, 270):
            w, h = h, w
        info.update(width=w, height=h, fps=round(fps, 3), rotation=rot,
                    hdr=v.get("color_transfer") in ("smpte2084", "arib-std-b67"),
                    pix_fmt=v.get("pix_fmt"))
    return info


def slug(text: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "item"


def hex_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)
