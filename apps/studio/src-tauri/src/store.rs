//! The workspace files Studio owns: ideas, weekly card packs and long videos.
//! Shapes are defined in docs/CONTRACTS.md.

use serde_json::{json, Map, Value};


use crate::brand::Brand;
use crate::dates::{self, fmt_date, iso_week, iso_week_start, week_label};
use crate::jsonfile::{merge_write, norm, read_json, s, slugify};
use crate::paths::Paths;

// ── Ideas ────────────────────────────────────────────────────────────────────────────────────

fn ideas_default() -> Value {
    json!({"schema": "ideas/v1", "items": []})
}

pub fn load_ideas(paths: &Paths, kind: &str) -> Result<Value, String> {
    let p = paths.ideas_file(kind);
    if !p.exists() {
        return Ok(ideas_default());
    }
    read_json(&p)
}

/// Adds ideas, skipping titles that already exist (killed ones too, so a killed idea stays dead).
pub fn add_ideas(paths: &Paths, kind: &str, ideas: Vec<Value>) -> Result<Vec<Value>, String> {
    let today = dates::today_local();
    merge_write(&paths.ideas_file(kind), Some(ideas_default()), |doc| {
        let items = doc["items"].as_array_mut().ok_or("ideas file has no items list")?;
        let mut seen: Vec<String> = items.iter().map(|i| norm(&s(i, "title"))).collect();
        let mut ids: Vec<String> = items.iter().map(|i| s(i, "id")).collect();
        let mut added = Vec::new();
        for idea in &ideas {
            let title = s(idea, "title").trim().to_string();
            if title.is_empty() || seen.contains(&norm(&title)) {
                continue;
            }
            let base = slugify(&title);
            let mut id = base.clone();
            let mut n = 2;
            while ids.contains(&id) {
                id = format!("{base}-{n}");
                n += 1;
            }
            let item = json!({
                "id": id, "title": title, "angle": s(idea, "angle").trim(),
                "format": s(idea, "format"), "created": today, "status": "new"
            });
            seen.push(norm(&title));
            ids.push(id);
            items.push(item.clone());
            added.push(item);
        }
        Ok(added)
    })
}

pub fn set_idea_status(paths: &Paths, kind: &str, id: &str, status: &str) -> Result<(), String> {
    if !["new", "kept", "killed", "used"].contains(&status) {
        return Err(format!("Unknown idea status \"{status}\"."));
    }
    merge_write(&paths.ideas_file(kind), None, |doc| {
        let item = doc["items"].as_array_mut().and_then(|a| a.iter_mut().find(|i| i["id"] == id)).ok_or("That idea no longer exists.")?;
        item["status"] = json!(status);
        Ok(())
    })
}

pub fn delete_idea(paths: &Paths, kind: &str, id: &str) -> Result<(), String> {
    merge_write(&paths.ideas_file(kind), None, |doc| {
        doc["items"].as_array_mut().ok_or("ideas file has no items list")?.retain(|i| i["id"] != id);
        Ok(())
    })
}

pub fn idea_by_id(paths: &Paths, kind: &str, id: &str) -> Option<Value> {
    load_ideas(paths, kind).ok()?["items"].as_array()?.iter().find(|i| i["id"] == id).cloned()
}

// ── Weeks and cards ──────────────────────────────────────────────────────────────────────────

/// (year, week) for today.
pub fn current_week() -> (i64, i64) {
    iso_week(dates::today_utc())
}

fn pack_default(year: i64, week: i64) -> Value {
    json!({"schema": "cards/v1", "week": week_label(year, week), "cards": []})
}

pub fn load_week(paths: &Paths, week: i64) -> Result<Value, String> {
    let p = paths.cards_file(week);
    if !p.exists() {
        return Ok(pack_default(current_week().0, week));
    }
    read_json(&p)
}

fn year_of(pack: &Value, fallback: i64) -> i64 {
    s(pack, "week").split("-W").next().and_then(|y| y.parse().ok()).unwrap_or(fallback)
}

