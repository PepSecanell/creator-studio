//! Every prompt Studio sends, built from the brand voice and the formats. No persona is written
//! into the code: who is talking and who listens always comes from `brand.resolved.json`.

use serde_json::Value;

use crate::brand::Brand;
use crate::formats::points_range;
use crate::jsonfile::{s, str_list};

const PLAIN_RULES: &str = "\
Hard rules for every word you write:\n\
- Plain, spoken words. Short sentences. Sound like a real person, not a brand.\n\
- No dashes of any kind (no em dash, no en dash, no \" - \"). Use a comma or a full stop.\n\
- No hype and no filler openers (\"here's the thing\", \"nobody talks about\", \"game changer\", \"unlock\", \"dive in\").\n\
- Never invent facts, numbers, results, names, quotes or sources. If a number appears in the text, it must also be listed under facts.\n";

pub fn format_lines(formats: &[Value]) -> String {
    formats
        .iter()
        .map(|f| {
            let (lo, hi) = points_range(f);
            format!("- {} (\"{}\"): {} {} Points: {} to {}.", s(f, "name"), s(f, "id"), s(f, "blurb"), s(f, "structure"), lo, hi)
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn list_or_none(items: &[String]) -> String {
    if items.is_empty() {
        "(none)".to_string()
    } else {
        items.iter().map(|t| format!("- {t}")).collect::<Vec<_>>().join("\n")
    }
}

pub fn ideas_prompt(brand: &Brand, kind: &str, count: usize, formats: &[Value], existing: &[String], kept: &[String], killed: &[String]) -> String {
    let what = if kind == "long" { "long videos (5 to 12 minutes)" } else { "Shorts (under a minute, filmed in one go)" };
    format!(
        "{voice}\n{rules}\n=== TASK ===\nWrite {count} new ideas for {what}. Each idea is a title (a plain phrase a viewer would type or tap, under 70 characters) \
and an angle (one sentence: what the viewer gets, from the viewer's side). Mix the topics. Do not repeat or lightly reword any idea below.\n\n\
=== FORMATS (pick the best fit for each idea, use the id) ===\n{formats}\n\n\
=== ALREADY USED OR PROPOSED ===\n{existing}\n\n\
=== IDEAS THE CREATOR KEPT (more like these) ===\n{kept}\n\n\
=== IDEAS THE CREATOR KILLED (never like these) ===\n{killed}\n\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        rules = PLAIN_RULES,
        formats = format_lines(formats),
        existing = list_or_none(existing),
        kept = list_or_none(kept),
        killed = list_or_none(killed),
    )
}

/// One planned card: its format and, when there is one, the idea behind it.
pub struct CardSpec {
    pub format: Value,
    pub idea: Option<(String, String)>,
}

pub fn short_rules(brand: &Brand) -> String {
    format!(
        "=== HOW A CARD WORKS (scriptless) ===\n\
This is a card, not a script. The creator talks naturally from it. Never write full sentences to read aloud, except the two hook takes.\n\
- title: a plain search-style phrase, under 70 characters.\n\
- hook.idea: what the first two seconds are about, written about the viewer (\"you\").\n\
- hook.takes: exactly 2 versions of the first words said, 3 to 14 words each, in different shapes (for example one question and one statement, or one short and one longer). Different first word. The creator says the first words three times, so they must be easy to say.\n\
- points: one short line each, at most 12 words, a prompt to talk from, not a sentence to read.\n\
- payoff: one line, what the viewer gets by the end.\n\
- end_line: one closing line. It may use the call to action lightly, but only when it fits. Current call to action: {cta}\n\
- facts: only the real facts the creator must get right. Every number in the card must be in facts.\n\
The whole Short must fit in {secs} seconds when talked.\n{rules}",
        cta = if brand.cta().is_empty() { "(none)".to_string() } else { brand.cta() },
        secs = brand.max_short_seconds(),
        rules = PLAIN_RULES,
    )
}

pub fn cards_prompt(brand: &Brand, specs: &[CardSpec]) -> String {
    let lines: Vec<String> = specs
        .iter()
        .enumerate()
        .map(|(i, sp)| {
            let (lo, hi) = points_range(&sp.format);
            let idea = match &sp.idea {
                Some((t, a)) => format!("Idea: {t}. Angle: {a}"),
                None => format!("No idea given: invent a fresh one from the brand topics ({}).", brand.topics().join(", ")),
            };
            format!("Card {}: format \"{}\" ({} points). {}\nFormat structure: {}", i + 1, s(&sp.format, "name"), if lo == hi { lo.to_string() } else { format!("{lo} to {hi}") }, idea, s(&sp.format, "structure"))
        })
        .collect();
    format!(
        "{voice}\n{rules}\n=== TASK ===\nWrite {n} cards, one per card below, in the same order. Make them feel different from each other.\n\n{cards}\n\nFill the JSON schema exactly: {n} cards.",
        voice = brand.voice_block(),
        rules = short_rules(brand),
        n = specs.len(),
        cards = lines.join("\n\n"),
    )
}

pub fn fix_prompt(brand: &Brand, what: &str, current: &str, problems: &[String]) -> String {
    format!(
        "{voice}\n=== TASK ===\nThe {what} below was checked and these problems were found:\n{problems}\n\n\
Fix ONLY these problems. Change as little else as possible. Keep the meaning, the facts and the plain spoken voice. Return the same JSON structure.\n\n=== CURRENT {upper} ===\n{current}\n\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        problems = problems.iter().map(|p| format!("- {p}")).collect::<Vec<_>>().join("\n"),
        upper = what.to_uppercase(),
    )
}

pub fn rewrite_prompt(brand: &Brand, card_json: &str, part: &str, note: &str) -> String {
    let scope = match part {
        "all" => "Rewrite the whole card.".to_string(),
        p => format!("Rewrite ONLY the \"{p}\" part. Keep everything else exactly as it is (still return all fields)."),
    };
    format!(
        "{voice}\n{rules}\n=== TASK ===\n{scope}\nThe creator's note: {note}\n\n=== CURRENT CARD ===\n{card}\n\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        rules = short_rules(brand),
        note = if note.trim().is_empty() { "(none, just make it better and more natural)" } else { note.trim() },
        card = card_json,
    )
}

pub fn script_prompt(brand: &Brand, card_json: &str) -> String {
    let words = (brand.max_short_seconds() as f64 * 2.4) as i64;
    format!(
        "{voice}\n{rules}\n=== TASK ===\nTurn this card into a word for word script the creator will read. Keep the hook take that works best as the first line, then the points in order, then the payoff and the end line. \
It must sound spoken, not written. At most {words} words. Do not add facts that are not on the card.\n\n=== CARD ===\n{card}\n\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        rules = PLAIN_RULES,
        card = card_json,
    )
}

// ── Long videos ──────────────────────────────────────────────────────────────────────────────

pub fn long_context(video: &Value, format: Option<&Value>) -> String {
    let fmt = format.map(|f| format!("Format: {} ({})", s(f, "name"), s(f, "structure"))).unwrap_or_default();
    format!("Working title: {}\nIdea: {}\n{}\nFacts the creator confirmed: {}\n", s(video, "title"), s(video, "idea"), fmt, {
        let f = str_list(video, "facts");
        if f.is_empty() { "(none)".to_string() } else { f.join("; ") }
    })
}

pub fn titles_prompt(brand: &Brand, ctx: &str) -> String {
    format!(
        "{voice}\n{rules}\n=== TASK ===\nWrite 3 title options for this video. Under 70 characters each. Each uses a different approach: one a plain search phrase, one a result the viewer gets, one a belief the video corrects. No clickbait the video cannot back up.\n\n{ctx}\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        rules = PLAIN_RULES,
    )
}

pub fn map_prompt(brand: &Brand, ctx: &str, format: &Value) -> String {
    let (lo, hi) = points_range(format);
    format!(
        "{voice}\n{rules}\n=== TASK ===\nWrite the map for this video: the talking points the creator will speak from. Not a script. {lo} to {hi} points in order. \
Each point has two lines only: \"title\" (at most 8 words, what this part is) and \"detail\" (at most 14 words, the one thing to say or show). \
Also list under facts anything the creator must get right.\n\n{ctx}\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        rules = PLAIN_RULES,
    )
}

pub fn long_script_prompt(brand: &Brand, ctx: &str, map: &str, minutes: i64) -> String {
    format!(
        "{voice}\n{rules}\n=== TASK ===\nWrite the full spoken script for this video, about {minutes} minutes ({words} words). Open on the thing itself, promise the result in the first 30 seconds, follow the map in order, and end with the steps or the lesson. It must sound spoken, not written.\n\n{ctx}\n=== MAP ===\n{map}\n\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        rules = PLAIN_RULES,
        words = minutes * 150,
    )
}

pub fn thumbs_prompt(brand: &Brand, ctx: &str, shapes: &[Value]) -> String {
    let lines = shapes.iter().map(|f| format!("- \"{}\" ({}): {}", s(f, "id"), s(f, "name"), s(f, "rule"))).collect::<Vec<_>>().join("\n");
    format!(
        "{voice}\n{rules}\n=== TASK ===\nWrite 3 thumbnail ideas for this video. They must be structurally different, so use 3 different shapes from this list, one each:\n{lines}\n\
For each: shape (the id), words (the text on the thumbnail, 2 to 5 words, never the whole title), scene (what is in the frame, concrete enough to photograph or draw), why (one line on why a viewer would tap).\n\n{ctx}\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        rules = PLAIN_RULES,
    )
}

pub fn description_prompt(brand: &Brand, ctx: &str, map: &str) -> String {
    format!(
        "{voice}\n{rules}\n=== TASK ===\nWrite the video description and the chapters. The description: 2 to 4 short plain sentences saying what the viewer gets (no hashtags, no keyword lists), then the link once if there is one. \
Chapters: 4 to 10, one per part of the map, each with start_seconds (estimated, the first is 0) and a short plain title.\n\n{ctx}\n=== MAP ===\n{map}\n\nFill the JSON schema exactly.",
        voice = brand.voice_block(),
        rules = PLAIN_RULES,
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::brand::sample;
    use crate::formats::Formats;
    use serde_json::json;

    fn all_prompts() -> Vec<String> {
        let b = sample();
        let f = Formats::built_in();
        let ctx = long_context(&json!({"title": "T", "idea": "I", "facts": ["f"]}), f.long_format("explainer").as_ref());
        vec![
            ideas_prompt(&b, "shorts", 5, &f.shorts(), &["Old one".to_string()], &[], &["Bad one".to_string()]),
            cards_prompt(&b, &[CardSpec { format: f.short("myth-then-fix").unwrap(), idea: Some(("Ship it ugly".into(), "why".into())) }, CardSpec { format: f.short("i-tried-x").unwrap(), idea: None }]),
            fix_prompt(&b, "card", "{}", &["it has a dash".to_string()]),
            rewrite_prompt(&b, "{}", "payoff", "shorter"),
            script_prompt(&b, "{}"),
            titles_prompt(&b, &ctx),
            map_prompt(&b, &ctx, &f.long_format("explainer").unwrap()),
            long_script_prompt(&b, &ctx, "map", 6),
            thumbs_prompt(&b, &ctx, &f.thumbnail_shapes()),
            description_prompt(&b, &ctx, "map"),
        ]
    }

    #[test]
    fn every_prompt_carries_the_brand_voice() {
        for p in all_prompts() {
            assert!(p.contains("THE BRAND: Northwind"), "no brand block in: {}", &p[..80.min(p.len())]);
            assert!(p.contains("A designer who builds tiny tools at night"));
            assert!(p.contains("People who want to make their first app"));
            assert!(p.contains("game changer"), "banned words are listed");
        }
    }

    #[test]
    fn prompts_name_the_task_inputs() {
        let b = sample();
        let f = Formats::built_in();
        let p = ideas_prompt(&b, "shorts", 5, &f.shorts(), &["Old one".to_string()], &["Liked one".to_string()], &["Bad one".to_string()]);
        for part in ["Write 5 new ideas", "Same idea, 3 ways", "say-this-not-that", "Old one", "Liked one", "Bad one", "Shorts"] {
            assert!(p.contains(part), "missing {part}");
        }
        let c = cards_prompt(&b, &[CardSpec { format: f.short("myth-then-fix").unwrap(), idea: Some(("Ship it ugly".into(), "why".into())) }, CardSpec { format: f.short("i-tried-x").unwrap(), idea: None }]);
        assert!(c.contains("Card 2") && c.contains("Ship it ugly") && c.contains("no-code, AI tools") && c.contains("45 seconds") && c.contains("Follow for one small build a day"));
        assert!(rewrite_prompt(&b, "{}", "payoff", "shorter").contains("ONLY the \"payoff\""));
    }

    #[test]
    fn no_personal_names_are_baked_in() {
        for p in all_prompts() {
            // Written in pieces so this file stays free of the names it guards against.
            for (a, b) in [("Pe", "p"), ("Seca", "nell"), ("Ke", "ak"), ("Ke", "oly"), ("Vi", "nh"), ("Second", " Brain"), ("Post", " Today"), ("Can", "vas")] {
                let name = format!("{a}{b}");
                assert!(!p.contains(&name), "{name} found in a prompt");
            }
        }
    }
}
