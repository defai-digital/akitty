use serde::Serialize;
use serde_json::{Value, json};
use unicode_normalization::UnicodeNormalization;

const MAX_QUERY_BYTES: usize = 512;
const MAX_QUERY_CHARS: usize = 128;

#[derive(Serialize)]
struct Command {
    id: &'static str,
    title: &'static str,
    shortcut: &'static str,
    keywords: &'static [&'static str],
}

const COMMANDS: &[Command] = &[
    Command { id: "new-window", title: "New Window", shortcut: "⌘N", keywords: &["terminal", "shell"] },
    Command { id: "new-tab", title: "New Tab", shortcut: "⌘T", keywords: &["terminal", "shell"] },
    Command { id: "split", title: "Split Pane", shortcut: "⌘D", keywords: &["vertical", "side by side"] },
    Command { id: "close-pane", title: "Close Pane", shortcut: "⌘W", keywords: &["close", "shell"] },
    Command { id: "copy", title: "Copy Selection", shortcut: "⌘C", keywords: &["clipboard", "shell"] },
    Command { id: "paste", title: "Paste Text", shortcut: "⌘V", keywords: &["clipboard"] },
    Command { id: "find", title: "Find in Scrollback", shortcut: "⌘F", keywords: &["search", "history"] },
    Command { id: "find-next", title: "Find Next", shortcut: "⌘G", keywords: &["search", "next"] },
    Command { id: "find-previous", title: "Find Previous", shortcut: "⌘⇧G", keywords: &["search", "previous"] },
    Command { id: "find-all", title: "Find in All Terminals", shortcut: "⌥⌘F", keywords: &["search", "all", "tabs", "windows"] },
    Command { id: "font-increase", title: "Increase Font Size", shortcut: "⌘+", keywords: &["zoom", "larger"] },
    Command { id: "font-decrease", title: "Decrease Font Size", shortcut: "⌘−", keywords: &["zoom", "smaller"] },
    Command { id: "font-reset", title: "Reset Font Size", shortcut: "⌘0", keywords: &["zoom", "default"] },
    Command { id: "agent-overview", title: "Agent Overview", shortcut: "⌥⌘A", keywords: &["agents", "control", "reclaim", "sessions"] },
];

pub fn search(input: &str) -> Result<Value, String> {
    if input.len() > MAX_QUERY_BYTES { return Err("palette query exceeds 512 bytes".into()); }
    let needle = normalize(input).chars().take(MAX_QUERY_CHARS).collect::<Vec<_>>();
    if needle.is_empty() { return Ok(envelope(COMMANDS.iter().collect())); }
    let contiguous = needle.iter().collect::<String>();

    let mut ranked = Vec::new();
    for (index, command) in COMMANDS.iter().enumerate() {
        let searchable = format!("{} {} {}", command.title, command.id, command.keywords.join(" "));
        let haystack = normalize(&searchable);
        let (sparse, distance) = if let Some(offset) = haystack.find(&contiguous) {
            (false, offset)
        } else {
            let haystack = haystack.chars().collect::<Vec<_>>();
            let Some(skipped) = alignment_score(&needle, &haystack) else { continue; };
            (true, skipped)
        };
        ranked.push(((sparse, distance, index), command));
    }
    ranked.sort_by_key(|(rank, _)| *rank);
    Ok(envelope(ranked.into_iter().map(|(_, command)| command).collect()))
}

fn envelope(commands: Vec<&Command>) -> Value {
    json!({"version": 1, "commands": commands})
}

fn normalize(input: &str) -> String {
    let line = input.chars().map(|character| match character {
        '\u{0000}'..='\u{001f}' | '\u{007f}'..='\u{009f}' | '\u{2028}' | '\u{2029}' => ' ',
        character => character,
    }).collect::<String>();
    line.trim().nfkc().flat_map(char::to_lowercase).collect()
}

/// Counts candidate characters skipped before an ordered query match. Characters
/// after the final matched character are free, so unrelated suffixes do not affect rank.
fn alignment_score(needle: &[char], haystack: &[char]) -> Option<usize> {
    const UNMATCHED: usize = usize::MAX;
    let mut previous = vec![0; haystack.len() + 1];
    for wanted in needle {
        let mut current = vec![UNMATCHED; haystack.len() + 1];
        for column in 1..=haystack.len() {
            if current[column - 1] != UNMATCHED { current[column] = current[column - 1] + 1; }
            if haystack[column - 1] == *wanted { current[column] = current[column].min(previous[column - 1]); }
        }
        previous = current;
    }
    previous.into_iter().min().filter(|score| *score != UNMATCHED)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(input: &str) -> Vec<String> {
        search(input).unwrap()["commands"].as_array().unwrap().iter()
            .map(|command| command["id"].as_str().unwrap().to_owned()).collect()
    }

    #[test]
    fn empty_query_returns_the_complete_catalog_in_declaration_order() {
        let result = search("").unwrap();
        assert_eq!(result["version"], 1);
        assert_eq!(result["commands"].as_array().unwrap().len(), 14);
        assert_eq!(ids("").first().map(String::as_str), Some("new-window"));
        assert_eq!(result["commands"][7]["shortcut"], "⌘G");
        assert_eq!(result["commands"][8]["shortcut"], "⌘⇧G");
        assert_eq!(result["commands"][9]["shortcut"], "⌥⌘F");
        assert_eq!(ids(""), ids(""));
    }

    #[test]
    fn contiguous_matches_outrank_ordered_character_alignment() {
        assert_eq!(ids("split").first().map(String::as_str), Some("split"));
        assert_eq!(ids("side").first().map(String::as_str), Some("split"));
        assert_eq!(ids("next").first().map(String::as_str), Some("find-next"));
        assert_eq!(ids("previous").first().map(String::as_str), Some("find-previous"));
        assert_eq!(ids("agent").first().map(String::as_str), Some("agent-overview"));
        assert_eq!(ids("reclaim").first().map(String::as_str), Some("agent-overview"));
    }

    #[test]
    fn unicode_normalization_and_sparse_queries_are_supported() {
        assert_eq!(ids("ｓｐｌｉｔ").first().map(String::as_str), Some("split"));
        assert_eq!(ids("nwtab").first().map(String::as_str), Some("new-tab"));
        assert!(ids("🚀unknown").is_empty());
        assert_eq!(ids("\u{0} split \u{2028}"), ids("split"));
    }

    #[test]
    fn alignment_chooses_the_least_sparse_match() {
        assert_eq!(alignment_score(&['a', 'b'], &['a', 'x', 'x', 'b']), Some(2));
        assert_eq!(alignment_score(&['a', 'b'], &['a', 'b', 'x', 'x']), Some(0));
        assert_eq!(alignment_score(&['z'], &['a', 'b']), None);
    }

    #[test]
    fn query_input_is_bounded_and_truncated_deterministically() {
        assert!(search(&"x".repeat(513)).is_err());
        assert_eq!(ids(&"x".repeat(128)), ids(&"x".repeat(129)));
        assert_eq!(ids(&"ｓ".repeat(128)), ids(&"ｓ".repeat(129)));
    }
}
