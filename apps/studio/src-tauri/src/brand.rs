//! The resolved brand (`workspace/.brand/brand.resolved.json`, written by `./studio brand build`).
//! Falls back to `brand/brand.json` in the repo. Every prompt takes its voice from here.

use crate::jsonfile::{read_json, s, str_list};
use crate::paths::Paths;
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub struct Brand {
    pub raw: Value,
}

impl Brand {
    pub fn load(paths: &Paths) -> Result<Brand, String> {
        let resolved = paths.brand_dir().join("brand.resolved.json");
        let source = paths.repo.join("brand/brand.json");
        let raw = if resolved.exists() {
            read_json(&resolved)?
        } else if source.exists() {
            read_json(&source)?
        } else {
            return Err("No brand found. Edit brand/brand.json, then run ./studio brand build.".to_string());
        };
        Ok(Brand::from_value(raw))
    }

    pub fn from_value(raw: Value) -> Brand {
        Brand { raw }
    }

    pub fn name(&self) -> String {
        let n = s(&self.raw, "name");
        if n.is_empty() {
            "Your brand".to_string()
        } else {
            n
        }
    }

    pub fn language(&self) -> String {
        let l = s(&self.raw, "language");
        if l.is_empty() {
            "en".to_string()
        } else {
            l
        }
    }

    fn voice(&self) -> Value {
        self.raw.get("voice").cloned().unwrap_or(Value::Null)
    }

    pub fn topics(&self) -> Vec<String> {
        str_list(&self.voice(), "topics")
    }

    pub fn banned(&self) -> Vec<String> {
        str_list(&self.voice(), "banned")
    }

    pub fn cta(&self) -> String {
        s(&self.voice(), "cta")
    }

    fn schedule_number(&self, key: &str, default: i64) -> i64 {
        self.raw.pointer(&format!("/schedule/{key}")).and_then(Value::as_i64).filter(|n| *n > 0).unwrap_or(default)
    }

    pub fn shorts_per_day(&self) -> i64 {
        self.schedule_number("shorts_per_day", 2).min(12)
    }

    pub fn long_per_week(&self) -> i64 {
        self.schedule_number("long_per_week", 1)
    }

    pub fn max_short_seconds(&self) -> i64 {
        self.raw.pointer("/editing/max_short_seconds").and_then(Value::as_i64).filter(|n| *n > 0).unwrap_or(45)
    }

    /// "creative" or "mechanical" model alias for `claude --model`.
    pub fn model(&self, role: &str) -> String {
        let fallback = if role == "creative" { "opus" } else { "sonnet" };
        self.raw.pointer(&format!("/models/{role}")).and_then(Value::as_str).filter(|m| !m.is_empty()).unwrap_or(fallback).to_string()
    }

    /// The voice, as the block every prompt starts with.
    pub fn voice_block(&self) -> String {
        let v = self.voice();
        let list = |k: &str| {
            let items = str_list(&v, k);
            if items.is_empty() { "(not set)".to_string() } else { items.join(", ") }
        };
        let one = |k: &str| {
            let t = s(&v, k);
            if t.is_empty() { "(not set)".to_string() } else { t }
        };
        format!(
            "=== THE BRAND: {name} ===\n\
Who is talking: {who}\n\
Who it is for: {audience}\n\
Topics: {topics}\n\
Tone: {tone}\n\
Never use these words or phrases: {banned}\n\
Call to action (use at most once, never forced): {cta}\n\
Link people can visit: {link}\n\
Language to write in: {lang} (every sentence the viewer hears or reads is in this language)\n\
Write like a real person talking: short plain sentences, no hype, no dashes of any kind.\n",
            name = self.name(),
            who = one("who"),
            audience = one("audience"),
            topics = list("topics"),
            tone = list("tone"),
            banned = list("banned"),
            cta = one("cta"),
            link = one("link"),
            lang = self.language(),
        )
    }

    /// Everything the Brand screen shows, in one plain object.
    pub fn summary(&self, paths: &Paths) -> Value {
        json!({
            "name": self.name(),
            "tagline": s(&self.raw, "tagline"),
            "language": self.language(),
            "style": s(&self.raw, "style"),
            "palette": self.raw.get("palette").cloned().unwrap_or(json!({})),
            "fonts": self.raw.get("fonts").cloned().unwrap_or(json!({})),
            "voice": self.voice(),
            "handles": self.raw.get("handles").cloned().unwrap_or(json!({})),
            "schedule": self.raw.get("schedule").cloned().unwrap_or(json!({})),
            "resolved": paths.brand_dir().join("brand.resolved.json").exists(),
        })
    }
}

#[cfg(test)]
pub fn sample() -> Brand {
    Brand::from_value(json!({
        "schema": "creator-brand/v1",
        "name": "Northwind",
        "language": "en",
        "palette": {"ground": "#F7F5EF", "ink": "#1F2433", "accent": "#FFD84D", "accent_2": "#2F6BFF", "muted": "#8A8F9C", "on_accent": "#1F2433"},
        "voice": {
            "who": "A designer who builds tiny tools at night",
            "audience": "People who want to make their first app",
            "topics": ["no-code", "AI tools", "side projects"],
            "tone": ["plain words", "warm", "a bit dry"],
            "banned": ["game changer", "unlock", "dive in"],
            "cta": "Follow for one small build a day",
            "link": "example.com"
        },
        "schedule": {"shorts_per_day": 2, "long_per_week": 1, "timezone": "UTC"},
        "editing": {"max_short_seconds": 45}
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn voice_block_carries_the_whole_voice() {
        let b = sample().voice_block();
        for part in ["Northwind", "A designer who builds tiny tools", "first app", "no-code, AI tools", "plain words", "game changer", "Follow for one small build", "example.com", "Language to write in: en"] {
            assert!(b.contains(part), "missing {part}");
        }
    }

    #[test]
    fn schedule_has_safe_defaults() {
        let b = Brand::from_value(json!({}));
        assert_eq!(b.shorts_per_day(), 2);
        assert_eq!(b.model("creative"), "opus");
        assert_eq!(b.name(), "Your brand");
        assert_eq!(sample().max_short_seconds(), 45);
    }
}
