//! Ported from `src-tauri/src/lib.rs` (`note_to_markdown`). Keep in sync.
use crate::db::{Note, NoteTab};

pub fn note_to_markdown(note: &Note) -> String {
    let mut md = String::new();
    if !note.title.is_empty() {
        md.push_str(&format!("# {}\n\n", note.title));
    }
    blocks_to_markdown(&note.content_blocks, &mut md);
    md
}

/// The note followed by each extra tab as its own section.
pub fn note_with_tabs_to_markdown(note: &Note, tabs: &[NoteTab]) -> String {
    let mut md = note_to_markdown(note);
    for tab in tabs {
        md.push_str(&format!("\n---\n\n<!-- tab {} -->\n", tab.position + 1));
        blocks_to_markdown(&tab.content_blocks, &mut md);
    }
    md
}

/// A backtick fence longer than any backtick run in `content`, so a code
/// block can hold "```" lines: a closing fence needs at least as many
/// backticks as the opening one (CommonMark 4.5), and the fixed three closed
/// the block early, leaving the rest of the note read as plain Markdown.
fn code_fence(content: &str) -> String {
    let (mut longest, mut run) = (0usize, 0usize);
    for c in content.chars() {
        if c == '`' { run += 1; longest = longest.max(run); } else { run = 0; }
    }
    "`".repeat((longest + 1).max(3))
}

/// CommonMark reads a line followed by `---` as a setext heading and a line
/// after a list item as its continuation, so a divider gets a blank line
/// before it and a list run a blank line after it.
fn blocks_to_markdown(content_blocks: &str, md: &mut String) {
    if let Ok(blocks) = serde_json::from_str::<Vec<serde_json::Value>>(content_blocks) {
        let mut in_list = false;
        for block in blocks {
            let btype = block.get("type").and_then(|v| v.as_str()).unwrap_or("text");
            let content = block.get("content").and_then(|v| v.as_str()).unwrap_or("");
            let is_list = matches!(btype, "bullet" | "todo");
            if (in_list && !is_list) || (btype == "divider" && !md.is_empty() && !md.ends_with("\n\n")) {
                md.push('\n');
            }
            in_list = is_list;
            match btype {
                "text" => {
                    md.push_str(content);
                    md.push('\n');
                }
                "subtitle" => md.push_str(&format!("## {}\n", content)),
                "bullet" => md.push_str(&format!("- {}\n", content)),
                "todo" => {
                    let checked = block.get("checked").and_then(|v| v.as_bool()).unwrap_or(false);
                    md.push_str(&format!("- [{}] {}\n", if checked { "x" } else { " " }, content));
                }
                "code" => {
                    let fence = code_fence(content);
                    md.push_str(&format!("{fence}\n{content}\n{fence}\n"));
                }
                "label" => {
                    let label = block.get("label").and_then(|v| v.as_str()).unwrap_or("");
                    md.push_str(&format!("**{}**: {}\n", label, content));
                }
                "divider" => md.push_str("---\n"),
                "image" => md.push_str("![image](embedded)\n"),
                _ => {
                    md.push_str(content);
                    md.push('\n');
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_fence_outgrows_backticks_in_content() {
        let mut md = String::new();
        blocks_to_markdown(r#"[{"type":"code","content":"x\n```\ny"},{"type":"todo","content":"after"}]"#, &mut md);
        assert_eq!(md, "````\nx\n```\ny\n````\n- [ ] after\n");
        let mut md = String::new();
        blocks_to_markdown(r#"[{"type":"code","content":"a `````b"}]"#, &mut md);
        assert_eq!(md, "``````\na `````b\n``````\n");
        assert_eq!(code_fence(""), "```");
    }

    // A line before `---` would be a setext heading, a line after a list item
    // its continuation: blank lines keep a divider a divider and a list a list.
    #[test]
    fn dividers_and_list_ends_get_a_blank_line() {
        let mut md = String::new();
        blocks_to_markdown(r#"[{"type":"text","content":"Shopping"},{"type":"divider"},{"type":"bullet","content":"Milk"},{"type":"todo","content":"Eggs"},{"type":"text","content":"Call"},{"type":"divider"},{"type":"divider"}]"#, &mut md);
        assert_eq!(md, "Shopping\n\n---\n- Milk\n- [ ] Eggs\n\nCall\n\n---\n\n---\n");
        let mut md = String::new();
        blocks_to_markdown(r#"[{"type":"divider"},{"type":"bullet","content":"a"}]"#, &mut md);
        assert_eq!(md, "---\n- a\n", "a leading divider needs nothing before it");
    }

    #[test]
    fn renders_every_block_type() {
        let note = Note {
            id: "x".into(),
            title: "T".into(),
            content_blocks: r#"[{"type":"text","content":"a"},{"type":"subtitle","content":"b"},
                {"type":"bullet","content":"c"},{"type":"todo","content":"d","checked":true},
                {"type":"code","content":"e"},{"type":"label","label":"L","content":"f"},
                {"type":"divider"},{"type":"image","src":"data:"}]"#.into(),
            position_x: 0.0, position_y: 0.0, width: 1.0, height: 1.0,
            theme_name: "system".into(), display_id: 0, z_order: 0, pinned: false,
            always_on_top: false, opacity: 1.0, font_size: None, zoom: 100.0,
            icon: None, icon_size: None, piled: false,
            workspace_id: 0, workspace_name: String::new(), tab_icon: String::new(),
            created_at: String::new(), updated_at: String::new(),
        };
        assert_eq!(
            note_to_markdown(&note),
            "# T\n\na\n## b\n- c\n- [x] d\n\n```\ne\n```\n**L**: f\n\n---\n![image](embedded)\n"
        );
        let tab = NoteTab {
            id: "t".into(), note_id: "x".into(), position: 1, icon: String::new(),
            content_blocks: r#"[{"type":"todo","content":"page two"}]"#.into(),
            created_at: String::new(), updated_at: String::new(),
        };
        assert_eq!(
            note_with_tabs_to_markdown(&note, &[tab]),
            format!("{}\n---\n\n<!-- tab 2 -->\n- [ ] page two\n", note_to_markdown(&note))
        );
    }
}
