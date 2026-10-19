"""./studio demo: the whole Shorts loop on a synthetic take. LLM steps use fixed text with --offline."""
from __future__ import annotations

from pathlib import Path

from .. import brand as brand_mod
from .. import build_short, checks, cover, motion, package, pipeline, schemas, spec as spec_mod
from ..config import Config
from ..util import StudioError, ffmpeg, write_json
from . import CARD, make_take


DEMO_MOTION = [
    None,
    {"comp": "big-number", "zone": "split", "vars": {"variant": "hero", "value": 1, "prefix": "", "label": "clear goal", "count_at": 0.2}},
    {"comp": "stamp", "zone": "split", "vars": {"variant": "ink", "text": "ONE LINE", "sub": "then build it", "at": 0.3}},
]


def creative_fixture(brand: dict, cut_duration: float, with_motion: bool = False) -> dict:
    """A fixed creative.json: three beats across the cut, layouts taken from the look.
    With the motion kit installed, the second and third beats get a real motion graphic."""
    avail = brand["look"].get("layouts") or ["face"]
    order = [l for l in ("face", "split", "graphic") if l in avail] or ["face"]
    third = round(cut_duration / 3, 2)
    texts = ["", "One clear goal", "One line"]
    beats = []
    for i in range(3):
        a = round(i * third, 2)
        b = round(cut_duration if i == 2 else (i + 1) * third, 2)
        beats.append({"from": a, "to": b, "layout": order[i % len(order)], "caption": True,
                      "motion": DEMO_MOTION[i] if with_motion and order[i % len(order)] != "face" else None,
                      "text": texts[i], "why": "Fixed demo beat."})
    return {"schema": "creative/v1", "vision": "Plain and calm.",
            "hook": {"text": CARD["hook"]["idea"], "emphasis": "clear goal", "take": 0},
            "keywords": ["goal", "line"], "beats": beats,
            "cover": {"frame_at": 1.0, "words": "One clear goal", "emphasis": "goal"},
            "end": {"line": CARD["end_line"], "cta": ""}, "music": False, "notes": "Offline demo fixture."}


def before_after(raw: Path, final: Path, out: Path) -> Path:
    out.parent.mkdir(parents=True, exist_ok=True)
    fc = ("[0:v]scale=540:960,setsar=1,fps=30[l];[1:v]scale=540:960,setsar=1,fps=30[r];[l][r]hstack=inputs=2:shortest=0[v];"
          "[1:a]apad[a]")
    ffmpeg(["-i", raw, "-i", final, "-filter_complex", fc, "-map", "[v]", "-map", "[a]", "-c:v", "libx264",
            "-pix_fmt", "yuv420p", "-crf", "20", "-c:a", "aac", "-shortest", out], what="before and after")
    return out


def run(cfg: Config, offline: bool = True) -> dict:
    cfg.ensure()
    brand = brand_mod.build(cfg)
    take_dir = cfg.takes_dir("shorts") / "demo-demo-take-1"
    print("1/7 making a synthetic take (speech with a retake, a filler and a long pause)")
    known = make_take(take_dir)
    edit = pipeline.edit_dir_for_take(cfg, "short", take_dir)
    print("2/7 words")
    try:
        pipeline.run_words(cfg, "short", take_dir)
    except StudioError as e:
        print(f"    speech to text unavailable ({e}); using the known timings")
        write_json(edit / "work" / "words.json", known)
        write_json(edit / "work" / "take_ref.json", {"take": str(take_dir), "source": str(take_dir / "take.mov"), "unmirror": False})
    print("3/7 cut")
    _, plan = pipeline.run_cut(cfg, "short", take_dir)
    print("    " + plan.review().replace("\n", "\n    "))
    print("4/7 creative (fixed fixture)" if offline else "4/7 creative (fixture)")
    write_json(edit / "creative.json", creative_fixture(brand, plan.duration, motion.available(cfg)))
    write_json(cfg.workspace / "shorts" / "demo-cards.json", {"schema": "cards/v1", "week": "demo", "cards": [CARD]})
    spec_mod.from_creative(cfg, edit, "short", brand)
    if motion.available(cfg):
        print("    rendering motion graphics")
        pipeline.render_motion(cfg, edit)
    print("5/7 build")
    report = build_short.build(cfg, edit)
    cover.make(cfg, edit, "short")
    print("6/7 posting text" + (" (template)" if offline else ""))
    package.generate(cfg, brand, edit, offline=offline)
    schemas.set_status(edit, "ready_for_review", "Demo edit.")
    results = checks.check_edit(cfg, edit, "short")
    print("7/7 before and after")
    ba = before_after(take_dir / "take.mov", edit / "final.mp4", cfg.repo / "demo" / "out" / "before_after.mp4")
    failed = [k for k, v in results.items() if not v["ok"]]
    print(f"\nfinal:        {edit / 'final.mp4'}\ncover:        {edit / 'cover.jpg'}\nposting text: {edit / 'POSTING.md'}\n"
          f"before/after: {ba}\nself checks:  {'all passed' if not failed else 'failed: ' + ', '.join(failed)}")
    for w in report["warnings"]:
        print(f"warning: {w}")
    return {"edit": str(edit), "checks": results, "report": report, "before_after": str(ba)}