/// Posting slot times for N posts a day, spread through the day.
pub fn slot_times(per_day: i64) -> Vec<String> {
    let n = per_day.max(1);
    if n == 1 {
        return vec!["12:00".to_string()];
    }
    (0..n).map(|i| format!("{:02}:00", 9 + (11 * i) / (n - 1))).collect()
}

/// The week with each card's planned day and slot (the plan is derived, never saved).
pub fn week_view(paths: &Paths, brand: &Brand, week: i64) -> Result<Value, String> {
    let mut pack = load_week(paths, week)?;
    let year = year_of(&pack, current_week().0);
    let start = iso_week_start(year, week);
    let per_day = brand.shorts_per_day();
    let slots = slot_times(per_day);
    if let Some(cards) = pack["cards"].as_array_mut() {
        for (i, c) in cards.iter_mut().enumerate() {
            let day = start + (i as i64) / per_day;
            c["plan"] = json!({"date": fmt_date(day), "label": dates::nice_date(day), "slot": slots[(i as i64 % per_day) as usize]});
        }
    }
    pack["week_number"] = json!(week);
    pack["start"] = json!(fmt_date(start));
    pack["capacity"] = json!(per_day * 7);
    Ok(pack)
}

pub fn list_weeks(paths: &Paths) -> Vec<Value> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(paths.ws("shorts")) else { return out };
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().to_string();
        let Some(n) = name.strip_prefix("week-").and_then(|n| n.parse::<i64>().ok()) else { continue };
        let Ok(pack) = read_json(&e.path().join("cards.json")) else { continue };
        let cards = pack["cards"].as_array().cloned().unwrap_or_default();
        let to_film = cards.iter().filter(|c| c["status"] == "to_film").count();
        out.push(json!({"week": n, "label": s(&pack, "week"), "cards": cards.len(), "to_film": to_film}));
    }
    out.sort_by_key(|w| std::cmp::Reverse(w["week"].as_i64().unwrap_or(0)));
    out
}

pub fn next_card_number(pack: &Value, week: i64) -> usize {
    let prefix = format!("w{week:02}-");
    pack["cards"].as_array().into_iter().flatten().filter_map(|c| s(c, "id").strip_prefix(&prefix).and_then(|n| n.parse::<usize>().ok())).max().unwrap_or(0) + 1
}

pub fn card_id(week: i64, n: usize) -> String {
    format!("w{week:02}-{n:02}")
}

/// Appends finished cards to the week's pack (creating it when missing).
pub fn append_cards(paths: &Paths, week: i64, cards: Vec<Value>) -> Result<(), String> {
    let year = current_week().0;
    merge_write(&paths.cards_file(week), Some(pack_default(year, week)), |pack| {
        let list = pack["cards"].as_array_mut().ok_or("cards file has no cards list")?;
        list.extend(cards.iter().cloned());
        Ok(())
    })
}

pub fn find_card(paths: &Paths, week: i64, id: &str) -> Result<Value, String> {
    load_week(paths, week)?["cards"].as_array().and_then(|a| a.iter().find(|c| c["id"] == id)).cloned().ok_or_else(|| format!("No card {id} in week {week}."))
}

const CARD_KEYS: &[&str] = &["title", "format", "mode", "hook", "points", "payoff", "end_line", "script", "facts", "status", "setup"];

/// Replaces the editable parts of one card. Only known card keys are taken from `fields`.
pub fn save_card(paths: &Paths, week: i64, id: &str, fields: &Map<String, Value>) -> Result<Value, String> {
    merge_write(&paths.cards_file(week), None, |pack| {
        let card = pack["cards"].as_array_mut().and_then(|a| a.iter_mut().find(|c| c["id"] == id)).ok_or_else(|| format!("No card {id} in week {week}."))?;
        for (k, v) in fields {
            if CARD_KEYS.contains(&k.as_str()) {
                card[k.as_str()] = v.clone();
            }
        }
        Ok(card.clone())
    })
}

