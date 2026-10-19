"""Synthetic raw take for the demo and the tests: a moving plate (no person) and spoken lines with a retake."""
from __future__ import annotations

import platform
import tempfile
from pathlib import Path

from ..util import StudioError, ffmpeg, have, now_iso, probe, write_json
from ..util import run as run_cmd

# (text, silence in seconds after it). The retake, the filler and the long pause are on purpose.
PARTS = [
    ("Here is a quick tip about goals.", 0.6),
    ("The first thing", 1.0),
    ("um", 0.3),
    ("No, the first thing you need is a clear goal.", 2.4),
    ("Write it on one line.", 0.5),
    ("Then build only that.", 0.4),
]
CARD = {
    "id": "demo", "title": "One clear goal", "format": "same-idea-3-ways", "mode": "cards",
    "hook": {"idea": "Start with one clear goal", "takes": ["Start with one clear goal"]},
    "points": ["One clear goal", "Write it on one line", "Build only that"],
    "payoff": "A goal on one line keeps the build small.", "end_line": "One small build, every day.",
    "script": None, "facts": [], "status": "to_film", "setup": {"urls": [], "apps": []},
}


def _speak(text: str, out: Path) -> Path:
    if platform.system() == "Darwin" and have("say"):
        run_cmd(["say", "-o", str(out), "--data-format=LEI16@22050", text], what="say")
    elif have("espeak-ng"):
        run_cmd(["espeak-ng", "-w", str(out), text], what="espeak-ng")
    else:
        raise StudioError("The demo needs a text to speech voice: `say` on macOS or `espeak-ng` on Linux "
                          "(sudo apt install espeak-ng).")
    return out


def make_take(take_dir: Path) -> list[dict]:
    """Create take.mov + take.json in take_dir. Returns the exact word timings of the synthetic speech."""
    take_dir.mkdir(parents=True, exist_ok=True)
    words: list[dict] = []
    with tempfile.TemporaryDirectory() as tmp:
        t = 0.5
        inputs, filt, labels = [], [], []
        for i, (text, gap) in enumerate(PARTS):
            wav = Path(tmp) / f"p{i}.wav"
            _speak(text, wav)
            dur = probe(wav)["duration"]
            toks = text.split()
            per = dur / len(toks)
            words += [{"w": w, "s": round(t + k * per, 2), "e": round(t + (k + 1) * per, 2)} for k, w in enumerate(toks)]
            inputs += ["-i", wav]
            ms = int(t * 1000)
            filt.append(f"[{i}:a]aresample=48000,aformat=channel_layouts=stereo,adelay={ms}|{ms}[a{i}]")
            labels.append(f"[a{i}]")
            t += dur + gap
        total = t + 0.3
        ffmpeg([*inputs, "-filter_complex", ";".join(filt) + ";" + "".join(labels) + f"amix=inputs={len(PARTS)}:normalize=0,"
                f"apad,atrim=0:{total:.2f}[a]", "-map", "[a]", "-ar", "48000", Path(tmp) / "voice.wav"], what="demo voice")
        plate = ("color=c=0x24304a:s=1080x1920:r=30[bg];color=c=0xffd84d:s=360x360:r=30[sq];"
                 "[bg][sq]overlay=x='(W-w)/2+250*sin(2*t)':y='700+60*cos(3*t)',format=yuv420p[v]")
        ffmpeg(["-i", Path(tmp) / "voice.wav", "-filter_complex", plate, "-map", "[v]", "-map", "0:a", "-t", f"{total:.2f}", "-c:v", "libx264",
                "-preset", "veryfast", "-crf", "18", "-c:a", "aac", "-b:a", "160k", take_dir / "take.mov"], what="demo video")
    write_json(take_dir / "take.json", {
        "schema": "take/v1", "id": "demo", "kind": "short", "take": 1, "mode": "cards", "started": now_iso(),
        "duration_s": round(total, 2), "fps": 30, "files": {"camera": "take.mov", "screen": None},
        "crop": {"x": 0, "y": 0, "w": 1080, "h": 1920, "mirrored": False}, "clicks": None})
    return words
