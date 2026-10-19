//! Runtime theming: the brand palette and fonts from `workspace/.brand/`.

use serde_json::{json, Value};
use std::path::{Path, PathBuf};

use crate::brand::Brand;
use crate::paths::Paths;

fn font_path_of(entry: &Value) -> Option<String> {
    match entry {
        Value::String(p) if !p.is_empty() => Some(p.clone()),
        Value::Object(o) => ["path", "file", "src"].iter().find_map(|k| o.get(*k).and_then(Value::as_str)).map(str::to_string),
        _ => None,
    }
}

fn find_font(paths: &Paths, brand: &Brand, rel: &str) -> Option<PathBuf> {
    let p = Path::new(rel);
    if p.is_absolute() {
        return p.exists().then(|| p.to_path_buf());
    }
    let style = crate::jsonfile::s(&brand.raw, "style");
    let bases = [paths.brand_dir(), paths.repo.join("brand"), paths.repo.join("looks").join(&style)];
    bases.iter().map(|r| r.join(rel)).find(|c| c.exists())
}

/// The fonts that really exist on disk: [{role, family, path}]. The page registers them.
pub fn fonts(paths: &Paths, brand: &Brand) -> Vec<Value> {
    let Some(map) = brand.raw.get("fonts").and_then(Value::as_object) else { return vec![] };
    map.iter()
        .filter_map(|(role, entry)| {
            let found = find_font(paths, brand, &font_path_of(entry)?)?;
            Some(json!({"role": role, "family": format!("Studio {role}"), "path": found.to_string_lossy()}))
        })
        .collect()
}

pub fn theme(paths: &Paths, brand: &Brand) -> Value {
    let tokens = std::fs::read_to_string(paths.brand_dir().join("tokens.css")).unwrap_or_default();
    let logo = ["logo.png", "logo.svg"].iter().map(|n| paths.brand_dir().join(n)).chain([paths.repo.join("brand/logo.png")]).find(|p| p.exists());
    json!({
        "tokens_css": tokens,
        "palette": brand.raw.get("palette").cloned().unwrap_or(json!({})),
        "fonts": fonts(paths, brand),
        "logo": logo.map(|l| l.to_string_lossy().to_string()),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::store::test_paths;

    #[test]
    fn only_existing_fonts_are_listed_and_tokens_are_read() {
        let p = test_paths("theme");
        std::fs::create_dir_all(p.brand_dir()).unwrap();
        std::fs::write(p.brand_dir().join("tokens.css"), ":root{--cs-ink:#111}").unwrap();
        std::fs::write(p.brand_dir().join("T.ttf"), b"x").unwrap();
        let brand = Brand::from_value(json!({"name": "N", "fonts": {"title": "T.ttf", "body": "missing.ttf", "caption": null}}));
        let t = theme(&p, &brand);
        assert!(t["tokens_css"].as_str().unwrap().contains("--cs-ink"));
        assert_eq!(t["fonts"].as_array().unwrap().len(), 1);
        assert_eq!(t["fonts"][0]["role"], "title");
    }
}
