//! Studio: plan, write and film short and long videos for a brand.
//!
//! Everything is read from and written to the workspace described in docs/CONTRACTS.md.
//! Commands are `async` on purpose: Tauri runs plain `fn` commands on the main thread, and a slow
//! disk read would freeze the window.

pub mod brand;
pub mod cards;
pub mod dates;
pub mod edits;
pub mod formats;
pub mod gates;
pub mod gen;
pub mod jobs;
pub mod jsonfile;
pub mod llm;
pub mod paths;
pub mod plan;
pub mod prompts;
pub mod store;
pub mod theme;

use serde_json::{json, Map, Value};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use tauri::Manager;

use brand::Brand;
use formats::Formats;
use gen::Ctx;
use jobs::{job_json, run_logged, start_job};
use paths::Paths;

type Loaded = (Paths, Brand, Formats);

fn loaded() -> Result<Loaded, String> {
    let paths = Paths::load()?;
    let brand = Brand::load(&paths)?;
    let formats = Formats::load(&paths)?;
    Ok((paths, brand, formats))
}

fn window_title(brand: &Brand) -> String {
    format!("{} Studio", brand.name())
}

/// Starts a Claude job on a background thread with its own copy of the data.
fn claude_job<F>(kind: &str, label: &str, f: F) -> Result<String, String>
where
    F: FnOnce(&Ctx) -> Result<Value, String> + Send + 'static,
{
    let (paths, brand, formats) = loaded()?;
    Ok(start_job(kind, label, move |job| f(&Ctx { paths: &paths, brand: &brand, formats: &formats, job })))
}

fn inside(paths: &Paths, target: &str) -> Result<PathBuf, String> {
    let p = PathBuf::from(target);
    if p.components().any(|c| c.as_os_str() == "..") {
        return Err("That path is not allowed.".to_string());
    }
    if p.starts_with(&paths.workspace) || p.starts_with(&paths.repo) {
        Ok(p)
    } else {
        Err("Studio only opens files from your workspace.".to_string())
    }
}

fn to_map(v: Value) -> Result<Map<String, Value>, String> {
    match v {
        Value::Object(m) => Ok(m),
        _ => Err("Expected an object of fields.".to_string()),
    }
}

// ── Boot, jobs ───────────────────────────────────────────────────────────────────────────────

#[tauri::command]
async fn boot(window: tauri::WebviewWindow) -> Value {
    match loaded() {
        Err(message) => json!({"ok": false, "message": message}),
        Ok((paths, brand, formats)) => {
            let _ = window.set_title(&window_title(&brand));
            let (year, week) = store::current_week();
            json!({
                "ok": true, "brand_name": brand.name(), "title": window_title(&brand),
                "theme": theme::theme(&paths, &brand),
                "formats": {"shorts": formats.shorts(), "long": formats.long(), "thumbnail_shapes": formats.thumbnail_shapes()},
                "per_day": brand.shorts_per_day(), "week": week, "year": year,
                "workspace": paths.workspace.to_string_lossy(),
                "has_studio_cli": paths.studio_bin().exists(),
            })
        }
    }
}

#[tauri::command]
async fn job_status(id: String) -> Result<Value, String> {
    job_json(&id)
}

#[tauri::command]
async fn stop_job(id: String) -> Result<(), String> {
    jobs::stop_job(&id)
}

// ── Ideas ────────────────────────────────────────────────────────────────────────────────────

#[tauri::command]
async fn list_ideas(kind: String) -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    store::load_ideas(&paths, &kind)
}

#[tauri::command]
async fn add_idea(kind: String, title: String, angle: String, format: String) -> Result<Vec<Value>, String> {
    let (paths, ..) = loaded()?;
    store::add_ideas(&paths, &kind, vec![json!({"title": title, "angle": angle, "format": format})])
}

#[tauri::command]
async fn set_idea_status(kind: String, id: String, status: String) -> Result<(), String> {
    let (paths, ..) = loaded()?;
    store::set_idea_status(&paths, &kind, &id, &status)
}

#[tauri::command]
async fn delete_idea(kind: String, id: String) -> Result<(), String> {
    let (paths, ..) = loaded()?;
    store::delete_idea(&paths, &kind, &id)
}

#[tauri::command]
async fn start_generate_ideas(kind: String, count: usize, format: Option<String>) -> Result<String, String> {
    claude_job("ideas", "New ideas", move |ctx| gen::generate_ideas(ctx, &kind, count.clamp(1, 20), format.as_deref()))
}

// ── Shorts ───────────────────────────────────────────────────────────────────────────────────

#[tauri::command]
async fn list_weeks() -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    Ok(json!(store::list_weeks(&paths)))
}