pub fn delete_card(paths: &Paths, week: i64, id: &str) -> Result<(), String> {
    merge_write(&paths.cards_file(week), None, |pack| {
        pack["cards"].as_array_mut().ok_or("cards file has no cards list")?.retain(|c| c["id"] != id);
        Ok(())
    })
}

/// Formats used by the most recent cards, oldest first (for rotation).
pub fn recent_formats(paths: &Paths) -> Vec<String> {
    let mut out = Vec::new();
    for w in list_weeks(paths).iter().rev().take(2) {
        if let Ok(pack) = load_week(paths, w["week"].as_i64().unwrap_or(0)) {
            out.extend(pack["cards"].as_array().into_iter().flatten().map(|c| s(c, "format")));
        }
    }
    out
}

// ── Long videos ──────────────────────────────────────────────────────────────────────────────

pub fn video_default(slug: &str, title: &str, format: &str) -> Value {
    json!({
        "schema": "long-video/v1", "slug": slug, "title": title, "format": format, "mode": "map",
        "map": [], "script": null, "thumbnail_ideas": [], "description": "", "status": "draft",
        "idea": "", "title_options": [], "chapters": [], "facts": [], "setup": {"urls": [], "apps": []}
    })
}

pub fn list_videos(paths: &Paths) -> Vec<Value> {
    let mut out = Vec::new();
    let Ok(rd) = std::fs::read_dir(paths.ws("long")) else { return out };
    for e in rd.flatten() {
        if let Ok(v) = read_json(&e.path().join("video.json")) {
            out.push(v);
        }
    }
    out.sort_by_key(|v| s(v, "slug"));
    out
}

pub fn load_video(paths: &Paths, slug: &str) -> Result<Value, String> {
    read_json(&paths.video_file(slug)).map_err(|_| format!("No long video called {slug}."))
}

/// Starts a long video from an idea (or just a working title).
pub fn create_video(paths: &Paths, idea_id: Option<&str>, title: Option<&str>, format: &str) -> Result<Value, String> {
    let idea = idea_id.and_then(|id| idea_by_id(paths, "long", id));
    let working = title.map(str::to_string).or_else(|| idea.as_ref().map(|i| s(i, "title"))).filter(|t| !t.trim().is_empty()).ok_or("Give the video an idea or a working title.")?;
    let base = slugify(&working);
    let mut slug = base.clone();
    let mut n = 2;
    while paths.video_file(&slug).exists() {
        slug = format!("{base}-{n}");
        n += 1;
    }
    let mut v = video_default(&slug, working.trim(), format);
    if let Some(i) = &idea {
        v["idea"] = json!(s(i, "angle"));
    }
    merge_write(&paths.video_file(&slug), Some(v.clone()), |_| Ok(()))?;
    if let Some(id) = idea_id {
        let _ = set_idea_status(paths, "long", id, "used");
    }
    Ok(v)
}

const VIDEO_KEYS: &[&str] = &["title", "format", "mode", "map", "script", "thumbnail_ideas", "description", "status", "idea", "title_options", "chapters", "facts", "setup"];

pub fn update_video(paths: &Paths, slug: &str, fields: &Map<String, Value>) -> Result<Value, String> {
    merge_write(&paths.video_file(slug), None, |v| {
        for (k, val) in fields {
            if VIDEO_KEYS.contains(&k.as_str()) {
                v[k.as_str()] = val.clone();
            }
        }
        Ok(v.clone())
    })
}

pub fn delete_video(paths: &Paths, slug: &str) -> Result<(), String> {
    let dir = paths.video_dir(slug);
    if !dir.starts_with(paths.ws("long")) || slug.contains('/') || slug.contains("..") {
        return Err("Not a video folder.".to_string());
    }
    std::fs::remove_dir_all(&dir).map_err(|e| format!("Can't delete {slug}: {e}"))
}

/// A fresh workspace folder for tests.
#[cfg(test)]
pub fn test_paths(tag: &str) -> Paths {
    let repo = crate::jsonfile::testutil::temp_dir(tag);
    let workspace = repo.join("workspace");
    std::fs::create_dir_all(&workspace).unwrap();
    Paths { repo, workspace }
}


