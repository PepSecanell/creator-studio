import json
import shutil
import subprocess

import pytest

from cstudio import build_short, checks, cover, cut, kit, package, schemas, sound, spec as spec_mod
from cstudio.util import probe, write_json
from .conftest import needs_ffmpeg

pytestmark = [pytest.mark.slow, needs_ffmpeg]


def synth(path, seconds=3):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=s=1080x1920:r=25:d={seconds}",
                    "-f", "lavfi", "-i", f"sine=f=330:d={seconds}", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac",
                    "-shortest", str(path)], check=True)


def test_build_short_end_to_end(cfg, tmp_path):
    src = tmp_path / "take.mov"
    synth(src)
    ed = cfg.edit_dir("shorts", "e2e")
    words = [{"w": w, "s": 0.2 + i * 0.35, "e": 0.45 + i * 0.35} for i, w in enumerate("make one small thing today please".split())]
    spec = {"schema": "short-spec/v1", "id": "e2e", "source": str(src), "unmirror": False,
            "segments": [{"start": 0.0, "end": 1.4, "layout": "face", "zoom": 1.0},
                         {"start": 1.4, "end": 2.6, "layout": "split", "text": "One small thing"}],
            "words": words, "keywords": ["small"], "captions": True, "caption_off": [],
            "hook": {"text": "Make one small thing", "seconds": 1.5}, "overlays": [{"comp": "x", "vars": {}, "at": 0.5, "duration": 1, "zone": "full", "file": "work/motion/none.webm"}],
            "end": {"line": "Bye"}, "cover": {"words": "One small thing", "frame_at": 0.5}, "music": False}
    write_json(ed / "spec.json", spec)
    report = build_short.build(cfg, ed)
    info = probe(ed / "final.mp4")
    assert (info["width"], info["height"]) == (1080, 1920)
    assert abs(info["fps"] - 30) < 0.1 and info["has_audio"]
    assert abs(info["duration"] - (2.6 + build_short.END_SECONDS)) < 0.2
    assert any("no rendered file" in w for w in report["warnings"])     # missing motion file is a warning, not a crash
    lufs = sound.integrated_lufs(ed / "final.mp4")
    assert lufs is not None and abs(lufs + 14) < 2.0
    assert cover.make(cfg, ed, "short").exists()
    frames = checks.extract_frames(ed, every=1.0)
    assert len(frames) >= 4 and all(p.exists() for p in frames)


def test_cut_take_on_real_audio_silence(tmp_path):
    src = tmp_path / "a.wav"
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=f=300:d=1", "-f", "lavfi", "-i", "anullsrc=d=1.5:r=44100",
                    "-f", "lavfi", "-i", "sine=f=300:d=1", "-filter_complex", "[0][1][2]concat=n=3:v=0:a=1", str(src)], check=True)
    sil = cut.detect_silences(src)
    assert len(sil) == 1 and 0.8 < sil[0][0] < 1.2 and sil[0][1] - sil[0][0] > 1.2


def test_demo_offline_full_loop(cfg):
    if not (shutil.which("say") or shutil.which("espeak-ng")):
        pytest.skip("no text to speech voice")
    from cstudio.demo import run as demo
    out = demo.run(cfg, offline=True)
    ed = cfg.edit_dir("shorts", "demo")
    for name in ("final.mp4", "cover.jpg", "POSTING.md", "creative.json", "spec.json", "status.json"):
        assert (ed / name).exists(), name
    assert all(v["ok"] for v in out["checks"].values()), out["checks"]
    assert (cfg.repo / "demo" / "out" / "before_after.mp4").exists()
    problems, _ = checks.check_creative(cfg, ed / "creative.json")
    assert problems == []
    assert not package.dash_violations((ed / "POSTING.md").read_text())
    kit_dir = kit.build(cfg, "2026-01-01")
    assert len(json.loads((kit_dir / "kit.json").read_text())["items"]) == 3
    cutinfo = json.loads((ed / "work" / "cut.json").read_text())
    assert any(d["reason"] in ("retake", "filler") for d in cutinfo["dropped"])
