/* cs.js: the motion kit's shared helpers. Loaded after gsap.min.js.
 *
 * Craft rules the helpers enforce, so every comp gets them for free:
 *   - six gestures only: enter, settle, reveal, emphasis, drift, exit (one ease each)
 *   - surfaces and lines arrive by a masked edge (clip-path / a mask), never a plain fade
 *   - nothing is a dead hold: CS.breath() pushes the camera 2% over the hold
 *   - every graphic is fitted into its zone, clear of the platform UI (CS.place)
 *   - no clocks, no randomness: helpers only add tweens at the times you pass, so any frame can be seeked
 *
 *   CS.comp('big-number', function (v, c) { ... return tl; })   register a comp (vars, stage, timeline)
 */
(function (root) {
  var gsap = root.gsap;

  // ---------------------------------------------------------------- motion vocabulary
  var EASE = { enter: 'power3.out', settle: 'power2.out', exit: 'power2.in', emphasis: 'sine.inOut', travel: 'power3.inOut', linear: 'none' };
  var S = { micro: 0.2, short: 0.38, medium: 0.55, long: 0.7, travel: 1.25, drift: 2.6 };
  var STEP = 0.07;          // stagger between lines / items
  var MASK = { surface: 0.7, plate: 0.5, line: 0.5, out: 0.3, park: 115 };
  var CLIP = { full: 'inset(0% 0% 0% 0%)', right: 'inset(0% 100% 0% 0%)', left: 'inset(0% 0% 0% 100%)', up: 'inset(100% 0% 0% 0%)', down: 'inset(0% 0% 100% 0%)' };
  var OUT = { right: CLIP.left, left: CLIP.right, up: CLIP.down, down: CLIP.up };

  // ---------------------------------------------------------------- zones (frame pixels)
  // Vertical: the top 240 px hold the platform header, the right column below y 900 holds the like and
  // comment buttons, everything under the zone belongs to the face card or the captions.
  // Landscape: a title safe margin; split keeps the right half free for the speaker.
  // The rectangles sit 16 px inside each box, so a hard shadow or the camera breath never leaves the zone.
  var ZONES = {
    vertical: {
      split: { box: [60, 240, 1020, 880], rects: [[76, 256, 1004, 864]] },
      full: { box: [60, 240, 1020, 1150], rects: [[76, 256, 1004, 884], [76, 256, 884, 1134]] },
    },
    landscape: {
      split: { box: [96, 72, 1000, 1008], rects: [[112, 88, 984, 992]] },
      full: { box: [96, 72, 1824, 1008], rects: [[112, 88, 1808, 992]] },
    },
  };

  // ---------------------------------------------------------------- small parsers
  function trim(s) { return String(s).replace(/^\s+|\s+$/g, ''); }
  function list(s, sep) { if (s == null) return []; if (Array.isArray(s)) return s.map(String).map(trim).filter(Boolean); return String(s).split(sep || '|').map(trim).filter(function (x) { return x.length; }); }
  function nums(s) { return list(s).map(parseFloat).filter(function (x) { return !isNaN(x); }); }
  function pairs(s) { return list(s).map(function (p) { var a = p.split('='); return { k: trim(a[0]), v: a.length > 1 ? trim(a.slice(1).join('=')) : '' }; }); }
  function fields(s) { return list(s).map(function (p) { return p.split(';').map(trim); }); }
  function esc(s) { return String(s == null ? '' : s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;'); }
  function lower(s) { return String(s == null ? '' : s).toLowerCase().trim(); }
  function pick(v, allowed) { var x = lower(v); return allowed.indexOf(x) >= 0 ? x : allowed[0]; }
  function fmt(n, dec) { var s = Math.abs(n).toFixed(dec || 0), p = s.split('.'); p[0] = p[0].replace(/\B(?=(\d{3})+(?!\d))/g, ','); return (n < 0 ? '-' : '') + p.join('.'); }
  function clock(mins) { mins = ((Math.round(mins) % 1440) + 1440) % 1440; var h = Math.floor(mins / 60), m = mins % 60; return (h < 10 ? '0' : '') + h + ':' + (m < 10 ? '0' : '') + m; }
  function initials(s) { var w = String(s || '').trim(); return (w[0] || '?').toUpperCase(); }

  var C = null;   // the current comp context, set by CS.comp()
  // a time variable: seconds from the start of the beat, clamped inside the comp
  function t(key, fallback) { var x = parseFloat(C.v[key]); if (isNaN(x)) x = fallback; return Math.max(0, Math.min(x, C.dur - 0.4)); }
  // a `|` list of times; missing ones continue from the last given one by `step`
  function times(key, n, start, step) {
    var given = nums(C.v[key]), out = [];
    for (var i = 0; i < n; i++) {
      var x = i < given.length ? given[i] : (given.length ? given[given.length - 1] + step * (i - given.length + 1) : start + step * i);
      out.push(Math.max(0, Math.min(x, C.dur - 0.4)));
    }
    return out;
  }

  // ---------------------------------------------------------------- gestures
  function enter(tl, el, at) { gsap.set(el, { y: 24, opacity: 0 }); tl.to(el, { y: 0, opacity: 1, duration: S.medium, ease: EASE.enter }, at); return at + S.medium; }
  function settle(tl, el, at, o) {
    o = o || {}; gsap.set(el, o.scale ? { scale: 0.92, opacity: 0 } : { y: 14, opacity: 0 });
    tl.to(el, o.scale ? { scale: 1, opacity: 1, duration: S.short, ease: EASE.settle } : { y: 0, opacity: 1, duration: S.short, ease: EASE.settle }, at); return at + S.short;
  }
  function reveal(tl, el, at, o) { o = o || {}; var ax = o.axis === 'y' ? 'scaleY' : 'scaleX', f = {}, to = { duration: 0.45, ease: EASE.enter }; f[ax] = 0; to[ax] = 1; gsap.set(el, f); tl.to(el, to, at); return at + 0.45; }
  function emphasis(tl, el, at, o) { var h = 0.3; tl.to(el, { scale: (o && o.scale) || 1.04, duration: h, ease: EASE.emphasis }, at); tl.to(el, { scale: 1, duration: h, ease: EASE.emphasis }, at + h); return at + 2 * h; }
  function exit(tl, el, at) { tl.to(el, { y: -12, opacity: 0, duration: 0.34, ease: EASE.exit }, at); return at + 0.34; }
  // a surface uncovered by an edge travelling in `dir` (right = the edge moves left to right)
  function surfaceIn(tl, el, at, o) {
    o = o || {}; var d = o.plate ? MASK.plate : MASK.surface;
    gsap.set(el, { clipPath: CLIP[o.dir || 'right'] }); tl.to(el, { clipPath: CLIP.full, duration: d, ease: EASE.enter }, at); return at + d;
  }
  function surfaceOut(tl, el, at, o) { o = o || {}; tl.to(el, { clipPath: OUT[o.dir || 'up'], duration: MASK.out, ease: EASE.exit }, at); return at + MASK.out; }
  // lines of type rise from their masks, one after the other
  function linesIn(tl, els, at, o) {
    var arr = gsap.utils.toArray(els); if (!arr.length) return at; var st = (o && o.stagger) || STEP;
    gsap.set(arr, { yPercent: MASK.park }); tl.to(arr, { yPercent: 0, duration: MASK.line, ease: EASE.enter, stagger: st }, at);
    return at + MASK.line + (arr.length - 1) * st;
  }
  // drift: a finite yoyo that ends at rest exactly at `until` (never an endless repeat)
  function drift(tl, el, at, until, o) {
    o = o || {}; var win = until - at; if (win < 1) return; var k = Math.max(2, Math.floor(win / S.drift)); if (k % 2) k -= 1;
    tl.to(el, { y: o.y == null ? -6 : o.y, rotation: o.rot || 0, duration: win / k, ease: EASE.emphasis, yoyo: true, repeat: k - 1 }, at);
  }

  // ---------------------------------------------------------------- the marker
  function swipe(tl, mk, at, dur) {
    if (!mk) return at; var d = dur || S.short, els = [mk];
    if (mk.nextSibling && mk.parentNode.querySelector('.mko')) els.push(mk.parentNode.querySelector('.mko'));
    tl.to(els, { clipPath: CLIP.full, duration: d, ease: EASE.settle }, at); return at + d;
  }
  function swipeAll(tl, marks, at, dur) { var d = (dur || S.short) / Math.max(1, marks.length), x = at; marks.forEach(function (m) { x = swipe(tl, m, x, Math.max(d, S.micro)); }); return x; }
  function norm(s) { return String(s).toLowerCase().replace(/[^a-z0-9$%À-ɏ]/g, ''); }
  // rich(el, text, hots): one masked line per rendered line, each hot run (whole words) in a marker span.
  // Returns {inner: [.mi], marks: [[markers of hot 0], [markers of hot 1], ...]}. Call again after fonts load.
  var uid = 0;
  function rich(el, text, hots) {
    var words = String(text == null ? '' : text).split(/\s+/).filter(Boolean), tag = words.map(function () { return -1; });
    (hots || []).forEach(function (h, hi) {
      var hw = String(h).split(/\s+/).filter(Boolean); if (!hw.length) return;
      for (var i = 0; i <= words.length - hw.length; i++) {
        var ok = true;
        for (var k = 0; k < hw.length; k++) if (tag[i + k] >= 0 || !norm(hw[k]) || norm(words[i + k]).indexOf(norm(hw[k])) !== 0) { ok = false; break; }
        if (ok) { for (var k2 = 0; k2 < hw.length; k2++) tag[i + k2] = hi; break; }
      }
    });
    el.innerHTML = words.map(function (w) { return '<span class="wd">' + esc(w) + '</span>'; }).join(' ');
    var spans = el.querySelectorAll('.wd'), rows = [], last = null;
    for (var j = 0; j < spans.length; j++) { var top = spans[j].offsetTop; if (last === null || Math.abs(top - last) > 4) { rows.push([]); last = top; } rows[rows.length - 1].push(j); }
    var marks = (hots || []).map(function () { return []; }), html = '';
    rows.forEach(function (r) {
      var out = [], run = [], runTag = -1;
      function flush() {
        if (!run.length) return; var id = 'mk' + (uid++), txt = run.join(' '); marks[runTag].push(id);
        out.push('<span class="hl"><i class="mk" id="' + id + '"></i><span class="hw">' + txt + '</span><span class="mko" aria-hidden="true">' + txt + '</span></span>'); run = [];
      }
      r.forEach(function (i) { var w = esc(words[i]); if (tag[i] >= 0) { if (run.length && runTag !== tag[i]) flush(); runTag = tag[i]; run.push(w); } else { flush(); out.push(w); } });
      flush(); html += '<span class="ml"><span class="mi">' + out.join(' ') + '</span></span>';
    });
    el.innerHTML = html;
    return { inner: [].slice.call(el.querySelectorAll('.mi')), marks: marks.map(function (ids) { return ids.map(function (id) { return document.getElementById(id); }); }) };
  }
  // marked(text, hots): HTML with the first occurrence of each hot run wrapped in a marker (for one-line text)
  function marked(text, hots) {
    var out = esc(text);
    list(hots).forEach(function (h) {
      var e = esc(h), i = out.indexOf(e); if (i < 0) return;
      out = out.slice(0, i) + '<span class="hl"><i class="mk"></i><span class="hw">' + e + '</span><span class="mko" aria-hidden="true">' + e + '</span></span>' + out.slice(i + e.length);
    });
    return out;
  }
  // fitText(el, text, hots, sizes, maxLines): the largest size from `sizes` that keeps the text to maxLines
  function fitText(el, text, hots, sizes, maxLines) {
    var r = null;
    for (var i = 0; i < sizes.length; i++) { el.style.fontSize = sizes[i] + 'px'; r = rich(el, text, hots); if (r.inner.length <= maxLines) break; }
    return r;
  }
  // shrink a single-line element until it fits `width`
  function fitWidth(el, width, sizes) { for (var i = 0; i < sizes.length; i++) { el.style.fontSize = sizes[i] + 'px'; if (el.scrollWidth <= width) return sizes[i]; } return sizes[sizes.length - 1]; }

  // ---------------------------------------------------------------- numbers and typing (setter driven: seek safe)
  function count(tl, el, o) {
    var st = {}, val = o.from || 0, render = function (x) { el.textContent = (o.pre || '') + (o.time ? clock(x) : fmt(x, o.dec || 0)) + (o.suf || ''); };
    Object.defineProperty(st, 'v', { get: function () { return val; }, set: function (x) { val = x; render(x); } });
    render(val); tl.to(st, { v: o.to, duration: Math.max(S.micro, o.dur || S.travel), ease: o.ease || EASE.travel }, o.at || 0);
    return (o.at || 0) + (o.dur || S.travel);
  }
  function typeOn(tl, el, text, at, dur) {
    var st = {}, n = 0; text = String(text || '');
    Object.defineProperty(st, 'n', { get: function () { return n; }, set: function (x) { n = x; el.textContent = text.slice(0, Math.round(x)); } });
    el.textContent = ''; tl.to(st, { n: text.length, duration: dur, ease: EASE.linear }, at); return at + dur;
  }

  // ---------------------------------------------------------------- placement
  // place(el, {max, centre}): el's natural size is fitted, centred, into the zone rectangle that gives the
  // largest scale. max caps the scale (default 1: type never grows past its design size).
  function place(el, o) {
    o = o || {}; var z = ZONES[C.shape][C.zone], w = el.offsetWidth, h = el.offsetHeight, best = null;
    z.rects.forEach(function (r) { var s = Math.min(o.max || 1, (r[2] - r[0]) / w, (r[3] - r[1]) / h); if (!best || s > best.s + 0.005) best = { s: s, r: r }; });
    var r = best.r, s = best.s, x = r[0] + (r[2] - r[0] - w * s) / 2, y = r[1] + (r[3] - r[1] - h * s) / 2;
    if (o.align === 'top') y = r[1];
    if (o.align === 'bottom') y = r[3] - h * s;
    gsap.set(el, { x: x, y: y, scale: s, transformOrigin: '0 0' });
    C.placed = { s: s, x: x, y: y, w: w * s, h: h * s, rect: r, el: el };
    return C.placed;
  }
  // anchor(el, 'bottom-left' | 'bottom-right' | 'top-left' | 'top-right' | 'top' | 'centre'): pin a block to an
  // edge of the zone rectangle at its design size (shrunk only if it would not fit). For overlays such as
  // lower thirds and navigation, which belong to an edge rather than the middle.
  function anchor(el, where) {
    var r = ZONES[C.shape][C.zone].rects[0], w = el.offsetWidth, h = el.offsetHeight;
    var s = Math.min(1, (r[2] - r[0]) / w, (r[3] - r[1]) / h), x, y;
    x = /left/.test(where) ? r[0] : /right/.test(where) ? r[2] - w * s : r[0] + (r[2] - r[0] - w * s) / 2;
    y = /top/.test(where) ? r[1] : /bottom/.test(where) ? r[3] - h * s : r[1] + (r[3] - r[1] - h * s) / 2;
    gsap.set(el, { x: x, y: y, scale: s, transformOrigin: '0 0' });
    C.placed = { s: s, x: x, y: y, w: w * s, h: h * s, rect: r, el: el };
    return C.placed;
  }
  // the camera breathes: a small push over the hold, about the placed box's centre, capped so the box keeps
  // 12 px of its rectangle's air (room for a hard offset shadow)
  function breath(tl, el, from, to, amt) {
    if (to - from < 1) return; var node = typeof el === 'string' ? document.querySelector(el) : el, p = C.placed, a = amt || 0.02;
    if (p && p.rect && p.w > 0) {
      var r = p.rect, gx = Math.min(p.x - r[0], r[2] - (p.x + p.w)) - 12, gy = Math.min(p.y - r[1], r[3] - (p.y + p.h)) - 12;
      a = Math.max(0, Math.min(a, 2 * gx / p.w, 2 * gy / p.h));
    }
    if (a < 0.002 || !node) return;
    tl.fromTo(node, { scale: 1 }, { scale: 1 + a, duration: to - from, ease: EASE.emphasis, immediateRender: false }, from);
  }
  // the standard ending: "cut" holds to the end (the builder cuts), "edge" leaves by its edge at out_at
  function ending(tl, els, key) {
    var mode = lower(C.v[key || 'out']);
    if (mode === 'edge') { var oa = Math.min(C.dur - MASK.out, parseFloat(C.v[(key || 'out') + '_at']) || C.dur - MASK.out); surfaceOut(tl, els, oa, { dir: 'up' }); }
    tl.set({}, {}, C.dur);
  }

  // an image tile: the user's image if given, else initials in the title face
  // `i` rotates the fill (ink, accent, paper) so a row of initials reads as a set, not as clones
  function tile(el, src, name, i) {
    el.innerHTML = ''; el.classList.remove('mono', 'mono-1', 'mono-2');
    if (src) { var im = document.createElement('img'); im.src = src; im.alt = ''; el.appendChild(im); }
    else { el.classList.add('mono'); if (i % 3) el.classList.add('mono-' + (i % 3)); el.textContent = initials(name); el.style.fontSize = Math.round(el.offsetHeight * 0.56) + 'px'; }
  }

  // a numeric look token read off the stage, e.g. CS.token('--x-title-scale', 1)
  function token(name, fallback) { var x = parseFloat(getComputedStyle(C.stage).getPropertyValue(name)); return isNaN(x) ? fallback : x; }
  // title sizes in px, scaled by the look (a condensed or light display face needs a different size)
  function titleSizes(list) { var k = token('--x-title-scale', 1); return list.map(function (s) { return Math.round(s * k); }); }

  // ---------------------------------------------------------------- comp registration
  // The renderer injects window.__CS_VARS (schema defaults merged with the job's vars, plus zone) and patches
  // data-width / data-height / data-duration on #stage. The build runs once, then again when fonts are ready
  // (line breaks depend on the real font metrics).
  function comp(name, build) {
    var stage = document.getElementById('stage'), v = Object.assign({}, root.__CS_VARS || {});
    var W = parseFloat(stage.getAttribute('data-width')) || 1080, H = parseFloat(stage.getAttribute('data-height')) || 1920;
    var shape = W >= H ? 'landscape' : 'vertical';
    stage.style.width = W + 'px'; stage.style.height = H + 'px'; stage.setAttribute('data-shape', shape);
    C = { name: name, v: v, W: W, H: H, shape: shape, zone: lower(v.zone) === 'full' ? 'full' : 'split', dur: parseFloat(stage.getAttribute('data-duration')) || 4, stage: stage };
    stage.classList.add('zone-' + C.zone, 'shape-' + shape);
    var tl = gsap.timeline({ paused: true });
    function run() { tl.clear(); uid = 0; build(v, C, tl); }
    run();
    // load every declared face now (a face only starts loading once text uses it), then rebuild with real metrics
    if (document.fonts) {
      var loads = []; document.fonts.forEach(function (f) { loads.push(f.load().catch(function () {})); });
      Promise.all(loads).then(function () { return document.fonts.ready; }).then(run);
    }
    root.__timelines = root.__timelines || {};
    root.__timelines[stage.getAttribute('data-composition-id')] = tl;
    return tl;
  }

  root.CS = {
    EASE: EASE, S: S, STEP: STEP, MASK: MASK, CLIP: CLIP, ZONES: ZONES,
    list: list, nums: nums, pairs: pairs, fields: fields, esc: esc, lower: lower, pick: pick, fmt: fmt, clock: clock, initials: initials,
    t: t, times: times, enter: enter, settle: settle, reveal: reveal, emphasis: emphasis, exit: exit, drift: drift,
    surfaceIn: surfaceIn, surfaceOut: surfaceOut, linesIn: linesIn, swipe: swipe, swipeAll: swipeAll, rich: rich, marked: marked, fitText: fitText, fitWidth: fitWidth,
    count: count, typeOn: typeOn, anchor: anchor, token: token, titleSizes: titleSizes, place: place, breath: breath, ending: ending, tile: tile, comp: comp,
    ctx: function () { return C; },
  };
})(window);
