//! End to end with a fake `claude` binary: ideas, a week of cards, rewrites, the long-video chain,
//! the gate repair call, and the edit job runner. Runs offline.

#![cfg(unix)]

use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use studio_lib::brand::Brand;
use studio_lib::cards::card_problems;
use studio_lib::formats::Formats;
use studio_lib::gen::{self, Ctx};
use studio_lib::jobs::{run_logged, Job};
use studio_lib::jsonfile::read_json;
use studio_lib::paths::Paths;
use studio_lib::{edits, store};

/// The fake binary is chosen by an environment variable, so these tests take turns.
static ENV: Mutex<()> = Mutex::new(());

fn sample_brand() -> Value {
    json!({
        "schema": "creator-brand/v1", "name": "Northwind", "language": "en", "style": "notebook",
        "palette": {"ground": "#F7F5EF", "ink": "#1F2433", "accent": "#FFD84D", "accent_2": "#2F6BFF", "muted": "#8A8F9C", "on_accent": "#1F2433"},
        "voice": {
            "who": "A designer who builds tiny tools at night", "audience": "People who want to make their first app",
            "topics": ["no-code", "AI tools"], "tone": ["plain words"], "banned": ["game changer", "unlock", "dive in"],
            "cta": "Follow for one small build a day", "link": "example.com"
        },
        "schedule": {"shorts_per_day": 2, "long_per_week": 1}, "editing": {"max_short_seconds": 45}
    })
}

struct Setup {
    paths: Paths,
    brand: Brand,
    formats: Formats,
    log: PathBuf,
}

