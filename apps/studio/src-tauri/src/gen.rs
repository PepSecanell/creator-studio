//! Generation: ideas, weekly card packs, card rewrites and the long-video steps. Every answer is
//! checked by the gates; when a gate fails there is exactly one repair call.

use serde_json::{json, Map, Value};

use crate::brand::Brand;
use crate::cards::{assemble, batch_schema, card_problems, card_schema, script_schema};
use crate::dates::week_label;
use crate::formats::{points_range, Formats};
use crate::gates::{digit_problems, text_problems, word_count};
use crate::jobs::Job;
use crate::jsonfile::{norm, s, str_list, to_pretty};
use crate::llm::{ask, run_claude_structured};
use crate::paths::Paths;
use crate::prompts::{self, CardSpec};
use crate::store;

pub struct Ctx<'a> {
    pub paths: &'a Paths,
    pub brand: &'a Brand,
    pub formats: &'a Formats,
    pub job: &'a Job,
}

type ProblemFn<'a> = &'a (dyn Fn(&Value) -> Vec<String> + Sync);

/// The single repair call: send back what was wrong, keep the repair only if it is better.
fn repair(ctx: &Ctx, schema: &str, what: &str, first: Value, found: Vec<String>, problems: ProblemFn) -> Result<(Value, Vec<String>), String> {
    ctx.job.step(&format!("Fixing {} problem(s) in the {what}", found.len()));
    let prompt = prompts::fix_prompt(ctx.brand, what, &to_pretty(&first, 2), &found);
    match ask(ctx.job, schema, &prompt, &ctx.brand.model("mechanical")) {
        Ok(second) => {
            let rest = problems(&second);
            if rest.len() < found.len() {
                Ok((second, rest))
            } else {
                Ok((first, found))
            }
        }
        Err(e) if ctx.job.is_cancelled() => Err(e),
        Err(_) => Ok((first, found)),
    }
}

/// Ask once, check, repair once. Returns the answer and whatever problems are still left.
fn checked(ctx: &Ctx, schema: &str, prompt: &str, what: &str, problems: ProblemFn) -> Result<(Value, Vec<String>), String> {
    let first = ask(ctx.job, schema, prompt, &ctx.brand.model("creative"))?;
    let found = problems(&first);
    if found.is_empty() {
        return Ok((first, found));
    }
    repair(ctx, schema, what, first, found, problems)
}

fn fields(pairs: Vec<(&str, Value)>) -> Map<String, Value> {
    pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect()
}

// ── Ideas ────────────────────────────────────────────────────────────────────────────────────

const IDEAS_SCHEMA: &str = r#"{"type":"object","properties":{"ideas":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"angle":{"type":"string"},"format":{"type":"string"}},"required":["title","angle","format"]}}},"required":["ideas"]}"#;

fn titles_with(paths: &Paths, kind: &str, status: &[&str]) -> Vec<String> {
    store::load_ideas(paths, kind)
        .ok()
        .and_then(|d| d["items"].as_array().cloned())
        .unwrap_or_default()
        .iter()
        .filter(|i| status.contains(&s(i, "status").as_str()))
        .map(|i| s(i, "title"))
        .collect()
}

pub fn generate_ideas(ctx: &Ctx, kind: &str, count: usize, format: Option<&str>) -> Result<Value, String> {
    let all = if kind == "long" { ctx.formats.long() } else { ctx.formats.shorts() };
    let formats: Vec<Value> = match format.filter(|f| !f.is_empty() && *f != "any") {
        Some(f) => vec![all.iter().find(|x| x["id"] == f).cloned().ok_or_else(|| format!("Unknown format {f}."))?],
        None => all.clone(),
    };
    let ids: Vec<String> = formats.iter().filter_map(|f| f["id"].as_str().map(str::to_string)).collect();
    let prompt = prompts::ideas_prompt(
        ctx.brand,
        kind,
        count,
        &formats,
        &titles_with(ctx.paths, kind, &["new", "used"]),
        &titles_with(ctx.paths, kind, &["kept"]),
        &titles_with(ctx.paths, kind, &["killed"]),
    );
    ctx.job.step("Thinking of ideas");
    let banned = ctx.brand.banned();
    let check = |a: &Value| {
        let mut out = Vec::new();
        for i in a["ideas"].as_array().into_iter().flatten() {
            let t = s(i, "title");
            if t.chars().count() > 70 {
                out.push(format!("idea \"{t}\" is longer than 70 characters"));
            }
            out.extend(text_problems(&format!("{} {}", t, s(i, "angle")), &banned));
        }
        out
    };
    let (answer, left) = checked(ctx, IDEAS_SCHEMA, &prompt, "ideas", &check)?;
    let ideas: Vec<Value> = answer["ideas"]
        .as_array()
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .map(|(n, mut i)| {
            if !ids.contains(&s(&i, "format")) {
                i["format"] = json!(ids[n % ids.len()]);
            }
            i
        })
        .filter(|i| text_problems(&format!("{} {}", s(i, "title"), s(i, "angle")), &banned).is_empty() || left.is_empty())
        .collect();
    let asked = ideas.len();
    let added = store::add_ideas(ctx.paths, kind, ideas)?;
    Ok(json!({"added": added, "skipped": asked - added.len(), "warnings": left}))
}

