//! Film day and the handoff to the Recorder app.

use serde_json::{json, Value};
use std::path::PathBuf;

use crate::brand::Brand;
use crate::cards::{beats, prompter_text};
use crate::dates::iso_now;
use crate::jsonfile::{atomic_write, s, str_list, to_pretty};
use crate::paths::Paths;
use crate::store;

pub const RECORDER_BUNDLE_ID: &str = "io.github.creatorstudio.recorder";

fn setup_key(setup: &Value) -> String {
    let mut urls = str_list(setup, "urls");
    let mut apps = str_list(setup, "apps");
    urls.sort();
    apps.sort();
    format!("{}|{}", urls.join(","), apps.join(","))
}

fn count_short_takes(paths: &Paths, id: &str) -> usize {
    let needle = format!("-{id}-take-");
    std::fs::read_dir(paths.ws("takes/shorts")).map(|rd| rd.flatten().filter(|e| e.file_name().to_string_lossy().contains(&needle)).count()).unwrap_or(0)
}

fn count_long_takes(paths: &Paths, slug: &str) -> usize {
    std::fs::read_dir(paths.ws(&format!("takes/long/{slug}"))).map(|rd| rd.flatten().filter(|e| e.file_name().to_string_lossy().starts_with("take-")).count()).unwrap_or(0)
}

/// What to film today, grouped by setup so the screen and apps change as rarely as possible.
pub fn film_day(paths: &Paths) -> Value {
    let mut items: Vec<Value> = Vec::new();
    for w in store::list_weeks(paths) {
        let week = w["week"].as_i64().unwrap_or(0);
        let Ok(pack) = store::load_week(paths, week) else { continue };
        for c in pack["cards"].as_array().into_iter().flatten().filter(|c| c["status"] == "to_film") {
            let setup = c.get("setup").cloned().unwrap_or(json!({}));
            items.push(json!({
                "kind": "short", "id": s(c, "id"), "week": week, "title": s(c, "title"), "mode": s(c, "mode"),
                "format": s(c, "format"), "setup": setup, "setup_key": setup_key(&setup),
                "takes": count_short_takes(paths, &s(c, "id")),
            }));
        }
    }
    for v in store::list_videos(paths).iter().filter(|v| v["status"] == "to_film") {
        let setup = v.get("setup").cloned().unwrap_or(json!({}));
        items.push(json!({
            "kind": "long", "id": s(v, "slug"), "week": Value::Null, "title": s(v, "title"), "mode": s(v, "mode"),
            "format": s(v, "format"), "setup": setup, "setup_key": setup_key(&setup),
            "takes": count_long_takes(paths, &s(v, "slug")),
        }));
    }
    // No setup first (just the camera), then each distinct setup together.
    items.sort_by(|a, b| {
        let (ka, kb) = (s(a, "setup_key"), s(b, "setup_key"));
        let (ea, eb) = (ka == "|", kb == "|");
        eb.cmp(&ea).then(ka.cmp(&kb)).then(s(a, "kind").cmp(&s(b, "kind"))).then(s(a, "id").cmp(&s(b, "id")))
    });
    let mut changes = 0;
    let mut prev: Option<String> = None;
    for it in items.iter_mut() {
        let key = s(it, "setup_key");
        let changed = prev.as_ref().is_some_and(|p| *p != key);
        if changed {
            changes += 1;
        }
        it["setup_change"] = json!(changed);
        prev = Some(key);
    }
    json!({"items": items, "setup_changes": changes})
}

fn next_short_dir(paths: &Paths, id: &str, today: &str) -> PathBuf {
    let mut n = count_short_takes(paths, id) + 1;
    loop {
        let d = paths.ws(&format!("takes/shorts/{today}-{id}-take-{n}"));
        if !d.exists() {
            return d;
        }
        n += 1;
    }
}

fn next_long_dir(paths: &Paths, slug: &str) -> PathBuf {
    let mut n = count_long_takes(paths, slug) + 1;
    loop {
        let d = paths.ws(&format!("takes/long/{slug}/take-{n}"));
        if !d.exists() {
            return d;
        }
        n += 1;
    }
}

