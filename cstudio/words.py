"""Word timings for captions and cuts.

Words are dicts: {"w": "text", "s": start_seconds, "e": end_seconds}, in the time of the file they came from.
whisper.cpp (`whisper-cli`) is tried first, then faster-whisper if it is installed.
"""
from __future__ import annotations

import json
import re
import tempfile
from pathlib import Path

from .util import StudioError, have, probe, run

MODEL_DIR = Path.home() / ".cache" / "whisper-cpp"
MODEL_NAME = "ggml-base.en.bin"


def model_path() -> Path:
    return MODEL_DIR / MODEL_NAME


def tidy_tokens(tokens: list[dict]) -> list[dict]:
    """Merge the odd splits whisper makes: bare punctuation, "'s" endings, acronyms in pieces."""
    out: list[dict] = []
    for tk in tokens:
        w = (tk["w"] or "").strip()
        if not w:
            continue
        if not re.search(r"[A-Za-z0-9]", w) or w.startswith("'"):
            if out:
                out[-1]["w"] += w
                out[-1]["e"] = max(out[-1]["e"], tk["e"])
            continue
        if out and abs(out[-1]["s"] - tk["s"]) < 0.005:      # one word split in two
            glue = "" if (w.isupper() and out[-1]["w"].isupper()) else " "
            out[-1]["w"] += glue + w
            out[-1]["e"] = max(out[-1]["e"], tk["e"])
            continue
        out.append({"w": w, "s": round(tk["s"], 2), "e": round(tk["e"], 2)})
    return out


def apply_fixes(words: list[dict], fixes: dict | None) -> list[dict]:
    """Replace whole-word mishearings. `fixes` comes from brand.json editing.word_fixes (optional)."""
    if not fixes:
        return words
    lower = {k.lower(): v for k, v in fixes.items()}
    for wd in words:
        core = re.sub(r"[^\w']", "", wd["w"]).lower()
        if core in lower:
            wd["w"] = re.sub(re.escape(core), lower[core], wd["w"], count=1, flags=re.I)
    return words


def _extract_audio(src: Path, wav: Path) -> None:
    info = probe(src)
    if not info["has_audio"]:
        raise StudioError(f"{src.name} has no audio track.")
    r = run(["ffprobe", "-v", "error", "-select_streams", "a", "-show_entries", "stream=index,codec_name",
             "-of", "json", src], what="ffprobe")
    streams = json.loads(r.stdout).get("streams", [])
    good = [s for s in streams if s.get("codec_name") not in ("apac", "none", None)]
    amap = ["-map", f"0:{good[0]['index']}"] if good and len(streams) > 1 else []
    run(["ffmpeg", "-v", "error", "-y", "-i", src, *amap, "-vn", "-ar", "16000", "-ac", "1",
         "-c:a", "pcm_s16le", wav], what="audio extract")


def _whisper_cpp(wav: Path, language: str) -> list[dict]:
    model = model_path()
    if not model.exists():
        raise StudioError(f"Whisper model missing: {model}. Run ./studio setup.")
    stem = wav.with_suffix("")
    run(["whisper-cli", "-m", model, "-f", wav, "-ml", "1", "-oj", "-of", stem, "-l", language, "--no-prints"],
            what="whisper-cli")
    data = json.loads(stem.with_suffix(".json").read_text(encoding="utf-8"))
    toks = [{"w": s.get("text", ""), "s": s["offsets"]["from"] / 1000, "e": s["offsets"]["to"] / 1000}
            for s in data.get("transcription", [])]
    return tidy_tokens(toks)


def _faster_whisper(wav: Path, language: str) -> list[dict]:
    from faster_whisper import WhisperModel  # optional dependency
    model = WhisperModel("base.en" if language == "en" else "base", compute_type="int8")
    segs, _ = model.transcribe(str(wav), word_timestamps=True, language=language)
    toks = [{"w": w.word, "s": w.start, "e": w.end} for seg in segs for w in (seg.words or [])]
    return tidy_tokens(toks)


def transcribe(src: Path | str, language: str = "en", fixes: dict | None = None) -> list[dict]:
    """Transcribe a video or audio file to word timings."""
    src = Path(src)
    if not src.exists():
        raise StudioError(f"File not found: {src}")
    with tempfile.TemporaryDirectory(prefix="cs_words_") as tmp:
        wav = Path(tmp) / "a.wav"
        _extract_audio(src, wav)
        if have("whisper-cli") and model_path().exists():
            words = _whisper_cpp(wav, language)
        else:
            try:
                words = _faster_whisper(wav, language)
            except ImportError:
                raise StudioError("No speech-to-text engine found. Run ./studio setup "
                                  "(it installs whisper.cpp and the model).")
    return apply_fixes(words, fixes)


def to_output_time(words: list[dict], segments: list[dict]) -> list[dict]:
    """Map source-time words to the clock of the cut video, in the order the segments play."""
    out, offset = [], 0.0
    for seg in segments:
        for wd in words:
            if seg["start"] - 0.05 <= wd["s"] < seg["end"]:
                s = offset + max(0.0, wd["s"] - seg["start"])
                e = offset + min(seg["end"], wd["e"]) - seg["start"]
                out.append({"w": wd["w"], "s": round(s, 3), "e": round(max(e, s + 0.05), 3)})
        offset += seg["end"] - seg["start"]
    return sorted(out, key=lambda x: x["s"])
