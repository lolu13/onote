//! One-way Markdown mirror: every note is also a `.md` file in a folder of the
//! user's choice (for example an Obsidian vault). Files are written, renamed and
//! removed by the helper and never read back; the database stays the source of
//! truth. Best effort: a failing write is logged and never fails the edit.
use crate::db::{Database, Note, NoteTab};
use crate::markdown;
use std::path::{Path, PathBuf};

pub const SETTING: &str = "markdownMirrorDir";

pub fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/"))
}

pub fn expand_home(raw: &str) -> PathBuf {
    if raw == "~" {
        home()
    } else if let Some(rest) = raw.strip_prefix("~/") {
        home().join(rest)
    } else {
        PathBuf::from(raw)
    }
}

/// The configured folder, or None when the mirror is off.
pub fn dir(db: &Database) -> Option<PathBuf> {
    let raw = db.get_setting(SETTING).ok().flatten()?;
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    Some(expand_home(raw))
}

fn short_id(id: &str) -> String {
    id.replace('-', "").chars().take(12).collect()
}

/// A file name from a title: no path separators or characters Windows/Obsidian
/// reject, collapsed whitespace, at most 80 chars; untitled notes use their id.
pub fn safe_file_stem(title: &str, id: &str) -> String {
    let cleaned: String = title
        .chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|' | '\n' | '\r' | '\t' | '#' | '^' | '[' | ']' => ' ',
            c => c,
        })
        .collect();
    let cleaned = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    let cleaned: String = cleaned.chars().take(80).collect();
    let cleaned = cleaned.trim().trim_end_matches('.').trim().to_string();
    if cleaned.is_empty() {
        format!("Untitled {}", short_id(id))
    } else {
        cleaned
    }
}

/// Mirror file contents: a small front matter block, then the note and its tabs.
pub fn document(note: &Note, tabs: &[NoteTab]) -> String {
    format!(
        "---\nid: {}\ncreated: {}\nupdated: {}\nsource: DeskNotes\n---\n\n{}",
        note.id,
        note.created_at,
        note.updated_at,
        markdown::note_with_tabs_to_markdown(note, tabs)
    )
}

fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    crate::fsutil::write_private_atomic(path, text.as_bytes())
}

/// True when the file at `path` is a mirror file written for `note_id`: it
/// starts with our front matter and names that id. Anything else (a document
/// the user already had, another note's file) is never touched.
fn file_belongs_to(path: &Path, note_id: &str) -> bool {
    let Some(head) = crate::fsutil::read_owned_head(path, 256) else { return false };
    let head = String::from_utf8_lossy(&head);
    head.starts_with("---\n") && head.contains(&format!("\nid: {note_id}\n"))
}

/// The file this note may be written to: its current file when the name still
/// fits, else the first candidate no other note owns and no foreign file sits
/// at. Ownership is decided by the tracking table and, for untracked files,
/// by the front matter, so a real document in the folder is never replaced.
fn allocate_path(db: &Database, dir: &Path, note: &Note) -> Result<PathBuf, String> {
    let stem = safe_file_stem(&note.title, &note.id);
    let short = short_id(&note.id);
    let mut candidates = vec![format!("{stem}.md"), format!("{stem} {short}.md")];
    for n in 2..100 {
        candidates.push(format!("{stem} {short}-{n}.md"));
    }
    for name in candidates {
        let path = dir.join(name);
        let key = path.to_string_lossy();
        match db.mirror_path_owner(&key)? {
            Some(owner) if owner == note.id => return Ok(path),
            Some(_) => continue,
            None => {}
        }
        // lstat: a dangling or planted symlink counts as occupied.
        let occupied = std::fs::symlink_metadata(&path).is_ok();
        if !occupied || file_belongs_to(&path, &note.id) {
            return Ok(path);
        }
    }
    Err(format!("no free mirror file name for {stem} in {}", dir.display()))
}

fn sync_note_in(db: &Database, dir: &Path, note_id: &str) -> Result<(), String> {
    let Some(note) = db.get_note(note_id)? else {
        return remove_in(db, note_id);
    };
    crate::fsutil::ensure_owned_dir(dir)?;
    let path = allocate_path(db, dir, &note)?;
    if let Some(old) = db.mirror_path(&note.id)? {
        let old = Path::new(&old);
        if old != path && file_belongs_to(old, &note.id) {
            let _ = std::fs::remove_file(old);
        }
    }
    let tabs = db.tabs_for(&note.id)?;
    write_atomic(&path, &document(&note, &tabs))?;
    db.set_mirror_path(&note.id, &path.to_string_lossy())
}

