//! Short and long formats live in `formats.json` (not in code). The copy next to the app is
//! built in; a `formats.json` in the workspace replaces it, so users can add their own formats.

use crate::paths::Paths;
use serde_json::Value;

const BUILT_IN: &str = include_str!("../../formats.json");

#[derive(Clone, Debug)]
pub struct Formats {
    pub raw: Value,
}

impl Formats {
    pub fn built_in() -> Formats {
        Formats::parse(BUILT_IN).expect("the built-in formats.json is valid")
    }

    pub fn load(paths: &Paths) -> Result<Formats, String> {
        match std::fs::read_to_string(paths.ws("formats.json")) {
            Ok(text) => Formats::parse(&text).map_err(|e| format!("workspace/formats.json: {e}")),
            Err(_) => Ok(Formats::built_in()),
        }
    }

    pub fn parse(text: &str) -> Result<Formats, String> {
        let raw: Value = serde_json::from_str(text).map_err(|e| format!("not valid JSON ({e})"))?;
        for key in ["shorts", "long"] {
            let list = raw.get(key).and_then(Value::as_array).filter(|a| !a.is_empty()).ok_or_else(|| format!("\"{key}\" must be a non-empty list"))?;
            for f in list {
                for need in ["id", "name", "structure"] {
                    if f.get(need).and_then(Value::as_str).unwrap_or("").is_empty() {
                        return Err(format!("a format in \"{key}\" has no {need}"));
                    }
                }
                let ok = f.get("points").and_then(Value::as_array).is_some_and(|p| p.len() == 2 && p.iter().all(|n| n.is_u64()));
                if !ok {
                    return Err(format!("format {} needs \"points\": [min, max]", f["id"]));
                }
            }
        }
        Ok(Formats { raw })
    }

    fn list(&self, key: &str) -> Vec<Value> {
        self.raw.get(key).and_then(Value::as_array).cloned().unwrap_or_default()
    }
    pub fn shorts(&self) -> Vec<Value> {
        self.list("shorts")
    }
    pub fn long(&self) -> Vec<Value> {
        self.list("long")
    }
    pub fn thumbnail_shapes(&self) -> Vec<Value> {
        self.list("thumbnail_shapes")
    }
    pub fn short(&self, id: &str) -> Option<Value> {
        self.shorts().into_iter().find(|f| f["id"] == id)
    }
    pub fn long_format(&self, id: &str) -> Option<Value> {
        self.long().into_iter().find(|f| f["id"] == id)
    }
    pub fn short_ids(&self) -> Vec<String> {
        self.shorts().iter().filter_map(|f| f["id"].as_str().map(str::to_string)).collect()
    }
    pub fn long_ids(&self) -> Vec<String> {
        self.long().iter().filter_map(|f| f["id"].as_str().map(str::to_string)).collect()
    }
    pub fn thumb_ids(&self) -> Vec<String> {
        self.thumbnail_shapes().iter().filter_map(|f| f["id"].as_str().map(str::to_string)).collect()
    }
}

/// The point range [min, max] of a format.
pub fn points_range(f: &Value) -> (usize, usize) {
    let p = &f["points"];
    (p[0].as_u64().unwrap_or(2) as usize, p[1].as_u64().unwrap_or(3) as usize)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn built_in_formats_are_complete() {
        let f = Formats::built_in();
        assert!(f.short_ids().contains(&"same-idea-3-ways".to_string()));
        assert!(f.short_ids().contains(&"say-this-not-that".to_string()));
        assert!(f.shorts().len() >= 4 && f.long().len() >= 3);
        assert_eq!(f.thumb_ids().len(), 3);
        assert_eq!(points_range(&f.short("same-idea-3-ways").unwrap()), (3, 3));
    }

    #[test]
    fn a_broken_file_is_explained() {
        assert!(Formats::parse("{}").unwrap_err().contains("shorts"));
        assert!(Formats::parse(r#"{"shorts":[{"id":"a","name":"A"}],"long":[]}"#).unwrap_err().contains("structure"));
    }
}