// ── Week pack ────────────────────────────────────────────────────────────────────────────────

struct Planned {
    id: String,
    format: Value,
    idea: Option<(String, String)>,
    idea_id: Option<String>,
}

/// Makes the cards of one batch (one Claude call) and repairs each card that fails a gate.
fn make_batch(ctx: &Ctx, batch: &[Planned]) -> Result<Vec<(Value, Vec<String>)>, String> {
    let specs: Vec<CardSpec> = batch.iter().map(|p| CardSpec { format: p.format.clone(), idea: p.idea.clone() }).collect();
    let prompt = prompts::cards_prompt(ctx.brand, &specs);
    let answer = ask(ctx.job, &batch_schema(), &prompt, &ctx.brand.model("creative"))?;
    let answers = answer["cards"].as_array().cloned().unwrap_or_default();
    if answers.len() < batch.len() {
        return Err(format!("Claude wrote {} cards, {} were needed.", answers.len(), batch.len()));
    }
    let mut out = Vec::new();
    for (p, a) in batch.iter().zip(answers) {
        let format_id = s(&p.format, "id");
        let backing = p.idea.as_ref().map(|(t, an)| format!("{t} {an}")).unwrap_or_default();
        let check = |x: &Value| card_problems(&assemble(&p.id, &format_id, x), Some(&p.format), ctx.brand, &backing);
        let found = check(&a);
        let (best, left) = if found.is_empty() { (a, found) } else { repair(ctx, &card_schema(), "card", a, found, &check)? };
        out.push((assemble(&p.id, &format_id, &best), left));
    }
    Ok(out)
}

