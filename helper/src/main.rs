//! onote-helper: owns the Onote SQLite database on behalf of the
//! Omarchy shell plugin. Long-lived; speaks JSON lines over stdio; exits when
//! stdin closes. Schema, migrations, validation and the FTS index are the
//! Tauri edition's `db.rs`, compiled in by path (see src/db.rs).
mod db;
mod fsutil;
mod image;
mod markdown;
mod mirror;
mod preview;
mod welcome;
mod protocol;
mod search;

use db::{CustomTheme, Database, Note, NoteTab};
use protocol::{Request, Response};
use serde_json::{json, Value};
use std::io::{BufRead, Write};
use std::path::PathBuf;

const DEFAULT_CONTENT: &str = r#"[{"type":"text","content":""}]"#;

fn db_path() -> PathBuf {
    // Test and development override; only an absolute path is honoured and the
    // same private-directory rules apply to it.
    if let Some(p) = std::env::var_os("ONOTE_DB").map(PathBuf::from).filter(|p| p.is_absolute()) {
        return p;
    }
    let data_home = std::env::var_os("XDG_DATA_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| {
            let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"));
            home.join(".local/share")
        });
    data_home.join("com.desknotes.omarchy").join("desknotes.db")
}

/// The database and everything SQLite keeps beside it are private to this
/// user: a 0700 directory, files created 0600, older modes repaired.
fn prepare_private_db(path: &std::path::Path) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fsutil::ensure_private_dir(parent)?;
    }
    fsutil::create_private_if_missing(path)?;
    fsutil::make_private(path)?;
    for suffix in ["-wal", "-shm", "-journal"] {
        let mut side = path.as_os_str().to_owned();
        side.push(suffix);
        fsutil::make_private(std::path::Path::new(&side))?;
    }
    Ok(())
}

fn main() {
    let path = db_path();
    if let Err(e) = prepare_private_db(&path) {
        eprintln!("onote-helper: {e}");
        std::process::exit(2);
    }
    let db = match Database::new(&path) {
        Ok(db) => db,
        Err(e) => {
            eprintln!("onote-helper: cannot open {}: {e}", path.display());
            std::process::exit(2);
        }
    };
    eprintln!("onote-helper: ready on {}", path.display());

    let stdin = std::io::stdin();
    let stdout = std::io::stdout();
    let mut out = stdout.lock();
    for line in stdin.lock().lines() {
        let line = match line {
            Ok(l) => l,
            Err(_) => break,
        };
        if line.trim().is_empty() {
            continue;
        }
        let response = match serde_json::from_str::<Request>(&line) {
            Ok(req) => {
                let id = req.id.clone();
                match dispatch(&db, req) {
                    Ok(result) => Response::ok(id, result),
                    Err(e) => Response::err(id, e),
                }
            }
            Err(e) => Response::err(Value::Null, format!("malformed request: {e}")),
        };
        let mut text = serde_json::to_string(&response).unwrap_or_else(|e| {
            format!(r#"{{"id":null,"ok":false,"error":"serialize: {e}"}}"#)
        });
        text.push('\n');
        if out.write_all(text.as_bytes()).and_then(|_| out.flush()).is_err() {
            break;
        }
    }
}

fn arg_str<'a>(req: &'a Request, key: &str) -> Result<&'a str, String> {
    req.args
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("missing string field '{key}'"))
}

fn bounded_setting(db: &Database, key: &str, fallback: f64, min: f64, max: f64) -> f64 {
    db.get_setting(key)
        .ok()
        .flatten()
        .and_then(|v| v.trim().parse::<f64>().ok())
        .filter(|v| v.is_finite())
        .map(f64::trunc)
        .unwrap_or(fallback)
        .clamp(min, max)
}

fn all_notes(db: &Database) -> Result<Vec<Note>, String> {
    let mut notes = db.get_all_notes()?;
    notes.extend(db.get_piled_notes()?);
    Ok(notes)
}

const CLIPBOARD_DEADLINE: std::time::Duration = std::time::Duration::from_secs(5);
const WL_PASTE: &str = "/usr/bin/wl-paste";
const WL_COPY: &str = "/usr/bin/wl-copy";

/// Plain text from the Wayland clipboard: at most the note size limit, read
/// under a deadline. Empty when the clipboard holds none.
fn clipboard_text() -> Result<String, String> {
    match fsutil::run_bounded(&[WL_PASTE, "-n", "-t", "text"], db::MAX_NOTE_CONTENT_BYTES, CLIPBOARD_DEADLINE) {
        fsutil::Bounded::Ok(bytes) => Ok(String::from_utf8_lossy(&bytes).into_owned()),
        fsutil::Bounded::Failed => Ok(String::new()),
        fsutil::Bounded::TooLarge => Err("Clipboard text exceeds 5 MB".into()),
        fsutil::Bounded::TimedOut => Err("Clipboard did not answer".into()),
    }
}

