"""./studio edit: run the editing agents headless (claude -p) on takes."""
from __future__ import annotations

from pathlib import Path

from . import brand as brand_mod
from . import pipeline, runner, schemas
from .config import Config


DONE = ("ready_for_review", "approved", "posted")


def prompt_for(cfg: Config, kind: str, take_dir: Path, edit_dir: Path) -> str:
    skill = "edit-short" if kind == "short" else "edit-long"
    return (
        f"Use the {skill} skill on this take folder: {take_dir}\n"
        f"Write all output into the edit folder: {edit_dir}\n\n"
        "Work in this order. Ask the creative-director agent for creative.json, let the editor agent build the video "
        "from it, then ask the qa agent to review the frames. Use the package skill for the posting text.\n"
        "Use the ./studio commands from the skill. Do not post anything anywhere.\n"
        f"When the self checks pass, set status.json to ready_for_review. If something needs the creator, set it to "
        f'needs_you and write one plain sentence in "notes" saying what is needed.'
    )


def pending(cfg: Config, kind: str) -> list[tuple[str, Path]]:
    out = []
    for ident, take in pipeline.list_takes(cfg, kind).items():
        st = schemas.read_status(cfg.edit_dir(pipeline.kind_dir(kind), ident))
        if st and st["state"] in DONE + ("editing",):
            continue
        out.append((ident, take))
    return out


def edit_one(cfg: Config, kind: str, ident: str, *, dry_run: bool = False, claude_bin: str = "claude") -> runner.Result | str:
    take = pipeline.resolve_take(cfg, kind, ident)
    ident = pipeline.take_info(take).get("id") or ident
    edit = pipeline.edit_dir_for_take(cfg, kind, take)
    prompt = prompt_for(cfg, kind, take, edit)
    if dry_run:
        return prompt
    brand = brand_mod.load_cfg(cfg)
    schemas.set_status(edit, "editing", "Started.")
    res = runner.run(prompt, role="mechanical", brand=brand, cwd=cfg.repo, claude_bin=claude_bin,
                     allowed_tools="Bash,Read,Write,Edit,Glob,Grep,Agent,Task,Skill", timeout_s=5400)
    st = schemas.read_status(edit) or {}
    if res.ok:
        if st.get("state") == "editing":
            has = (edit / "final.mp4").exists()
            schemas.set_status(edit, "ready_for_review" if has else "failed",
                               "" if has else "The run finished but no final.mp4 was written.")
    elif res.kind in (runner.AUTH, runner.LIMIT, runner.TRANSIENT):
        schemas.set_status(edit, "queued", res.explain())
    else:
        schemas.set_status(edit, "failed", res.explain())
    return res


def edit_pending(cfg: Config, *, dry_run: bool = False, claude_bin: str = "claude") -> list[tuple[str, str]]:
    summary = []
    for kind in ("short", "long"):
        for ident, _ in pending(cfg, kind):
            res = edit_one(cfg, kind, ident, dry_run=dry_run, claude_bin=claude_bin)
            summary.append((f"{kind} {ident}", "dry run" if isinstance(res, str) else res.kind))
            if not isinstance(res, str) and res.kind in (runner.AUTH, runner.LIMIT):
                return summary          # no point trying the rest
    return summary
