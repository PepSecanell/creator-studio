"""Self checks the agents and the CLI run before a human looks: creative.json, the finished edit, frames for QA."""
from __future__ import annotations

from pathlib import Path

from . import brand as brand_mod
from . import motion, schemas, sound
from .config import Config
from .package import dash_violations
from .util import StudioError, ffmpeg, probe, read_json

MAX_HOOK_WORDS = 7
MAX_LABELS = 3


def _strings(obj):
    if isinstance(obj, str):
        yield obj
    elif isinstance(obj, list):
        for x in obj:
            yield from _strings(x)
    elif isinstance(obj, dict):
        for v in obj.values():
            yield from _strings(v)


def _var_names(spec) -> set[str] | None:
    if isinstance(spec, dict):
        return set(spec.keys())
    if isinstance(spec, list):
        return {x if isinstance(x, str) else x.get("name") for x in spec}
    return None


def _label_count(vars_: dict) -> int:
    n = 0
    for k, v in vars_.items():
        if k.lower() == "labels" and isinstance(v, list):
            n += len(v)
        elif k.lower().startswith("label"):
            n += 1
    return n


def check_creative(cfg: Config, path: Path) -> tuple[list[str], list[str]]:
    """Return (problems, warnings) for a creative.json."""
    path = Path(path)
    d = read_json(path)
    problems: list[str] = []
    warnings: list[str] = []
    if d.get("schema") != "creative/v1":
        problems.append('"schema" must be "creative/v1".')
    for key, typ in (("vision", str), ("hook", dict), ("keywords", list), ("beats", list), ("cover", dict), ("end", dict)):
        if not isinstance(d.get(key), typ):
            problems.append(f'"{key}" is missing or has the wrong type.')
    hook = d.get("hook") if isinstance(d.get("hook"), dict) else {}
    n = len(str(hook.get("text", "")).split())
    if not n:
        problems.append("hook.text is empty.")
    elif n > MAX_HOOK_WORDS:
        problems.append(f"hook.text has {n} words. The limit is {MAX_HOOK_WORDS}.")

    cut_p = path.parent / "work" / "cut.json"
    cut_dur = read_json(cut_p)["duration"] if cut_p.exists() else None
    if cut_dur is None:
        warnings.append("work/cut.json not found, so beat times were not checked against the cut length.")

    try:
        layouts_ok = brand_mod.load_cfg(cfg)["look"].get("layouts") or []
    except StudioError as e:
        layouts_ok = []
        warnings.append(f"Brand not loaded, layouts not checked: {e}")
    comps = motion.list_comps(cfg)
    if comps is None:
        warnings.append("Motion kit not available (node or motion/ missing), so comp names were not checked.")
    comp_map = {c["name"]: c for c in comps if isinstance(c, dict) and "name" in c} if comps else {}

    prev_end = 0.0
    for i, b in enumerate(d.get("beats") or []):
        tag = f"beat {i + 1}"
        if not isinstance(b, dict) or not isinstance(b.get("from"), (int, float)) or not isinstance(b.get("to"), (int, float)):
            problems.append(f"{tag}: needs numeric from and to.")
            continue
        if b["to"] <= b["from"]:
            problems.append(f"{tag}: to ({b['to']}) must be after from ({b['from']}).")
        if b["from"] < prev_end - 1e-6:
            problems.append(f"{tag}: starts at {b['from']}s before the previous beat ends ({prev_end}s).")
        prev_end = max(prev_end, b["to"])
        if cut_dur is not None and b["to"] > cut_dur + 0.05:
            problems.append(f"{tag}: ends at {b['to']}s but the cut is only {cut_dur:.1f}s long.")
        if layouts_ok and b.get("layout") not in layouts_ok:
            problems.append(f"{tag}: layout {b.get('layout')!r} is not in this look ({', '.join(layouts_ok)}).")
        if "caption" in b and not isinstance(b["caption"], bool):
            problems.append(f"{tag}: caption must be true or false.")
        m = b.get("motion")
        if m is None:
            continue
        if not isinstance(m, dict) or not m.get("comp"):
            problems.append(f"{tag}: motion must be null or an object with comp, zone, vars.")
            continue
        vars_ = m.get("vars") or {}
        if comp_map:
            comp = comp_map.get(m["comp"])
            if comp is None:
                problems.append(f"{tag}: motion comp {m['comp']!r} does not exist. Available: {', '.join(sorted(comp_map))}.")
            else:
                allowed = _var_names(comp.get("vars"))
                extra = sorted(set(vars_) - allowed) if allowed is not None else []
                if extra:
                    problems.append(f"{tag}: comp {m['comp']} has no variables named {', '.join(extra)}.")
        if _label_count(vars_) > MAX_LABELS:
            problems.append(f"{tag}: more than {MAX_LABELS} labels in the motion vars.")

    for s in _strings(d):
        problems += [f"dash in text: {v}" for v in dash_violations(s)[:1]]
    return problems, warnings


