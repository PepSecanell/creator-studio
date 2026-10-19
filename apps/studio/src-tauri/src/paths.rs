//! Where the repo and the workspace live. Everything is found from the config file that
//! `./studio setup` writes, never from a hardcoded path.

use serde_json::Value;
use std::path::{Path, PathBuf};

pub const SETUP_HINT: &str = "Run ./studio setup first.";

#[derive(Clone, Debug)]
pub struct Paths {
    pub repo: PathBuf,
    pub workspace: PathBuf,
}

fn default_config_path() -> PathBuf {
    let home = std::env::var("HOME").unwrap_or_default();
    PathBuf::from(home).join(".config/creator-studio/config.json")
}

impl Paths {
    /// Reads the config file (env `CREATOR_STUDIO_CONFIG` picks another one) and applies the
    /// `CREATOR_STUDIO_WORKSPACE` override.
    pub fn load() -> Result<Paths, String> {
        let config = std::env::var("CREATOR_STUDIO_CONFIG").ok().filter(|s| !s.is_empty()).map(PathBuf::from).unwrap_or_else(default_config_path);
        let workspace_env = std::env::var("CREATOR_STUDIO_WORKSPACE").ok().filter(|s| !s.is_empty()).map(PathBuf::from);
        match (Paths::from_config_file(&config), workspace_env) {
            (Ok(mut p), Some(w)) => {
                p.workspace = w;
                Ok(p)
            }
            (Ok(p), None) => Ok(p),
            (Err(_), Some(w)) => {
                // No config, but the workspace was named: the repo is the folder around it.
                let repo = w.parent().map(Path::to_path_buf).unwrap_or_else(|| w.clone());
                Ok(Paths { repo, workspace: w })
            }
            (Err(e), None) => Err(e),
        }
    }

    pub fn from_config_file(config: &Path) -> Result<Paths, String> {
        let raw = std::fs::read_to_string(config).map_err(|_| SETUP_HINT.to_string())?;
        let v: Value = serde_json::from_str(&raw).map_err(|_| format!("The config file is damaged. {SETUP_HINT}"))?;
        let repo = v.get("repo").and_then(Value::as_str).ok_or_else(|| format!("The config file has no repo. {SETUP_HINT}"))?;
        let workspace = v.get("workspace").and_then(Value::as_str).map(PathBuf::from).unwrap_or_else(|| Path::new(repo).join("workspace"));
        Ok(Paths { repo: PathBuf::from(repo), workspace })
    }

    pub fn ws(&self, rel: &str) -> PathBuf {
        self.workspace.join(rel)
    }
    pub fn brand_dir(&self) -> PathBuf {
        self.ws(".brand")
    }
    pub fn ideas_file(&self, kind: &str) -> PathBuf {
        self.ws(&format!("ideas/{kind}.json"))
    }
    pub fn week_dir(&self, week: i64) -> PathBuf {
        self.ws(&format!("shorts/week-{week:02}"))
    }
    pub fn cards_file(&self, week: i64) -> PathBuf {
        self.week_dir(week).join("cards.json")
    }
    pub fn video_dir(&self, slug: &str) -> PathBuf {
        self.ws(&format!("long/{slug}"))
    }
    pub fn video_file(&self, slug: &str) -> PathBuf {
        self.video_dir(slug).join("video.json")
    }
    pub fn handoff_dir(&self) -> PathBuf {
        self.ws("handoff")
    }
    pub fn edits_dir(&self, kind: &str) -> PathBuf {
        self.ws(&format!("edits/{}", if kind == "short" { "shorts" } else { "long" }))
    }
    pub fn kits_dir(&self) -> PathBuf {
        self.ws("kits")
    }
    /// The `studio` launcher in the repo root (env `STUDIO_BIN` swaps it, used by tests).
    pub fn studio_bin(&self) -> PathBuf {
        match std::env::var("STUDIO_BIN") {
            Ok(b) if !b.is_empty() => PathBuf::from(b),
            _ => self.repo.join("studio"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn config_file_is_read() {
        let dir = std::env::temp_dir().join(format!("studio-paths-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let cfg = dir.join("config.json");
        std::fs::write(&cfg, r#"{"schema":"cs-config/v1","repo":"/r","workspace":"/r/ws"}"#).unwrap();
        let p = Paths::from_config_file(&cfg).unwrap();
        assert_eq!(p.workspace, PathBuf::from("/r/ws"));
        assert_eq!(p.cards_file(7), PathBuf::from("/r/ws/shorts/week-07/cards.json"));
        assert!(Paths::from_config_file(&dir.join("missing.json")).unwrap_err().contains("./studio setup"));
    }
}
