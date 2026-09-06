//! Plain-text preview of a note body for the Notes & Stack list, computed here
//! so stacked notes travel without their full content. Mirrors the shell's
//! NotePreview.js: same separators, same 400-character bound.
use serde_json::Value;

pub const LIMIT: usize = 400;

fn take(s: &str, n: usize) -> &str {
    match s.char_indices().nth(n) {
        Some((i, _)) => &s[..i],
        None => s,
    }
}

pub fn text(content_blocks: &str) -> String {
    let Ok(Value::Array(blocks)) = serde_json::from_str::<Value>(content_blocks) else { return String::new() };
    let mut out = String::new();
    for b in blocks {
        if out.chars().count() >= LIMIT {
            break;
        }
        let kind = b.get("type").and_then(Value::as_str).unwrap_or("");
        let content = b.get("content").and_then(Value::as_str).unwrap_or("");
        let part = match kind {
            "image" => "[image]".to_string(),
            "divider" => "—".to_string(),
            "label" => {
                let label = b.get("label").and_then(Value::as_str).unwrap_or("");
                format!("{}: {}", take(label, LIMIT), take(content, LIMIT))
            }
            _ if !content.is_empty() => take(content, LIMIT).to_string(),
            _ => continue,
        };
        if part.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push_str("  ·  ");
        }
        let room = LIMIT.saturating_sub(out.chars().count());
        out.push_str(take(&part, room));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn preview_joins_blocks_and_stays_bounded() {
        let blocks = r#"[{"type":"text","content":"hello"},{"type":"image","src":"x"},{"type":"label","label":"Tag","content":"v"},{"type":"divider"},{"type":"text","content":""}]"#;
        assert_eq!(text(blocks), "hello  ·  [image]  ·  Tag: v  ·  —");
        let long = format!(r#"[{{"type":"text","content":"{}"}},{{"type":"text","content":"more"}}]"#, "é".repeat(500));
        assert_eq!(text(&long).chars().count(), LIMIT);
        assert_eq!(text("not json"), "");
        assert_eq!(text("{}"), "");
    }
}