/// Fills a week with cards up to `shorts_per_day x 7`, using kept ideas first.
pub fn write_week(ctx: &Ctx, week: i64) -> Result<Value, String> {
    let capacity = (ctx.brand.shorts_per_day() * 7) as usize;
    let pack = store::load_week(ctx.paths, week)?;
    let existing = pack["cards"].as_array().map(Vec::len).unwrap_or(0);
    if existing >= capacity {
        return Err(format!("Week {week} already has {existing} cards, which is a full week."));
    }
    let need = capacity - existing;

    let ideas = store::load_ideas(ctx.paths, "shorts")?;
    let items = ideas["items"].as_array().cloned().unwrap_or_default();
    let mut chosen: Vec<Value> = items.iter().filter(|i| i["status"] == "kept").cloned().collect();
    chosen.extend(items.iter().filter(|i| i["status"] == "new").cloned());
    chosen.truncate(need);

    let ids = ctx.formats.short_ids();
    let mut recent = store::recent_formats(ctx.paths);
    let first_number = store::next_card_number(&pack, week);
    let mut planned = Vec::new();
    for n in 0..need {
        let idea = chosen.get(n);
        let want = idea.map(|i| s(i, "format")).filter(|f| ids.contains(f));
        let fid = want.unwrap_or_else(|| crate::cards::rotate_formats(1, &ids, &recent).remove(0));
        recent.push(fid.clone());
        planned.push(Planned {
            id: store::card_id(week, first_number + n),
            format: ctx.formats.short(&fid).ok_or("A format in formats.json went missing.")?,
            idea: idea.map(|i| (s(i, "title"), s(i, "angle"))),
            idea_id: idea.map(|i| s(i, "id")),
        });
    }

    ctx.job.step(&format!("Writing {need} cards"));
    let results: Vec<Result<Vec<(Value, Vec<String>)>, String>> = std::thread::scope(|sc| {
        let handles: Vec<_> = planned.chunks(4).map(|batch| sc.spawn(move || make_batch(ctx, batch))).collect();
        handles.into_iter().map(|h| h.join().unwrap_or_else(|_| Err("A writer crashed.".to_string()))).collect()
    });

    let mut cards = Vec::new();
    let mut used = Vec::new();
    let mut warnings = Vec::new();
    let mut first_error = None;
    for (batch, r) in planned.chunks(4).zip(results) {
        match r {
            Ok(done) => {
                for (p, (card, left)) in batch.iter().zip(done) {
                    if !left.is_empty() {
                        warnings.push(json!({"id": p.id, "problems": left}));
                    }
                    if let Some(i) = &p.idea_id {
                        used.push(i.clone());
                    }
                    cards.push(card);
                }
            }
            Err(e) => {
                first_error.get_or_insert(e.clone());
                warnings.push(json!({"id": batch[0].id, "problems": [format!("This batch of {} cards failed: {e}", batch.len())]}));
            }
        }
    }
    if cards.is_empty() {
        return Err(first_error.unwrap_or_else(|| "No cards were written.".to_string()));
    }
    let ids_added: Vec<String> = cards.iter().map(|c| s(c, "id")).collect();
    store::append_cards(ctx.paths, week, cards)?;
    for id in used {
        let _ = store::set_idea_status(ctx.paths, "shorts", &id, "used");
    }
    Ok(json!({"week": week, "label": week_label(store::current_week().0, week), "added": ids_added, "warnings": warnings}))
}

/// Which part of a card a rewrite may change.
fn merge_part(cur: &Value, answer: &Value, part: &str) -> Value {
    let mut out = cur.clone();
    let take = |out: &mut Value, key: &str| {
        if let Some(v) = answer.get(key) {
            out[key] = v.clone();
        }
    };
    match part {
        "all" => {
            for k in ["title", "hook", "points", "payoff", "end_line", "facts"] {
                take(&mut out, k);
            }
        }
        "hook" | "points" | "payoff" | "end_line" | "title" | "facts" => take(&mut out, part),
        _ => {}
    }
    out
}

pub fn rewrite_card(ctx: &Ctx, week: i64, id: &str, part: &str, note: &str) -> Result<Value, String> {
    let cur = store::find_card(ctx.paths, week, id)?;
    let fmt = ctx.formats.short(&s(&cur, "format"));
    let prompt = prompts::rewrite_prompt(ctx.brand, &to_pretty(&cur, 2), part, note);
    ctx.job.step("Rewriting");
    let check = |a: &Value| card_problems(&merge_part(&cur, a, part), fmt.as_ref(), ctx.brand, "");
    let (answer, left) = checked(ctx, &card_schema(), &prompt, "card", &check)?;
    let merged = merge_part(&cur, &answer, part);
    let f = fields(["title", "hook", "points", "payoff", "end_line", "facts"].iter().map(|k| (*k, merged[*k].clone())).collect());
    let card = store::save_card(ctx.paths, week, id, &f)?;
    Ok(json!({"card": card, "warnings": left}))
}

pub fn make_script(ctx: &Ctx, week: i64, id: &str) -> Result<Value, String> {
    let cur = store::find_card(ctx.paths, week, id)?;
    let prompt = prompts::script_prompt(ctx.brand, &to_pretty(&cur, 2));
    let limit = (ctx.brand.max_short_seconds() as f64 * 2.6) as usize;
    let banned = ctx.brand.banned();
    let backing = crate::cards::visible_texts(&cur).join(" ");
    ctx.job.step("Writing the script");
    let check = |a: &Value| {
        let t = s(a, "script");
        let mut out = Vec::new();
        if t.trim().is_empty() {
            out.push("the script is empty".to_string());
        }
        if word_count(&t) > limit {
            out.push(format!("the script has {} words, at most {limit} fit", word_count(&t)));
        }
        out.extend(text_problems(&t, &banned));
        out.extend(digit_problems(&t, &backing));
        out
    };
    let (answer, left) = checked(ctx, &script_schema(), &prompt, "script", &check)?;
    let f = fields(vec![("mode", json!("script")), ("script", json!(s(&answer, "script").trim()))]);
    let card = store::save_card(ctx.paths, week, id, &f)?;
    Ok(json!({"card": card, "warnings": left}))
}

