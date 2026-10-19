"""POSTING.md (Shorts) and DESCRIPTION.md (long videos): per platform text written in the brand voice."""
from __future__ import annotations

import re
from pathlib import Path

from . import runner
from .config import Config
from .util import StudioError, read_json, write_json

SHORT_PLATFORMS = {"tiktok": "TikTok", "youtube_shorts": "YouTube Shorts", "reels": "Instagram Reels"}
DASHES = re.compile(r"[–—‒―]|(?<=\s)-(?=\s)|--")


def dash_violations(text: str) -> list[str]:
    """Em dashes, en dashes and dash-like hyphens used as punctuation."""
    return [f"dash at position {m.start()}: ...{text[max(0, m.start() - 15):m.end() + 15]}..." for m in DASHES.finditer(text)]


def strip_dashes(text: str) -> str:
    text = re.sub(r"\s*[–—‒―]\s*|\s+-\s+|\s*--\s*", ", ", text)
    return re.sub(r",\s*,", ",", text)


def banned_hits(text: str, banned: list[str]) -> list[str]:
    low = text.lower()
    return [b for b in banned if b and b.lower() in low]


def _clean(obj, brand: dict):
    """Walk a JSON value, strip dashes from every string."""
    if isinstance(obj, str):
        return strip_dashes(obj)
    if isinstance(obj, list):
        return [_clean(x, brand) for x in obj]
    if isinstance(obj, dict):
        return {k: _clean(v, brand) for k, v in obj.items()}
    return obj


def template_posting(brand: dict, title: str, transcript: str, points: list[str] | None = None) -> dict:
    """Deterministic text used with --offline or when Claude is not available."""
    cta = brand["voice"].get("cta") or f"Follow {brand['name']} for more."
    tags = ["#" + re.sub(r"\W", "", t.title()) for t in (brand["voice"].get("topics") or [])[:3]] or ["#shorts"]
    first = transcript.strip().split(".")[0].strip() if transcript.strip() else title
    out = {}
    for key in SHORT_PLATFORMS:
        out[key] = {"title": title[:90] if key == "youtube_shorts" else "", "caption": f"{first}. {cta}".strip(),
                    "hashtags": tags + (["#shorts"] if key == "youtube_shorts" else []),
                    "pinned_comment": f"What would you add? {cta}"}
    return out


def render_posting_md(title: str, data: dict) -> str:
    lines = [f"# Posting text: {title}", ""]
    for key, name in SHORT_PLATFORMS.items():
        p = data.get(key, {})
        lines += [f"## {name}", ""]
        if p.get("title"):
            lines += [f"Title: {p['title']}", ""]
        lines += [f"Caption: {p.get('caption', '')}", "", "Hashtags: " + " ".join(p.get("hashtags", [])), "",
                  f"Pinned comment: {p.get('pinned_comment', '')}", ""]
    return "\n".join(lines)


def _prompt(brand: dict, title: str, transcript: str, long: bool) -> str:
    v = brand["voice"]
    ask = ('Write a YouTube description with these keys: "title_options" (3 titles), "description" (plain text, first line '
           'is the hook, no chapters), "tags" (list).') if long else (
        'Write posting text for each of tiktok, youtube_shorts, reels. Each has "title" (youtube_shorts only, under 70 '
        'characters, otherwise empty), "caption" (under 150 characters), "hashtags" (3 to 5), "pinned_comment" (a question).')
    return (f"You write social posting text for the channel {brand['name']}.\n"
            f"Who is speaking: {v['who']}\nAudience: {v['audience']}\nTone: {', '.join(v['tone'])}\n"
            f"Never use these words: {', '.join(v['banned'])}\nCall to action: {v['cta']}\nLink: {v['link']}\n\n"
            f"Video title: {title}\nTranscript:\n{transcript}\n\n{ask}\n"
            "Rules: plain simple English, short sentences. No em dashes, no en dashes, no hyphens used as dashes. "
            "Do not invent facts that are not in the transcript. Reply with one JSON object only.")


def generate(cfg: Config, brand: dict, edit_dir: Path, *, offline: bool = False, claude_bin: str = "claude",
             kind: str = "short") -> dict:
    """Write POSTING.md + posting.json (Shorts) or DESCRIPTION.md + description.json (long)."""
    edit_dir = Path(edit_dir)
    words_p = edit_dir / "work" / "words.json"
    transcript = " ".join(w["w"] for w in read_json(words_p)) if words_p.exists() else ""
    spec = read_json(edit_dir / "spec.json") if (edit_dir / "spec.json").exists() else {}
    title = spec.get("hook", {}).get("text") or edit_dir.name
    long = kind == "long"
    data = None
    if not offline:
        for attempt in range(2):
            res = runner.run(_prompt(brand, title, transcript, long), role="mechanical", brand=brand, cwd=cfg.repo,
                             claude_bin=claude_bin)
            if not res.ok:
                raise StudioError(res.explain())
            data = runner.extract_json(res.text)
            if data is not None:
                break
        if data is None:
            raise StudioError("Claude did not return usable posting text. Try again.")
        data = _clean(data, brand)
    elif not long:
        data = template_posting(brand, title, transcript)
    else:
        data = {"title_options": [title], "description": f"{title}. {brand['voice'].get('cta', '')}".strip(), "tags": []}
    if long:
        body = data.get("description", "")
        chapters = edit_dir / "chapters.txt"
        if chapters.exists():
            body += "\n\nChapters\n" + chapters.read_text()
        text = "# " + "\n# ".join(data.get("title_options", [title])) + "\n\n" + body + "\n"
        (edit_dir / "DESCRIPTION.md").write_text(text, encoding="utf-8")
        write_json(edit_dir / "description.json", data)
    else:
        text = render_posting_md(title, data)
        (edit_dir / "POSTING.md").write_text(text, encoding="utf-8")
        write_json(edit_dir / "posting.json", data)
    hits = banned_hits(text, brand["voice"].get("banned", []))
    if hits:
        data["_warning"] = "contains banned words: " + ", ".join(hits)
    return data