/// An image from the Wayland clipboard as a `data:` URI block source, or None
/// when the clipboard holds no image. The byte cap is enforced while reading,
/// the dimension check refuses anything whose header cannot be read.
fn clipboard_image() -> Result<Option<Value>, String> {
    let offered = match fsutil::run_bounded(&[WL_PASTE, "-l"], 4096, CLIPBOARD_DEADLINE) {
        fsutil::Bounded::Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
        fsutil::Bounded::TimedOut => return Err("Clipboard did not answer".into()),
        _ => return Ok(None),
    };
    let offered: Vec<&str> = offered.lines().map(str::trim).collect();
    let Some(mime) = image::SUPPORTED.iter().copied().find(|m| offered.contains(m)) else { return Ok(None) };
    let bytes = match fsutil::run_bounded(&[WL_PASTE, "-t", mime], image::MAX_IMAGE_FILE_BYTES, CLIPBOARD_DEADLINE) {
        fsutil::Bounded::Ok(bytes) if !bytes.is_empty() => bytes,
        fsutil::Bounded::Ok(_) | fsutil::Bounded::Failed => return Ok(None),
        fsutil::Bounded::TooLarge => return Err("Image exceeds 2 MB".into()),
        fsutil::Bounded::TimedOut => return Err("Clipboard did not answer".into()),
    };
    let (w, h) = image::dimensions(mime, &bytes).ok_or("Image header could not be read")?;
    image::check_dimensions(w, h)?;
    Ok(Some(json!({
        "src": format!("data:{mime};base64,{}", image::base64(&bytes)),
        "mime": mime,
        "width": w,
        "height": h,
        "bytes": bytes.len(),
    })))
}

fn copy_to_clipboard(text: &str) -> Result<(), String> {
    fsutil::feed_detached(&[WL_COPY, "--"], text.as_bytes(), std::time::Duration::from_secs(3))
}

/// Blocks per note, matching the editor's cap.
const MAX_BLOCKS: usize = 2000;

/// One text block per line of captured text (blank lines kept, trailing ones
/// dropped, at most MAX_BLOCKS lines; the rest stays in the last block).
fn blocks_from_text(text: &str) -> String {
    let mut lines: Vec<&str> = text.lines().collect();
    while lines.last().is_some_and(|l| l.trim().is_empty()) {
        lines.pop();
    }
    if lines.is_empty() {
        return DEFAULT_CONTENT.to_string();
    }
    let mut blocks: Vec<Value> = lines.iter().take(MAX_BLOCKS - 1).map(|l| json!({ "type": "text", "content": l.trim_end() })).collect();
    if lines.len() >= MAX_BLOCKS {
        let rest = lines[MAX_BLOCKS - 1..].join("\n");
        blocks.push(json!({ "type": "text", "content": rest.trim_end() }));
    }
    Value::Array(blocks).to_string()
}

fn new_note(db: &Database, content_blocks: String) -> Result<Value, String> {
    if content_blocks.len() > db::MAX_NOTE_CONTENT_BYTES {
        return Err("Clipboard text exceeds 5 MB".into());
    }
    let id = uuid::Uuid::new_v4().to_string();
    let theme = db
        .get_setting("defaultTheme")
        .ok()
        .flatten()
        .filter(|t| !t.trim().is_empty())
        .unwrap_or_else(|| "system".to_string());
    let note = Note {
        id: id.clone(),
        title: String::new(),
        content_blocks,
        position_x: 200.0,
        position_y: 200.0,
        width: bounded_setting(db, "defaultNoteWidth", 300.0, 200.0, 4_000.0),
        height: bounded_setting(db, "defaultNoteHeight", 350.0, 150.0, 4_000.0),
        theme_name: theme,
        display_id: 0,
        z_order: 0,
        pinned: false,
        always_on_top: false,
        opacity: 1.0,
        // None: the window follows the shell's font size.
        font_size: db
            .get_setting("defaultFontSize")
            .ok()
            .flatten()
            .and_then(|v| v.trim().parse::<f64>().ok())
            .filter(|v| v.is_finite())
            .map(|v| v.clamp(10.0, 40.0) as i32),
        zoom: 100.0,
        icon: None,
        icon_size: None,
        piled: false,
        workspace_id: 0,
        workspace_name: String::new(),
        tab_icon: String::new(),
        created_at: String::new(),
        updated_at: String::new(),
    };
    db.create_note(&note)?;
    mirror::sync_note(db, &id);
    note_json(db, &id)
}

