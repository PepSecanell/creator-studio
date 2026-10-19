import json
import stat

import pytest

from cstudio import package, runner


@pytest.mark.parametrize("text,exit_code,kind", [
    ("", 0, runner.OK),
    ("You've hit your usage limit. Resets 5pm", 1, runner.LIMIT),
    ("Failed to authenticate. Please run /login", 1, runner.AUTH),
    ("API Error: 529 overloaded", 1, runner.TRANSIENT),
    ("ECONNRESET", 1, runner.TRANSIENT),
    ("something odd happened", 1, runner.FAILURE),
])
def test_classify(text, exit_code, kind):
    assert runner.classify(text, exit_code=exit_code).kind == kind


def test_long_successful_reply_is_never_an_error():
    assert runner.classify("this talks about a usage limit and 401", exit_code=0).kind == runner.OK


def test_timeout_is_failure():
    assert runner.classify("", exit_code=1, timed_out=True).kind == runner.FAILURE


def fake_claude(tmp_path, payload: dict, code=0, fail_times=0):
    counter = tmp_path / "count"
    counter.write_text("0")
    script = tmp_path / "claude"
    script.write_text(f"""#!/usr/bin/env bash
n=$(cat {counter}); echo $((n+1)) > {counter}
if [ "$n" -lt {fail_times} ]; then echo '{{"is_error": true, "result": "API Error: 503 service unavailable"}}'; exit 1; fi
echo '{json.dumps(payload)}'
exit {code}
""")
    script.chmod(script.stat().st_mode | stat.S_IEXEC)
    return str(script)


def test_run_ok(tmp_path):
    bin_ = fake_claude(tmp_path, {"is_error": False, "result": "hello", "session_id": "s1", "total_cost_usd": 0.01})
    r = runner.run("hi", claude_bin=bin_)
    assert r.ok and r.text == "hello" and r.session_id == "s1"


def test_run_retries_transient_then_succeeds(tmp_path):
    bin_ = fake_claude(tmp_path, {"is_error": False, "result": "fine"}, fail_times=2)
    waits = []
    r = runner.run("hi", claude_bin=bin_, sleep=waits.append)
    assert r.ok and r.attempts == 3 and len(waits) == 2


def test_run_gives_up_and_reports_limit(tmp_path):
    bin_ = fake_claude(tmp_path, {"is_error": True, "result": "You have hit your weekly limit"}, code=1)
    r = runner.run("hi", claude_bin=bin_, sleep=lambda s: None)
    assert r.kind == runner.LIMIT and "usage limit" in r.explain()


def test_missing_claude():
    r = runner.run("hi", claude_bin="/nonexistent/claude")
    assert not r.ok and "not installed" in r.explain()


def test_model_roles():
    assert runner.model_for({"models": {"creative": "opus", "mechanical": "sonnet"}}, "creative") == "opus"
    assert runner.model_for({}, "mechanical") == "sonnet"


def test_extract_json_from_fence():
    assert runner.extract_json('Sure:\n```json\n{"a": 1}\n```') == {"a": 1}
    assert runner.extract_json("no json here") is None


def test_dash_gate():
    assert package.dash_violations("Short and sweet.") == []
    assert package.dash_violations("One thing — another")
    assert package.dash_violations("a – b")
    assert package.dash_violations("a - b")
    assert not package.dash_violations("well-known tool")
    cleaned = package.strip_dashes("One thing — another - third")
    assert not package.dash_violations(cleaned)


def test_banned_words():
    assert package.banned_hits("This is a game changer", ["game changer", "unlock"]) == ["game changer"]


def test_template_posting_has_no_dashes(brand):
    data = package.template_posting(brand, "One clear goal", "Start small. Then ship.")
    md = package.render_posting_md("One clear goal", data)
    assert not package.dash_violations(md)
    assert set(data) == set(package.SHORT_PLATFORMS)


def test_generate_with_fake_claude_strips_dashes(tmp_path, cfg, brand):
    ed = cfg.edit_dir("shorts", "x")
    (ed / "work").mkdir(parents=True)
    (ed / "work" / "words.json").write_text('[{"w":"Hi","s":0,"e":0.2}]')
    body = {k: {"title": "T — x", "caption": "C - d", "hashtags": ["#a"], "pinned_comment": "Q?"} for k in package.SHORT_PLATFORMS}
    bin_ = fake_claude(tmp_path, {"is_error": False, "result": json.dumps(body)})
    package.generate(cfg, brand, ed, claude_bin=bin_)
    assert not package.dash_violations((ed / "POSTING.md").read_text())
