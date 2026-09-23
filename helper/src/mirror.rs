//! One-way Markdown mirror: every note is also a `.md` file in a folder of the
//! user's choice (for example an Obsidian vault). Files are written, renamed and
//! removed by the helper and never read back; the database stays the source of
//! truth. Best effort: a failing write is logged and never fails the edit.
use crate::db::{Database, Note, NoteTab};
use crate::markdown;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

/// The same file under two spellings (`vault` and `vault/../vault`, a
/// symlinked folder): the old path is then the new file, never to be removed.
fn same_file(a: &Path, b: &Path) -> bool {
    if a == b {
        return true;
    }
    match (std::fs::metadata(a), std::fs::metadata(b)) {
        (Ok(x), Ok(y)) => x.dev() == y.dev() && x.ino() == y.ino(),
        _ => false,
    }
}

pub const SETTING: &str = "markdownMirrorDir";
/// Longest file stem in bytes; see `safe_file_stem`.
const MAX_STEM_BYTES: usize = 190;

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
    // 80 characters, and at most MAX_STEM_BYTES bytes: the file system counts
    // bytes (NAME_MAX 255), an emoji is four of them, and the name still has
    // to carry the longest suffix (" <12 hex>-99.md") and the atomic
    // temporary's overhead (".<name>.<32 hex>.tmp", 38 bytes): 255 - 38 - 19 = 198.
    let mut cleaned: String = cleaned.chars().take(80).collect();
    while cleaned.len() > MAX_STEM_BYTES {
        cleaned.pop();   // one character, never half of one
    }
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
        "---\nid: {}\ncreated: {}\nupdated: {}\nsource: Onote\n---\n\n{}",
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
            // Our tracked path, as long as what sits there (if anything) is
            // still our file: the user may have deleted it and put an
            // unrelated document, or a symlink, under the same name since.
            Some(owner) if owner == note.id => {
                if std::fs::symlink_metadata(&path).is_err() || file_belongs_to(&path, &note.id) {
                    return Ok(path);
                }
                continue;
            }
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
    let old = db.mirror_path(&note.id)?;
    let tabs = db.tabs_for(&note.id)?;
    // The renamed file first: a failed write keeps the last good mirror.
    write_atomic(&path, &document(&note, &tabs))?;
    db.set_mirror_path(&note.id, &path.to_string_lossy())?;
    if let Some(old) = old {
        let old = Path::new(&old);
        if !same_file(old, &path) && file_belongs_to(old, &note.id) {
            let _ = std::fs::remove_file(old);
        }
    }
    Ok(())
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
        eprintln!("onote-helper: mirror {note_id}: {e}");
    }
}

/// Deleting a note: its file is read up first (the tracking row cascades
/// with the note) and unlinked only once the note is gone, so a deletion
/// the database refuses keeps the mirror as it was.
pub fn pending_removal(db: &Database, note_id: &str) -> Option<PathBuf> {
    dir(db)?;
    db.mirror_path(note_id).ok().flatten().map(PathBuf::from)
}

pub fn finish_removal(path: Option<PathBuf>, note_id: &str) {
    if let Some(path) = path {
        if file_belongs_to(&path, note_id) {
            let _ = std::fs::remove_file(&path);
        }
    }
}

/// A hard link when the filesystem has them (no copy), else a private copy
/// on disk: exFAT and similar folders keep their rollback too.
fn keep_backup(path: &Path, backup: &Path) -> Result<(), String> {
    if std::fs::hard_link(path, backup).is_ok() {
        return Ok(());
    }
    copy_backup(path, backup)
}

fn copy_backup(path: &Path, backup: &Path) -> Result<(), String> {
    let mut from = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .map_err(|e| format!("keep a copy of {}: {e}", path.display()))?;
    let mut to = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(backup)
        .map_err(|e| format!("keep a copy of {}: {e}", path.display()))?;
    if let Err(e) = std::io::copy(&mut from, &mut to) {
        let _ = std::fs::remove_file(backup);
        return Err(format!("keep a copy of {}: {e}", path.display()));
    }
    Ok(())
}

