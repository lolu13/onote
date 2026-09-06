//! The note a new user sees first: pinned on every workspace, listing the
//! most-used keys as label blocks and a short "try it" checklist. Keep in step
//! with KEYBINDINGS.md and omarchy-plugin/hypr/desknotes.lua.
use crate::db::Note;
use serde_json::{json, Value};

fn heading(text: &str) -> Value { json!({ "type": "subtitle", "content": text }) }
fn key(label: &str, what: &str) -> Value { json!({ "type": "label", "label": label, "content": what }) }
fn todo(text: &str) -> Value { json!({ "type": "todo", "content": text, "checked": false }) }
fn text(text: &str) -> Value { json!({ "type": "text", "content": text }) }

pub fn blocks() -> Vec<Value> {
    vec![
        text("This note is pinned: it stays on top on every workspace, so switch away and try the keys."),
        heading("Notes"),
        key("Super+N", "Notes & Stack: search, open, restore"),
        key("Super+Alt+N", "New note (opens on this workspace)"),
        key("Super+Alt+V", "New note from the clipboard text"),
        key("Super+W", "Put the note in the stack (Ctrl+W on its last tab too)"),
        key("Super+Shift+1…9", "Move a note to a workspace; it reopens there"),
        key("Super+Alt+P", "Pin / unpin on every workspace (this note is pinned)"),
        key("Super+Alt+S", "Send to the scratchpad · Super+S shows or hides it"),
        heading("Tabs"),
        key("Ctrl+T", "New tab · Ctrl+W closes it"),
        key("Ctrl+Tab", "Next tab · Ctrl+Shift+Tab previous · Ctrl+1…9 jump"),
        key("Ctrl+Shift+I", "Give the tab an icon (or right-click it)"),
        heading("Writing"),
        key("/", "Block types: to-do, bullet, heading, code, label…"),
        key("Ctrl+Enter", "Tick a to-do · Ctrl+V pastes text or an image"),
        key("Ctrl+= / Ctrl+-", "Text size · Ctrl+Shift+T theme · Ctrl+, settings"),
        heading("Try it"),
        todo("Press Super+Alt+N and type a note"),
        todo("Press Ctrl+T here, then Ctrl+Tab back"),
        todo("Switch workspace: this note follows you"),
        todo("Press Super+Alt+P to unpin it, then Super+W to stack it"),
        todo("Press Super+N and find it in the stack"),
    ]
}

pub fn note(id: &str) -> Note {
    Note {
        id: id.into(),
        title: "Welcome to DeskNotes".into(),
        content_blocks: Value::Array(blocks()).to_string(),
        position_x: 40.0,
        position_y: 60.0,
        width: 380.0,
        height: 560.0,
        theme_name: "system".into(),
        display_id: 0,
        z_order: 0,
        pinned: true,
        always_on_top: false,
        opacity: 1.0,
        font_size: None,
        zoom: 100.0,
        icon: None,
        icon_size: None,
        piled: false,
        workspace_id: 0,
        workspace_name: String::new(),
        tab_icon: "\u{f0eb}".into(),
        created_at: String::new(),
        updated_at: String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn welcome_note_is_pinned_and_every_shipped_bind_is_mentioned() {
        let n = note("w");
        assert!(n.pinned && n.title == "Welcome to DeskNotes");
        let body = n.content_blocks.clone();
        for k in ["Super+N", "Super+Alt+N", "Super+Alt+V", "Super+Alt+P", "Super+Alt+S", "Ctrl+T", "Ctrl+Tab", "Ctrl+Shift+I"] {
            assert!(body.contains(k), "welcome note should mention {k}");
        }
        let parsed: Vec<Value> = serde_json::from_str(&body).unwrap();
        assert!(parsed.iter().filter(|b| b["type"] == "todo").count() >= 4);
        assert!(body.len() < 4_000, "stays a small note");
    }
}