fn note_json(db: &Database, id: &str) -> Result<Value, String> {
    let note = db.get_note(id)?.ok_or("Note not found")?;
    serde_json::to_value(note).map_err(|e| e.to_string())
}

fn dispatch(db: &Database, req: Request) -> Result<Value, String> {
    match req.op.as_str() {
        "ping" => Ok(json!("pong")),

        // Open notes travel whole. Stacked notes travel as metadata plus a
        // bounded plain-text preview: the shell never holds every body at once.
        "listNotes" => {
            let mut rows = Vec::new();
            for note in all_notes(db)? {
                let mut v = serde_json::to_value(&note).map_err(|e| e.to_string())?;
                let obj = v.as_object_mut().ok_or("note is not an object")?;
                obj.insert("preview".into(), json!(preview::text(&note.content_blocks)));
                if note.piled {
                    obj.insert("contentBlocks".into(), json!(""));
                }
                rows.push(v);
            }
            Ok(Value::Array(rows))
        }

        "getNote" => {
            let id = arg_str(&req, "noteId")?;
            serde_json::to_value(db.get_note(id)?).map_err(|e| e.to_string())
        }

        "createNote" => new_note(db, DEFAULT_CONTENT.to_string()),

        "createNoteFromClipboard" => new_note(db, blocks_from_text(&clipboard_text()?)),

        "clipboardImage" => Ok(clipboard_image()?.unwrap_or(Value::Null)),

        // First launch: a pinned note with the most-used keys. `force` recreates it.
        "ensureWelcomeNote" => {
            let force = req.args.get("force").and_then(Value::as_bool).unwrap_or(false);
            let has_notes = !all_notes(db)?.is_empty();
            let shown = db.get_setting("welcomeCreated")?.as_deref() == Some("1");
            if !force && (has_notes || shown) {
                return Ok(Value::Null);
            }
            let num = |k: &str, d: f64| req.args.get(k).and_then(Value::as_f64).filter(|v| v.is_finite()).unwrap_or(d);
            let id = uuid::Uuid::new_v4().to_string();
            let mut note = welcome::note(&id);
            note.position_x = num("x", 40.0);
            note.position_y = num("y", 60.0);
            note.width = num("width", 380.0).clamp(200.0, 4_000.0);
            note.height = num("height", 560.0).clamp(150.0, 4_000.0);
            db.create_note(&note)?;
            db.set_setting("welcomeCreated", "1")?;
            mirror::sync_note(db, &id);
            note_json(db, &id)
        }

        "updateNote" => {
            let raw = req.args.get("note").ok_or("missing field 'note'")?;
            let note: Note = serde_json::from_value(raw.clone()).map_err(|e| format!("bad note: {e}"))?;
            db.update_note(&note)?;
            mirror::sync_note(db, &note.id);
            note_json(db, &note.id)
        }

        "deleteNote" => {
            let id = arg_str(&req, "noteId")?;
            mirror::remove(db, id);
            db.delete_note(id)?;
            Ok(json!(true))
        }

        "stackNote" => {
            let id = arg_str(&req, "noteId")?;
            db.pile_note(id)?;
            note_json(db, id)
        }

        "unstackNote" => {
            let id = arg_str(&req, "noteId")?;
            db.unpile_note(id)?;
            note_json(db, id)
        }

        "stackAll" => Ok(json!(db.set_all_notes_piled(true)?)),

        "restoreAll" => Ok(json!(db.set_all_notes_piled(false)?)),

        "search" => {
            let q = search::fts_query(arg_str(&req, "q")?);
            if q.is_empty() {
                return Ok(json!([]));
            }
            serde_json::to_value(db.search_notes_fts(&q)?).map_err(|e| e.to_string())
        }

        "searchNoteIds" => {
            let q = search::fts_query(arg_str(&req, "q")?);
            if q.is_empty() {
                return Ok(json!([]));
            }
            serde_json::to_value(db.search_note_ids_fts(&q)?).map_err(|e| e.to_string())
        }

        "getSetting" => serde_json::to_value(db.get_setting(arg_str(&req, "key")?)?).map_err(|e| e.to_string()),

        "setSetting" => {
            db.set_setting(arg_str(&req, "key")?, arg_str(&req, "value")?)?;
            Ok(json!(true))
        }

        "listSettings" => serde_json::to_value(db.get_all_settings()?).map_err(|e| e.to_string()),

        "listThemes" => serde_json::to_value(db.get_custom_themes()?).map_err(|e| e.to_string()),

        "saveTheme" => {
            let raw = req.args.get("theme").ok_or("missing field 'theme'")?;
            let theme: CustomTheme = serde_json::from_value(raw.clone()).map_err(|e| format!("bad theme: {e}"))?;
            db.save_custom_theme(&theme)?;
            Ok(json!(true))
        }

        "deleteTheme" => {
            db.delete_custom_theme(arg_str(&req, "themeId")?)?;
            Ok(json!(true))
        }

        "listTabs" => serde_json::to_value(db.list_tabs()?).map_err(|e| e.to_string()),

        "createTab" => {
            let note_id = arg_str(&req, "noteId")?;
            let id = uuid::Uuid::new_v4().to_string();
            let tab = db.create_tab(&id, note_id)?;
            mirror::sync_note(db, note_id);
            serde_json::to_value(tab).map_err(|e| e.to_string())
        }

        "updateTab" => {
            let raw = req.args.get("tab").ok_or("missing field 'tab'")?;
            let tab: NoteTab = serde_json::from_value(raw.clone()).map_err(|e| format!("bad tab: {e}"))?;
            db.update_tab(&tab)?;
            let saved = db.get_tab(&tab.id)?.ok_or("Tab not found")?;
            mirror::sync_note(db, &saved.note_id);
            serde_json::to_value(saved).map_err(|e| e.to_string())
        }

        "deleteTab" => {
            let id = arg_str(&req, "tabId")?;
            let note_id = db.get_tab(id)?.map(|t| t.note_id);
            db.delete_tab(id)?;
            if let Some(n) = note_id {
                mirror::sync_note(db, &n);
            }
            Ok(json!(true))
        }

        // Markdown mirror folder: a path turns it on and writes every note; "" or "off" turns it off.
        "setMirrorDir" => {
            let dir = arg_str(&req, "dir")?.trim().to_string();
            if dir.is_empty() || dir == "off" {
                db.set_setting(mirror::SETTING, "")?;
                return Ok(json!({ "dir": "", "written": 0 }));
            }
            db.set_setting(mirror::SETTING, &dir)?;
            match mirror::sync_all(db) {
                Ok(n) => Ok(json!({ "dir": mirror::expand_home(&dir).to_string_lossy(), "written": n })),
                Err(e) => {
                    db.set_setting(mirror::SETTING, "")?;
                    Err(format!("mirror not enabled: {e}"))
                }
            }
        }

        "copyMarkdown" => {
            let note = db.get_note(arg_str(&req, "noteId")?)?.ok_or("Note not found")?;
            let tabs = db.tabs_for(&note.id)?;
            let text = markdown::note_with_tabs_to_markdown(&note, &tabs);
            copy_to_clipboard(&text)?;
            Ok(json!(text.len()))
        }

        // Save one note as Markdown into ~/Documents/Onote (or `dir`); returns
        // the path. Never replaces a file: an occupied name gets " (2)", " (3)", …
        "exportNote" => {
            let note = db.get_note(arg_str(&req, "noteId")?)?.ok_or("Note not found")?;
            let tabs = db.tabs_for(&note.id)?;
            let dir = match req.args.get("dir").and_then(Value::as_str) {
                Some(d) if !d.trim().is_empty() => mirror::expand_home(d.trim()),
                _ => mirror::home().join("Documents").join("Onote"),
            };
            fsutil::ensure_owned_dir(&dir)?;
            let stem = mirror::safe_file_stem(&note.title, &note.id);
            let text = markdown::note_with_tabs_to_markdown(&note, &tabs);
            let mut last = String::new();
            for n in 1..100 {
                let name = if n == 1 { format!("{stem}.md") } else { format!("{stem} ({n}).md") };
                let path = dir.join(name);
                match fsutil::write_private_new(&path, text.as_bytes()) {
                    Ok(()) => return Ok(json!(path.to_string_lossy())),
                    Err(e) => last = e,
                }
            }
            Err(format!("no free file name for {stem} in {}: {last}", dir.display()))
        }

        "renderMarkdown" => {
            let note = db.get_note(arg_str(&req, "noteId")?)?.ok_or("Note not found")?;
            let tabs = db.tabs_for(&note.id)?;
            Ok(json!(markdown::note_with_tabs_to_markdown(&note, &tabs)))
        }

        other => Err(format!("unknown op '{other}'")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clipboard_lines_become_text_blocks() {
        assert_eq!(blocks_from_text(""), DEFAULT_CONTENT);
        assert_eq!(blocks_from_text("\n  \n"), DEFAULT_CONTENT);
        assert_eq!(
            blocks_from_text("+40 700 000 000 \n\nhttps://example.com\n\n"),
            r#"[{"content":"+40 700 000 000","type":"text"},{"content":"","type":"text"},{"content":"https://example.com","type":"text"}]"#
        );
    }
}