fn remove_in(db: &Database, note_id: &str) -> Result<(), String> {
    if let Some(old) = db.mirror_path(note_id)? {
        if file_belongs_to(Path::new(&old), note_id) {
            let _ = std::fs::remove_file(&old);
        }
        db.clear_mirror_path(note_id)?;
    }
    Ok(())
}

/// Write (or rewrite) one note's file. No-op when the mirror is off.
pub fn sync_note(db: &Database, note_id: &str) {
    let Some(dir) = dir(db) else { return };
    if let Err(e) = sync_note_in(db, &dir, note_id) {
        eprintln!("desknotes-helper: mirror {note_id}: {e}");
    }
}

/// Remove a note's file. Call before deleting the note; the row cascades.
pub fn remove(db: &Database, note_id: &str) {
    if dir(db).is_none() {
        return;
    }
    if let Err(e) = remove_in(db, note_id) {
        eprintln!("desknotes-helper: mirror remove {note_id}: {e}");
    }
}

/// Write every note. Errors are returned here because the user asked for it.
pub fn sync_all(db: &Database) -> Result<usize, String> {
    let Some(dir) = dir(db) else { return Ok(0) };
    let ids = db.all_note_ids()?;
    for id in &ids {
        sync_note_in(db, &dir, id)?;
    }
    Ok(ids.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn temp_dir() -> PathBuf {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let d = std::env::temp_dir().join(format!("desknotes-mirror-test-{}-{n}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        d
    }

    fn db() -> Database {
        Database::new(Path::new(":memory:")).unwrap()
    }

    fn note(id: &str, title: &str) -> Note {
        Note {
            id: id.into(), title: title.into(), content_blocks: r#"[{"type":"text","content":"body"}]"#.into(),
            position_x: 0.0, position_y: 0.0, width: 300.0, height: 350.0, theme_name: "system".into(),
            display_id: 0, z_order: 0, pinned: false, always_on_top: false, opacity: 1.0, font_size: None,
            zoom: 100.0, icon: None, icon_size: None, piled: false, workspace_id: 0,
            workspace_name: String::new(), tab_icon: String::new(), created_at: String::new(), updated_at: String::new(),
        }
    }

    #[test]
    fn file_stems_are_safe_and_untitled_uses_the_id() {
        assert_eq!(safe_file_stem("  Plan: A/B  <draft>? ", "x"), "Plan A B draft");
        assert_eq!(safe_file_stem("", "7fb70d54-b3f1-4960-b2ae-e8d858452f0f"), "Untitled 7fb70d54b3f1");
        assert_eq!(safe_file_stem("...", "abc"), "Untitled abc");
        assert_eq!(safe_file_stem(&"x".repeat(200), "a").chars().count(), 80);
    }

    #[test]
    fn mirror_writes_renames_disambiguates_and_removes() {
        let db = db();
        let dir = temp_dir();
        assert_eq!(sync_all(&db).unwrap(), 0, "off by default");
        db.create_notes(&[note("a", "Groceries"), note("b", "Groceries"), note("c", "")]).unwrap();
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 3);
        let names = || {
            let mut v: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
            v.sort();
            v
        };
        assert_eq!(names(), vec!["Groceries b.md", "Groceries.md", "Untitled c.md"]);
        let text = std::fs::read_to_string(dir.join("Groceries.md")).unwrap();
        assert!(text.starts_with("---\nid: a\n") && text.contains("# Groceries\n\nbody\n"), "{text}");

        let mut a = db.get_note("a").unwrap().unwrap();
        a.title = "Shopping".into();
        db.update_note(&a).unwrap();
        sync_note(&db, "a");
        assert_eq!(names(), vec!["Groceries b.md", "Shopping.md", "Untitled c.md"], "renamed, old file gone");

        db.create_tab("t", "a").unwrap();
        sync_note(&db, "a");
        assert!(std::fs::read_to_string(dir.join("Shopping.md")).unwrap().contains("<!-- tab 2 -->"));

        remove(&db, "b");
        db.delete_note("b").unwrap();
        assert_eq!(names(), vec!["Shopping.md", "Untitled c.md"]);

        db.set_setting(SETTING, "").unwrap();
        a.title = "Ignored while off".into();
        db.update_note(&a).unwrap();
        sync_note(&db, "a");
        assert_eq!(names(), vec!["Shopping.md", "Untitled c.md"], "mirror off leaves files alone");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn mirror_never_replaces_or_deletes_files_it_did_not_write() {
        let db = db();
        let dir = temp_dir();
        std::fs::create_dir_all(&dir).unwrap();
        // A document the user already keeps in the vault, plus a stray file at
        // the fallback name, neither written by DeskNotes.
        std::fs::write(dir.join("Plan.md"), "USER DOCUMENT").unwrap();
        std::fs::write(dir.join("Plan a.md"), "ANOTHER USER DOCUMENT").unwrap();
        db.create_notes(&[note("a", "Plan")]).unwrap();
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 1);
        assert_eq!(std::fs::read_to_string(dir.join("Plan.md")).unwrap(), "USER DOCUMENT");
        assert_eq!(std::fs::read_to_string(dir.join("Plan a.md")).unwrap(), "ANOTHER USER DOCUMENT");
        let own = dir.join("Plan a-2.md");
        assert!(std::fs::read_to_string(&own).unwrap().starts_with("---\nid: a\n"));
        assert_eq!(db.mirror_path("a").unwrap().as_deref(), own.to_str());

        // Deleting the note removes only its own file.
        remove(&db, "a");
        db.delete_note("a").unwrap();
        assert!(!own.exists());
        assert!(dir.join("Plan.md").exists() && dir.join("Plan a.md").exists());

        // A note whose tracking row is gone (rebuilt database) reclaims its
        // own file through the front matter instead of leaving a copy.
        db.create_notes(&[note("b", "Notes")]).unwrap();
        sync_note(&db, "b");
        db.clear_mirror_path("b").unwrap();
        sync_note(&db, "b");
        let mut v: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().into_string().unwrap()).collect();
        v.sort();
        assert_eq!(v, vec!["Notes.md", "Plan a.md", "Plan.md"]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn planted_symlink_or_fifo_never_reaches_another_file() {
        let db = db();
        let dir = temp_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let victim = dir.join("victim.txt");
        std::fs::write(&victim, "must survive").unwrap();
        // The note's own name, its temp sibling shape and its fallback name are all planted.
        std::os::unix::fs::symlink(&victim, dir.join("Plan.md")).unwrap();
        std::os::unix::fs::symlink(&victim, dir.join("Plan.md.tmp")).unwrap();
        let fifo = std::ffi::CString::new(dir.join("Plan a.md").to_str().unwrap()).unwrap();
        assert_eq!(unsafe { libc::mkfifo(fifo.as_ptr(), 0o600) }, 0);
        db.create_notes(&[note("a", "Plan")]).unwrap();
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 1);
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "must survive");
        assert!(std::fs::symlink_metadata(dir.join("Plan.md")).unwrap().file_type().is_symlink(), "left alone");
        let own = dir.join("Plan a-2.md");
        assert!(std::fs::read_to_string(&own).unwrap().starts_with("---\nid: a\n"));
        assert_eq!(std::os::unix::fs::PermissionsExt::mode(&std::fs::metadata(&own).unwrap().permissions()) & 0o777, 0o600);
        // A symlink planted at the tracked path later is not followed on removal.
        std::fs::remove_file(&own).unwrap();
        std::os::unix::fs::symlink(&victim, &own).unwrap();
        remove(&db, "a");
        assert!(victim.exists() && std::fs::symlink_metadata(&own).is_ok(), "the planted link and its target survive");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn fallback_name_owned_by_another_note_is_not_stolen() {
        let db = db();
        let dir = temp_dir();
        // "c" is titled exactly like "b"'s fallback name, and is mirrored first.
        let b_short = short_id("bbbbbbbb-0000-0000-0000-000000000000");
        db.create_notes(&[
            note("aaaaaaaa-0000-0000-0000-000000000000", "Collision"),
            note("cccccccc-0000-0000-0000-000000000000", &format!("Collision {b_short}")),
            note("bbbbbbbb-0000-0000-0000-000000000000", "Collision"),
        ])
        .unwrap();
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 3);
        let owned = dir.join(format!("Collision {b_short}.md"));
        assert!(std::fs::read_to_string(&owned).unwrap().contains("id: cccccccc-"), "c keeps its file");
        assert_eq!(db.mirror_path_owner(owned.to_str().unwrap()).unwrap().as_deref(), Some("cccccccc-0000-0000-0000-000000000000"));
        let b_path = db.mirror_path("bbbbbbbb-0000-0000-0000-000000000000").unwrap().unwrap();
        assert!(b_path.ends_with(&format!("Collision {b_short}-2.md")), "{b_path}");
        // The tracking table refuses to hand one path to two notes.
        assert!(db.set_mirror_path("aaaaaaaa-0000-0000-0000-000000000000", &b_path).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