/// Write every note. Errors are returned here because the user asked for it.
/// Two phases, so a failure part-way leaves the previous mirror whole: every
/// file is written first, nothing tracked or deleted yet; only once all of
/// them exist are the rows moved and the old files removed. On an error the
/// files this run created are taken back and the ones it rewrote get their
/// previous contents back.
pub fn sync_all(db: &Database) -> Result<usize, String> {
    let Some(dir) = dir(db) else { return Ok(0) };
    crate::fsutil::ensure_owned_dir(&dir)?;
    // Ids only: the bodies are not held for the whole run. `before`: a hard
    // link to what the destination held when this run rewrote it (the note's
    // tracked file, or its own untracked file reclaimed by front matter after
    // the mirror was off), None for a file this run created. The rewrite
    // replaces the name, so the link keeps the old file on disk, not in memory.
    let mut written: Vec<(String, PathBuf, Option<String>, Option<PathBuf>)> = Vec::new();
    let rollback = |written: &[(String, PathBuf, Option<String>, Option<PathBuf>)]| {
        for (_, path, _, before) in written {
            match before {
                Some(backup) => { let _ = std::fs::rename(backup, path); }
                None => { let _ = std::fs::remove_file(path); }
            }
        }
    };
    for id in db.all_note_ids()? {
        let Some(note) = db.get_note(&id)? else { continue };
        let old = db.mirror_path(&note.id)?;
        let result = allocate_path(db, &dir, &note).and_then(|path| {
            let before = if std::fs::symlink_metadata(&path).is_ok() {
                let backup = dir.join(format!(".onote-rollback.{}.md", uuid::Uuid::new_v4().simple()));
                keep_backup(&path, &backup)?;
                Some(backup)
            } else {
                None
            };
            let tabs = db.tabs_for(&note.id)?;
            let done = write_atomic(&path, &document(&note, &tabs));
            if let Err(e) = done {
                if let Some(b) = &before { let _ = std::fs::remove_file(b); }
                return Err(e);
            }
            Ok((path, before))
        });
        match result {
            Ok((path, before)) => written.push((note.id, path, old, before)),
            Err(e) => {
                rollback(&written);
                return Err(e);
            }
        }
    }
    // Every tracking row moves in one transaction; if that fails the new
    // files are taken back and the old folder is still whole and tracked.
    let moves: Vec<(String, String)> = written
        .iter()
        .map(|(id, path, _, _)| (id.clone(), path.to_string_lossy().into_owned()))
        .collect();
    if let Err(e) = db.set_mirror_paths(&moves) {
        rollback(&written);
        return Err(e);
    }
    for (_, _, _, before) in &written {
        if let Some(backup) = before {
            let _ = std::fs::remove_file(backup);
        }
    }
    // Only now, with the rows moved, do the old files go.
    for (id, path, old, _) in &written {
        if let Some(old) = old {
            let old = Path::new(old);
            if !same_file(old, path) && file_belongs_to(old, id) {
                let _ = std::fs::remove_file(old);
            }
        }
    }
    Ok(written.len())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static COUNTER: AtomicUsize = AtomicUsize::new(0);

    fn temp_dir() -> PathBuf {
        let n = COUNTER.fetch_add(1, Ordering::SeqCst);
        let d = std::env::temp_dir().join(format!("onote-mirror-test-{}-{n}", std::process::id()));
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
        let emoji = safe_file_stem(&"😀".repeat(80), "a");
        assert!(emoji.len() <= MAX_STEM_BYTES && emoji.chars().count() == MAX_STEM_BYTES / 4, "{}", emoji.len());
    }

    // The file system counts bytes: an 80-emoji title (320 bytes) has to
    // write, temporary name, collision suffix and all.
    #[test]
    fn a_title_of_four_byte_characters_writes() {
        let db = db();
        let dir = temp_dir();
        db.create_notes(&[note("a", &"😀".repeat(80)), note("b", &"😀".repeat(80))]).unwrap();
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        let mut names: Vec<String> = std::fs::read_dir(&dir).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        names.sort();
        assert_eq!(names.len(), 2, "{names:?}");
        assert!(names.iter().all(|n| n.len() <= 255 - 38 && n.ends_with(".md")), "{names:?}");
        let _ = std::fs::remove_dir_all(&dir);
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

        let gone = pending_removal(&db, "b");
        assert!(dir.join("Groceries b.md").exists(), "nothing is unlinked before the note is gone");
        db.delete_note("b").unwrap();
        finish_removal(gone, "b");
        assert_eq!(names(), vec!["Shopping.md", "Untitled c.md"]);

        db.set_setting(SETTING, "").unwrap();
        a.title = "Ignored while off".into();
        db.update_note(&a).unwrap();
        sync_note(&db, "a");
        assert_eq!(names(), vec!["Shopping.md", "Untitled c.md"], "mirror off leaves files alone");
        // Off forgets the files (as setMirrorDir does); a later folder does not move them away.
        db.clear_mirror_paths().unwrap();
        let other = std::env::temp_dir().join(format!("onote-mirror-other-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&other);
        db.set_setting(SETTING, other.to_str().unwrap()).unwrap();
        sync_all(&db).unwrap();
        assert_eq!(names(), vec!["Shopping.md", "Untitled c.md"], "left behind, not moved");
        assert!(other.join("Ignored while off.md").exists(), "written afresh under the current title");
        let _ = std::fs::remove_dir_all(&other);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn mirror_never_replaces_or_deletes_files_it_did_not_write() {
        let db = db();
        let dir = temp_dir();
        std::fs::create_dir_all(&dir).unwrap();
        // A document the user already keeps in the vault, plus a stray file at
        // the fallback name, neither written by Onote.
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
        let gone = pending_removal(&db, "a");
        db.delete_note("a").unwrap();
        finish_removal(gone, "a");
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

    // The fallback for folders without hard links: a private copy, and a
    // name already taken is refused rather than overwritten.
    #[test]
    fn a_backup_copy_is_private_and_never_overwrites() {
        let dir = temp_dir();
        std::fs::create_dir_all(&dir).unwrap();
        let (file, backup) = (dir.join("Alpha.md"), dir.join(".onote-rollback.x.md"));
        std::fs::write(&file, "old contents").unwrap();
        copy_backup(&file, &backup).unwrap();
        assert_eq!(std::fs::read_to_string(&backup).unwrap(), "old contents");
        assert_eq!(std::fs::metadata(&backup).unwrap().mode() & 0o777, 0o600);
        assert!(copy_backup(&file, &backup).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Off then on in the same folder: the rows are gone, the files are not.
    // A run that rewrites them and then fails takes back only the files it
    // created; the rewritten ones existed before it and stay, as they were.
    #[test]
    fn a_failed_run_keeps_the_files_it_only_rewrote() {
        let db = db();
        let dir = temp_dir();
        db.create_notes(&[note("a", "Alpha"), note("b", "Beta")]).unwrap();
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        db.clear_mirror_paths().unwrap();   // the mirror was switched off
        let alpha_before = std::fs::read(dir.join("Alpha.md")).unwrap();
        db.execute_for_tests("UPDATE notes SET content_blocks = '[{\"type\":\"text\",\"content\":\"edited since\"}]' WHERE id = 'a'");
        // A later note (created after the others) finds every name taken by
        // the user's own documents, so the run fails after Alpha and Beta.
        db.create_notes(&[note("g", "Gamma")]).unwrap();
        db.execute_for_tests("UPDATE notes SET created_at = '2999-01-01 00:00:00' WHERE id = 'g'");
        let (stem, short) = (safe_file_stem("Gamma", "g"), short_id("g"));
        std::fs::write(dir.join(format!("{stem}.md")), "USER").unwrap();
        std::fs::write(dir.join(format!("{stem} {short}.md")), "USER").unwrap();
        for n in 2..100 {
            std::fs::write(dir.join(format!("{stem} {short}-{n}.md")), "USER").unwrap();
        }
        assert!(sync_all(&db).unwrap_err().contains("no free mirror file name"));
        assert!(dir.join("Alpha.md").exists(), "rewritten, not created: kept on rollback");
        assert!(dir.join("Beta.md").exists());
        assert!(file_belongs_to(&dir.join("Alpha.md"), "a"));
        assert_eq!(std::fs::read(dir.join("Alpha.md")).unwrap(), alpha_before, "rewritten, then restored whole");
        let leftovers = |d: &Path| std::fs::read_dir(d).unwrap().filter(|e| e.as_ref().unwrap().file_name().to_string_lossy().starts_with(".onote-rollback")).count();
        assert_eq!(leftovers(&dir), 0, "no rollback copies left after a failed run");
        // The same failure on a fresh folder leaves nothing behind.
        let fresh = temp_dir();
        db.set_setting(SETTING, fresh.to_str().unwrap()).unwrap();
        db.clear_mirror_paths().unwrap();
        std::fs::create_dir_all(&fresh).unwrap();
        std::fs::write(fresh.join(format!("{stem}.md")), "USER").unwrap();
        std::fs::write(fresh.join(format!("{stem} {short}.md")), "USER").unwrap();
        for n in 2..100 {
            std::fs::write(fresh.join(format!("{stem} {short}-{n}.md")), "USER").unwrap();
        }
        assert!(sync_all(&db).is_err());
        assert!(!fresh.join("Alpha.md").exists(), "created by the failed run: taken back");
        std::fs::remove_file(fresh.join(format!("{stem}.md"))).unwrap();   // Gamma fits now
        assert_eq!(sync_all(&db).unwrap(), 3);
        assert_eq!(sync_all(&db).unwrap(), 3, "a resync rewrites the files it owns");
        assert_eq!(leftovers(&fresh), 0, "no rollback copies left after a good run");
        let _ = std::fs::remove_dir_all(&dir);
        let _ = std::fs::remove_dir_all(&fresh);
    }

    // A tracked path is trusted only while our file is still there: a
    // user document (or a symlink) dropped under the same name after ours
    // was deleted is never overwritten; the note moves to the next name.
    #[test]
    fn tracked_path_taken_by_a_foreign_file_is_not_overwritten() {
        let db = db();
        let dir = temp_dir();
        db.create_notes(&[note("a", "Plan")]).unwrap();
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        sync_note(&db, "a");
        let own = dir.join("Plan.md");
        assert_eq!(db.mirror_path("a").unwrap().as_deref(), own.to_str());
        std::fs::remove_file(&own).unwrap();
        std::fs::write(&own, "USER DOCUMENT").unwrap();
        sync_note(&db, "a");
        assert_eq!(std::fs::read_to_string(&own).unwrap(), "USER DOCUMENT", "left alone");
        let moved = dir.join("Plan a.md");
        assert!(std::fs::read_to_string(&moved).unwrap().starts_with("---\nid: a\n"));
        assert_eq!(db.mirror_path("a").unwrap().as_deref(), moved.to_str());

        // A symlink planted at the tracked path reaches nothing either.
        std::fs::remove_file(&moved).unwrap();
        let target = dir.join("target.md");
        std::fs::write(&target, "TARGET").unwrap();
        std::os::unix::fs::symlink(&target, &moved).unwrap();
        sync_note(&db, "a");
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "TARGET");
        assert!(std::fs::symlink_metadata(&moved).unwrap().file_type().is_symlink(), "the link stays as it was");
        assert!(std::fs::read_to_string(dir.join("Plan a-2.md")).unwrap().starts_with("---\nid: a\n"));

        // A mirror file the user deleted is simply written again at its path.
        db.create_notes(&[note("b", "Beta")]).unwrap();
        sync_note(&db, "b");
        std::fs::remove_file(dir.join("Beta.md")).unwrap();
        sync_note(&db, "b");
        assert!(dir.join("Beta.md").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }

    // Switching folders writes every new file before any old one goes, so a
    // failure on the last note leaves the old folder complete and untracked
    // new files gone.
    #[test]
    fn failed_folder_switch_leaves_the_previous_mirror_whole() {
        let db = db();
        let old_dir = temp_dir();
        let new_dir = temp_dir();
        db.create_notes(&[note("a", "Alpha"), note("b", "Beta")]).unwrap();
        db.set_setting(SETTING, old_dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        // Every name Beta could take in the new folder is a foreign file.
        std::fs::create_dir_all(&new_dir).unwrap();
        std::fs::write(new_dir.join("Beta.md"), "USER").unwrap();
        let short = short_id("b");
        std::fs::write(new_dir.join(format!("Beta {short}.md")), "USER").unwrap();
        for n in 2..100 {
            std::fs::write(new_dir.join(format!("Beta {short}-{n}.md")), "USER").unwrap();
        }
        db.set_setting(SETTING, new_dir.to_str().unwrap()).unwrap();
        let err = sync_all(&db).unwrap_err();
        assert!(err.contains("no free mirror file name"), "{err}");
        assert!(old_dir.join("Alpha.md").exists() && old_dir.join("Beta.md").exists(), "old folder untouched");
        assert!(!new_dir.join("Alpha.md").exists(), "the file written before the failure is taken back");
        assert_eq!(db.mirror_path("a").unwrap().as_deref(), old_dir.join("Alpha.md").to_str());
        assert_eq!(std::fs::read_dir(&new_dir).unwrap().count(), 100, "foreign files untouched");
        let _ = std::fs::remove_dir_all(&old_dir);
        let _ = std::fs::remove_dir_all(&new_dir);
    }

    // The row moves are one transaction: a database failure on the last
    // note leaves every row in the old folder, no old file deleted, and the
    // new files taken back.
    #[test]
    fn failed_row_move_leaves_the_previous_mirror_whole() {
        let db = db();
        let old_dir = temp_dir();
        let new_dir = temp_dir();
        db.create_notes(&[note("a", "Alpha"), note("b", "Beta")]).unwrap();
        db.set_setting(SETTING, old_dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        db.execute_for_tests(
            "CREATE TRIGGER reject_move BEFORE UPDATE OF path ON mirror_files
             WHEN new.note_id='b' BEGIN SELECT RAISE(ABORT, 'test failure'); END;",
        );
        db.set_setting(SETTING, new_dir.to_str().unwrap()).unwrap();
        let err = sync_all(&db).unwrap_err();
        assert!(err.contains("test failure"), "{err}");
        assert!(old_dir.join("Alpha.md").exists() && old_dir.join("Beta.md").exists(), "old folder whole");
        assert_eq!(db.mirror_path("a").unwrap().as_deref(), old_dir.join("Alpha.md").to_str(), "no row moved");
        assert_eq!(db.mirror_path("b").unwrap().as_deref(), old_dir.join("Beta.md").to_str());
        assert!(!new_dir.exists() || std::fs::read_dir(&new_dir).unwrap().count() == 0, "new files taken back");
        let _ = std::fs::remove_dir_all(&old_dir);
        let _ = std::fs::remove_dir_all(&new_dir);
    }

    // Rows tracked through an alias (an older install stored the folder as
    // typed) and the canonical folder applied over them: a failed row move
    // takes back only new files, and the rewritten files are the old ones.
    #[test]
    fn failed_row_move_over_aliased_rows_keeps_the_files() {
        let db = db();
        let dir = temp_dir();
        let link = temp_dir();
        std::fs::create_dir_all(&dir).unwrap();
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        db.create_notes(&[note("a", "Alpha"), note("b", "Beta")]).unwrap();
        db.set_setting(SETTING, link.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        assert_eq!(db.mirror_path("a").unwrap().as_deref(), link.join("Alpha.md").to_str(), "tracked through the alias");
        db.execute_for_tests(
            "CREATE TRIGGER reject_move BEFORE UPDATE OF path ON mirror_files
             BEGIN SELECT RAISE(ABORT, 'test failure'); END;",
        );
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        let err = sync_all(&db).unwrap_err();
        assert!(err.contains("test failure"), "{err}");
        assert!(dir.join("Alpha.md").exists() && dir.join("Beta.md").exists(), "the mirror is still whole");
        assert_eq!(db.mirror_path("a").unwrap().as_deref(), link.join("Alpha.md").to_str(), "no row moved");
        let _ = std::fs::remove_file(&link);
        let _ = std::fs::remove_dir_all(&dir);
    }

    // The same folder under another spelling (`..`, a symlink) is a switch
    // to itself: the files are rewritten in place, none removed.
    #[test]
    fn switching_to_an_alias_of_the_same_folder_keeps_every_file() {
        let db = db();
        let dir = temp_dir();
        db.create_notes(&[note("a", "Alpha"), note("b", "Beta")]).unwrap();
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        let name = dir.file_name().unwrap().to_owned();
        let alias = dir.join("..").join(&name);
        db.set_setting(SETTING, alias.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        assert!(dir.join("Alpha.md").exists() && dir.join("Beta.md").exists(), "nothing removed through the old spelling");
        let link = temp_dir();
        std::os::unix::fs::symlink(&dir, &link).unwrap();
        db.set_setting(SETTING, link.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        assert!(dir.join("Alpha.md").exists() && dir.join("Beta.md").exists(), "nor through a symlink");
        db.set_setting(SETTING, dir.to_str().unwrap()).unwrap();
        assert_eq!(sync_all(&db).unwrap(), 2);
        assert_eq!(std::fs::read_dir(&dir).unwrap().count(), 2);
        let _ = std::fs::remove_file(&link);
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
        let gone = pending_removal(&db, "a");
        db.delete_note("a").unwrap();
        finish_removal(gone, "a");
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