/// Quick fix for a pasted or edited text: removes flagged phrases, keeps the rest.
pub fn fix_text(brand: &Brand, text: &str) -> Result<String, String> {
    let banned = brand.banned();
    let found = text_problems(text, &banned);
    if found.is_empty() {
        return Ok(text.to_string());
    }
    let schema = r#"{"type":"object","properties":{"fixed_text":{"type":"string"}},"required":["fixed_text"]}"#;
    let prompt = format!(
        "{}\n=== TASK ===\nRewrite the text below to remove ONLY these problems, changing as little else as possible. Same facts, same length, same plain voice.\n{}\n\n=== TEXT ===\n{}\n\nFill the JSON schema exactly.",
        brand.voice_block(),
        found.iter().map(|p| format!("- {p}")).collect::<Vec<_>>().join("\n"),
        text
    );
    let v = run_claude_structured(schema, &prompt, "", &brand.model("mechanical"))?;
    let fixed = s(&v, "fixed_text").trim().to_string();
    let rest = text_problems(&fixed, &banned);
    if fixed.is_empty() || !rest.is_empty() {
        return Err(format!("Couldn't clean it fully: {}", rest.join("; ")));
    }
    Ok(fixed)
}

// ── Long videos ──────────────────────────────────────────────────────────────────────────────

fn video_ctx(ctx: &Ctx, v: &Value) -> String {
    prompts::long_context(v, ctx.formats.long_format(&s(v, "format")).as_ref())
}

fn map_text(v: &Value) -> String {
    v["map"]
        .as_array()
        .into_iter()
        .flatten()
        .enumerate()
        .map(|(i, p)| if p.is_string() { format!("{}. {}", i + 1, p.as_str().unwrap_or("")) } else { format!("{}. {}\n   {}", i + 1, s(p, "title"), s(p, "detail")) })
        .collect::<Vec<_>>()
        .join("\n")
}

fn backing_of(v: &Value) -> String {
    format!("{} {} {} {}", s(v, "title"), s(v, "idea"), str_list(v, "facts").join(" "), map_text(v))
}

pub fn long_titles(ctx: &Ctx, slug: &str) -> Result<Value, String> {
    let v = store::load_video(ctx.paths, slug)?;
    let prompt = prompts::titles_prompt(ctx.brand, &video_ctx(ctx, &v));
    let schema = r#"{"type":"object","properties":{"titles":{"type":"array","items":{"type":"string"}}},"required":["titles"]}"#;
    let banned = ctx.brand.banned();
    ctx.job.step("Writing title options");
    let check = |a: &Value| {
        let titles = str_list(a, "titles");
        let mut out = Vec::new();
        if titles.len() != 3 {
            out.push(format!("3 titles are needed, there are {}", titles.len()));
        }
        let mut seen: Vec<String> = Vec::new();
        for t in &titles {
            if t.chars().count() > 70 {
                out.push(format!("title \"{t}\" is longer than 70 characters"));
            }
            if seen.contains(&norm(t)) {
                out.push(format!("title \"{t}\" is repeated"));
            }
            seen.push(norm(t));
            out.extend(text_problems(t, &banned));
        }
        out
    };
    let (answer, left) = checked(ctx, schema, &prompt, "titles", &check)?;
    let titles = str_list(&answer, "titles");
    let video = store::update_video(ctx.paths, slug, &fields(vec![("title_options", json!(titles))]))?;
    Ok(json!({"video": video, "warnings": left}))
}

