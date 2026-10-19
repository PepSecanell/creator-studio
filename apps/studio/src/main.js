// Studio: vanilla JS, no build step. One render function per screen, one click handler for all buttons.
const invoke = window.__TAURI__.core.invoke;
const fileUrl = (p) => window.__TAURI__.core.convertFileSrc(p);

const S = {
  boot: null, screen: "shorts", shortsTab: "ideas",
  week: 0, weekData: null, cardId: null,
  ideas: { shorts: null, long: null }, videos: [], videoSlug: null, longTab: "videos",
  film: null, edits: null, kits: null, kit: null, kitDate: null, brand: null,
  jobs: {}, logJob: null, previewOpen: {}, editLogJob: null, lastResult: {},
};

// ── Small helpers ────────────────────────────────────────────────────────────────────────────

const $ = (sel, root = document) => root.querySelector(sel);
const esc = (t) => String(t ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
const lines = (t) => String(t || "").split("\n").map((x) => x.trim()).filter(Boolean);
const plain = (id) => $("#" + id)?.value ?? "";

let toastTimer;
function toast(msg, bad = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast" + (bad ? " error" : "");
  t.hidden = false;
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => (t.hidden = true), bad ? 7000 : 3500);
}

async function call(cmd, args = {}) {
  try {
    return await invoke(cmd, args);
  } catch (e) {
    toast(String(e), true);
    throw e;
  }
}

function formatName(id, kind = "shorts") {
  const f = (S.boot.formats[kind] || []).find((x) => x.id === id);
  return f ? f.name : id || "";
}
const formatOptions = (kind, selected) =>
  (S.boot.formats[kind] || []).map((f) => `<option value="${esc(f.id)}" ${f.id === selected ? "selected" : ""}>${esc(f.name)}</option>`).join("");

// ── Jobs: every Claude call and edit runs in the background with a live status line ──────────

function startJob(id, onDone) {
  S.jobs[id] = { onDone };
  pollJobs();
}

async function pollJobs() {
  clearTimeout(pollJobs.t);
  const bar = $("#status");
  let running = null;
  for (const id of Object.keys(S.jobs)) {
    let j;
    try { j = await invoke("job_status", { id }); } catch { delete S.jobs[id]; continue; }
    if (j.state === "running") {
      running = j;
    } else {
      const cb = S.jobs[id].onDone;
      delete S.jobs[id];
      if (j.state === "done") {
        toast(`${j.label}: done${j.cost_usd ? ` ($${j.cost_usd})` : ""}`);
        S.lastResult[id] = j.result;
        try { cb && (await cb(j.result)); } catch (e) { console.error(e); }
      } else {
        toast(`${j.label}: ${j.error || j.state}`, j.state === "error");
        if (cb && S.editLogJob === id) try { await cb(null); } catch (e) { console.error(e); }
      }
      renderLog(j);
    }
  }
  if (running) {
    const m = Math.floor(running.elapsed / 60), sec = String(running.elapsed % 60).padStart(2, "0");
    bar.className = "status on";
    bar.innerHTML = `<span class="dot"></span><b>${esc(running.label)}</b><span class="grow">${esc(running.step)}${running.detail ? " · " + esc(running.detail) : ""}</span>
      <span>${m}:${sec}</span><button class="btn small" data-act="toggle-log" data-id="${esc(running.id)}">Log</button><button class="btn small danger" data-act="stop-job" data-id="${esc(running.id)}">Stop</button>`;
    renderLog(running);
  } else if (!Object.keys(S.jobs).length) {
    bar.className = "status";
    bar.innerHTML = `<span>Ready</span>`;
  }
  if (Object.keys(S.jobs).length) pollJobs.t = setTimeout(pollJobs, 800);
}

function renderLog(j) {
  const d = $("#logdrawer");
  if (S.logJob === j.id) {
    d.hidden = false;
    d.textContent = (j.log || []).join("\n");
    d.scrollTop = d.scrollHeight;
  }
  const inline = $("#editlog");
  if (inline && S.editLogJob === j.id) { inline.textContent = (j.log || []).join("\n"); inline.scrollTop = inline.scrollHeight; }
}

// ── Boot and theme ───────────────────────────────────────────────────────────────────────────

async function start() {
  const boot = await invoke("boot");
  if (!boot.ok) {
    $("#setup").hidden = false;
    $("#app").hidden = true;
    $("#setup-title").textContent = boot.message.startsWith("Run ./studio setup") ? "Run ./studio setup first" : "Studio can't start yet";
    $("#setup-text").textContent = boot.message;
    return;
  }
  S.boot = boot;
  S.week = boot.week;
  $("#setup").hidden = true;
  $("#app").hidden = false;
  document.title = boot.title;
  $("#brand-name").textContent = boot.brand_name;
  applyTheme(boot.theme);
  $("#status").innerHTML = "<span>Ready</span>";
  go("shorts");
}

