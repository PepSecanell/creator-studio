import json

import pytest

from cstudio import brand
from cstudio.util import StudioError
from .conftest import write_brand


def test_load_merges_look_defaults(cfg):
    write_brand(cfg, palette={"accent": "#112233"})
    b = brand.load_cfg(cfg)
    assert b["palette"]["accent"] == "#112233"          # brand wins
    assert b["palette"]["ink"] == "#22305A"            # look default fills the gap
    assert b["style"] == "test" and b["look"]["layouts"][0] == "face"


def test_bad_hex_names_the_role(cfg):
    write_brand(cfg, palette={"accent": "yellow"})
    with pytest.raises(StudioError, match="accent"):
        brand.load_cfg(cfg)


def test_unknown_palette_role(cfg):
    write_brand(cfg, palette={"sparkle": "#112233"})
    with pytest.raises(StudioError, match="sparkle"):
        brand.load_cfg(cfg)


def test_unknown_style_lists_available(cfg):
    write_brand(cfg, style="nope")
    with pytest.raises(StudioError, match="Available looks: test"):
        brand.load_cfg(cfg)


def test_missing_font_file(cfg):
    write_brand(cfg, fonts={"title": "fonts/none.ttf"})
    with pytest.raises(StudioError, match="Font file"):
        brand.load_cfg(cfg)


def test_missing_brand_file(cfg):
    (cfg.brand_dir / "brand.json").unlink()
    with pytest.raises(StudioError, match="No brand file"):
        brand.load_cfg(cfg)


def test_invalid_json_gives_line(cfg):
    (cfg.brand_dir / "brand.json").write_text("{\n bad")
    with pytest.raises(StudioError, match="not valid JSON"):
        brand.load_cfg(cfg)


def test_wrong_schema(cfg):
    write_brand(cfg, schema="other/v1")
    with pytest.raises(StudioError, match="creator-brand/v1"):
        brand.load_cfg(cfg)


def test_build_writes_tokens_with_brand_colours(cfg):
    brand.build(cfg)
    css = (cfg.resolved_dir / "tokens.css").read_text()
    assert "--cs-accent: #FFD84D;" in css          # from brand.json, not the look's placeholder
    assert "--cs-radius: 20px;" in css             # look value kept
    assert "#000000" not in css
    resolved = json.loads((cfg.resolved_dir / "brand.resolved.json").read_text())
    assert resolved["name"] == "Northwind"
