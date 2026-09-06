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

fn blocks_to_markdown(content_blocks: &str, md: &mut String) {
    if let Ok(blocks) = serde_json::from_str::<Vec<serde_json::Value>>(content_blocks) {
        for block in blocks {
            let btype = block.get("type").and_then(|v| v.as_str()).unwrap_or("text");
            let content = block.get("content").and_then(|v| v.as_str()).unwrap_or("");
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
                "code" => md.push_str(&format!("```\n{}\n```\n", content)),
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
            "# T\n\na\n## b\n- c\n- [x] d\n```\ne\n```\n**L**: f\n---\n![image](embedded)\n"
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
