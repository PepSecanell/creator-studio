"""Sound: voice cut together, optional music bed, synthesised sfx, loudness to -14 LUFS.

Only sounds that are safe to ship are used. SFX are made with ffmpeg here. Music is never bundled: if you want
a bed, drop files in brand/sounds/ (mp3, wav, m4a, ogg) and set editing.music to true.
"""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path

from .util import ffmpeg

TARGET_LUFS = -14.0
MUSIC_EXT = (".mp3", ".wav", ".m4a", ".ogg", ".flac")

SFX_RECIPES = {
    "pop": ["-f", "lavfi", "-i", "sine=f=880:d=0.18", "-af", "afade=t=out:st=0.02:d=0.16,volume=0.5"],
    "tick": ["-f", "lavfi", "-i", "sine=f=1800:d=0.06", "-af", "afade=t=out:st=0.005:d=0.05,volume=0.4"],
    "whoosh": ["-f", "lavfi", "-i", "anoisesrc=d=0.45:c=pink:a=0.5", "-af",
               "bandpass=f=1400:w=1200,afade=t=in:st=0:d=0.2,afade=t=out:st=0.2:d=0.25,volume=0.7"],
}


def sfx_file(name: str, cache: Path) -> Path:
    cache.mkdir(parents=True, exist_ok=True)
    out = cache / f"{name}.wav"
    if not out.exists():
        ffmpeg([*SFX_RECIPES[name], "-ar", "48000", "-ac", "2", out], what="sfx")
    return out


def pick_music(brand_dir: Path, seed: str) -> Path | None:
    folder = Path(brand_dir) / "sounds"
    files = sorted(p for p in folder.glob("*") if p.suffix.lower() in MUSIC_EXT) if folder.is_dir() else []
    if not files:
        return None
    return files[int(hashlib.sha1(seed.encode()).hexdigest(), 16) % len(files)]


def voice_filter(segments: list[dict], input_index: int = 0) -> tuple[str, float]:
    """filter_complex part that cuts and joins the voice. Returns (graph ending in [voice], total seconds)."""
    parts, labels = [], []
    for i, s in enumerate(segments):
        d = s["end"] - s["start"]
        fade = min(0.012, d / 4)
        parts.append(f"[{input_index}:a]atrim={s['start']:.3f}:{s['end']:.3f},asetpts=PTS-STARTPTS,"
                     f"afade=t=in:d={fade:.3f},afade=t=out:st={d - fade:.3f}:d={fade:.3f}[a{i}]")
        labels.append(f"[a{i}]")
    parts.append("".join(labels) + f"concat=n={len(segments)}:v=0:a=1[voice]")
    return ";".join(parts), sum(s["end"] - s["start"] for s in segments)


def mix(src: Path, segments: list[dict], total: float, out: Path, *, music: Path | None = None,
        sfx: list[tuple[str, float]] = (), sfx_dir: Path | None = None) -> Path:
    """Write out (wav, 48k stereo): voice, ducked music, sfx. `total` includes `tail` seconds of end card."""
    graph, _ = voice_filter(segments)
    inputs = ["-i", src]
    idx = 1
    if music:
        graph += f";[voice]apad=whole_dur={total:.3f},asplit=2[voicep][sc]"
        inputs += ["-stream_loop", "-1", "-i", music]
        graph += (f";[{idx}:a]atrim=0:{total:.3f},asetpts=PTS-STARTPTS,volume=0.22,"
                  f"afade=t=in:d=0.8,afade=t=out:st={max(0, total - 1.0):.3f}:d=1.0[m];"
                  f"[m][sc]sidechaincompress=threshold=0.04:ratio=8:attack=20:release=400[md]")
        labels = ["[voicep]", "[md]"]
        idx += 1
    else:
        graph += f";[voice]apad=whole_dur={total:.3f}[voicep]"
        labels = ["[voicep]"]
    for name, at in sfx:
        inputs += ["-i", sfx_file(name, sfx_dir or out.parent)]
        graph += f";[{idx}:a]adelay={int(at * 1000)}|{int(at * 1000)},volume=0.6[s{idx}]"
        labels.append(f"[s{idx}]")
        idx += 1
    graph += f";{''.join(labels)}amix=inputs={len(labels)}:normalize=0:duration=first,atrim=0:{total:.3f}[mixed]"
    ffmpeg([*inputs, "-filter_complex", graph, "-map", "[mixed]", "-ar", "48000", "-ac", "2", out], what="audio mix")
    return out


def measure_loudness(path: Path) -> dict:
    r = subprocess.run(["ffmpeg", "-hide_banner", "-i", str(path), "-vn", "-af",
                        f"loudnorm=I={TARGET_LUFS}:TP=-1.5:LRA=11:print_format=json", "-f", "null", "-"],
                       capture_output=True, text=True)
    m = re.search(r"\{[^{}]*\"input_i\"[^{}]*\}", r.stderr, re.S)
    return json.loads(m.group(0)) if m else {}


def normalise(src: Path, out: Path) -> Path:
    """Two pass loudnorm to -14 LUFS integrated."""
    m = measure_loudness(src)
    if m:
        flt = (f"loudnorm=I={TARGET_LUFS}:TP=-1.5:LRA=11:measured_I={m['input_i']}:measured_TP={m['input_tp']}:"
               f"measured_LRA={m['input_lra']}:measured_thresh={m['input_thresh']}:offset={m['target_offset']}:linear=true")
    else:
        flt = f"loudnorm=I={TARGET_LUFS}:TP=-1.5:LRA=11"
    ffmpeg(["-i", src, "-af", flt, "-ar", "48000", "-ac", "2", out], what="loudness")
    return out


def integrated_lufs(path: Path) -> float | None:
    m = measure_loudness(path)
    try:
        return float(m["input_i"])
    except (KeyError, ValueError):
        return None