#[tauri::command]
async fn load_week(week: i64) -> Result<Value, String> {
    let (paths, brand, formats) = loaded()?;
    let mut view = store::week_view(&paths, &brand, week)?;
    gen::annotate_problems(&mut view, &brand, &formats);
    Ok(view)
}

#[tauri::command]
async fn add_card(week: i64, title: String, format: String) -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    if title.trim().is_empty() {
        return Err("Give the card a title.".to_string());
    }
    let n = store::next_card_number(&store::load_week(&paths, week)?, week);
    let card = cards::blank_card(&store::card_id(week, n), title.trim(), &format);
    store::append_cards(&paths, week, vec![card.clone()])?;
    Ok(card)
}

#[tauri::command]
async fn save_card(week: i64, id: String, fields: Value) -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    store::save_card(&paths, week, &id, &to_map(fields)?)
}

#[tauri::command]
async fn delete_card(week: i64, id: String) -> Result<(), String> {
    let (paths, ..) = loaded()?;
    store::delete_card(&paths, week, &id)
}

#[tauri::command]
async fn start_write_week(week: i64) -> Result<String, String> {
    claude_job("week", &format!("Week {week} cards"), move |ctx| gen::write_week(ctx, week))
}

#[tauri::command]
async fn start_rewrite_card(week: i64, id: String, part: String, note: String) -> Result<String, String> {
    claude_job("rewrite", &format!("Rewrite {id}"), move |ctx| gen::rewrite_card(ctx, week, &id, &part, &note))
}

#[tauri::command]
async fn start_make_script(week: i64, id: String) -> Result<String, String> {
    claude_job("script", &format!("Script for {id}"), move |ctx| gen::make_script(ctx, week, &id))
}

#[tauri::command]
async fn fix_text(text: String) -> Result<String, String> {
    let (_, brand, _) = loaded()?;
    gen::fix_text(&brand, &text)
}

// ── Long videos ──────────────────────────────────────────────────────────────────────────────

#[tauri::command]
async fn list_videos() -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    Ok(json!(store::list_videos(&paths)))
}

#[tauri::command]
async fn create_video(idea_id: Option<String>, title: Option<String>, format: String) -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    store::create_video(&paths, idea_id.as_deref(), title.as_deref(), &format)
}

#[tauri::command]
async fn load_video(slug: String) -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    store::load_video(&paths, &slug)
}

#[tauri::command]
async fn update_video(slug: String, fields: Value) -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    store::update_video(&paths, &slug, &to_map(fields)?)
}

#[tauri::command]
async fn delete_video(slug: String) -> Result<(), String> {
    let (paths, ..) = loaded()?;
    store::delete_video(&paths, &slug)
}

/// One step of the long-video chain: titles, map, script, thumbnails, description.
#[tauri::command]
async fn start_long_step(slug: String, step: String, minutes: Option<i64>) -> Result<String, String> {
    let label = format!("{step} for {slug}");
    claude_job("long", &label, move |ctx| match step.as_str() {
        "titles" => gen::long_titles(ctx, &slug),
        "map" => gen::long_map(ctx, &slug),
        "script" => gen::long_script(ctx, &slug, minutes.unwrap_or(6)),
        "thumbnails" => gen::long_thumbs(ctx, &slug),
        "description" => gen::long_description(ctx, &slug),
        other => Err(format!("Unknown step {other}.")),
    })
}

// ── Film day, edits, kit, brand ──────────────────────────────────────────────────────────────

#[tauri::command]
async fn film_day() -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    Ok(plan::film_day(&paths))
}

#[tauri::command]
async fn record(kind: String, id: String, week: Option<i64>) -> Result<Value, String> {
    let (paths, brand, _) = loaded()?;
    plan::record(&paths, &brand, &kind, &id, week)
}

#[tauri::command]
async fn list_edits() -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    Ok(json!(edits::list_edits(&paths)))
}

#[tauri::command]
async fn approve_edit(kind: String, id: String) -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    let status = edits::approve_edit(&paths, &kind, &id)?;
    if kind == "short" {
        mark_card_ready(&paths, &id);
    }
    Ok(status)
}

/// An approved Short is ready to post: reflect it on its card (best effort).
fn mark_card_ready(paths: &Paths, id: &str) {
    for w in store::list_weeks(paths) {
        let week = w["week"].as_i64().unwrap_or(0);
        if store::find_card(paths, week, id).is_ok() {
            let mut f = Map::new();
            f.insert("status".into(), json!("ready"));
            let _ = store::save_card(paths, week, id, &f);
        }
    }
}

#[tauri::command]
async fn start_edit(kind: String, id: String) -> Result<String, String> {
    let (paths, ..) = loaded()?;
    let cmd = edits::edit_command(&paths, &kind, &id)?;
    Ok(start_job("edit", &format!("Edit {id}"), move |job| {
        job.step("Editing");
        match run_logged(job, cmd)? {
            0 => Ok(json!({"exit": 0})),
            n => Err(format!("The edit stopped with exit code {n}. The log above shows why.")),
        }
    }))
}