def _check(name: str, ok: bool, detail: str = "") -> dict:
    return {"ok": bool(ok), "detail": detail}


def check_edit(cfg: Config, edit_dir: Path, kind: str | None = None) -> dict:
    """Run the self checks, write them into status.json, return the checks dict."""
    edit_dir = Path(edit_dir)
    kind = kind or ("long" if edit_dir.parent.name == "long" else "short")
    brand = brand_mod.load_cfg(cfg)
    want = (1080, 1920) if kind == "short" else (1920, 1080)
    checks: dict[str, dict] = {}
    final = edit_dir / "final.mp4"
    checks["final_exists"] = _check("final", final.exists(), str(final.name))
    if final.exists():
        info = probe(final)
        checks["size"] = _check("size", (info.get("width"), info.get("height")) == want,
                                f"{info.get('width')}x{info.get('height')}, want {want[0]}x{want[1]}")
        checks["fps"] = _check("fps", abs(info.get("fps", 0) - 30) < 0.1, f"{info.get('fps')} fps")
        checks["audio"] = _check("audio", info["has_audio"], "has an audio track" if info["has_audio"] else "no audio")
        lufs = sound.integrated_lufs(final) if info["has_audio"] else None
        checks["loudness"] = _check("loudness", lufs is not None and abs(lufs - sound.TARGET_LUFS) <= 1.5,
                                    f"{lufs} LUFS, want about {sound.TARGET_LUFS:.0f}")
        if kind == "short":
            mx = brand["editing"]["max_short_seconds"]
            checks["length"] = _check("length", info["duration"] <= mx + 0.1, f"{info['duration']:.1f}s, limit {mx}s")
    cover = edit_dir / ("cover.jpg" if kind == "short" else "thumbnail.jpg")
    checks["cover"] = _check("cover", cover.exists(), cover.name)
    text_file = edit_dir / ("POSTING.md" if kind == "short" else "DESCRIPTION.md")
    if text_file.exists():
        dv = dash_violations(text_file.read_text(encoding="utf-8"))
        checks["no_dashes"] = _check("dashes", not dv, f"{len(dv)} dashes found" if dv else "clean")
    else:
        checks["no_dashes"] = _check("dashes", False, f"{text_file.name} not found")
    try:
        existing = schemas.read_status(edit_dir)
        if existing:
            schemas.check(existing, "edit-status/v1")
        checks["status_valid"] = _check("status", True, "ok" if existing else "will be created")
    except StudioError as e:
        checks["status_valid"] = _check("status", False, str(e))
    state = (schemas.read_status(edit_dir) or {}).get("state", "editing")
    if checks["status_valid"]["ok"]:
        schemas.set_status(edit_dir, state, (schemas.read_status(edit_dir) or {}).get("notes", ""), checks)
    return checks


def extract_frames(edit_dir: Path, every: float = 1.0) -> list[Path]:
    """PNG frames of final.mp4 into <edit>/checks/: first, 1.5 s, each beat boundary, last, plus one every `every` s."""
    edit_dir = Path(edit_dir)
    final = edit_dir / "final.mp4"
    if not final.exists():
        raise StudioError("final.mp4 not found.")
    dur = probe(final)["duration"]
    times = {0.0, 1.5, max(dur - 0.1, 0.0)}
    cp = edit_dir / "creative.json"
    if cp.exists():
        for b in read_json(cp).get("beats", []):
            times.update({float(b.get("from", 0)), float(b.get("to", 0))})
    t = every
    while t < dur and every > 0:
        times.add(round(t, 2))
        t += every
    out_dir = edit_dir / "checks"
    out_dir.mkdir(exist_ok=True)
    paths = []
    for t in sorted(x for x in times if 0 <= x < dur):
        p = out_dir / f"t_{t:06.2f}.png"
        ffmpeg(["-ss", f"{t:.2f}", "-i", final, "-frames:v", "1", p], what="frame")
        paths.append(p)
    return paths


def first_seconds(spec: dict, out_words: list[dict]) -> list[str]:
    """Hook rules for a Short: hook text present, first spoken word under 1 s, hook short."""
    out = []
    hook = (spec.get("hook") or {}).get("text", "")
    if not hook:
        out.append("No hook text. The first 2 seconds need a line for the viewer.")
    elif len(hook.split()) > MAX_HOOK_WORDS:
        out.append(f"Hook is {len(hook.split())} words. Keep it to {MAX_HOOK_WORDS} or fewer.")
    if out_words and out_words[0]["s"] > 1.0:
        out.append(f"The first word is spoken at {out_words[0]['s']:.1f}s. Cut closer to the start.")
    return out