pub fn long_map(ctx: &Ctx, slug: &str) -> Result<Value, String> {
    let v = store::load_video(ctx.paths, slug)?;
    let format = ctx.formats.long_format(&s(&v, "format")).ok_or("This video's format is not in formats.json.")?;
    let (lo, hi) = points_range(&format);
    let prompt = prompts::map_prompt(ctx.brand, &video_ctx(ctx, &v), &format);
    let schema = r#"{"type":"object","properties":{"points":{"type":"array","items":{"type":"object","properties":{"title":{"type":"string"},"detail":{"type":"string"}},"required":["title","detail"]}},"facts":{"type":"array","items":{"type":"string"}}},"required":["points","facts"]}"#;
    let banned = ctx.brand.banned();
    let backing = backing_of(&v);
    ctx.job.step("Writing the map");
    let check = |a: &Value| {
        let pts = a["points"].as_array().cloned().unwrap_or_default();
        let mut out = Vec::new();
        if !(lo..=hi).contains(&pts.len()) {
            out.push(format!("the map needs {lo} to {hi} points, there are {}", pts.len()));
        }
        let facts = str_list(a, "facts").join(" ");
        for p in &pts {
            let (t, d) = (s(p, "title"), s(p, "detail"));
            if t.trim().is_empty() || d.trim().is_empty() {
                out.push("every point needs a title line and a detail line".to_string());
            }
            if word_count(&t) > 9 || word_count(&d) > 18 {
                out.push(format!("point \"{t}\" is too long: title up to 8 words, detail up to 14"));
            }
            let both = format!("{t} {d}");
            out.extend(text_problems(&both, &banned));
            out.extend(digit_problems(&both, &format!("{backing} {facts}")));
        }
        out
    };
    let (answer, left) = checked(ctx, schema, &prompt, "map", &check)?;
    let map: Vec<Value> = answer["points"].as_array().cloned().unwrap_or_default().iter().map(|p| json!({"title": s(p, "title").trim(), "detail": s(p, "detail").trim()})).collect();
    let mut facts = str_list(&v, "facts");
    facts.extend(str_list(&answer, "facts"));
    facts.dedup();
    let video = store::update_video(ctx.paths, slug, &fields(vec![("map", json!(map)), ("mode", json!("map")), ("facts", json!(facts))]))?;
    Ok(json!({"video": video, "warnings": left}))
}

pub fn long_script(ctx: &Ctx, slug: &str, minutes: i64) -> Result<Value, String> {
    let v = store::load_video(ctx.paths, slug)?;
    if v["map"].as_array().is_none_or(|m| m.is_empty()) {
        return Err("Write the map first, the script follows it.".to_string());
    }
    let minutes = minutes.clamp(2, 20);
    let prompt = prompts::long_script_prompt(ctx.brand, &video_ctx(ctx, &v), &map_text(&v), minutes);
    let banned = ctx.brand.banned();
    let backing = backing_of(&v);
    ctx.job.step("Writing the script");
    let check = |a: &Value| {
        let t = s(a, "script");
        let mut out = Vec::new();
        if word_count(&t) < (minutes as usize) * 60 {
            out.push(format!("the script is too short for {minutes} minutes ({} words)", word_count(&t)));
        }
        out.extend(text_problems(&t, &banned));
        out.extend(digit_problems(&t, &backing));
        out
    };
    let (answer, left) = checked(ctx, &script_schema(), &prompt, "script", &check)?;
    let video = store::update_video(ctx.paths, slug, &fields(vec![("script", json!(s(&answer, "script").trim())), ("mode", json!("script"))]))?;
    Ok(json!({"video": video, "warnings": left}))
}

