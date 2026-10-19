import pytest
from PIL import ImageChops

from cstudio import layouts
from cstudio.render import captions, cards, track

SIZE = (1080, 1920)


@pytest.mark.parametrize("shape", captions.SHAPES)
@pytest.mark.parametrize("emph", captions.EMPHASIS)
def test_every_caption_shape_draws(brand, shape, emph):
    look = {**brand["look"], "captions": {**brand["look"]["captions"], "shape": shape, "emphasis_mode": emph}}
    img, box = captions.render(SIZE, ["Make", "one", "small", "thing"], ["small"], look, brand["palette"], brand["fonts"])
    assert img.size == SIZE and img.getbbox() is not None
    assert box[0] < box[2] and box[1] < box[3]


def test_chunks_break_on_gap_and_size():
    ws = [{"w": w, "s": i * 0.3, "e": i * 0.3 + 0.25} for i, w in enumerate("a b c d e f".split())]
    ws[4]["s"] += 1.0
    ws[4]["e"] += 1.0
    ws[5]["s"] += 1.0
    ws[5]["e"] += 1.0
    cs = captions.chunks(ws, 4)
    assert [len(c["words"]) for c in cs] == [4, 2]


def test_case_modes(brand):
    img, _ = captions.render(SIZE, ["hello"], [], brand["look"], brand["palette"], brand["fonts"], "upper")
    assert img.getbbox()


def test_hook_end_and_panels(brand):
    img, box = cards.hook_card(SIZE, "Start with one clear goal", brand["look"], brand["palette"], brand["fonts"], (60, 300, 1000, 1200))
    assert img.getbbox()
    assert cards.end_card(SIZE, brand, "See you", "Follow for more").size == SIZE
    for lay in ("graphic", "title", "split"):
        assert cards.panel(SIZE, lay, "One clear goal", brand, region=(0, 806)).getbbox()
    assert cards.lower_third((1920, 1080), "Name", "Role", brand).getbbox()
    assert cards.chapter_card((1920, 1080), 1, "Setup", brand).getbbox()


def test_hook_none_shape(brand):
    look = {**brand["look"], "hook_card": {"shape": "none"}}
    assert cards.hook_card(SIZE, "x y", look, brand["palette"], brand["fonts"], (0, 0, 1, 1)) == (None, None)


def test_track_builds_concat_list(tmp_path, brand):
    img, _ = captions.render(SIZE, ["hi"], [], brand["look"], brand["palette"], brand["fonts"])
    lst = track.build(tmp_path, SIZE, 3.0, [(1.0, 2.0, img)])
    lines = lst.read_text().splitlines()
    assert sum(1 for l in lines if l.startswith("duration")) == 3
    assert lines[-1].startswith("file")


def test_layout_rotation_never_repeats():
    out = layouts.assign(12, seed="x")
    assert out[0] == "face" and all(a != b for a, b in zip(out, out[1:]))
    no_text = layouts.assign(6, has_text=[False] * 6)
    assert set(no_text) == {"face"}
