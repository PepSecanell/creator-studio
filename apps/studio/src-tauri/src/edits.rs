//! Edits (output of the editing agents) and posting kits. Studio only reads these, except for
//! approving an edit and starting the edit pipeline.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::dates::iso_now;
use crate::jsonfile::{merge_write, read_json, s};
use crate::llm::gui_path;
use crate::paths::Paths;

fn file_if_exists(p: PathBuf) -> Value {
    if p.exists() {
        json!(p.to_string_lossy())
    } else {
        Value::Null
    }
}

/// Every edit folder with a status.json, newest first.
pub fn list_edits(paths: &Paths) -> Vec<Value> {
    let mut out = Vec::new();
    for kind in ["short", "long"] {
        let Ok(rd) = std::fs::read_dir(paths.edits_dir(kind)) else { continue };
        for e in rd.flatten() {
            let dir = e.path();
            let Ok(st) = read_json(&dir.join("status.json")) else { continue };
            let cover = if kind == "short" { dir.join("cover.jpg") } else { dir.join("thumbnail.jpg") };
            out.push(json!({
                "kind": kind, "id": e.file_name().to_string_lossy(), "dir": dir.to_string_lossy(),
                "state": s(&st, "state"), "updated": s(&st, "updated"), "notes": s(&st, "notes"),
                "final": file_if_exists(dir.join("final.mp4")), "cover": file_if_exists(cover),
                "posting": file_if_exists(dir.join("POSTING.md")),
            }));
        }
    }
    out.sort_by(|a, b| s(b, "updated").cmp(&s(a, "updated")));
    out
}

fn safe_id(id: &str) -> Result<(), String> {
    if id.is_empty() || id.contains('/') || id.contains("..") || id.contains('\\') {
        return Err(format!("\"{id}\" is not a valid id."));
    }
    Ok(())
}

pub fn approve_edit(paths: &Paths, kind: &str, id: &str) -> Result<Value, String> {
    safe_id(id)?;
    let p = paths.edits_dir(kind).join(id).join("status.json");
    merge_write(&p, None, |st| {
        let state = s(st, "state");
        if state != "ready_for_review" && state != "needs_you" {
            return Err(format!("This edit is \"{state}\", so there is nothing to approve yet."));
        }
        st["state"] = json!("approved");
        st["updated"] = json!(iso_now());
        Ok(st.clone())
    })
}

/// `<repo>/studio edit short <id>` or `edit long <slug>`.
pub fn edit_command(paths: &Paths, kind: &str, id: &str) -> Result<Command, String> {
    safe_id(id)?;
    if kind != "short" && kind != "long" {
        return Err(format!("Unknown kind \"{kind}\"."));
    }
    studio_command(paths, &["edit", kind, id])
}

pub fn studio_command(paths: &Paths, args: &[&str]) -> Result<Command, String> {
    let bin = paths.studio_bin();
    if !bin.exists() {
        return Err(format!("Can't find {}. Run ./studio setup first.", bin.display()));
    }
    let mut cmd = Command::new(bin);
    cmd.args(args).current_dir(&paths.repo).env("PATH", gui_path());
    Ok(cmd)
}

// ── Kit ──────────────────────────────────────────────────────────────────────────────────────

pub fn list_kits(paths: &Paths) -> Vec<String> {
    let mut dates: Vec<String> = std::fs::read_dir(paths.kits_dir())
        .map(|rd| rd.flatten().filter(|e| e.path().join("kit.json").exists()).map(|e| e.file_name().to_string_lossy().to_string()).collect())
        .unwrap_or_default();
    dates.sort_by(|a, b| b.cmp(a));
    dates
}

fn abs_if_exists(base: &Path, name: &str) -> Value {
    if name.is_empty() {
        return Value::Null;
    }
    file_if_exists(base.join(name))
}

/// A kit with every file resolved to an absolute path (null when the file is missing).
pub fn load_kit(paths: &Paths, date: &str) -> Result<Value, String> {
    safe_id(date)?;
    let dir = paths.kits_dir().join(date);
    let mut kit = read_json(&dir.join("kit.json")).map_err(|_| format!("No kit for {date}."))?;
    if let Some(items) = kit["items"].as_array_mut() {
        for it in items.iter_mut() {
            it["file_abs"] = abs_if_exists(&dir, &s(it, "file"));
            it["cover_abs"] = abs_if_exists(&dir, &s(it, "cover"));
        }
    }
    kit["dir"] = json!(dir.to_string_lossy());
    Ok(kit)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::test_paths;

    fn write_status(p: &Paths, kind: &str, id: &str, state: &str, updated: &str) {
        let dir = p.edits_dir(kind).join(id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("status.json"), format!("{{\"schema\":\"edit-status/v1\",\"state\":\"{state}\",\"updated\":\"{updated}\",\"notes\":\"n\",\"checks\":{{}}}}")).unwrap();
    }

    #[test]
    fn edits_are_listed_and_approved() {
        let p = test_paths("edits");
        write_status(&p, "short", "w42-01", "ready_for_review", "2026-10-19T10:00:00Z");
        write_status(&p, "long", "plan-a-week", "editing", "2026-10-19T11:00:00Z");
        std::fs::write(p.edits_dir("short").join("w42-01/final.mp4"), b"x").unwrap();
        let list = list_edits(&p);
        assert_eq!(list.len(), 2);
        assert_eq!(list[0]["id"], "plan-a-week", "newest first");
        assert!(list[1]["final"].is_string() && list[1]["cover"].is_null());

        assert!(approve_edit(&p, "long", "plan-a-week").is_err(), "still editing");
        let st = approve_edit(&p, "short", "w42-01").unwrap();
        assert_eq!(st["state"], "approved");
        assert!(approve_edit(&p, "short", "../x").is_err());
    }

    #[test]
    fn kits_resolve_their_files() {
        let p = test_paths("kit");
        let dir = p.kits_dir().join("2026-10-19");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("a.mp4"), b"x").unwrap();
        std::fs::write(dir.join("kit.json"), r#"{"schema":"kit/v1","date":"2026-10-19","brand":"Northwind","items":[{"id":"a","platform":"tiktok","file":"a.mp4","cover":"missing.jpg","caption":"hi"}]}"#).unwrap();
        assert_eq!(list_kits(&p), vec!["2026-10-19"]);
        let kit = load_kit(&p, "2026-10-19").unwrap();
        assert!(kit["items"][0]["file_abs"].is_string());
        assert!(kit["items"][0]["cover_abs"].is_null());
        assert!(load_kit(&p, "1999-01-01").is_err());
    }

    #[test]
    fn edit_command_needs_the_launcher() {
        let p = test_paths("editcmd");
        assert!(edit_command(&p, "short", "w42-01").unwrap_err().contains("./studio setup"));
        std::fs::write(p.repo.join("studio"), "#!/bin/sh\n").unwrap();
        let cmd = edit_command(&p, "long", "slug").unwrap();
        assert_eq!(cmd.get_args().map(|a| a.to_string_lossy().to_string()).collect::<Vec<_>>(), vec!["edit", "long", "slug"]);
        assert!(edit_command(&p, "short", "../etc").is_err());
    }
}