pub fn long_thumbs(ctx: &Ctx, slug: &str) -> Result<Value, String> {
    let v = store::load_video(ctx.paths, slug)?;
    let shapes = ctx.formats.thumbnail_shapes();
    let shape_ids = ctx.formats.thumb_ids();
    let prompt = prompts::thumbs_prompt(ctx.brand, &video_ctx(ctx, &v), &shapes);
    let schema = r#"{"type":"object","properties":{"ideas":{"type":"array","items":{"type":"object","properties":{"shape":{"type":"string"},"words":{"type":"string"},"scene":{"type":"string"},"why":{"type":"string"}},"required":["shape","words","scene","why"]}}},"required":["ideas"]}"#;
    let banned = ctx.brand.banned();
    let title = s(&v, "title");
    ctx.job.step("Designing thumbnails");
    let check = |a: &Value| {
        let ideas = a["ideas"].as_array().cloned().unwrap_or_default();
        let mut out = Vec::new();
        if ideas.len() != 3 {
            out.push(format!("3 thumbnail ideas are needed, there are {}", ideas.len()));
        }
        let mut used: Vec<String> = Vec::new();
        for i in &ideas {
            let shape = s(i, "shape");
            if !shape_ids.contains(&shape) {
                out.push(format!("shape \"{shape}\" is not one of: {}", shape_ids.join(", ")));
            }
            if used.contains(&shape) {
                out.push(format!("the shape \"{shape}\" is used twice, the 3 ideas must look structurally different"));
            }
            used.push(shape);
            let words = s(i, "words");
            if !(1..=5).contains(&word_count(&words)) {
                out.push(format!("thumbnail words \"{words}\" must be 1 to 5 words"));
            }
            if norm(&words) == norm(&title) {
                out.push("thumbnail words must not repeat the title".to_string());
            }
            if s(i, "scene").trim().is_empty() {
                out.push("a thumbnail idea has no scene".to_string());
            }
            out.extend(text_problems(&format!("{} {} {}", words, s(i, "scene"), s(i, "why")), &banned));
        }
        out
    };
    let (answer, left) = checked(ctx, schema, &prompt, "thumbnail ideas", &check)?;
    let video = store::update_video(ctx.paths, slug, &fields(vec![("thumbnail_ideas", answer["ideas"].clone())]))?;
    Ok(json!({"video": video, "warnings": left}))
}

fn clock(secs: i64) -> String {
    if secs >= 3600 {
        format!("{}:{:02}:{:02}", secs / 3600, (secs % 3600) / 60, secs % 60)
    } else {
        format!("{}:{:02}", secs / 60, secs % 60)
    }
}

pub fn long_description(ctx: &Ctx, slug: &str) -> Result<Value, String> {
    let v = store::load_video(ctx.paths, slug)?;
    let prompt = prompts::description_prompt(ctx.brand, &video_ctx(ctx, &v), &map_text(&v));
    let schema = r#"{"type":"object","properties":{"description":{"type":"string"},"chapters":{"type":"array","items":{"type":"object","properties":{"start_seconds":{"type":"integer"},"title":{"type":"string"}},"required":["start_seconds","title"]}}},"required":["description","chapters"]}"#;
    let banned = ctx.brand.banned();
    ctx.job.step("Writing the description");
    let check = |a: &Value| {
        let mut out = text_problems(&s(a, "description"), &banned);
        let ch = a["chapters"].as_array().cloned().unwrap_or_default();
        if ch.len() < 3 {
            out.push("at least 3 chapters are needed".to_string());
        }
        if ch.first().and_then(|c| c["start_seconds"].as_i64()) != Some(0) {
            out.push("the first chapter must start at 0".to_string());
        }
        let starts: Vec<i64> = ch.iter().map(|c| c["start_seconds"].as_i64().unwrap_or(-1)).collect();
        if starts.windows(2).any(|w| w[1] <= w[0]) {
            out.push("chapter start times must go up".to_string());
        }
        for c in &ch {
            out.extend(text_problems(&s(c, "title"), &banned));
        }
        out
    };
    let (answer, left) = checked(ctx, schema, &prompt, "description", &check)?;
    let chapters: Vec<Value> = answer["chapters"].as_array().cloned().unwrap_or_default().iter().map(|c| {
        let t = c["start_seconds"].as_i64().unwrap_or(0);
        json!({"start": t, "time": clock(t), "title": s(c, "title").trim()})
    }).collect();
    let lines: Vec<String> = chapters.iter().map(|c| format!("{} {}", s(c, "time"), s(c, "title"))).collect();
    let description = format!("{}\n\n{}", s(&answer, "description").trim(), lines.join("\n"));
    let video = store::update_video(ctx.paths, slug, &fields(vec![("description", json!(description)), ("chapters", json!(chapters))]))?;
    Ok(json!({"video": video, "warnings": left}))
}

/// Adds the derived problem list to every card of a week view, so the editor can show what to fix.
pub fn annotate_problems(view: &mut Value, brand: &Brand, formats: &Formats) {
    if let Some(cards) = view["cards"].as_array_mut() {
        for c in cards.iter_mut() {
            let fmt = formats.short(&s(c, "format"));
            c["problems"] = json!(card_problems(c, fmt.as_ref(), brand, ""));
        }
    }
}
