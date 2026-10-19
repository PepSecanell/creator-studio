"""Command line entry for ./studio."""
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

from . import __version__, config
from .util import StudioError


def _cfg():
    return config.load().ensure()


def _edit_dir(cfg, kind: str, ref: str) -> Path:
    by_id = cfg.edit_dir("shorts" if kind == "short" else "long", ref)
    p = Path(ref).expanduser()
    return p.resolve() if p.is_dir() and not by_id.is_dir() else by_id


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="studio", description="Edit Shorts and long videos with your own brand.")
    ap.add_argument("--version", action="version", version=__version__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("setup", help="install tools, create the venv, download the speech model")
    sub.add_parser("doctor", help="check what is installed")
    b = sub.add_parser("brand")
    b.add_argument("action", choices=["build", "preview"])
    e = sub.add_parser("edit", help="run the editing agents headless")
    e.add_argument("kind", choices=["short", "long", "pending"])
    e.add_argument("ref", nargs="?")
    e.add_argument("--dry-run", action="store_true", help="print the prompt instead of running claude")
    k = sub.add_parser("kit")
    k.add_argument("date", nargs="?")
    k.add_argument("--approved-only", action="store_true")
    d = sub.add_parser("demo")
    d.add_argument("--offline", action="store_true", help="no Claude calls: fixed text for the LLM steps")
    for name in ("words", "cut"):
        p = sub.add_parser(name, help=f"{name} for a take folder or card id")
        p.add_argument("take")
        p.add_argument("--long", action="store_true")
    s = sub.add_parser("spec")
    s.add_argument("action", choices=["from-creative"])
    s.add_argument("edit")
    s.add_argument("--long", action="store_true")
    r = sub.add_parser("render")
    r.add_argument("what", choices=["motion"])
    r.add_argument("edit")
    r.add_argument("--only")
    r.add_argument("--long", action="store_true")
    bd = sub.add_parser("build")
    bd.add_argument("kind", choices=["short", "long"])
    bd.add_argument("edit")
    cv = sub.add_parser("cover")
    cv.add_argument("edit")
    cv.add_argument("--long", action="store_true")
    pk = sub.add_parser("package")
    pk.add_argument("edit")
    pk.add_argument("--long", action="store_true")
    pk.add_argument("--offline", action="store_true")
    ck = sub.add_parser("check")
    ck.add_argument("what", choices=["creative", "edit"])
    ck.add_argument("path")
    ck.add_argument("--long", action="store_true")
    fr = sub.add_parser("frames")
    fr.add_argument("edit")
    fr.add_argument("--every", type=float, default=1.0)
    return ap


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        return dispatch(args)
    except StudioError as e:
        print(f"Problem: {e}", file=sys.stderr)
        return 1


def dispatch(a) -> int:
    kind = "long" if getattr(a, "long", False) else "short"
    if a.cmd == "setup":
        script = Path(__file__).resolve().parent.parent / "scripts" / "setup.sh"
        return subprocess.call(["bash", str(script)])
    if a.cmd == "doctor":
        from . import doctor
        return doctor.run()
    if a.cmd == "demo":
        from .demo import run as demo_run
        demo_run.run(_cfg(), offline=a.offline)
        return 0
    cfg = _cfg()
    if a.cmd == "brand":
        from . import brand
        if a.action == "build":
            b = brand.build(cfg)
            print(f"Brand '{b['name']}' with look '{b['style']}' written to {cfg.resolved_dir}")
        else:
            from . import preview
            print(f"Preview written to {preview.render(cfg)}")
    elif a.cmd == "edit":
        from . import edit
        if a.kind == "pending":
            for name, state in edit.edit_pending(cfg, dry_run=a.dry_run):
                print(f"{name}: {state}")
        else:
            if not a.ref:
                raise StudioError(f"Say which one: ./studio edit {a.kind} <id>")
            res = edit.edit_one(cfg, a.kind, a.ref, dry_run=a.dry_run)
            print(res if isinstance(res, str) else f"{res.kind}: {res.explain() if not res.ok else 'done'}")
            return 0 if isinstance(res, str) or res.ok else 1
    elif a.cmd == "kit":
        from . import kit
        print(f"Kit written to {kit.build(cfg, a.date, include_review=not a.approved_only)}")
    elif a.cmd in ("words", "cut"):
        from . import pipeline
        take = pipeline.resolve_take(cfg, kind, a.take)
        if a.cmd == "words":
            print(f"Words written to {pipeline.run_words(cfg, kind, take)}")
        else:
            path, plan = pipeline.run_cut(cfg, kind, take)
            print(plan.review())
            print(f"Cut written to {path}")
    elif a.cmd == "spec":
        from . import brand, spec
        ed = _edit_dir(cfg, kind, a.edit)
        spec.from_creative(cfg, ed, kind, brand.load_cfg(cfg))
        print(f"spec.json written to {ed}")
    elif a.cmd == "render":
        from . import pipeline
        for m in pipeline.render_motion(cfg, _edit_dir(cfg, kind, a.edit), a.only, kind):
            print(m)
    elif a.cmd == "build":
        if a.kind == "short":
            from . import build_short as bm
        else:
            from . import build_long as bm
        rep = bm.build(cfg, _edit_dir(cfg, a.kind, a.edit))
        print(f"Built {rep['out']} ({rep['duration']}s)")
        for w in rep["warnings"]:
            print(f"warning: {w}")
    elif a.cmd == "cover":
        from . import cover
        print(f"Cover written to {cover.make(cfg, _edit_dir(cfg, kind, a.edit), kind)}")
    elif a.cmd == "package":
        from . import brand, package
        package.generate(cfg, brand.load_cfg(cfg), _edit_dir(cfg, kind, a.edit), offline=a.offline, kind=kind)
        print("Posting text written.")
    elif a.cmd == "check":
        from . import checks
        if a.what == "creative":
            problems, warnings = checks.check_creative(cfg, Path(a.path))
            for w in warnings:
                print(f"warning: {w}")
            for p in problems:
                print(f"problem: {p}")
            print("creative.json is valid." if not problems else f"{len(problems)} problem(s).")
            return 1 if problems else 0
        res = checks.check_edit(cfg, _edit_dir(cfg, kind, a.path), "long" if a.long else None)
        for name, v in res.items():
            print(f"[{'ok' if v['ok'] else 'FAIL'}] {name}: {v['detail']}")
        return 0 if all(v["ok"] for v in res.values()) else 1
    elif a.cmd == "frames":
        from . import checks
        for p in checks.extract_frames(_edit_dir(cfg, "short", a.edit), a.every):
            print(p)
    return 0
