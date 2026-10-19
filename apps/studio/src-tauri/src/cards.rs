//! Cards: one Short as scriptless talking points (mode "cards") or word for word text
//! (mode "script"). Shape, checks and the text the Recorder shows all live here.

use serde_json::{json, Value};

use crate::brand::Brand;
use crate::formats::points_range;
use crate::gates::{digit_problems, text_problems, word_count};
use crate::jsonfile::{s, str_list};

/// What Claude must fill for each card. Ids, formats and statuses are set by the app, not by Claude.
pub const CARD_PROPERTIES: &str = r#"{
  "title": {"type": "string"},
  "hook": {"type": "object", "properties": {
    "idea": {"type": "string"},
    "takes": {"type": "array", "items": {"type": "string"}}
  }, "required": ["idea", "takes"]},
  "points": {"type": "array", "items": {"type": "string"}},
  "payoff": {"type": "string"},
  "end_line": {"type": "string"},
  "facts": {"type": "array", "items": {"type": "string"}}
}"#;

pub const CARD_REQUIRED: &str = r#"["title", "hook", "points", "payoff", "end_line", "facts"]"#;

pub fn card_schema() -> String {
    format!(r#"{{"type":"object","properties":{CARD_PROPERTIES},"required":{CARD_REQUIRED}}}"#)
}

pub fn batch_schema() -> String {
    format!(r#"{{"type":"object","properties":{{"cards":{{"type":"array","items":{{"type":"object","properties":{CARD_PROPERTIES},"required":{CARD_REQUIRED}}}}}}},"required":["cards"]}}"#)
}

pub fn script_schema() -> String {
    r#"{"type":"object","properties":{"script":{"type":"string"}},"required":["script"]}"#.to_string()
}

pub fn blank_card(id: &str, title: &str, format: &str) -> Value {
    json!({
        "id": id, "title": title, "format": format, "mode": "cards",
        "hook": {"idea": "", "takes": ["", ""]},
        "points": [], "payoff": "", "end_line": "",
        "script": null, "facts": [], "status": "to_film",
        "setup": {"urls": [], "apps": []}
    })
}

/// Builds a full card from what Claude returned plus the facts the app decides.
pub fn assemble(id: &str, format: &str, answer: &Value) -> Value {
    let mut c = blank_card(id, &s(answer, "title"), format);
    c["hook"] = json!({
        "idea": answer.pointer("/hook/idea").and_then(Value::as_str).unwrap_or("").trim(),
        "takes": answer.pointer("/hook/takes").cloned().unwrap_or(json!([])),
    });
    c["points"] = json!(str_list(answer, "points"));
    c["payoff"] = json!(s(answer, "payoff").trim());
    c["end_line"] = json!(s(answer, "end_line").trim());
    c["facts"] = json!(str_list(answer, "facts"));
    c["title"] = json!(s(&c, "title").trim());
    c
}

/// The first words of a take are what the camera hears. Two takes should not be one sentence twice.
fn shape(t: &str) -> (bool, bool) {
    (t.trim_end().ends_with('?'), word_count(t) > 6)
}

fn sentences(t: &str) -> usize {
    t.split(['.', '!', '?']).filter(|p| !p.trim().is_empty()).count()
}

/// Every text a viewer will hear or read on the card.
pub fn visible_texts(c: &Value) -> Vec<String> {
    let mut v = vec![s(c, "title"), s(c, "payoff"), s(c, "end_line"), c.pointer("/hook/idea").and_then(Value::as_str).unwrap_or("").to_string()];
    v.extend(c.pointer("/hook/takes").and_then(Value::as_array).into_iter().flatten().filter_map(|t| t.as_str().map(str::to_string)));
    v.extend(str_list(c, "points"));
    if let Some(sc) = c.get("script").and_then(Value::as_str) {
        v.push(sc.to_string());
    }
    v.retain(|t| !t.trim().is_empty());
    v
}

/// Everything wrong with a card, in plain sentences. An empty list means it is ready.
pub fn card_problems(c: &Value, format: Option<&Value>, brand: &Brand, backing: &str) -> Vec<String> {
    let mut out = Vec::new();
    let title = s(c, "title");
    if title.trim().is_empty() {
        out.push("the title is empty".to_string());
    } else if title.chars().count() > 70 {
        out.push("the title is longer than 70 characters".to_string());
    }
    let mode = s(c, "mode");
    if mode != "cards" && mode != "script" {
        out.push(format!("mode must be \"cards\" or \"script\", not \"{mode}\""));
    }
    if c.pointer("/hook/idea").and_then(Value::as_str).unwrap_or("").trim().is_empty() {
        out.push("the hook idea is empty".to_string());
    }
    let takes: Vec<String> = c.pointer("/hook/takes").and_then(Value::as_array).map(|a| a.iter().filter_map(|t| t.as_str().map(str::to_string)).collect()).unwrap_or_default();
    if takes.len() != 2 || takes.iter().any(|t| t.trim().is_empty()) {
        out.push("the hook needs exactly 2 takes (the first words of the video)".to_string());
    } else {
        for t in &takes {
            let n = word_count(t);
            if !(3..=14).contains(&n) {
                out.push(format!("a hook take should be 3 to 14 words, \"{t}\" has {n}"));
            }
        }
        let (a, b) = (takes[0].to_lowercase(), takes[1].to_lowercase());
        let first = |t: &str| t.split_whitespace().next().unwrap_or("").to_string();
        if a == b || first(&a) == first(&b) || shape(&takes[0]) == shape(&takes[1]) {
            out.push("the 2 hook takes must differ in shape: different first word, and one a question or one short and one longer".to_string());
        }
    }
    let points = str_list(c, "points");
    if let Some(f) = format {
        let (lo, hi) = points_range(f);
        if mode == "cards" && !(lo..=hi).contains(&points.len()) {
            out.push(format!("this format needs {lo} to {hi} points, there are {}", points.len()));
        }
    }
    for p in &points {
        if p.trim().is_empty() {
            out.push("a point is empty".to_string());
        } else if word_count(p) > 16 || sentences(p) > 1 {
            out.push(format!("point \"{p}\" reads like a script: keep each point to one short line"));
        }
    }
    let payoff = s(c, "payoff");
    if payoff.trim().is_empty() {
        out.push("the payoff is empty".to_string());
    } else if word_count(&payoff) > 25 {
        out.push("the payoff is longer than 25 words".to_string());
    }
    let end = s(c, "end_line");
    if end.trim().is_empty() {
        out.push("the end line is empty".to_string());
    } else if word_count(&end) > 20 {
        out.push("the end line is longer than 20 words".to_string());
    }
    match (mode.as_str(), c.get("script").and_then(Value::as_str)) {
        ("script", Some(t)) if !t.trim().is_empty() => {
            let limit = (brand.max_short_seconds() as f64 * 2.6) as usize;
            if word_count(t) > limit {
                out.push(format!("the script has {} words, more than {limit} fit in {} seconds", word_count(t), brand.max_short_seconds()));
            }
        }
        ("script", _) => out.push("script mode needs the script text".to_string()),
        ("cards", Some(t)) if !t.trim().is_empty() => out.push("cards mode must not carry a script (it would turn into a teleprompter)".to_string()),
        _ => {}
    }

    let all = visible_texts(c).join("\n");
    out.extend(text_problems(&all, &brand.banned()));
    let backing = format!("{backing}\n{}", str_list(c, "facts").join("\n"));
    out.extend(digit_problems(&all, &backing));
    out
}

/// The text the Recorder shows. Cards mode lists the beats; script mode is the script itself.
pub fn prompter_text(c: &Value) -> String {
    if s(c, "mode") == "script" {
        if let Some(t) = c.get("script").and_then(Value::as_str) {
            return t.to_string();
        }
    }
    let takes = str_list(&json!({"t": c.pointer("/hook/takes").cloned().unwrap_or(json!([]))}), "t");
    let mut lines = vec![format!("HOOK IDEA: {}", c.pointer("/hook/idea").and_then(Value::as_str).unwrap_or(""))];
    for (i, t) in takes.iter().enumerate() {
        lines.push(format!("OPENING {}: {}", i + 1, t));
    }
    lines.push("POINTS:".to_string());
    lines.extend(str_list(c, "points").iter().map(|p| format!("- {p}")));
    lines.push(format!("PAYOFF: {}", s(c, "payoff")));
    lines.push(format!("END: {}", s(c, "end_line")));
    lines.join("\n")
}

/// The beats as a list (for the Recorder's points column and the card page).
pub fn beats(c: &Value) -> Vec<String> {
    let mut b = vec![c.pointer("/hook/idea").and_then(Value::as_str).unwrap_or("").to_string()];
    b.extend(str_list(c, "points"));
    b.push(s(c, "payoff"));
    b.push(s(c, "end_line"));
    b.retain(|t| !t.trim().is_empty());
    b
}

/// Formats round-robin from where the last pack stopped, so a week is not five of the same.
pub fn rotate_formats(count: usize, ids: &[String], recent: &[String]) -> Vec<String> {
    if ids.is_empty() {
        return vec![];
    }
    let start = recent.last().and_then(|l| ids.iter().position(|i| i == l)).map(|p| p + 1).unwrap_or(0);
    (0..count).map(|i| ids[(start + i) % ids.len()].clone()).collect()
}

#[cfg(test)]
pub mod tests {
    use super::*;
    use crate::brand::sample;
    use crate::formats::Formats;

    pub fn good_card() -> Value {
        json!({
            "id": "w42-01", "title": "Ship it ugly", "format": "same-idea-3-ways", "mode": "cards",
            "hook": {"idea": "Saying the same sentence three ways", "takes": ["Nobody hears your first draft.", "Why does the plan always change when you start?"]},
            "points": ["Rushed and flat", "Slow with one pause", "Warm and a bit quiet"],
            "payoff": "The pause version is the one people remember.",
            "end_line": "Follow for one small build a day.",
            "script": null, "facts": [], "status": "to_film",
            "setup": {"urls": [], "apps": []}
        })
    }

    fn fmt() -> Value {
        Formats::built_in().short("same-idea-3-ways").unwrap()
    }

    #[test]
    fn a_good_card_passes() {
        let p = card_problems(&good_card(), Some(&fmt()), &sample(), "");
        assert!(p.is_empty(), "{p:?}");
    }

    #[test]
    fn schema_shape_is_enforced() {
        let b = sample();
        let mut c = good_card();
        c["hook"]["takes"] = json!(["Only one"]);
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|p| p.contains("exactly 2 takes")));

        let mut c = good_card();
        c["points"] = json!(["a", "b"]);
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|p| p.contains("3 to 3 points")));

        let mut c = good_card();
        c["mode"] = json!("teleprompter");
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|p| p.contains("mode must be")));

        let mut c = good_card();
        c["script"] = json!("Read this out loud.");
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|p| p.contains("must not carry a script")));

        let mut c = good_card();
        c["mode"] = json!("script");
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|p| p.contains("needs the script")));
        c["script"] = json!("Short and fine.");
        assert!(card_problems(&c, Some(&fmt()), &b, "").is_empty());
        c["script"] = json!("word ".repeat(200));
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|p| p.contains("fit in 45 seconds")));
    }

    #[test]
    fn takes_must_differ_and_points_must_stay_short() {
        let b = sample();
        let mut c = good_card();
        c["hook"]["takes"] = json!(["Nobody hears your first draft.", "Nobody hears your second draft."]);
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|p| p.contains("differ in shape")));
        let mut c = good_card();
        c["points"][0] = json!("This is a whole sentence. And then a second one that a person would read out loud.");
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|p| p.contains("reads like a script")));
    }

    #[test]
    fn gates_apply_to_cards() {
        let b = sample();
        let mut c = good_card();
        c["payoff"] = json!("It will unlock everything \u{2014} fast.");
        let p = card_problems(&c, Some(&fmt()), &b, "");
        assert!(p.iter().any(|x| x.contains("dash")));
        assert!(p.iter().any(|x| x.contains("banned")));
        let mut c = good_card();
        c["payoff"] = json!("It saved 83 hours.");
        assert!(card_problems(&c, Some(&fmt()), &b, "").iter().any(|x| x.contains("83")));
        c["facts"] = json!(["It saved 83 hours in total"]);
        assert!(card_problems(&c, Some(&fmt()), &b, "").is_empty());
    }

    #[test]
    fn prompter_lists_beats_in_cards_mode() {
        let t = prompter_text(&good_card());
        assert!(t.contains("HOOK IDEA:") && t.contains("OPENING 2:") && t.contains("- Slow with one pause") && t.contains("END:"));
        let mut c = good_card();
        c["mode"] = json!("script");
        c["script"] = json!("Word for word.");
        assert_eq!(prompter_text(&c), "Word for word.");
    }

    #[test]
    fn formats_rotate_from_the_last_one() {
        let ids: Vec<String> = ["a", "b", "c"].iter().map(|s| s.to_string()).collect();
        assert_eq!(rotate_formats(4, &ids, &["b".to_string()]), vec!["c", "a", "b", "c"]);
        assert_eq!(rotate_formats(2, &ids, &[]), vec!["a", "b"]);
    }
}
