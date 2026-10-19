"""Decide what to keep from a raw take: pauses, fillers, retakes and spoken cues come out.

`plan()` is pure: it takes word timings (and optionally silences) and returns segments in source time.
`cut_take()` adds the ffmpeg parts (silence detection) around it.
"""
from __future__ import annotations

import difflib
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .util import StudioError, probe

FILLERS = {"um", "uh", "erm", "hmm", "uhm", "er", "ah"}
LEAD_FILLERS = {"no", "sorry", "wait", "so", "well", "okay", "ok", "actually"}
# Spoken cues. "undo" removes the sentence just before the cue. "restart" removes everything before it.
DEFAULT_CUES = {
    "undo": ["scratch that", "let me redo that", "cut that", "delete that", "strike that", "no wait"],
    "restart": ["from the top", "start over", "take two", "let me start over", "one more time from the top"],
}
NEAR_UNITS, NEAR_SECONDS = 6, 30.0


def norm(w: str) -> str:
    return re.sub(r"[^a-z0-9']", "", w.lower())


@dataclass
class CutPlan:
    segments: list[dict]
    dropped: list[dict] = field(default_factory=list)
    flags: list[str] = field(default_factory=list)
    kept_words: list[dict] = field(default_factory=list)

    @property
    def duration(self) -> float:
        return round(sum(s["end"] - s["start"] for s in self.segments), 3)

    def to_json(self) -> dict:
        return {"schema": "cut/v1", "duration": self.duration, "segments": self.segments,
                "dropped": self.dropped, "flags": self.flags}

    def review(self) -> str:
        lines = [f"{len(self.segments)} segments, {self.duration:.1f}s kept"]
        for d in self.dropped:
            lines.append(f"  dropped {d['reason']:<10} {d['start']:6.2f}-{d['end']:6.2f}  {d['text']}")
        lines += [f"  CHECK: {f}" for f in self.flags]
        return "\n".join(lines)


def _find_phrase(tokens: list[str], phrase: str, start: int = 0) -> int:
    want = phrase.split()
    for i in range(start, len(tokens) - len(want) + 1):
        if tokens[i:i + len(want)] == want:
            return i
    return -1


def _apply_cues(ws: list[dict], cues: dict, min_sil: float) -> None:
    toks = [w["n"] for w in ws]
    for kind, phrases in cues.items():
        for phrase in phrases:
            at = _find_phrase(toks, phrase)
            while at != -1:
                end = at + len(phrase.split())
                if kind == "restart":
                    first = 0
                else:
                    first = at
                    while first > 0:
                        prev = ws[first - 1]
                        if prev["raw"][-1:] in ".?!" or ws[first]["s"] - prev["e"] >= min_sil:
                            break
                        first -= 1
                for i in range(first, end):
                    if not ws[i].get("drop"):
                        ws[i]["drop"] = "cue"
                at = _find_phrase(toks, phrase, end)


def _runs(ws: list[dict], min_sil: float, silences) -> list[list[dict]]:
    """Group kept words into units: runs with no pause and no dropped word between them."""
    runs: list[list[dict]] = []
    cur: list[dict] = []
    prev = None
    for w in ws:
        if w.get("drop"):
            if cur:
                runs.append(cur)
            cur, prev = [], w
            continue
        if prev is not None:
            gap = w["s"] - prev["e"]
            paused = gap >= min_sil or any(a < w["s"] and b > prev["e"] and min(b, w["s"]) - max(a, prev["e"]) >= min_sil * 0.8
                                           for a, b in silences)
            if paused and cur:
                runs.append(cur)
                cur = []
        cur.append(w)
        prev = w
    if cur:
        runs.append(cur)
    return runs


def _align(ws: list[dict], silences) -> None:
    """Whisper stretches words across pauses. Pull each word's edges out of any detected silence."""
    for w in ws:
        for a, b in silences:
            if a < w["s"] < b and b - 0.02 < w["e"]:
                w["s"] = b - 0.02
        for a, b in silences:
            if w["s"] < a < w["e"]:
                w["e"] = max(a, w["s"] + 0.05)


def _is_retake(a: list[str], b: list[str]) -> bool:
    """True when unit a is an earlier, shorter or equal attempt at the start of unit b."""
    k = min(len(a), len(b))
    if k < 2 or len(a) > len(b) + 1:
        return False
    return difflib.SequenceMatcher(None, a[:k], b[:k]).ratio() >= 0.8