fn setup(tag: &str) -> Setup {
    let root = std::env::temp_dir().join(format!("studio-pipeline-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let workspace = root.join("workspace");
    std::fs::create_dir_all(workspace.join(".brand")).unwrap();
    std::fs::write(workspace.join(".brand/brand.resolved.json"), sample_brand().to_string()).unwrap();
    let paths = Paths { repo: root.clone(), workspace };
    let fake = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fake_claude.sh");
    let log = root.join("prompts.log");
    std::env::set_var("STUDIO_CLAUDE_BIN", &fake);
    std::env::set_var("STUDIO_FAKE_LOG", &log);
    std::env::remove_var("STUDIO_FAKE_BAD");
    let brand = Brand::load(&paths).unwrap();
    Setup { paths, brand, formats: Formats::built_in(), log }
}

fn ctx<'a>(s: &'a Setup, job: &'a Job) -> Ctx<'a> {
    Ctx { paths: &s.paths, brand: &s.brand, formats: &s.formats, job }
}

#[test]
fn ideas_then_a_full_week_of_cards() {
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let s = setup("week");
    let job = Job::detached("test");

    let r = gen::generate_ideas(&ctx(&s, &job), "shorts", 3, None).unwrap();
    assert_eq!(r["added"].as_array().unwrap().len(), 3);
    let items = read_json(&s.paths.ideas_file("shorts")).unwrap();
    assert!(s.formats.short_ids().contains(&items["items"][2]["format"].as_str().unwrap().to_string()), "a made-up format is replaced");
    store::set_idea_status(&s.paths, "shorts", "ship-it-ugly", "kept").unwrap();

    // One bad card on purpose: the first answer has a dash and a banned word, the repair call fixes it.
    std::env::set_var("STUDIO_FAKE_BAD", "1");
    let r = gen::write_week(&ctx(&s, &job), 43).unwrap();
    std::env::remove_var("STUDIO_FAKE_BAD");
    assert_eq!(r["added"].as_array().unwrap().len(), 14);
    assert!(r["warnings"].as_array().unwrap().is_empty(), "{}", r["warnings"]);

    let pack = read_json(&s.paths.cards_file(43)).unwrap();
    assert_eq!(pack["schema"], "cards/v1");
    let cards = pack["cards"].as_array().unwrap();
    assert_eq!(cards.len(), 14);
    assert_eq!(cards[0]["id"], "w43-01");
    assert_eq!(cards[13]["id"], "w43-14");
    for c in cards {
        let fmt = s.formats.short(c["format"].as_str().unwrap());
        assert!(card_problems(c, fmt.as_ref(), &s.brand, "").is_empty(), "{} {:?}", c["id"], card_problems(c, fmt.as_ref(), &s.brand, ""));
        assert_eq!(c["mode"], "cards");
        assert_eq!(c["status"], "to_film");
        assert!(c["script"].is_null());
    }
    assert!(cards.iter().map(|c| c["format"].as_str().unwrap()).collect::<std::collections::HashSet<_>>().len() >= 4, "formats rotate");
    assert_eq!(store::idea_by_id(&s.paths, "shorts", "ship-it-ugly").unwrap()["status"], "used");

    // The prompts that went out carry the brand voice and no one else's.
    let sent = std::fs::read_to_string(&s.log).unwrap();
    assert!(sent.contains("A designer who builds tiny tools at night") && sent.contains("problems were found"));
    for (a, b) in [("Pe", "p"), ("Seca", "nell"), ("Ke", "ak")] {
        assert!(!sent.contains(&format!("{a}{b}")));
    }

    assert!(gen::write_week(&ctx(&s, &job), 43).unwrap_err().contains("full week"));

    // Rewrite one part, then make a word for word script.
    let r = gen::rewrite_card(&ctx(&s, &job), 43, "w43-02", "payoff", "shorter").unwrap();
    assert_eq!(r["card"]["payoff"], "A rewritten payoff people remember.");
    assert_eq!(r["card"]["id"], "w43-02");
    let r = gen::make_script(&ctx(&s, &job), 43, "w43-02").unwrap();
    assert_eq!(r["card"]["mode"], "script");
    assert!(r["card"]["script"].as_str().unwrap().starts_with("Short script."));
}

#[test]
fn problems_that_survive_the_repair_are_reported_not_hidden() {
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let s = setup("warn");
    // A brand that bans a word the fake always uses: the repair cannot fix it.
    let mut brand = sample_brand();
    brand["voice"]["banned"] = json!(["follow for one small build"]);
    std::fs::write(s.paths.brand_dir().join("brand.resolved.json"), brand.to_string()).unwrap();
    let brand = Brand::load(&s.paths).unwrap();
    let job = Job::detached("test");
    let s2 = Setup { brand, ..s };
    let r = gen::write_week(&ctx(&s2, &job), 44).unwrap();
    assert_eq!(r["added"].as_array().unwrap().len(), 14);
    assert_eq!(r["warnings"].as_array().unwrap().len(), 14);
    assert!(r["warnings"][0]["problems"][0].as_str().unwrap().contains("banned"));
    let mut view = store::week_view(&s2.paths, &s2.brand, 44).unwrap();
    gen::annotate_problems(&mut view, &s2.brand, &s2.formats);
    assert!(!view["cards"][0]["problems"].as_array().unwrap().is_empty());
}

#[test]
fn the_long_video_chain() {
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let s = setup("long");
    let job = Job::detached("test");
    let c = ctx(&s, &job);
    let v = store::create_video(&s.paths, None, Some("Plan a week"), "explainer").unwrap();
    let slug = v["slug"].as_str().unwrap();

    assert!(gen::long_script(&c, slug, 2).unwrap_err().contains("map first"));
    assert_eq!(gen::long_titles(&c, slug).unwrap()["video"]["title_options"].as_array().unwrap().len(), 3);
    let map = gen::long_map(&c, slug).unwrap();
    assert_eq!(map["video"]["map"].as_array().unwrap().len(), 5);
    assert_eq!(map["video"]["map"][0]["title"], "Start with the end");
    let script = gen::long_script(&c, slug, 2).unwrap();
    assert_eq!(script["video"]["mode"], "script");
    let thumbs = gen::long_thumbs(&c, slug).unwrap();
    let shapes: Vec<&str> = thumbs["video"]["thumbnail_ideas"].as_array().unwrap().iter().map(|t| t["shape"].as_str().unwrap()).collect();
    assert_eq!(shapes, vec!["face-words", "object-number", "split-contrast"]);
    let d = gen::long_description(&c, slug).unwrap();
    let desc = d["video"]["description"].as_str().unwrap();
    assert!(desc.contains("0:00 The idea") && desc.contains("1:05 The method") && desc.contains("3:10 Try it"), "{desc}");

    let saved = read_json(&s.paths.video_file(slug)).unwrap();
    assert_eq!(saved["schema"], "long-video/v1");
    for k in ["slug", "title", "format", "mode", "map", "script", "thumbnail_ideas", "description", "status"] {
        assert!(saved.get(k).is_some(), "missing {k}");
    }
}

#[test]
fn fix_text_uses_the_structured_runner() {
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let s = setup("fix");
    assert_eq!(gen::fix_text(&s.brand, "Let's dive in \u{2014} now").unwrap(), "Clean text.");
    assert_eq!(gen::fix_text(&s.brand, "Already fine.").unwrap(), "Already fine.");
    std::env::set_var("STUDIO_CLAUDE_BIN", "/nonexistent/claude");
    assert!(gen::fix_text(&s.brand, "Let's dive in").unwrap_err().contains("Couldn't run claude"));
}

#[test]
fn the_edit_job_streams_its_log() {
    let _g = ENV.lock().unwrap_or_else(|e| e.into_inner());
    let s = setup("edit");
    let launcher = s.paths.repo.join("studio");
    std::fs::write(&launcher, "#!/bin/sh\necho \"args: $*\"\necho \"working\"\nexit ${STUDIO_FAKE_EXIT:-0}\n").unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o755)).unwrap();

    let job = Job::detached("edit");
    let cmd = edits::edit_command(&s.paths, "short", "w43-01").unwrap();
    assert_eq!(run_logged(&job, cmd).unwrap(), 0);
    let log = studio_lib::jobs::job_json(&job.id).unwrap()["log"].to_string();
    assert!(log.contains("args: edit short w43-01") && log.contains("working"), "{log}");
}