/// Builds the `handoff/v1` object for a Short (needs its week) or a long video (needs its slug).
pub fn build_handoff(paths: &Paths, brand: &Brand, kind: &str, id: &str, week: Option<i64>, today: &str, created: &str) -> Result<Value, String> {
    let (title, mode, teleprompter, points, out_dir, setup) = match kind {
        "short" => {
            let week = week.ok_or("Which week is this card in?")?;
            let c = store::find_card(paths, week, id)?;
            (
                s(&c, "title"),
                if s(&c, "mode") == "script" { "script" } else { "cards" }.to_string(),
                prompter_text(&c),
                beats(&c),
                next_short_dir(paths, id, today),
                c.get("setup").cloned().unwrap_or(json!({})),
            )
        }
        "long" => {
            let v = store::load_video(paths, id)?;
            let map = v["map"].as_array().cloned().unwrap_or_default();
            let points: Vec<String> = map.iter().map(|p| if p.is_string() { p.as_str().unwrap_or("").to_string() } else { s(p, "title") }).filter(|t| !t.is_empty()).collect();
            let mode = match s(&v, "mode").as_str() {
                "script" => "script",
                "screen" => "screen",
                _ => "cards",
            };
            let text = if mode == "script" && v.get("script").and_then(Value::as_str).is_some_and(|t| !t.trim().is_empty()) {
                s(&v, "script")
            } else {
                let mut lines = vec![s(&v, "title")];
                for p in &map {
                    if p.is_string() {
                        lines.push(format!("- {}", p.as_str().unwrap_or("")));
                    } else {
                        lines.push(format!("- {}", s(p, "title")));
                        if !s(p, "detail").is_empty() {
                            lines.push(format!("    {}", s(p, "detail")));
                        }
                    }
                }
                lines.join("\n")
            };
            (s(&v, "title"), mode.to_string(), text, points, next_long_dir(paths, id), v.get("setup").cloned().unwrap_or(json!({})))
        }
        other => return Err(format!("Unknown kind \"{other}\".")),
    };
    Ok(json!({
        "schema": "handoff/v1", "kind": kind, "id": id, "title": title, "mode": mode,
        "teleprompter": teleprompter, "points": points,
        "out_dir": out_dir.to_string_lossy(), "created": created, "brand": brand.name(),
        "setup": setup,
    }))
}

/// Writes the handoff file the Recorder polls. Shorts use next_take.json, long videos next_recording.json.
pub fn write_handoff(paths: &Paths, handoff: &Value) -> Result<PathBuf, String> {
    let file = if handoff["kind"] == "long" { "next_recording.json" } else { "next_take.json" };
    let p = paths.handoff_dir().join(file);
    atomic_write(&p, &format!("{}\n", to_pretty(handoff, 2)))?;
    Ok(p)
}

/// `Record`: write the handoff and open the Recorder. Opening is best effort; the file is the contract.
pub fn record(paths: &Paths, brand: &Brand, kind: &str, id: &str, week: Option<i64>) -> Result<Value, String> {
    let handoff = build_handoff(paths, brand, kind, id, week, &crate::dates::today_local(), &iso_now())?;
    let file = write_handoff(paths, &handoff)?;
    let opened = open_recorder(paths);
    let message = match &opened {
        Ok(()) => "Sent to the Recorder.".to_string(),
        Err(e) => format!("The take is ready. {e}"),
    };
    Ok(json!({"handoff": file.to_string_lossy(), "out_dir": handoff["out_dir"], "opened": opened.is_ok(), "message": message}))
}

#[cfg(target_os = "macos")]
fn find_app(dir: &std::path::Path, depth: u32) -> Option<PathBuf> {
    for e in std::fs::read_dir(dir).ok()?.flatten() {
        let p = e.path();
        if p.extension().is_some_and(|x| x == "app") {
            return Some(p);
        }
        if depth > 0 && p.is_dir() {
            if let Some(f) = find_app(&p, depth - 1) {
                return Some(f);
            }
        }
    }
    None
}