#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ideas_are_added_once_and_status_changes() {
        let p = test_paths("ideas");
        let added = add_ideas(&p, "shorts", vec![json!({"title": "Ship it ugly", "angle": "a", "format": "myth-then-fix"}), json!({"title": "ship it UGLY"}), json!({"title": ""})]).unwrap();
        assert_eq!(added.len(), 1);
        assert_eq!(added[0]["id"], "ship-it-ugly");
        set_idea_status(&p, "shorts", "ship-it-ugly", "killed").unwrap();
        // a killed idea is not proposed again
        assert!(add_ideas(&p, "shorts", vec![json!({"title": "Ship it ugly"})]).unwrap().is_empty());
        assert!(set_idea_status(&p, "shorts", "ship-it-ugly", "weird").is_err());
        delete_idea(&p, "shorts", "ship-it-ugly").unwrap();
        assert_eq!(load_ideas(&p, "shorts").unwrap()["items"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn cards_append_save_and_plan_slots() {
        let p = test_paths("cards");
        let brand = crate::brand::sample();
        let mk = |n| crate::cards::blank_card(&card_id(42, n), "T", "myth-then-fix");
        append_cards(&p, 42, vec![mk(1), mk(2), mk(3)]).unwrap();
        let pack = load_week(&p, 42).unwrap();
        assert_eq!(next_card_number(&pack, 42), 4);
        let mut f = Map::new();
        f.insert("title".into(), json!("New title"));
        f.insert("id".into(), json!("hacked"));
        let saved = save_card(&p, 42, "w42-02", &f).unwrap();
        assert_eq!(saved["title"], "New title");
        assert_eq!(saved["id"], "w42-02", "the id cannot be edited");
        let view = week_view(&p, &brand, 42).unwrap();
        let cards = view["cards"].as_array().unwrap();
        assert_eq!(cards[0]["plan"]["slot"], "09:00");
        assert_eq!(cards[1]["plan"]["slot"], "20:00");
        assert_ne!(cards[1]["plan"]["date"], cards[2]["plan"]["date"]);
        assert_eq!(view["capacity"], 14);
        assert_eq!(list_weeks(&p)[0]["cards"], 3);
        delete_card(&p, 42, "w42-01").unwrap();
        assert_eq!(load_week(&p, 42).unwrap()["cards"].as_array().unwrap().len(), 2);
    }

    #[test]
    fn long_videos_are_created_and_edited() {
        let p = test_paths("video");
        add_ideas(&p, "long", vec![json!({"title": "How I plan a week", "angle": "angle"})]).unwrap();
        let v = create_video(&p, Some("how-i-plan-a-week"), None, "explainer").unwrap();
        assert_eq!(v["slug"], "how-i-plan-a-week");
        assert_eq!(v["idea"], "angle");
        assert_eq!(idea_by_id(&p, "long", "how-i-plan-a-week").unwrap()["status"], "used");
        let again = create_video(&p, None, Some("How I plan a week"), "explainer").unwrap();
        assert_eq!(again["slug"], "how-i-plan-a-week-2");
        let mut f = Map::new();
        f.insert("map".into(), json!([{"title": "a", "detail": "b"}]));
        f.insert("slug".into(), json!("nope"));
        let u = update_video(&p, "how-i-plan-a-week", &f).unwrap();
        assert_eq!(u["slug"], "how-i-plan-a-week");
        assert_eq!(u["map"][0]["title"], "a");
        assert_eq!(list_videos(&p).len(), 2);
        delete_video(&p, "how-i-plan-a-week-2").unwrap();
        assert!(delete_video(&p, "../x").is_err());
        assert_eq!(list_videos(&p).len(), 1);
    }

    #[test]
    fn slot_times_spread_through_the_day() {
        assert_eq!(slot_times(1), vec!["12:00"]);
        assert_eq!(slot_times(3), vec!["09:00", "14:00", "20:00"]);
    }
}