#[tauri::command]
async fn list_kits() -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    Ok(json!(edits::list_kits(&paths)))
}

#[tauri::command]
async fn load_kit(date: String) -> Result<Value, String> {
    let (paths, ..) = loaded()?;
    edits::load_kit(&paths, &date)
}

#[tauri::command]
async fn brand_summary() -> Result<Value, String> {
    let (paths, brand, _) = loaded()?;
    Ok(brand.summary(&paths))
}

/// Newest preview sheet that `./studio brand preview` left behind.
fn newest_preview(paths: &Paths) -> Option<PathBuf> {
    let mut best: Option<(std::time::SystemTime, PathBuf)> = None;
    for dir in [paths.brand_dir(), paths.ws("previews"), paths.ws("brand-preview")] {
        let Ok(rd) = std::fs::read_dir(dir) else { continue };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().to_lowercase();
            let ok_ext = ["png", "jpg", "html", "mp4"].iter().any(|x| name.ends_with(x));
            if !(ok_ext && name.contains("preview")) {
                continue;
            }
            if let Some(t) = e.metadata().ok().and_then(|m| m.modified().ok()) {
                if best.as_ref().is_none_or(|(bt, _)| t > *bt) {
                    best = Some((t, e.path()));
                }
            }
        }
    }
    best.map(|(_, p)| p)
}

#[tauri::command]
async fn start_brand_preview() -> Result<String, String> {
    let (paths, ..) = loaded()?;
    let cmd = edits::studio_command(&paths, &["brand", "preview"])?;
    Ok(start_job("preview", "Brand preview", move |job| {
        job.step("Rendering the preview sheet");
        match run_logged(job, cmd)? {
            0 => Ok(json!({"exit": 0, "preview": newest_preview(&paths).map(|p| p.to_string_lossy().to_string())})),
            n => Err(format!("The preview stopped with exit code {n}. The log above shows why.")),
        }
    }))
}

// ── Opening and copying ──────────────────────────────────────────────────────────────────────

#[tauri::command]
async fn open_path(path: String) -> Result<(), String> {
    let (paths, ..) = loaded()?;
    let p = inside(&paths, &path)?;
    let opener = if cfg!(target_os = "macos") { "open" } else { "xdg-open" };
    Command::new(opener).arg(&p).spawn().map(|_| ()).map_err(|e| format!("Can't open {}: {e}", p.display()))
}

#[tauri::command]
async fn reveal_path(path: String) -> Result<(), String> {
    let (paths, ..) = loaded()?;
    let p = inside(&paths, &path)?;
    let result = if cfg!(target_os = "macos") {
        Command::new("open").arg("-R").arg(&p).spawn()
    } else {
        Command::new("xdg-open").arg(p.parent().unwrap_or(Path::new("/"))).spawn()
    };
    result.map(|_| ()).map_err(|e| format!("Can't show {}: {e}", p.display()))
}

#[tauri::command]
async fn copy_text(text: String) -> Result<(), String> {
    let tools: &[(&str, &[&str])] = if cfg!(target_os = "macos") {
        &[("pbcopy", &[])]
    } else {
        &[("wl-copy", &[]), ("xclip", &["-selection", "clipboard"]), ("xsel", &["--clipboard", "--input"])]
    };
    for (tool, args) in tools {
        if let Ok(mut child) = Command::new(tool).args(*args).stdin(Stdio::piped()).stdout(Stdio::null()).stderr(Stdio::null()).spawn() {
            if let Some(mut stdin) = child.stdin.take() {
                let _ = stdin.write_all(text.as_bytes());
            }
            let _ = child.wait();
            return Ok(());
        }
    }
    Err("No clipboard tool found (install wl-clipboard or xclip).".to_string())
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .setup(|app| {
            if let Ok((_, brand, _)) = loaded() {
                if let Some(w) = app.get_webview_window("main") {
                    let _ = w.set_title(&window_title(&brand));
                }
            }
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            boot, job_status, stop_job,
            list_ideas, add_idea, set_idea_status, delete_idea, start_generate_ideas,
            list_weeks, load_week, add_card, save_card, delete_card, start_write_week, start_rewrite_card, start_make_script, fix_text,
            list_videos, create_video, load_video, update_video, delete_video, start_long_step,
            film_day, record, list_edits, approve_edit, start_edit, list_kits, load_kit,
            brand_summary, start_brand_preview, open_path, reveal_path, copy_text,
        ])
        .run(tauri::generate_context!())
        .expect("error while running the Studio app");
}