#[cfg(target_os = "macos")]
fn open_recorder(paths: &Paths) -> Result<(), String> {
    use std::process::Command;
    let by_id = Command::new("open").args(["-b", RECORDER_BUNDLE_ID]).status().map(|s| s.success()).unwrap_or(false);
    if by_id {
        return Ok(());
    }
    let hint = "Open the Recorder app yourself, it will pick the take up.";
    let built = find_app(&paths.repo.join("apps/recorder/build"), 3).ok_or(hint)?;
    match Command::new("open").arg(&built).status() {
        Ok(s) if s.success() => Ok(()),
        _ => Err(hint.to_string()),
    }
}

#[cfg(not(target_os = "macos"))]
fn open_recorder(_paths: &Paths) -> Result<(), String> {
    Err("The Recorder app runs on macOS. The handoff file is written.".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brand::sample;
    use crate::cards::tests::good_card;
    use crate::jsonfile::read_json;
    use crate::store::{append_cards, create_video, test_paths, update_video};
    use serde_json::Map;

    #[test]
    fn short_handoff_follows_the_contract() {
        let p = test_paths("handoff");
        append_cards(&p, 42, vec![good_card()]).unwrap();
        let h = build_handoff(&p, &sample(), "short", "w42-01", Some(42), "2026-10-19", "2026-10-19T09:00:00Z").unwrap();
        for k in ["schema", "kind", "id", "title", "mode", "teleprompter", "points", "out_dir", "created", "brand"] {
            assert!(h.get(k).is_some(), "missing {k}");
        }
        assert_eq!(h["schema"], "handoff/v1");
        assert_eq!(h["mode"], "cards");
        assert_eq!(h["brand"], "Northwind");
        assert!(h["out_dir"].as_str().unwrap().ends_with("takes/shorts/2026-10-19-w42-01-take-1"));
        let file = write_handoff(&p, &h).unwrap();
        assert!(file.ends_with("handoff/next_take.json"));
        assert_eq!(read_json(&file).unwrap()["id"], "w42-01");

        // a take folder that already exists moves the number up
        std::fs::create_dir_all(p.ws("takes/shorts/2026-10-19-w42-01-take-1")).unwrap();
        let h2 = build_handoff(&p, &sample(), "short", "w42-01", Some(42), "2026-10-19", "x").unwrap();
        assert!(h2["out_dir"].as_str().unwrap().ends_with("-take-2"));
    }

    #[test]
    fn long_handoff_goes_to_next_recording() {
        let p = test_paths("handoff-long");
        create_video(&p, None, Some("Plan a week"), "explainer").unwrap();
        let mut f = Map::new();
        f.insert("map".into(), json!([{"title": "Start", "detail": "why"}, "Plain string point"]));
        update_video(&p, "plan-a-week", &f).unwrap();
        let h = build_handoff(&p, &sample(), "long", "plan-a-week", None, "2026-10-19", "t").unwrap();
        assert_eq!(h["kind"], "long");
        assert_eq!(h["points"], json!(["Start", "Plain string point"]));
        assert!(h["out_dir"].as_str().unwrap().ends_with("takes/long/plan-a-week/take-1"));
        assert!(write_handoff(&p, &h).unwrap().ends_with("handoff/next_recording.json"));
        assert!(build_handoff(&p, &sample(), "short", "x", None, "d", "t").is_err());
    }

    #[test]
    fn film_day_groups_by_setup() {
        let p = test_paths("filmday");
        let mk = |n: usize, urls: Vec<&str>| {
            let mut c = good_card();
            c["id"] = json!(store::card_id(42, n));
            c["setup"] = json!({"urls": urls, "apps": []});
            c
        };
        let mut done = mk(4, vec![]);
        done["status"] = json!("filmed");
        append_cards(&p, 42, vec![mk(1, vec!["https://a.example"]), mk(2, vec![]), mk(3, vec!["https://a.example"]), done]).unwrap();
        let day = film_day(&p);
        let ids: Vec<&str> = day["items"].as_array().unwrap().iter().map(|i| i["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["w42-02", "w42-01", "w42-03"], "no-setup first, then the shared setup together");
        assert_eq!(day["setup_changes"], 1);
        assert_eq!(day["items"][1]["setup_change"], true);
        assert_eq!(day["items"][2]["setup_change"], false);
    }
}
