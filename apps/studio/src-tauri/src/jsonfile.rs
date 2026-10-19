//! Reading and writing the shared JSON files without disturbing other tools: keys keep their
//! order, writes are atomic, and a save that races with another writer is retried.

use serde_json::Value;
use std::path::Path;
use std::time::SystemTime;

pub fn s(v: &Value, k: &str) -> String {
    match v.get(k) {
        Some(Value::String(x)) => x.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

pub fn str_list(v: &Value, k: &str) -> Vec<String> {
    match v.get(k) {
        Some(Value::Array(a)) => a.iter().filter_map(|x| x.as_str().map(str::to_string)).collect(),
        Some(Value::String(x)) if !x.is_empty() => vec![x.clone()],
        _ => vec![],
    }
}

/// Lowercase, letters and digits only, single spaces.
pub fn norm(t: &str) -> String {
    t.to_lowercase().chars().filter(|c| c.is_alphanumeric() || *c == ' ').collect::<String>().split_whitespace().collect::<Vec<_>>().join(" ")
}

pub fn slugify(t: &str) -> String {
    let mut out = String::new();
    for w in norm(t).split_whitespace().take(7) {
        if !out.is_empty() {
            out.push('-');
        }
        out.push_str(w);
        if out.len() > 48 {
            break;
        }
    }
    if out.is_empty() {
        "untitled".into()
    } else {
        out
    }
}

pub fn read_json(p: &Path) -> Result<Value, String> {
    let raw = std::fs::read_to_string(p).map_err(|e| format!("Can't read {}: {e}", p.display()))?;
    serde_json::from_str(&raw).map_err(|e| format!("{} isn't valid JSON right now ({e}). Someone may be writing it; try again in a moment.", p.display()))
}

fn detect_indent(raw: &str) -> usize {
    raw.lines().nth(1).map(|l| l.len() - l.trim_start_matches(' ').len()).filter(|n| *n > 0 && *n <= 8).unwrap_or(2)
}

/// Pretty JSON with the given indent and non-ASCII text left as is (like Python's `ensure_ascii=False`).
pub fn to_pretty(v: &Value, indent: usize) -> String {
    use serde::Serialize;
    let ind = " ".repeat(indent);
    let mut buf = Vec::new();
    let fmt = serde_json::ser::PrettyFormatter::with_indent(ind.as_bytes());
    let mut ser = serde_json::Serializer::with_formatter(&mut buf, fmt);
    v.serialize(&mut ser).expect("a JSON value always serializes");
    String::from_utf8(buf).expect("serde_json writes UTF-8")
}

pub fn atomic_write(p: &Path, text: &str) -> Result<(), String> {
    if let Some(dir) = p.parent() {
        std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    }
    let tmp = p.with_extension(format!("tmp-studio-{}", std::process::id()));
    std::fs::write(&tmp, text).map_err(|e| format!("Can't write {}: {e}", p.display()))?;
    std::fs::rename(&tmp, p).map_err(|e| format!("Can't save {}: {e}", p.display()))
}

/// What identifies "the file as I read it": modified time plus size.
fn stamp(p: &Path) -> Option<(SystemTime, u64)> {
    std::fs::metadata(p).ok().and_then(|m| m.modified().ok().map(|t| (t, m.len())))
}

/// Read fresh, let `f` change the parsed value, and write back only if nobody else changed the
/// file in between (retries up to 5 times). `default` creates the file when it is missing.
pub fn merge_write<R, F>(p: &Path, default: Option<Value>, mut f: F) -> Result<R, String>
where
    F: FnMut(&mut Value) -> Result<R, String>,
{
    for _ in 0..5 {
        let before = stamp(p);
        let (mut v, raw) = match std::fs::read_to_string(p) {
            Ok(raw) => (
                serde_json::from_str::<Value>(&raw).map_err(|e| format!("{} isn't valid JSON ({e}). Not touching it.", p.display()))?,
                raw,
            ),
            Err(_) => match &default {
                Some(d) => (d.clone(), String::new()),
                None => return Err(format!("{} doesn't exist.", p.display())),
            },
        };
        let r = f(&mut v)?;
        if stamp(p) != before {
            std::thread::sleep(std::time::Duration::from_millis(150));
            continue;
        }
        let indent = if raw.is_empty() { 2 } else { detect_indent(&raw) };
        let mut text = to_pretty(&v, indent);
        if raw.is_empty() || raw.ends_with('\n') {
            text.push('\n');
        }
        atomic_write(p, &text)?;
        return Ok(r);
    }
    Err(format!("{} keeps changing (another tool is writing it). Try again in a minute.", p.display()))
}

#[cfg(test)]
pub mod testutil {
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    /// A fresh empty folder under the system temp dir.
    pub fn temp_dir(tag: &str) -> PathBuf {
        static N: AtomicU64 = AtomicU64::new(0);
        let d = std::env::temp_dir().join(format!("studio-test-{}-{}-{}", tag, std::process::id(), N.fetch_add(1, Ordering::SeqCst)));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }
}

#[cfg(test)]
mod tests {
    use super::testutil::temp_dir;
    use super::*;
    use serde_json::json;

    #[test]
    fn write_keeps_key_order_and_indent() {
        let d = temp_dir("order");
        let p = d.join("a.json");
        std::fs::write(&p, "{\n    \"zeta\": 1,\n    \"alpha\": 2\n}\n").unwrap();
        merge_write(&p, None, |v| {
            v["mid"] = json!("é");
            Ok(())
        })
        .unwrap();
        let text = std::fs::read_to_string(&p).unwrap();
        assert!(text.find("zeta").unwrap() < text.find("alpha").unwrap());
        assert!(text.find("alpha").unwrap() < text.find("mid").unwrap());
        assert!(text.contains("    \"zeta\""), "indent of 4 is kept");
        assert!(text.contains("é") && text.ends_with("}\n"));
    }

    #[test]
    fn default_creates_the_file() {
        let d = temp_dir("default");
        let p = d.join("sub/new.json");
        merge_write(&p, Some(json!({"items": []})), |v| {
            v["items"].as_array_mut().unwrap().push(json!(1));
            Ok(())
        })
        .unwrap();
        assert_eq!(read_json(&p).unwrap()["items"][0], 1);
        assert!(merge_write(&d.join("none.json"), None, |_| Ok(())).is_err());
    }

    #[test]
    fn a_concurrent_change_is_retried_then_reported() {
        let d = temp_dir("conflict");
        let p = d.join("c.json");
        std::fs::write(&p, "{\"n\": 0}\n").unwrap();

        // Someone else writes once while we are in the middle: we retry and see their change.
        let mut calls = 0;
        merge_write(&p, None, |v| {
            calls += 1;
            if calls == 1 {
                std::fs::write(&p, "{\"n\": 5, \"other\": true}\n").unwrap();
            }
            v["mine"] = json!(true);
            Ok(())
        })
        .unwrap();
        let now = read_json(&p).unwrap();
        assert_eq!(calls, 2);
        assert_eq!(now["n"], 5);
        assert_eq!(now["mine"], true);

        // Someone who never stops writing: we give up with a plain sentence and change nothing.
        let mut n = 0;
        let err = merge_write(&p, None, |v| {
            n += 1;
            std::fs::write(&p, format!("{{\"n\": {}, \"pad\": \"{}\"}}\n", 100 + n, "x".repeat(n))).unwrap();
            v["mine"] = json!(false);
            Ok(())
        })
        .unwrap_err();
        assert!(err.contains("keeps changing"));
        assert!(read_json(&p).unwrap().get("mine").is_none());
    }

    #[test]
    fn slugs_are_short_and_plain() {
        assert_eq!(slugify("Ship it ugly, then fix it!"), "ship-it-ugly-then-fix-it");
        assert_eq!(slugify("???"), "untitled");
    }
}
