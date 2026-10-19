from cstudio import cut


def W(text, start, per=0.3):
    out, t = [], start
    for w in text.split():
        out.append({"w": w, "s": round(t, 2), "e": round(t + per * 0.9, 2)})
        t += per
    return out, t


def test_silence_is_cut():
    a, t = W("hello there friend", 0.5)
    b, _ = W("this is next", t + 1.5)
    plan = cut.plan(a + b)
    assert len(plan.segments) == 2
    assert plan.segments[1]["start"] - plan.segments[0]["end"] > 1.0


def test_retake_and_lead_filler_dropped():
    a, t = W("the first thing", 0.5)
    b, t = W("um", t + 1.0)
    c, _ = W("No, the first thing you need is a goal.", t + 0.6)
    plan = cut.plan(a + b + c)
    texts = " ".join(w["w"] for w in plan.kept_words)
    assert texts == "the first thing you need is a goal."
    reasons = {d["reason"] for d in plan.dropped}
    assert {"retake", "filler"} <= reasons


def test_false_start_inside_pause_free_speech_is_kept():
    ws, _ = W("we ship small things every day", 0.2)
    plan = cut.plan(ws)
    assert len(plan.segments) == 1 and not plan.dropped


def test_scratch_that_removes_previous_sentence():
    a, t = W("Keep it simple.", 0.2)
    b, t = W("This part is wrong scratch that", t + 0.05)
    c, _ = W("This part is right", t + 0.8)
    plan = cut.plan(a + b + c)
    text = " ".join(w["w"] for w in plan.kept_words)
    assert "wrong" not in text and "scratch" not in text
    assert text.startswith("Keep it simple.") and text.endswith("This part is right")


def test_from_the_top_drops_everything_before():
    a, t = W("bad opening words here", 0.2)
    b, t = W("from the top", t + 0.2)
    c, _ = W("good opening", t + 0.8)
    plan = cut.plan(a + b + c)
    assert [w["w"] for w in plan.kept_words] == ["good", "opening"]


def test_custom_cue():
    a, t = W("oops banana", 0.2)
    b, _ = W("real line here now", t + 0.9)
    plan = cut.plan(a + b, cues={"restart": ["oops banana"]})
    assert "oops" not in " ".join(w["w"] for w in plan.kept_words)


def test_inline_repeat_flagged():
    ws, _ = W("and none of the and none of the companies agree", 0.2)
    plan = cut.plan(ws)
    assert plan.flags and "inline repeat" in plan.flags[0]
    assert " ".join(w["w"] for w in plan.kept_words).count("none of the") == 1


def test_keep_pause_leaves_room():
    a, t = W("one two three", 0.5)
    b, _ = W("four five six", t + 1.0)
    tight = cut.plan(a + b)
    loose = cut.plan(a + b, keep_pause=0.4)
    gap = lambda p: p.segments[1]["start"] - p.segments[0]["end"]
    assert gap(loose) < gap(tight)