function applyTheme(theme) {
  const root = document.documentElement;
  if (theme.tokens_css) {
    const s = document.createElement("style");
    s.textContent = theme.tokens_css;
    document.head.appendChild(s);
  } else {
    const p = theme.palette || {};
    const map = { ground: "--cs-ground", ink: "--cs-ink", accent: "--cs-accent", accent_2: "--cs-accent-2", muted: "--cs-muted", on_accent: "--cs-on-accent" };
    for (const [k, v] of Object.entries(map)) if (/^#[0-9a-f]{3,8}$/i.test(p[k] || "")) root.style.setProperty(v, p[k]);
  }
  let css = "";
  for (const f of theme.fonts || []) {
    css += `@font-face { font-family: "${f.family}"; src: url("${fileUrl(f.path)}"); }\n`;
    const v = { title: "--studio-title", body: "--studio-body", caption: "--studio-caption" }[f.role];
    if (v) root.style.setProperty(v, `"${f.family}", system-ui, sans-serif`);
  }
  if (css) { const s = document.createElement("style"); s.textContent = css; document.head.appendChild(s); }
  if (theme.logo) { const i = $("#logo"); i.src = fileUrl(theme.logo); i.hidden = false; }
}

// ── Navigation ───────────────────────────────────────────────────────────────────────────────

async function go(screen) {
  S.screen = screen;
  document.querySelectorAll(".nav").forEach((n) => n.classList.toggle("on", n.dataset.screen === screen));
  try {
    if (screen === "shorts") await loadShorts();
    if (screen === "long") await loadLong();
    if (screen === "film") S.film = await call("film_day");
    if (screen === "edits") S.edits = await call("list_edits");
    if (screen === "kit") await loadKit();
    if (screen === "brand") S.brand = await call("brand_summary");
  } catch { /* the toast already says why */ }
  render();
}

function render() {
  const main = $("#main");
  const views = { shorts: viewShorts, long: viewLong, film: viewFilm, edits: viewEdits, kit: viewKit, brand: viewBrand };
  main.innerHTML = (views[S.screen] || (() => ""))();
  if (S.screen === "edits" && S.editLogJob) {
    call("job_status", { id: S.editLogJob }).then(renderLog).catch(() => {});
  }
}

// ── Shorts ───────────────────────────────────────────────────────────────────────────────────

async function loadShorts() {
  S.ideas.shorts = await call("list_ideas", { kind: "shorts" });
  S.weekData = await call("load_week", { week: S.week });
}

function viewShorts() {
  const tabs = [["ideas", "Ideas"], ["week", "Week pack"]];
  return `<h1>Shorts</h1>
    <div class="tabs">${tabs.map(([k, n]) => `<button class="tab ${S.shortsTab === k ? "on" : ""}" data-act="shorts-tab" data-tab="${k}">${n}</button>`).join("")}</div>
    ${S.shortsTab === "ideas" ? ideasView("shorts") : weekView()}`;
}

function ideasView(kind) {
  const items = S.ideas[kind]?.items || [];
  const group = (status, title) => {
    const list = items.filter((i) => i.status === status);
    if (!list.length) return "";
    return `<h3>${title} (${list.length})</h3><div class="list">${list.map((i) => ideaRow(kind, i)).join("")}</div>`;
  };
  return `<div class="panel stack">
      <div class="row">
        <label class="field"><span>Format</span><select id="idea-format-${kind}" class="inline"><option value="any">Any</option>${formatOptions(kind === "long" ? "long" : "shorts", "")}</select></label>
        <label class="field"><span>How many</span><input id="idea-count-${kind}" class="inline" type="number" min="1" max="20" value="6" style="width:70px"></label>
        <button class="btn primary" data-act="gen-ideas" data-kind="${kind}" style="align-self:end">Generate ideas</button>
      </div>
      <div class="row">
        <input id="idea-title-${kind}" class="grow" placeholder="Or add your own: a plain title">
        <input id="idea-angle-${kind}" class="grow" placeholder="What the viewer gets (one sentence)">
        <button class="btn" data-act="add-idea" data-kind="${kind}">Add</button>
      </div>
    </div>
    <div style="margin-top:18px">
      ${items.length ? "" : `<p class="muted">No ideas yet. Generate some from your brand topics, or add your own.</p>`}
      ${group("kept", "Kept")}${group("new", "New")}${group("used", "Used")}${group("killed", "Killed")}
    </div>`;
}

function ideaRow(kind, i) {
  const keep = i.status !== "kept", kill = i.status !== "killed";
  return `<div class="item">
    <div class="grow"><div class="title">${esc(i.title)}</div><div class="muted small">${esc(i.angle)}</div></div>
    <span class="badge">${esc(formatName(i.format, kind === "long" ? "long" : "shorts"))}</span>
    ${kind === "long" && i.status !== "used" ? `<button class="btn small primary" data-act="make-video" data-id="${esc(i.id)}">Make video</button>` : ""}
    ${keep ? `<button class="btn small" data-act="idea-status" data-kind="${kind}" data-id="${esc(i.id)}" data-status="kept">Keep</button>` : ""}
    ${kill ? `<button class="btn small" data-act="idea-status" data-kind="${kind}" data-id="${esc(i.id)}" data-status="killed">Kill</button>` : ""}
    <button class="btn small quiet" data-act="del-idea" data-kind="${kind}" data-id="${esc(i.id)}" title="Delete for good">Delete</button>
  </div>`;
}

function weekView() {
  const w = S.weekData;
  if (!w) return "";
  const cards = w.cards || [];
  const perDay = S.boot.per_day;
  const days = [];
  for (let d = 0; d < 7; d++) {
    const start = d * perDay;
    const dayCards = cards.slice(start, start + perDay);
    const label = dayCards[0]?.plan?.label || dayLabel(w.start, d);
    days.push(`<div class="day"><h3>${esc(label)}</h3><div class="slots">${Array.from({ length: perDay }, (_, k) => {
      const c = dayCards[k];
      if (!c) return `<div class="slotcard empty"><span class="time">${esc(slotTime(k))}</span><br>open slot</div>`;
      const bad = (c.problems || []).length;
      return `<button class="slotcard ${S.cardId === c.id ? "on" : ""}" data-act="open-card" data-id="${esc(c.id)}">
        <span class="time">${esc(c.plan?.slot || "")} · ${esc(c.status)}</span><br>${esc(c.title || "(untitled)")}
        ${bad ? `<br><span class="warn small">${bad} to fix</span>` : ""}</button>`;
    }).join("")}</div></div>`);
  }
  const card = cards.find((c) => c.id === S.cardId);
  return `<div class="row spread">
      <div class="row">
        <button class="btn" data-act="week-step" data-d="-1">&larr;</button>
        <h2 style="margin:0">Week ${S.week}</h2>
        <button class="btn" data-act="week-step" data-d="1">&rarr;</button>
        <span class="muted">${esc(w.week || "")} · ${cards.length} of ${w.capacity} cards (${perDay} a day)</span>
      </div>
      <div class="row">
        <button class="btn" data-act="add-card">Add blank card</button>
        <button class="btn primary" data-act="write-week" ${cards.length >= w.capacity ? "disabled" : ""}>Write the week's cards</button>
      </div>
    </div>
    <div class="split" style="margin-top:16px">
      <div class="days">${days.join("")}</div>
      <div class="drawer">${card ? cardEditor(card) : `<div class="panel muted">Pick a card to edit it. Cards are talking points, not a script: you say the hook twice, then talk from the points.</div>`}</div>
    </div>`;
}

function dayLabel(start, offset) {
  const d = new Date(start + "T12:00:00");
  d.setDate(d.getDate() + offset);
  return d.toLocaleDateString("en-GB", { weekday: "short", day: "numeric", month: "short" });
}
function slotTime(k) {
  const n = S.boot.per_day;
  return n === 1 ? "12:00" : String(9 + Math.floor((11 * k) / (n - 1))).padStart(2, "0") + ":00";
}

function cardEditor(c) {
  const takes = c.hook?.takes || ["", ""];
  const script = c.mode === "script";
  return `<div class="card stack" id="editor" data-id="${esc(c.id)}">
    <div class="row spread"><h3>${esc(c.id)}</h3><span class="badge">${esc(formatName(c.format))}</span></div>
    <label class="field"><span>Title</span><input id="c-title" value="${esc(c.title)}"></label>
    <div class="row">
      <label class="field grow"><span>Format</span><select id="c-format">${formatOptions("shorts", c.format)}</select></label>
      <label class="field grow"><span>Mode</span><select id="c-mode"><option value="cards" ${script ? "" : "selected"}>Cards (talk from points)</option><option value="script" ${script ? "selected" : ""}>Script (word for word)</option></select></label>
      <label class="field grow"><span>Status</span><select id="c-status">${["to_film", "filmed", "editing", "ready", "posted"].map((s) => `<option ${s === c.status ? "selected" : ""}>${s}</option>`).join("")}</select></label>
    </div>
    <label class="field"><span>Hook idea (what the first two seconds are about)</span><textarea id="c-hook" rows="2">${esc(c.hook?.idea)}</textarea></label>
    <label class="field"><span>Opening take A (first words you say)</span><input id="c-take0" value="${esc(takes[0])}"></label>
    <label class="field"><span>Opening take B (a different shape)</span><input id="c-take1" value="${esc(takes[1])}"></label>
    <div><div class="small muted" style="margin-bottom:3px">Points (short prompts to talk from)</div>
      <div id="c-points">${(c.points || []).map((p) => pointRow(p)).join("")}</div>
      <button class="btn small" data-act="add-point">Add point</button></div>
    <label class="field"><span>Payoff</span><input id="c-payoff" value="${esc(c.payoff)}"></label>
    <label class="field"><span>End line</span><input id="c-end" value="${esc(c.end_line)}"></label>
    <label class="field"><span>Facts that must be true (one per line; any number in the card must be here)</span><textarea id="c-facts" rows="2">${esc((c.facts || []).join("\n"))}</textarea></label>
    ${script ? `<label class="field"><span>Script</span><textarea id="c-script" rows="7">${esc(c.script || "")}</textarea></label>` : ""}
    <div class="row">
      <label class="field grow"><span>Open before the take: websites (one per line)</span><textarea id="c-urls" rows="2">${esc((c.setup?.urls || []).join("\n"))}</textarea></label>
      <label class="field grow"><span>Apps (one per line)</span><textarea id="c-apps" rows="2">${esc((c.setup?.apps || []).join("\n"))}</textarea></label>
    </div>
    ${(c.problems || []).length ? `<ul class="problems">${c.problems.map((p) => `<li>${esc(p)}</li>`).join("")}</ul>` : `<div class="small" style="color:var(--good)">Passes every check.</div>`}
    <div class="row">
      <button class="btn primary" data-act="save-card">Save</button>
      <button class="btn" data-act="card-page" data-kind="short" data-id="${esc(c.id)}">Card page</button>
      <button class="btn" data-act="record" data-kind="short" data-id="${esc(c.id)}">Record</button>
      <button class="btn danger quiet" data-act="del-card">Delete</button>
    </div>
    <div class="panel stack">
      <div class="row"><select id="rw-part" class="inline"><option value="all">Whole card</option><option value="hook">Hook</option><option value="points">Points</option><option value="payoff">Payoff</option><option value="end_line">End line</option><option value="title">Title</option></select>
        <input id="rw-note" class="grow" placeholder="What should change? (optional)"></div>
      <div class="row"><button class="btn" data-act="rewrite">Rewrite with Claude</button>
        <button class="btn" data-act="make-script">Write a word for word script</button>
        ${script ? `<button class="btn" data-act="clean-script">Remove AI phrases from script</button>` : ""}</div>
    </div>
  </div>`;
}

const pointRow = (p = "") => `<div class="pointrow"><input class="pt" value="${esc(p)}"><button class="btn small quiet" data-act="rm-point">x</button></div>`;

function readCardForm(existingScript) {
  const mode = plain("c-mode");
  const f = {
    title: plain("c-title").trim(), format: plain("c-format"), mode, status: plain("c-status"),
    hook: { idea: plain("c-hook").trim(), takes: [plain("c-take0").trim(), plain("c-take1").trim()] },
    points: [...document.querySelectorAll("#c-points .pt")].map((i) => i.value.trim()).filter(Boolean),
    payoff: plain("c-payoff").trim(), end_line: plain("c-end").trim(),
    facts: lines(plain("c-facts")), setup: { urls: lines(plain("c-urls")), apps: lines(plain("c-apps")) },
  };
  f.script = mode === "script" ? ($("#c-script") ? $("#c-script").value : existingScript || "") : null;
  return f;
}

async function saveCard(quiet = false) {
  const id = $("#editor")?.dataset.id;
  if (!id) return;
  const f = readCardForm(S.weekData.cards.find((c) => c.id === id)?.script);
  await call("save_card", { week: S.week, id, fields: f });
  S.weekData = await call("load_week", { week: S.week });
  render();
  if (!quiet) toast("Saved.");
}

// ── Long videos ──────────────────────────────────────────────────────────────────────────────

async function loadLong() {
  S.ideas.long = await call("list_ideas", { kind: "long" });
  S.videos = await call("list_videos");
}

function viewLong() {
  const v = S.videos.find((x) => x.slug === S.videoSlug);
  if (v) return videoView(v);
  const tabs = [["videos", "Videos"], ["ideas", "Ideas"]];
  return `<h1>Long videos</h1>
    <div class="tabs">${tabs.map(([k, n]) => `<button class="tab ${S.longTab === k ? "on" : ""}" data-act="long-tab" data-tab="${k}">${n}</button>`).join("")}</div>
    ${S.longTab === "ideas" ? ideasView("long") : `
      <div class="panel row" style="margin-bottom:16px">
        <input id="nv-title" class="grow" placeholder="Working title for a new video">
        <select id="nv-format" class="inline">${formatOptions("long", "")}</select>
        <button class="btn primary" data-act="new-video">Start video</button>
      </div>
      <div class="list">${S.videos.map((x) => `<div class="item">
        <div class="grow"><div class="title">${esc(x.title)}</div><div class="muted small">${esc(formatName(x.format, "long"))} · ${(x.map || []).length} points${x.script ? " · script" : ""}</div></div>
        <span class="badge">${esc(x.status)}</span><button class="btn small" data-act="open-video" data-slug="${esc(x.slug)}">Open</button></div>`).join("") || `<p class="muted">No long videos yet. Start one above or make one from an idea.</p>`}</div>`}`;
}

function videoView(v) {
  const map = v.map || [];
  const thumbs = v.thumbnail_ideas || [];
  const mode = v.mode === "script" ? "script" : "map";
  return `<div class="row spread"><button class="btn quiet" data-act="close-video">&larr; All videos</button>
      <div class="row"><select id="v-status" class="inline">${["draft", "to_film", "filmed", "editing", "ready", "posted"].map((s) => `<option ${s === v.status ? "selected" : ""}>${s}</option>`).join("")}</select>
      <button class="btn" data-act="card-page" data-kind="long" data-id="${esc(v.slug)}">Card page</button>
      <button class="btn" data-act="record" data-kind="long" data-id="${esc(v.slug)}">Record</button>
      <button class="btn danger quiet" data-act="del-video">Delete</button></div></div>
    <h1 style="margin-top:10px">${esc(v.title)}</h1>
    <div class="steps" id="video" data-slug="${esc(v.slug)}">
      <section><h2><span>1</span>Idea and title</h2>
        <label class="field"><span>Working title</span><input id="v-title" value="${esc(v.title)}"></label>
        <label class="field" style="margin-top:8px"><span>Idea (what the viewer gets)</span><textarea id="v-idea" rows="2">${esc(v.idea)}</textarea></label>
        <label class="field" style="margin-top:8px"><span>Format</span><select id="v-format">${formatOptions("long", v.format)}</select></label>
        <div class="row" style="margin-top:10px"><button class="btn" data-act="long-step" data-step="titles">Write 3 title options</button></div>
        ${(v.title_options || []).map((t) => `<div class="row" style="margin-top:6px"><span class="grow">${esc(t)}</span><button class="btn small" data-act="use-title" data-title="${esc(t)}">Use this title</button></div>`).join("")}
      </section>
      <section><h2><span>2</span>Map or script</h2>
        <div class="row"><select id="v-mode" class="inline"><option value="map" ${mode === "map" ? "selected" : ""}>Map (talk from points)</option><option value="script" ${mode === "script" ? "selected" : ""}>Script (word for word)</option></select>
          <button class="btn" data-act="long-step" data-step="map">Write the map</button>
          <label class="small muted">Script minutes <input id="v-min" class="inline" type="number" min="2" max="20" value="6" style="width:60px"></label>
          <button class="btn" data-act="long-step" data-step="script" ${map.length ? "" : "disabled"}>Write the script</button></div>
        <div id="v-map" style="margin-top:10px">${map.map((p) => mapRow(p)).join("")}</div>
        <button class="btn small" data-act="add-map">Add point</button>
        <label class="field" style="margin-top:10px"><span>Script</span><textarea id="v-script" rows="8">${esc(v.script || "")}</textarea></label>
        <label class="field" style="margin-top:10px"><span>Facts that must be true (one per line)</span><textarea id="v-facts" rows="2">${esc((v.facts || []).join("\n"))}</textarea></label>
      </section>
      <section><h2><span>3</span>Thumbnail ideas</h2>
        <div class="row"><button class="btn" data-act="long-step" data-step="thumbnails">Write 3 thumbnail ideas</button></div>
        <div class="row" style="align-items:stretch;margin-top:10px">${thumbs.map((t) => `<div class="card grow"><span class="badge accent">${esc(thumbName(t.shape))}</span>
          <h3 style="margin-top:8px">${esc(t.words)}</h3><div>${esc(t.scene)}</div><div class="muted small" style="margin-top:6px">${esc(t.why)}</div></div>`).join("")}</div>
      </section>
      <section><h2><span>4</span>Description and chapters</h2>
        <div class="row"><button class="btn" data-act="long-step" data-step="description">Write description and chapters</button></div>
        <label class="field" style="margin-top:10px"><span>Description (chapters are at the end)</span><textarea id="v-desc" rows="9">${esc(v.description || "")}</textarea></label>
      </section>
      <section><h2><span>5</span>Before the take</h2>
        <div class="row"><label class="field grow"><span>Websites to open (one per line)</span><textarea id="v-urls" rows="2">${esc((v.setup?.urls || []).join("\n"))}</textarea></label>
        <label class="field grow"><span>Apps (one per line)</span><textarea id="v-apps" rows="2">${esc((v.setup?.apps || []).join("\n"))}</textarea></label></div>
      </section>
      <div class="row"><button class="btn primary" data-act="save-video">Save</button></div>
    </div>`;
}

const thumbName = (id) => (S.boot.formats.thumbnail_shapes.find((s) => s.id === id) || {}).name || id;
const mapRow = (p) => {
  const t = typeof p === "string" ? p : p.title, d = typeof p === "string" ? "" : p.detail;
  return `<div class="pointrow"><input class="mt" placeholder="Point (short)" value="${esc(t)}"><input class="md" placeholder="Second line" value="${esc(d)}"><button class="btn small quiet" data-act="rm-point">x</button></div>`;
};

function readVideoForm() {
  return {
    title: plain("v-title").trim(), idea: plain("v-idea").trim(), format: plain("v-format"), mode: plain("v-mode"),
    map: [...document.querySelectorAll("#v-map .pointrow")].map((r) => ({ title: $(".mt", r).value.trim(), detail: $(".md", r).value.trim() })).filter((p) => p.title),
    script: plain("v-script").trim() || null, facts: lines(plain("v-facts")), description: plain("v-desc"),
    status: plain("v-status"), setup: { urls: lines(plain("v-urls")), apps: lines(plain("v-apps")) },
  };
}

async function saveVideo(quiet = false) {
  const slug = $("#video")?.dataset.slug;
  if (!slug) return;
  await call("update_video", { slug, fields: readVideoForm() });
  S.videos = await call("list_videos");
  if (!quiet) { render(); toast("Saved."); }
}

// ── Film day, card page ──────────────────────────────────────────────────────────────────────

function viewFilm() {
  const items = S.film?.items || [];
  return `<h1>Film day</h1><p class="muted">What to film, ordered so the screen and apps change as little as possible. Record writes the take for the Recorder and opens it.</p>
    <p class="muted small">${items.length} to film · ${S.film?.setup_changes || 0} setup changes</p>
    ${items.map((it, n) => `${it.setup_change ? `<div class="panel small" style="margin:14px 0 8px"><b>Change setup:</b> ${esc([...(it.setup.urls || []), ...(it.setup.apps || [])].join(", ") || "camera only")}</div>` : (n === 0 && it.setup_key !== "|" ? `<div class="panel small" style="margin-bottom:8px"><b>Setup:</b> ${esc([...(it.setup.urls || []), ...(it.setup.apps || [])].join(", "))}</div>` : "")}
      <div class="list"><div class="item"><b>${n + 1}</b>
        <div class="grow"><div class="title">${esc(it.title)}</div><div class="muted small">${it.kind === "short" ? `Short ${esc(it.id)} · ` : "Long video · "}${esc(it.mode)}${it.takes ? ` · ${it.takes} take${it.takes > 1 ? "s" : ""} so far` : ""}</div></div>
        <button class="btn small" data-act="card-page" data-kind="${it.kind}" data-id="${esc(it.id)}" data-week="${it.week ?? ""}">Card page</button>
        <button class="btn small primary" data-act="record" data-kind="${it.kind}" data-id="${esc(it.id)}" data-week="${it.week ?? ""}">Record</button></div></div>`).join("") || `<p>Nothing to film. Set a card's status to to_film, or mark a long video as to_film.</p>`}`;
}

async function recordTake(kind, id, week) {
  const r = await call("record", { kind, id, week: week ? Number(week) : kind === "short" ? S.week : null });
  toast(r.message);
}

async function showCardPage(kind, id, week) {
  let title, blocks;
  if (kind === "short") {
    const w = week ? Number(week) : S.week;
    const data = week && Number(week) !== S.week ? await call("load_week", { week: w }) : S.weekData;
    const c = data.cards.find((x) => x.id === id);
    if (!c) return toast("Card not found.", true);
    title = c.title;
    const takes = c.hook?.takes || [];
    blocks = c.mode === "script" && c.script
      ? `<div class="block"><div class="label">Script</div><div class="big" style="white-space:pre-wrap">${esc(c.script)}</div></div>`
      : `<div class="block"><div class="label">Hook idea</div><div class="big">${esc(c.hook?.idea)}</div></div>
         <div class="block"><div class="label">Open with, three times, two ways</div><div class="big"><mark>${esc(takes[0])}</mark><br><br><mark>${esc(takes[1])}</mark></div></div>
         <div class="block"><div class="label">Points</div><ol>${(c.points || []).map((p) => `<li>${esc(p)}</li>`).join("")}</ol></div>
         <div class="block"><div class="label">Payoff</div><div class="big">${esc(c.payoff)}</div></div>
         <div class="block"><div class="label">End with</div><div class="big">${esc(c.end_line)}</div></div>
         ${(c.facts || []).length ? `<div class="block"><div class="label">Must be true</div><ul>${c.facts.map((f) => `<li>${esc(f)}</li>`).join("")}</ul></div>` : ""}`;
  } else {
    const v = S.videos.find((x) => x.slug === id) || (await call("load_video", { slug: id }));
    title = v.title;
    blocks = v.mode === "script" && v.script
      ? `<div class="block"><div class="label">Script</div><div class="big" style="white-space:pre-wrap;font-size:24px">${esc(v.script)}</div></div>`
      : `<div class="block"><div class="label">Map</div><ol>${(v.map || []).map((p) => `<li>${esc(typeof p === "string" ? p : p.title)}${p.detail ? `<small>${esc(p.detail)}</small>` : ""}</li>`).join("")}</ol></div>`;
  }
  const page = $("#cardpage");
  page.innerHTML = `<div class="bar"><button class="btn" data-act="print">Print</button><button class="btn" data-act="close-page">Close (Esc)</button></div>
    <div class="kicker">${esc(S.boot.brand_name)} · ${kind === "short" ? "Short" : "Long video"} ${esc(id)}</div><h1>${esc(title)}</h1>${blocks}`;
  page.hidden = false;
}

// ── Edits ────────────────────────────────────────────────────────────────────────────────────

const STATE_CLASS = { approved: "good", posted: "good", ready_for_review: "accent", needs_you: "bad", failed: "bad", editing: "", queued: "" };

function viewEdits() {
  const list = S.edits || [];
  const running = Object.keys(S.jobs).length > 0;
  return `<h1>Edits</h1>
    <div class="panel row" style="margin-bottom:16px"><span class="muted">Edit a take that has no edit yet:</span>
      <select id="ed-kind" class="inline"><option value="short">Short</option><option value="long">Long video</option></select>
      <input id="ed-id" class="inline" placeholder="card id or video slug" style="width:220px">
      <button class="btn" data-act="edit-now-id" ${running ? "disabled" : ""}>Edit now</button></div>
    ${S.editLogJob ? `<div class="panel" style="margin-bottom:16px"><div class="row spread"><b>Edit log</b>${running ? `<button class="btn small danger" data-act="stop-job" data-id="${esc(S.editLogJob)}">Stop</button>` : ""}</div><pre class="log" id="editlog"></pre></div>` : ""}
    <div class="list">${list.map((e) => {
      const key = e.kind + e.id;
      const canApprove = e.state === "ready_for_review" || e.state === "needs_you";
      return `<div class="item edit" style="align-items:flex-start">
        ${e.cover ? `<img class="thumb" src="${fileUrl(e.cover)}" alt="">` : `<div class="thumb"></div>`}
        <div class="grow stack">
          <div class="row"><span class="title">${esc(e.id)}</span><span class="badge">${e.kind}</span><span class="badge ${STATE_CLASS[e.state] || ""}">${esc(e.state)}</span><span class="muted small">${esc(e.updated)}</span></div>
          ${e.notes ? `<div class="muted small">${esc(e.notes)}</div>` : ""}
          ${S.previewOpen[key] && e.final ? `<video controls src="${fileUrl(e.final)}"></video>` : ""}
          <div class="row">
            ${e.final ? `<button class="btn small" data-act="preview" data-key="${esc(key)}">${S.previewOpen[key] ? "Hide" : "Preview"}</button>` : ""}
            <button class="btn small" data-act="edit-now" data-kind="${e.kind}" data-id="${esc(e.id)}" ${running ? "disabled" : ""}>Edit now</button>
            <button class="btn small primary" data-act="approve" data-kind="${e.kind}" data-id="${esc(e.id)}" ${canApprove ? "" : "disabled"}>Approve</button>
            <button class="btn small quiet" data-act="reveal" data-path="${esc(e.final || e.dir)}">Show in folder</button>
            ${e.posting ? `<button class="btn small quiet" data-act="open" data-path="${esc(e.posting)}">POSTING.md</button>` : ""}
          </div></div></div>`;
    }).join("") || `<p class="muted">No edits yet. Edits appear here once a take has been cut. Use the box above to start one.</p>`}</div>`;
}

async function startEdit(kind, id) {
  if (!id) return toast("Give the card id or video slug.", true);
  const jobId = await call("start_edit", { kind, id });
  S.editLogJob = jobId;
  S.logJob = null;
  startJob(jobId, async () => { S.edits = await call("list_edits"); if (S.screen === "edits") render(); });
  render();
}

// ── Kit ──────────────────────────────────────────────────────────────────────────────────────

async function loadKit() {
  S.kits = await call("list_kits");
  if (!S.kitDate || !S.kits.includes(S.kitDate)) S.kitDate = S.kits[0] || null;
  S.kit = S.kitDate ? await call("load_kit", { date: S.kitDate }) : null;
}

function viewKit() {
  if (!S.kits?.length) return `<h1>Kit</h1><p class="muted">No posting kit yet. Run <code>./studio kit</code> after your edits are approved. Nothing here posts anything for you: it is files and captions for you to post.</p>`;
  const items = S.kit?.items || [];
  return `<h1>Kit</h1><div class="row" style="margin-bottom:14px"><select id="kit-date" class="inline">${S.kits.map((d) => `<option ${d === S.kitDate ? "selected" : ""}>${esc(d)}</option>`).join("")}</select>
      <span class="muted">${items.length} item${items.length === 1 ? "" : "s"}</span></div>
    <div class="list">${items.map((it, n) => `<div class="item kititem" style="align-items:start">
      ${it.cover_abs ? `<img class="thumb" src="${fileUrl(it.cover_abs)}" alt="">` : `<div class="thumb"></div>`}
      <div class="stack">
        <div class="row"><span class="title">${esc(it.id)}</span><span class="badge accent">${esc(it.platform)}</span>${it.post_at ? `<span class="muted small">post at ${esc(it.post_at)}</span>` : ""}</div>
        ${it.title ? `<div><b>${esc(it.title)}</b></div>` : ""}
        <div style="white-space:pre-wrap">${esc(it.caption)}</div>
        ${(it.hashtags || []).length ? `<div class="muted small">${esc(it.hashtags.join(" "))}</div>` : ""}
        ${it.pinned_comment ? `<div class="muted small">Pinned comment: ${esc(it.pinned_comment)}</div>` : ""}
        <div class="row">
          <button class="btn small primary" data-act="copy-caption" data-n="${n}">Copy caption</button>
          ${it.title ? `<button class="btn small" data-act="copy-field" data-n="${n}" data-field="title">Copy title</button>` : ""}
          ${it.pinned_comment ? `<button class="btn small" data-act="copy-field" data-n="${n}" data-field="pinned_comment">Copy pinned comment</button>` : ""}
          ${it.file_abs ? `<button class="btn small" data-act="reveal" data-path="${esc(it.file_abs)}">Show file</button>` : `<span class="warn small">file missing</span>`}
        </div></div></div>`).join("")}</div>`;
}

async function copy(text) {
  try { await invoke("copy_text", { text }); toast("Copied."); }
  catch { try { await navigator.clipboard.writeText(text); toast("Copied."); } catch (e) { toast(String(e), true); } }
}

// ── Brand ────────────────────────────────────────────────────────────────────────────────────

function viewBrand() {
  const b = S.brand;
  if (!b) return "";
  const v = b.voice || {};
  const list = (x) => esc(Array.isArray(x) ? x.join(", ") : x || "");
  const running = Object.keys(S.jobs).length > 0;
  return `<h1>${esc(b.name)}</h1><p class="muted">${esc(b.tagline)}</p>
    <p class="small muted">This is read only. Change <code>brand/brand.json</code>, then run <code>./studio brand build</code>.${b.resolved ? "" : " The brand has not been built yet."}</p>
    <h2>Colours</h2><div class="swatches">${Object.entries(b.palette || {}).map(([k, c]) => `<div class="swatch"><i style="background:${esc(c)}"></i><b>${esc(k)}</b><span>${esc(c)}</span></div>`).join("")}</div>
    <h2 style="margin-top:22px">Look and fonts</h2>
    <dl class="kv"><dt>Style</dt><dd>${esc(b.style)}</dd><dt>Language</dt><dd>${esc(b.language)}</dd>
      ${Object.entries(b.fonts || {}).map(([k, f]) => `<dt>Font: ${esc(k)}</dt><dd>${esc((f && (f.path || f.file || f.family)) || f || "from the look")}</dd>`).join("")}</dl>
    <h2 style="margin-top:22px">Voice</h2>
    <dl class="kv"><dt>Who</dt><dd>${esc(v.who)}</dd><dt>Audience</dt><dd>${esc(v.audience)}</dd><dt>Topics</dt><dd>${list(v.topics)}</dd>
      <dt>Tone</dt><dd>${list(v.tone)}</dd><dt>Banned words</dt><dd>${list(v.banned)}</dd><dt>Call to action</dt><dd>${esc(v.cta)}</dd><dt>Link</dt><dd>${esc(v.link)}</dd></dl>
    <h2 style="margin-top:22px">Schedule</h2>
    <dl class="kv"><dt>Shorts per day</dt><dd>${esc(b.schedule?.shorts_per_day)}</dd><dt>Long per week</dt><dd>${esc(b.schedule?.long_per_week)}</dd><dt>Time zone</dt><dd>${esc(b.schedule?.timezone)}</dd></dl>
    <div class="row" style="margin-top:24px"><button class="btn primary" data-act="brand-preview" ${running || !S.boot.has_studio_cli ? "disabled" : ""}>Run ./studio brand preview</button>
      ${S.boot.has_studio_cli ? "" : `<span class="warn small">./studio was not found in the repo.</span>`}</div>
`;
}

// ── Click handling ───────────────────────────────────────────────────────────────────────────

const actions = {
  reload: () => location.reload(),
  go: (el) => go(el.dataset.screen),
  "shorts-tab": async (el) => { S.shortsTab = el.dataset.tab; await loadShorts(); render(); },
  "long-tab": (el) => { S.longTab = el.dataset.tab; render(); },

  "gen-ideas": async (el) => {
    const kind = el.dataset.kind;
    const id = await call("start_generate_ideas", { kind, count: Number(plain("idea-count-" + kind)) || 6, format: plain("idea-format-" + kind) });
    startJob(id, async () => { S.ideas[kind] = await call("list_ideas", { kind }); render(); });
  },
  "add-idea": async (el) => {
    const kind = el.dataset.kind;
    const title = plain("idea-title-" + kind).trim();
    if (!title) return toast("Type a title first.", true);
    const first = (S.boot.formats[kind === "long" ? "long" : "shorts"][0] || {}).id || "";
    const added = await call("add_idea", { kind, title, angle: plain("idea-angle-" + kind).trim(), format: first });
    if (!added.length) toast("That idea already exists.", true);
    S.ideas[kind] = await call("list_ideas", { kind });
    render();
  },
  "idea-status": async (el) => { await call("set_idea_status", { kind: el.dataset.kind, id: el.dataset.id, status: el.dataset.status }); S.ideas[el.dataset.kind] = await call("list_ideas", { kind: el.dataset.kind }); render(); },
  "del-idea": async (el) => { await call("delete_idea", { kind: el.dataset.kind, id: el.dataset.id }); S.ideas[el.dataset.kind] = await call("list_ideas", { kind: el.dataset.kind }); render(); },

  "week-step": async (el) => { S.week = Math.max(1, Math.min(53, S.week + Number(el.dataset.d))); S.cardId = null; S.weekData = await call("load_week", { week: S.week }); render(); },
  "open-card": (el) => { S.cardId = el.dataset.id; render(); },
  "add-card": async () => {
    const title = prompt("Title for the new card");
    if (!title) return;
    const c = await call("add_card", { week: S.week, title, format: S.boot.formats.shorts[0].id });
    S.weekData = await call("load_week", { week: S.week });
    S.cardId = c.id;
    render();
  },
  "write-week": async () => {
    const id = await call("start_write_week", { week: S.week });
    startJob(id, async (r) => {
      S.weekData = await call("load_week", { week: S.week });
      S.ideas.shorts = await call("list_ideas", { kind: "shorts" });
      render();
      if (r?.warnings?.length) toast(`${r.warnings.length} card(s) still have problems. Open them to see what to fix.`, true);
    });
  },
  "save-card": () => saveCard(),
  "del-card": async () => {
    if (!confirm("Delete this card?")) return;
    await call("delete_card", { week: S.week, id: $("#editor").dataset.id });
    S.cardId = null;
    S.weekData = await call("load_week", { week: S.week });
    render();
  },
  "add-point": () => $("#c-points").insertAdjacentHTML("beforeend", pointRow("")),
  "rm-point": (el) => el.closest(".pointrow").remove(),
  rewrite: async () => {
    await saveCard(true);
    const id = await call("start_rewrite_card", { week: S.week, id: $("#editor").dataset.id, part: plain("rw-part"), note: plain("rw-note") });
    startJob(id, async () => { S.weekData = await call("load_week", { week: S.week }); render(); });
  },
  "make-script": async () => {
    await saveCard(true);
    const id = await call("start_make_script", { week: S.week, id: $("#editor").dataset.id });
    startJob(id, async () => { S.weekData = await call("load_week", { week: S.week }); render(); });
  },
  "clean-script": async () => {
    const fixed = await call("fix_text", { text: plain("c-script") });
    $("#c-script").value = fixed;
    toast("Cleaned. Press Save to keep it.");
  },

  "make-video": async (el) => {
    const idea = (S.ideas.long.items || []).find((i) => i.id === el.dataset.id);
    const v = await call("create_video", { ideaId: el.dataset.id, title: null, format: idea?.format || S.boot.formats.long[0].id });
    await loadLong();
    S.videoSlug = v.slug;
    S.longTab = "videos";
    render();
  },
  "new-video": async () => {
    const title = plain("nv-title").trim();
    if (!title) return toast("Type a working title.", true);
    const v = await call("create_video", { ideaId: null, title, format: plain("nv-format") });
    await loadLong();
    S.videoSlug = v.slug;
    render();
  },
  "open-video": (el) => { S.videoSlug = el.dataset.slug; render(); },
  "close-video": async () => { S.videoSlug = null; await loadLong(); render(); },
  "del-video": async () => {
    if (!confirm("Delete this video and all its files?")) return;
    await call("delete_video", { slug: S.videoSlug });
    S.videoSlug = null;
    await loadLong();
    render();
  },
  "add-map": () => $("#v-map").insertAdjacentHTML("beforeend", mapRow({ title: "", detail: "" })),
  "save-video": () => saveVideo(),
  "use-title": async (el) => { $("#v-title").value = el.dataset.title; await saveVideo(true); S.videos = await call("list_videos"); render(); toast("Title set."); },
  "long-step": async (el) => {
    await saveVideo(true);
    const slug = S.videoSlug, step = el.dataset.step;
    const id = await call("start_long_step", { slug, step, minutes: Number(plain("v-min")) || 6 });
    startJob(id, async () => { S.videos = await call("list_videos"); render(); });
  },

  record: async (el) => recordTake(el.dataset.kind, el.dataset.id, el.dataset.week),
  "card-page": (el) => showCardPage(el.dataset.kind, el.dataset.id, el.dataset.week),
  "close-page": () => ($("#cardpage").hidden = true),
  print: () => window.print(),

  preview: (el) => { S.previewOpen[el.dataset.key] = !S.previewOpen[el.dataset.key]; render(); },
  "edit-now": (el) => startEdit(el.dataset.kind, el.dataset.id),
  "edit-now-id": () => startEdit(plain("ed-kind"), plain("ed-id").trim()),
  approve: async (el) => { await call("approve_edit", { kind: el.dataset.kind, id: el.dataset.id }); S.edits = await call("list_edits"); render(); toast("Approved."); },
  reveal: (el) => call("reveal_path", { path: el.dataset.path }),
  open: (el) => call("open_path", { path: el.dataset.path }),

  "copy-caption": (el) => { const it = S.kit.items[Number(el.dataset.n)]; copy([it.caption, (it.hashtags || []).join(" ")].filter(Boolean).join("\n\n")); },
  "copy-field": (el) => copy(S.kit.items[Number(el.dataset.n)][el.dataset.field] || ""),

  "brand-preview": async () => {
    const id = await call("start_brand_preview");
    S.logJob = id;
    startJob(id, async (r) => { if (r?.preview) { toast("Preview ready."); call("open_path", { path: r.preview }); } });
  },

  "toggle-log": (el) => { S.logJob = S.logJob === el.dataset.id ? null : el.dataset.id; $("#logdrawer").hidden = !S.logJob; },
  "stop-job": (el) => call("stop_job", { id: el.dataset.id }),
};

document.addEventListener("click", (ev) => {
  const el = ev.target.closest("[data-act]");
  if (!el || el.disabled) return;
  const fn = actions[el.dataset.act];
  if (fn) fn(el);
});

document.addEventListener("change", async (ev) => {
  if (ev.target.id === "kit-date") { S.kitDate = ev.target.value; S.kit = await call("load_kit", { date: S.kitDate }); render(); }
  if (ev.target.id === "c-mode" && S.cardId) { await saveCard(true); }
  if (ev.target.id === "v-status") { await saveVideo(true); }
});

document.addEventListener("keydown", (ev) => {
  if (ev.key === "Escape") $("#cardpage").hidden = true;
});

start().catch((e) => {
  $("#setup").hidden = false;
  $("#setup-text").textContent = String(e);
});
