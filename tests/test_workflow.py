import json
import shutil

import pytest

from cstudio import checks, edit, kit, pipeline, schemas
from cstudio.util import write_json


def creative(**over):
    d = {"schema": "creative/v1", "vision": "calm", "hook": {"text": "Start with one clear goal", "emphasis": "goal", "take": 0},
         "keywords": ["goal"], "beats": [
             {"from": 0, "to": 3, "layout": "face", "caption": True, "motion": None, "why": "x"},
             {"from": 3, "to": 6, "layout": "split", "caption": True, "motion": None, "why": "y"}],
         "cover": {"frame_at": 1, "words": "One goal", "emphasis": "goal"}, "end": {"line": "Bye", "cta": ""}, "notes": ""}
    d.update(over)
    return d


def put(cfg, data, cut=6.0):
    ed = cfg.edit_dir("shorts", "t1")
    write_json(ed / "work" / "cut.json", {"duration": cut, "segments": []})
    write_json(ed / "creative.json", data)
    return ed / "creative.json"


def test_creative_ok(cfg):
    problems, _ = checks.check_creative(cfg, put(cfg, creative()))
    assert problems == []


def test_creative_problems(cfg):
    bad = creative(hook={"text": "one two three four five six seven eight", "emphasis": "", "take": 0})
    bad["beats"] = [{"from": 0, "to": 4, "layout": "face", "caption": True, "motion": None},
                    {"from": 3, "to": 9, "layout": "nope", "caption": True, "motion": None}]
    bad["vision"] = "calm — and clear"
    problems, _ = checks.check_creative(cfg, put(cfg, bad))
    text = "\n".join(problems)
    assert "8 words" in text and "before the previous beat" in text and "only 6.0s" in text
    assert "layout 'nope'" in text and "dash in text" in text


def test_creative_too_many_labels_and_unknown_comp(cfg, monkeypatch):
    monkeypatch.setattr(checks.motion, "list_comps", lambda c: [{"name": "stat", "vars": {"value": "str", "labels": "list"}}])
    d = creative()
    d["beats"][0]["motion"] = {"comp": "stat", "zone": "full", "vars": {"labels": ["a", "b", "c", "d"], "oops": 1}}
    d["beats"][1]["motion"] = {"comp": "ghost", "zone": "full", "vars": {}}
    problems, _ = checks.check_creative(cfg, put(cfg, d))
    text = "\n".join(problems)
    assert "more than 3 labels" in text and "no variables named oops" in text and "'ghost' does not exist" in text


def test_creative_warns_without_motion_kit(cfg, monkeypatch):
    monkeypatch.setattr(checks.motion, "list_comps", lambda c: None)
    _, warnings = checks.check_creative(cfg, put(cfg, creative()))
    assert any("Motion kit" in w for w in warnings)


def make_take(cfg, ident="t1", n=1):
    d = cfg.takes_dir("shorts") / f"2026-01-01-{ident}-take-{n}"
    d.mkdir(parents=True)
    write_json(d / "take.json", {"schema": "take/v1", "id": ident, "kind": "short", "take": n, "mode": "cards",
                                 "started": "x", "duration_s": 1, "fps": 30, "files": {"camera": "take.mov", "screen": None}})
    (d / "take.mov").write_bytes(b"x")
    return d


def test_latest_take_wins(cfg):
    make_take(cfg, n=1)
    t2 = make_take(cfg, n=2)
    assert pipeline.list_takes(cfg, "short")["t1"] == t2
    assert pipeline.resolve_take(cfg, "short", "t1") == t2


def test_edit_dry_run_and_pending(cfg):
    make_take(cfg, "a")
    make_take(cfg, "b")
    schemas.set_status(cfg.edit_dir("shorts", "b"), "approved")
    assert [i for i, _ in edit.pending(cfg, "short")] == ["a"]
    prompt = edit.edit_one(cfg, "short", "a", dry_run=True)
    assert "edit-short skill" in prompt and "creative-director" in prompt and "qa" in prompt


def test_edit_failure_sets_status(cfg, tmp_path):
    make_take(cfg, "a")
    script = tmp_path / "claude"
    script.write_text('#!/usr/bin/env bash\necho \'{"is_error": true, "result": "Failed to authenticate"}\'\nexit 1\n')
    script.chmod(0o755)
    res = edit.edit_one(cfg, "short", "a", claude_bin=str(script))
    assert res.kind == "auth_expired"
    st = schemas.read_status(cfg.edit_dir("shorts", "a"))
    assert st["state"] == "queued" and "logged in" in st["notes"]


def test_kit_collects_ready_edits(cfg):
    ed = cfg.edit_dir("shorts", "w1")
    ed.mkdir(parents=True)
    (ed / "final.mp4").write_bytes(b"v")
    (ed / "cover.jpg").write_bytes(b"c")
    write_json(ed / "posting.json", {"tiktok": {"caption": "hi", "hashtags": ["#a"], "pinned_comment": "q"}})
    schemas.set_status(ed, "ready_for_review")
    other = cfg.edit_dir("shorts", "w2")
    other.mkdir(parents=True)
    (other / "final.mp4").write_bytes(b"v")
    schemas.set_status(other, "editing")
    kit_dir = kit.build(cfg, "2026-01-02")
    data = json.loads((kit_dir / "kit.json").read_text())
    schemas.check(data, "kit/v1")
    assert {i["platform"] for i in data["items"]} == {"tiktok", "youtube_shorts", "reels"}
    assert all(i["id"] == "w1" for i in data["items"])
    assert (kit_dir / "w1-tiktok.mp4").exists() and (kit_dir / "w1-cover.jpg").exists()
    assert kit.post_times(2) == ["08:00", "20:00"]


def test_spec_from_creative(cfg, brand):
    from cstudio import spec
    ed = cfg.edit_dir("shorts", "t1")
    write_json(ed / "work" / "cut.json", {"duration": 7.0, "segments": [{"start": 1.0, "end": 8.0}]})
    write_json(ed / "work" / "words.json", [{"w": "hi", "s": 1.1, "e": 1.3}])
    write_json(ed / "work" / "take_ref.json", {"source": "/x/take.mov", "unmirror": False})
    c = creative()
    c["beats"][1]["motion"] = {"comp": "stat", "zone": "split", "vars": {"value": "3"}}
    write_json(ed / "creative.json", c)
    s = spec.from_creative(cfg, ed, "short", brand)
    assert [x["layout"] for x in s["segments"]] == ["face", "split"]
    assert s["segments"][0]["end"] == 4.0 and s["segments"][1]["start"] == 4.0   # split at the beat boundary
    assert s["overlays"][0]["comp"] == "stat" and s["overlays"][0]["file"].startswith("work/motion/")
    assert s["hook"]["text"] == "Start with one clear goal"
    schemas.check(s, "short-spec/v1")
    assert spec.from_creative(cfg, ed, "short", brand) == s                          # deterministic
