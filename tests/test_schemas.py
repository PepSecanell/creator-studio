import json

import pytest

from cstudio import safezones, schemas
from cstudio.util import StudioError


def test_handoff_roundtrip():
    d = schemas.make_handoff("short", "w42-03", "Ship it", "cards", "text", ["a"], "/tmp/x", "Northwind")
    schemas.check(d, "handoff/v1")
    d["mode"] = "bogus"
    with pytest.raises(StudioError, match="mode"):
        schemas.check(d, "handoff/v1")


def test_take_schema():
    ok = {"schema": "take/v1", "id": "a", "kind": "short", "take": 1, "mode": "cards", "started": "x",
          "duration_s": 3.2, "fps": 30, "files": {"camera": "take.mov", "screen": None}}
    schemas.check(ok, "take/v1")
    bad = dict(ok)
    del bad["files"]
    with pytest.raises(StudioError, match="files"):
        schemas.check(bad, "take/v1")


def test_status_states(tmp_path):
    d = schemas.set_status(tmp_path, "editing", "x")
    assert d["state"] == "editing"
    schemas.set_status(tmp_path, "ready_for_review", checks={"a": {"ok": True}})
    assert schemas.read_status(tmp_path)["checks"]["a"]["ok"]
    with pytest.raises(StudioError):
        schemas.set_status(tmp_path, "sleeping")


def test_kit_schema_needs_known_platform():
    kit = {"schema": "kit/v1", "date": "2026-01-01", "brand": "N",
           "items": [{"id": "a", "platform": "myspace", "action": "post", "file": "a.mp4"}]}
    with pytest.raises(StudioError, match="platform"):
        schemas.check(kit, "kit/v1")


def test_safe_box_is_inside_all_platform_bars():
    box = safezones.safe_box()
    assert box[1] >= 288 and box[3] <= 1248 and box[0] >= 65 and box[2] <= 1015


def test_violations_and_clamp():
    safe = safezones.safe_box()
    bad = {"captions": (100, 1300, 900, 1400)}
    assert safezones.violations(bad)
    dx, dy = safezones.clamp(bad["captions"], safe)
    moved = (100 + dx, 1300 + dy, 900 + dx, 1400 + dy)
    assert not safezones.violations({"captions": moved})


def test_length_limits():
    assert safezones.length_ok(30) == []
    assert safezones.length_ok(120)      # over the Reels limit
