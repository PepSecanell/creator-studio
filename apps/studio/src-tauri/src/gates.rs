//! Quality gates for generated text: dashes, AI-sounding phrases, the brand's banned words and
//! numbers nobody can back up. They return plain sentences, which are also fed to the repair call.

/// Phrase match on word boundaries, so "realm" does not fire inside "realmente".
pub fn contains_word(lower: &str, phrase: &str) -> bool {
    let bytes = lower.as_bytes();
    let mut from = 0;
    while let Some(i) = lower[from..].find(phrase) {
        let at = from + i;
        let end = at + phrase.len();
        let before_ok = at == 0 || !bytes[at - 1].is_ascii_alphanumeric();
        let after_ok = end >= bytes.len() || !bytes[end].is_ascii_alphanumeric();
        if before_ok && after_ok {
            return true;
        }
        from = at + phrase.len().max(1);
        if from >= lower.len() {
            break;
        }
    }
    false
}

fn plain(text: &str) -> String {
    text.to_lowercase().replace(['\u{2019}', '\u{2018}'], "'")
}

pub fn dash_problems(text: &str) -> Vec<String> {
    if text.contains('\u{2014}') || text.contains('\u{2013}') {
        vec!["it has an em dash or en dash".to_string()]
    } else if text.contains(" - ") {
        vec!["it uses a hyphen as a dash (\" - \")".to_string()]
    } else {
        vec![]
    }
}

const TEE_UPS: &[&str] = &[
    "here's the kicker",
    "here's the part",
    "here's where it gets",
    "here's why",
    "and that's when it clicked",
    "let me zoom out",
    "i want you to sit with this",
];
const INSIGHT_FRAMING: &[&str] = &[
    "nobody talks about this",
    "what nobody tells you",
    "most people miss",
    "what surprises people is",
    "what most people get wrong",
    "people get wrong about",
    "worth remembering",
    "worth keeping in mind",
];
const REFRAMES: &[&str] = &["it's not just", "i don't just mean", "here's the thing"];
const HYPE_WORDS: &[&str] = &[
    "delve", "unlock", "unleash", "elevate", "supercharge", "harness", "leverage", "seamless", "robust",
    "game-changer", "game changer", "revolutionary", "cutting-edge", "at the end of the day", "the power of",
    "take it to the next level", "embark", "tapestry", "testament", "realm", "foster", "empower", "dive in",
    "deep dive",
];

pub fn ai_tell_problems(text: &str) -> Vec<String> {
    let lower = plain(text);
    let mut out = Vec::new();
    if let Some(at) = lower.find("that's where") {
        let tail = lower.get(at..(at + 60).min(lower.len())).unwrap_or("");
        if tail.contains("comes in") {
            out.push("AI phrase: \"that's where X comes in\"".to_string());
        }
    }
    for (label, list) in [
        ("tee-up opener", TEE_UPS),
        ("signposting", INSIGHT_FRAMING),
        ("reframe structure", REFRAMES),
        ("AI-sounding word", HYPE_WORDS),
    ] {
        for phrase in list {
            if contains_word(&lower, phrase) {
                out.push(format!("{label}: \"{phrase}\""));
            }
        }
    }
    if lower.starts_with("honestly") || lower.contains(". honestly") || lower.contains("and honestly") {
        out.push("\"Honestly\" used as an opener".to_string());
    }
    out
}

pub fn banned_problems(text: &str, banned: &[String]) -> Vec<String> {
    let lower = plain(text);
    banned
        .iter()
        .filter(|b| !b.trim().is_empty() && contains_word(&lower, &plain(b.trim())))
        .map(|b| format!("brand banned phrase: \"{b}\""))
        .collect()
}

/// Numbers in `text` that do not appear in `backing` (the idea, the facts). A made-up statistic is
/// the most believable kind of mistake, so each number must be traceable. Small whole numbers up
/// to 10 are counting words ("3 ways", "step 2") and pass, unless they are a percentage.
pub fn digit_problems(text: &str, backing: &str) -> Vec<String> {
    let chars: Vec<char> = text.chars().collect();
    let mut out: Vec<String> = Vec::new();
    let mut i = 0;
    while i < chars.len() {
        if !chars[i].is_ascii_digit() {
            i += 1;
            continue;
        }
        let start = i;
        while i < chars.len() && (chars[i].is_ascii_digit() || ((chars[i] == '.' || chars[i] == ',') && chars.get(i + 1).is_some_and(|c| c.is_ascii_digit()))) {
            i += 1;
        }
        let n: String = chars[start..i].iter().collect();
        let percent = chars.get(i) == Some(&'%');
        let counting = n.parse::<u32>().is_ok_and(|v| v <= 10) && !percent;
        if !counting && !backing.contains(&n) && !out.iter().any(|o| o.contains(&format!("\"{n}\""))) {
            out.push(format!("the number \"{n}\" is not in the facts, so remove it or add it to facts"));
        }
    }
    out
}

/// Dashes, AI phrases and banned words, for any piece of text.
pub fn text_problems(text: &str, banned: &[String]) -> Vec<String> {
    let mut out = dash_problems(text);
    out.extend(ai_tell_problems(text));
    out.extend(banned_problems(text, banned));
    out
}

pub fn word_count(t: &str) -> usize {
    t.split_whitespace().count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dashes_are_caught() {
        assert!(!dash_problems("Wait \u{2014} what").is_empty());
        assert!(!dash_problems("one \u{2013} two").is_empty());
        assert!(!dash_problems("pause - then talk").is_empty());
        assert!(dash_problems("A 20-minute fix").is_empty());
    }

    #[test]
    fn ai_phrases_are_caught_on_word_boundaries() {
        assert!(!ai_tell_problems("Let's delve into it").is_empty());
        assert!(!ai_tell_problems("Here\u{2019}s the kicker: it works").is_empty());
        assert!(!ai_tell_problems("That's where Claude comes in").is_empty());
        assert!(ai_tell_problems("Fostering a realmente good habit").is_empty());
        assert!(ai_tell_problems("I paused before the key word and people listened.").is_empty());
    }

    #[test]
    fn brand_banned_words_are_caught() {
        let banned = vec!["Dive In".to_string(), "unlock".to_string()];
        assert_eq!(banned_problems("Let's dive in", &banned).len(), 1);
        assert!(banned_problems("unlocking nothing", &banned).is_empty());
        assert_eq!(text_problems("Unlock it \u{2014} now", &banned).len(), 3);
    }

    #[test]
    fn numbers_must_be_backed() {
        assert!(digit_problems("I tried 3 ways", "").is_empty(), "small counting numbers pass");
        assert_eq!(digit_problems("It cut 5% of the work", "").len(), 1, "percentages never pass unbacked");
        assert!(digit_problems("It cut 5% of the work", "5% fewer steps").is_empty());
        assert!(digit_problems("Over 3,000 people", "3,000 signups").is_empty());
        let p = digit_problems("It saved 47% and 12.5 hours", "12.5 hours saved");
        assert_eq!(p.len(), 1);
        assert!(p[0].contains("47"));
        assert!(digit_problems("No numbers here", "").is_empty());
    }
}