def plan(words: list[dict], silences=(), duration: float | None = None, *, min_sil: float = 0.35,
         pad_in: float = 0.06, pad_out: float = 0.10, keep_pause: float = 0.0, cues: dict | None = None) -> CutPlan:
    """Return the segments to keep (source time) for a list of word timings."""
    if not words:
        raise StudioError("No words to cut. Is the take silent?")
    cues = {**DEFAULT_CUES, **(cues or {})}
    ws = [{"raw": w["w"], "n": norm(w["w"]), "s": w["s"], "e": w["e"], "w": w["w"]} for w in words]
    ws = [w for w in ws if w["n"]]
    flags: list[str] = []
    _align(ws, silences)

    _apply_cues(ws, cues, min_sil)
    for w in ws:
        if not w.get("drop") and w["n"] in FILLERS:
            w["drop"] = "filler"
    # a filler like "no," or "sorry" right after a pause, when real words follow
    for i, w in enumerate(ws):
        if w.get("drop") or w["n"] not in LEAD_FILLERS:
            continue
        starts_unit = i == 0 or ws[i - 1].get("drop") or w["s"] - ws[i - 1]["e"] >= min_sil
        follow = [x for x in ws[i + 1:i + 5] if not x.get("drop")]
        if starts_unit and len(follow) >= 2:
            w["drop"] = "filler"

    units = _runs(ws, min_sil, silences)
    dropped_units: set[int] = set()
    for i, a in enumerate(units):
        ta = [w["n"] for w in a]
        for j in range(i + 1, min(i + 1 + NEAR_UNITS, len(units))):
            if j in dropped_units or units[j][0]["s"] - a[-1]["e"] > NEAR_SECONDS:
                continue
            if _is_retake(ta, [w["n"] for w in units[j]]):
                dropped_units.add(i)
                break
    # a word repeated three or more tokens in a row inside one unit: keep the second copy
    for i, u in enumerate(units):
        if i in dropped_units:
            continue
        toks = [w["n"] for w in u]
        for n in range(6, 2, -1):
            p = 0
            while p + 2 * n <= len(toks):
                if toks[p:p + n] == toks[p + n:p + 2 * n]:
                    for w in u[p:p + n]:
                        w["drop"] = "inline"
                    flags.append(f"inline repeat at {u[p]['s']:.2f}s: {' '.join(toks[p:p + n])} (check by ear)")
                    p += n
                else:
                    p += 1
    for i in dropped_units:
        for w in units[i]:
            w["drop"] = "retake"

    units = _runs(ws, min_sil, silences)
    segs: list[dict] = []
    pad_a = pad_in + keep_pause / 2
    pad_b = pad_out + keep_pause / 2
    for u in units:
        s, e = u[0]["s"], u[-1]["e"]
        before = [w for w in ws if w["e"] <= u[0]["s"] + 1e-6 and w is not u[0]]
        after = [w for w in ws if w["s"] >= u[-1]["e"] - 1e-6 and w is not u[-1]]
        gap_b = s - before[-1]["e"] if before else s
        gap_a = after[0]["s"] - e if after else ((duration or e + 1) - e)
        s = max(0.0, s - min(pad_a, max(gap_b, 0) / 2))
        e = e + min(pad_b, max(gap_a, 0) / 2)
        if duration:
            e = min(e, duration)
        segs.append({"start": round(s, 3), "end": round(e, 3)})
    merged: list[dict] = []
    for sg in segs:
        if merged and sg["start"] - merged[-1]["end"] < 0.03:
            merged[-1]["end"] = sg["end"]
        elif sg["end"] - sg["start"] >= 0.12:
            merged.append(dict(sg))

    dropped = []
    for reason in ("cue", "retake", "filler", "inline"):
        run_: list[dict] = []
        for w in ws + [{"drop": None}]:
            if w.get("drop") == reason:
                run_.append(w)
            elif run_:
                dropped.append({"reason": reason, "start": run_[0]["s"], "end": run_[-1]["e"],
                                "text": " ".join(x["raw"] for x in run_)})
                run_ = []
    dropped.sort(key=lambda d: d["start"])
    kept = [{"w": w["w"], "s": w["s"], "e": w["e"]} for w in ws if not w.get("drop")]
    return CutPlan(segments=merged, dropped=dropped, flags=flags, kept_words=kept)


def auto_noise_db(src: Path) -> float:
    """Silence threshold for this take: 30 percent from the room floor to the speech level."""
    import numpy as np
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", str(src), "-vn", "-ac", "1", "-ar", "16000", "-f", "s16le", "-"],
                         capture_output=True).stdout
    x = np.frombuffer(raw, np.int16).astype(np.float32) / 32768.0
    win = 480
    n = len(x) // win
    if n < 10:
        return -35.0
    peaks = np.abs(x[:n * win].reshape(n, win)).max(axis=1) + 1e-6
    db = 20 * np.log10(peaks)
    floor, speech = np.percentile(db, 10), np.percentile(db, 90)
    return float(np.clip(floor + 0.3 * (speech - floor), -55, -25))


def detect_silences(src: Path, min_sil: float = 0.35) -> list[tuple[float, float]]:
    noise = auto_noise_db(src)
    r = subprocess.run(["ffmpeg", "-v", "info", "-i", str(src), "-vn", "-af", f"silencedetect=noise={noise:.1f}dB:d={min_sil}",
                        "-f", "null", "-"], capture_output=True, text=True)
    out, cur = [], None
    for line in r.stderr.splitlines():
        m = re.search(r"silence_start: (-?[\d.]+)", line)
        if m:
            cur = max(0.0, float(m.group(1)))
        m = re.search(r"silence_end: ([\d.]+)", line)
        if m and cur is not None:
            out.append((cur, float(m.group(1))))
            cur = None
    if cur is not None:
        out.append((cur, probe(src)["duration"]))
    return out


def cut_take(video: Path, words: list[dict], brand: dict | None = None) -> CutPlan:
    editing = (brand or {}).get("editing", {})
    dur = probe(video)["duration"]
    return plan(words, detect_silences(video), dur, keep_pause=0.35 if editing.get("keep_pauses") else 0.0,
                cues=editing.get("cues") or None)
