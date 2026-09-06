// Copied from DeskNotes (Tauri edition) src-tauri/src/db.rs by scripts/sync-public.py.
// Do not edit here; change it there and re-run the sync.
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::sync::Mutex;

#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Note {
    pub id: String,
    pub title: String,
    pub content_blocks: String,
    pub position_x: f64,
    pub position_y: f64,
    pub width: f64,
    pub height: f64,
    pub theme_name: String,
    pub display_id: i32,
    pub z_order: i32,
    pub pinned: bool,
    pub always_on_top: bool,
    pub opacity: f64,
    pub font_size: Option<i32>,
    pub zoom: f64,
    pub icon: Option<String>,
    pub icon_size: Option<i32>,
    pub piled: bool,
    /// Hyprland workspace the note lives on (Omarchy edition; 0 = unbound).
    #[serde(default)]
    pub workspace_id: i32,
    #[serde(default)]
    pub workspace_name: String,
    /// Glyph shown on the note's first tab instead of "1" (Omarchy edition).
    #[serde(default)]
    pub tab_icon: String,
    pub created_at: String,
    pub updated_at: String,
}

/// Extra page of a note (Omarchy edition). Tab 1 is the note's own
/// `content_blocks`; rows here are positions 1.. and are deleted with the note.
#[derive(Debug, Serialize, Deserialize, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NoteTab {
    pub id: String,
    pub note_id: String,
    pub position: i32,
    #[serde(default)]
    pub icon: String,
    pub content_blocks: String,
    #[serde(default)]
    pub created_at: String,
    #[serde(default)]
    pub updated_at: String,
}

const TAB_COLS: &str = "id, note_id, position, icon, content_blocks, created_at, updated_at";

fn row_to_tab(row: &rusqlite::Row) -> rusqlite::Result<NoteTab> {
    Ok(NoteTab {
        id: row.get(0)?,
        note_id: row.get(1)?,
        position: row.get(2)?,
        icon: row.get(3)?,
        content_blocks: row.get(4)?,
        created_at: row.get(5)?,
        updated_at: row.get(6)?,
    })
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct CustomTheme {
    pub id: String,
    pub name: String,
    pub theme_data: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct IconPack {
    pub id: String,
    pub name: String,
    pub folder_path: String,
    pub icon_count: i32,
    pub created_at: String,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct NoteSummary {
    pub id: String,
    pub title: String,
    pub piled: bool,
    pub theme_name: String,
}

pub struct Database {
    conn: Mutex<Connection>,
}

pub const MAX_NOTE_CONTENT_BYTES: usize = 5 * 1024 * 1024;
pub const MAX_NOTE_ICON_BYTES: usize = 2 * 1024 * 1024;

fn validate_note_storage(note: &Note) -> Result<(), String> {
    if note.content_blocks.len() > MAX_NOTE_CONTENT_BYTES {
        return Err("Note content exceeds 5 MB".into());
    }
    if note
        .icon
        .as_ref()
        .is_some_and(|icon| icon.len() > MAX_NOTE_ICON_BYTES)
    {
        return Err("Note icon exceeds 2 MB".into());
    }
    Ok(())
}

fn validate_note_update(conn: &Connection, note: &Note) -> Result<(), String> {
    let existing = conn
        .query_row(
            "SELECT content_blocks, icon FROM notes WHERE id=?1",
            params![note.id],
            |row| Ok((row.get::<_, String>(0)?, row.get::<_, Option<String>>(1)?)),
        )
        .optional()
        .map_err(|e| e.to_string())?;
    let Some((existing_content, existing_icon)) = existing else {
        return validate_note_storage(note);
    };

    let content_is_allowed = note.content_blocks.len() <= MAX_NOTE_CONTENT_BYTES
        || (existing_content.len() > MAX_NOTE_CONTENT_BYTES
            && note.content_blocks.len() <= existing_content.len());
    if !content_is_allowed {
        return Err("Note content exceeds 5 MB".into());
    }

    let new_icon_bytes = note.icon.as_ref().map_or(0, |icon| icon.len());
    let existing_icon_bytes = existing_icon.as_ref().map_or(0, |icon| icon.len());
    let icon_is_allowed = new_icon_bytes <= MAX_NOTE_ICON_BYTES
        || (existing_icon_bytes > MAX_NOTE_ICON_BYTES && new_icon_bytes <= existing_icon_bytes);
    if !icon_is_allowed {
        return Err("Note icon exceeds 2 MB".into());
    }

    Ok(())
}

fn insert_note(conn: &Connection, note: &Note) -> Result<(), String> {
    conn.execute(
        "INSERT INTO notes (id, title, content_blocks, position_x, position_y,
            width, height, theme_name, display_id, z_order, pinned, always_on_top,
            opacity, font_size, zoom, icon, icon_size, piled, workspace_id, workspace_name, tab_icon)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21)",
        params![
            note.id,
            note.title,
            note.content_blocks,
            note.position_x,
            note.position_y,
            note.width,
            note.height,
            note.theme_name,
            note.display_id,
            note.z_order,
            note.pinned,
            note.always_on_top,
            note.opacity,
            note.font_size,
            note.zoom,
            note.icon,
            note.icon_size,
            note.piled,
            note.workspace_id,
            note.workspace_name,
            note.tab_icon
        ],
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

fn row_to_note(row: &rusqlite::Row) -> rusqlite::Result<Note> {
    Ok(Note {
        id: row.get(0)?,
        title: row.get(1)?,
        content_blocks: row.get(2)?,
        position_x: row.get(3)?,
        position_y: row.get(4)?,
        width: row.get(5)?,
        height: row.get(6)?,
        theme_name: row.get(7)?,
        display_id: row.get(8)?,
        z_order: row.get(9)?,
        pinned: row.get(10)?,
        always_on_top: row.get(11)?,
        opacity: row.get(12)?,
        font_size: row.get(13)?,
        zoom: row.get(14)?,
        icon: row.get(15)?,
        icon_size: row.get(16)?,
        piled: row.get(17)?,
        created_at: row.get(18)?,
        updated_at: row.get(19)?,
        workspace_id: row.get(20)?,
        workspace_name: row.get(21)?,
        tab_icon: row.get(22)?,
    })
}

const SELECT_COLS: &str = "id, title, content_blocks, position_x, position_y, width, height,
    theme_name, display_id, z_order, pinned, always_on_top, opacity,
    font_size, zoom, icon, icon_size, piled, created_at, updated_at,
    workspace_id, workspace_name, tab_icon";

/// Same columns as SELECT_COLS but qualified with the `n` table alias. Required
/// for queries that JOIN `notes n` against `notes_fts f`, where bare `title` /
/// `content_blocks` would be ambiguous (both tables expose them).
const SELECT_COLS_N: &str = "n.id, n.title, n.content_blocks, n.position_x, n.position_y, n.width, n.height,
    n.theme_name, n.display_id, n.z_order, n.pinned, n.always_on_top, n.opacity,
    n.font_size, n.zoom, n.icon, n.icon_size, n.piled, n.created_at, n.updated_at,
    n.workspace_id, n.workspace_name, n.tab_icon";

const FTS_SEARCH_FROM: &str = "FROM notes n JOIN notes_fts f ON f.note_id = n.id \
    WHERE notes_fts MATCH ?1 ORDER BY rank LIMIT 200";

fn add_column_if_missing(conn: &Connection, table: &str, column: &str, decl: &str) -> Result<(), String> {
    let mut stmt = conn.prepare(&format!("PRAGMA table_info({table})")).map_err(|e| e.to_string())?;
    let names = stmt
        .query_map([], |r| r.get::<_, String>(1))
        .map_err(|e| e.to_string())?
        .collect::<Result<Vec<String>, _>>()
        .map_err(|e| e.to_string())?;
    if names.iter().any(|n| n == column) {
        return Ok(());
    }
    conn.execute_batch(&format!("ALTER TABLE {table} ADD COLUMN {column} {decl};")).map_err(|e| e.to_string())
}

impl Database {
    pub fn new(path: &std::path::Path) -> Result<Self, String> {
        let conn = Connection::open(path).map_err(|e| e.to_string())?;
        conn.execute_batch("PRAGMA journal_mode=WAL;")
            .map_err(|e| e.to_string())?;
        conn.execute_batch("PRAGMA foreign_keys=ON;")
            .map_err(|e| e.to_string())?;
        let db = Database {
            conn: Mutex::new(conn),
        };
        db.run_migrations()?;
        Ok(db)
    }

    fn run_migrations(&self) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;

        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY
            );",
        )
        .map_err(|e| e.to_string())?;

        let version: i32 = conn
            .query_row(
                "SELECT COALESCE(MAX(version), 0) FROM schema_version",
                [],
                |row| row.get(0),
            )
            .map_err(|e| e.to_string())?;

        // One transaction for every pending step: a launch that dies halfway
        // leaves the file at the old version instead of half-upgraded, and the
        // ADD COLUMN steps tolerate a column an earlier, non-transactional
        // build already added before it recorded the version.
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;

        if version < 1 {
            tx.execute_batch(
                "CREATE TABLE notes (
                    id TEXT PRIMARY KEY,
                    title TEXT NOT NULL DEFAULT '',
                    content_blocks TEXT NOT NULL DEFAULT '[]',
                    position_x REAL NOT NULL DEFAULT 100,
                    position_y REAL NOT NULL DEFAULT 100,
                    width REAL NOT NULL DEFAULT 300,
                    height REAL NOT NULL DEFAULT 350,
                    theme_name TEXT NOT NULL DEFAULT 'dracula',
                    display_id INTEGER NOT NULL DEFAULT 0,
                    z_order INTEGER NOT NULL DEFAULT 0,
                    pinned INTEGER NOT NULL DEFAULT 0,
                    always_on_top INTEGER NOT NULL DEFAULT 0,
                    opacity REAL NOT NULL DEFAULT 1.0,
                    font_size INTEGER,
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE custom_themes (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    theme_data TEXT NOT NULL DEFAULT '{}',
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );

                CREATE TABLE app_settings (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL DEFAULT ''
                );

                INSERT INTO schema_version (version) VALUES (1);",
            )
            .map_err(|e| e.to_string())?;
        }

        if version < 2 {
            add_column_if_missing(&tx, "notes", "piled", "INTEGER NOT NULL DEFAULT 0")?;
            tx.execute_batch("INSERT INTO schema_version (version) VALUES (2);")
                .map_err(|e| e.to_string())?;
        }

        if version < 3 {
            tx.execute_batch(
                "CREATE TABLE IF NOT EXISTS icon_packs (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    folder_path TEXT NOT NULL,
                    icon_count INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                INSERT INTO schema_version (version) VALUES (3);",
            )
            .map_err(|e| e.to_string())?;
        }

        if version < 4 {
            tx.execute_batch(
                "UPDATE notes SET opacity = 1.0;
                 INSERT INTO schema_version (version) VALUES (4);",
            )
            .map_err(|e| e.to_string())?;
        }

        if version < 5 {
            add_column_if_missing(&tx, "notes", "zoom", "REAL NOT NULL DEFAULT 100.0")?;
            tx.execute_batch("INSERT INTO schema_version (version) VALUES (5);")
                .map_err(|e| e.to_string())?;
        }

        if version < 6 {
            add_column_if_missing(&tx, "notes", "icon", "TEXT")?;
            tx.execute_batch("INSERT INTO schema_version (version) VALUES (6);")
                .map_err(|e| e.to_string())?;
        }

        if version < 7 {
            add_column_if_missing(&tx, "notes", "icon_size", "INTEGER")?;
            tx.execute_batch("INSERT INTO schema_version (version) VALUES (7);")
                .map_err(|e| e.to_string())?;
        }

        if version < 8 {
            // FTS5 mirror of (title, content_blocks). Kept in sync via triggers.
            tx.execute_batch(
                "CREATE VIRTUAL TABLE IF NOT EXISTS notes_fts USING fts5(
                    note_id UNINDEXED,
                    title,
                    content_blocks,
                    tokenize='unicode61 remove_diacritics 2'
                );

                -- Idempotent backfill: if this block already ran but the process
                -- died before the schema_version bump committed, the next launch
                -- re-enters here. Clearing first prevents duplicate FTS rows.
                DELETE FROM notes_fts;

                INSERT INTO notes_fts(note_id, title, content_blocks)
                SELECT id, title, content_blocks FROM notes;

                CREATE TRIGGER IF NOT EXISTS notes_fts_ai AFTER INSERT ON notes BEGIN
                    INSERT INTO notes_fts(note_id, title, content_blocks)
                    VALUES (new.id, new.title, new.content_blocks);
                END;

                CREATE TRIGGER IF NOT EXISTS notes_fts_au AFTER UPDATE ON notes BEGIN
                    UPDATE notes_fts SET title = new.title, content_blocks = new.content_blocks
                    WHERE note_id = new.id;
                END;

                CREATE TRIGGER IF NOT EXISTS notes_fts_ad AFTER DELETE ON notes BEGIN
                    DELETE FROM notes_fts WHERE note_id = old.id;
                END;

                INSERT INTO schema_version (version) VALUES (8);",
            )
            .map_err(|e| e.to_string())?;
        }

        if version < 9 {
            // FTS5 can leave term indexes stale when mirrored rows are updated
            // in place. Replace the row and rebuild once to repair existing data.
            tx.execute_batch(
                "DROP TRIGGER IF EXISTS notes_fts_au;

                CREATE TRIGGER notes_fts_au AFTER UPDATE OF title, content_blocks ON notes
                WHEN old.title IS NOT new.title OR old.content_blocks IS NOT new.content_blocks
                BEGIN
                    DELETE FROM notes_fts WHERE note_id = old.id;
                    INSERT INTO notes_fts(note_id, title, content_blocks)
                    VALUES (new.id, new.title, new.content_blocks);
                END;

                DELETE FROM notes_fts;
                INSERT INTO notes_fts(note_id, title, content_blocks)
                SELECT id, title, content_blocks FROM notes;

                INSERT INTO schema_version (version) VALUES (9);",
            )
            .map_err(|e| e.to_string())?;
        }

        if version < 10 {
            // Omarchy edition: which Hyprland workspace a note was last seen on.
            // The name survives id churn for named/special workspaces.
            add_column_if_missing(&tx, "notes", "workspace_id", "INTEGER NOT NULL DEFAULT 0")?;
            add_column_if_missing(&tx, "notes", "workspace_name", "TEXT NOT NULL DEFAULT ''")?;
            tx.execute_batch("INSERT INTO schema_version (version) VALUES (10);")
                .map_err(|e| e.to_string())?;
        }

        if version < 11 {
            // Omarchy edition: extra tabs per note. Tab 1 stays in notes.content_blocks
            // so previews, the Tauri edition and existing notes are untouched.
            add_column_if_missing(&tx, "notes", "tab_icon", "TEXT NOT NULL DEFAULT ''")?;
            tx.execute_batch(
                "CREATE TABLE IF NOT EXISTS note_tabs (
                    id TEXT PRIMARY KEY,
                    note_id TEXT NOT NULL REFERENCES notes(id) ON DELETE CASCADE,
                    position INTEGER NOT NULL,
                    icon TEXT NOT NULL DEFAULT '',
                    content_blocks TEXT NOT NULL DEFAULT '[]',
                    created_at TEXT NOT NULL DEFAULT (datetime('now')),
                    updated_at TEXT NOT NULL DEFAULT (datetime('now'))
                );
                CREATE INDEX IF NOT EXISTS note_tabs_by_note ON note_tabs(note_id, position);

                CREATE VIRTUAL TABLE IF NOT EXISTS tabs_fts USING fts5(
                    tab_id UNINDEXED,
                    note_id UNINDEXED,
                    content_blocks,
                    tokenize='unicode61 remove_diacritics 2'
                );
                DELETE FROM tabs_fts;
                INSERT INTO tabs_fts(tab_id, note_id, content_blocks)
                SELECT id, note_id, content_blocks FROM note_tabs;

                CREATE TRIGGER IF NOT EXISTS tabs_fts_ai AFTER INSERT ON note_tabs BEGIN
                    INSERT INTO tabs_fts(tab_id, note_id, content_blocks)
                    VALUES (new.id, new.note_id, new.content_blocks);
                END;
                CREATE TRIGGER IF NOT EXISTS tabs_fts_au AFTER UPDATE OF content_blocks ON note_tabs
                WHEN old.content_blocks IS NOT new.content_blocks
                BEGIN
                    DELETE FROM tabs_fts WHERE tab_id = old.id;
                    INSERT INTO tabs_fts(tab_id, note_id, content_blocks)
                    VALUES (new.id, new.note_id, new.content_blocks);
                END;
                CREATE TRIGGER IF NOT EXISTS tabs_fts_ad AFTER DELETE ON note_tabs BEGIN
                    DELETE FROM tabs_fts WHERE tab_id = old.id;
                END;

                INSERT INTO schema_version (version) VALUES (11);",
            )
            .map_err(|e| e.to_string())?;
        }

        if version < 12 {
            // Omarchy edition: which Markdown mirror file a note was last written to,
            // so a renamed note replaces its file instead of leaving a copy behind.
            tx.execute_batch(
                "CREATE TABLE IF NOT EXISTS mirror_files (
                    note_id TEXT PRIMARY KEY REFERENCES notes(id) ON DELETE CASCADE,
                    path TEXT NOT NULL UNIQUE
                );
                INSERT INTO schema_version (version) VALUES (12);",
            )
            .map_err(|e| e.to_string())?;
        }

        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    // ---- Markdown mirror bookkeeping (Omarchy edition)

    pub fn all_note_ids(&self) -> Result<Vec<String>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn.prepare("SELECT id FROM notes ORDER BY created_at").map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], |r| r.get(0)).map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<String>, _>>().map_err(|e| e.to_string())
    }

    pub fn mirror_path(&self, note_id: &str) -> Result<Option<String>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.query_row("SELECT path FROM mirror_files WHERE note_id = ?1", params![note_id], |r| r.get(0))
            .optional()
            .map_err(|e| e.to_string())
    }

    /// The note currently written to `path`, if any.
    pub fn mirror_path_owner(&self, path: &str) -> Result<Option<String>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.query_row("SELECT note_id FROM mirror_files WHERE path = ?1", params![path], |r| r.get(0))
            .optional()
            .map_err(|e| e.to_string())
    }

    pub fn set_mirror_path(&self, note_id: &str, path: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            // ON CONFLICT(note_id) moves this note's file; a path already owned
            // by another note fails on the UNIQUE index instead of evicting it.
            "INSERT INTO mirror_files (note_id, path) VALUES (?1, ?2)
             ON CONFLICT(note_id) DO UPDATE SET path = excluded.path",
            params![note_id, path],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn clear_mirror_path(&self, note_id: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM mirror_files WHERE note_id = ?1", params![note_id])
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    // ---- tabs (Omarchy edition)

    pub fn list_tabs(&self) -> Result<Vec<NoteTab>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!("SELECT {TAB_COLS} FROM note_tabs ORDER BY note_id, position");
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let rows = stmt.query_map([], row_to_tab).map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    pub fn tabs_for(&self, note_id: &str) -> Result<Vec<NoteTab>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!("SELECT {TAB_COLS} FROM note_tabs WHERE note_id = ?1 ORDER BY position");
        let mut stmt = conn.prepare_cached(&sql).map_err(|e| e.to_string())?;
        let rows = stmt.query_map(params![note_id], row_to_tab).map_err(|e| e.to_string())?;
        rows.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())
    }

    pub fn get_tab(&self, id: &str) -> Result<Option<NoteTab>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!("SELECT {TAB_COLS} FROM note_tabs WHERE id = ?1");
        let mut stmt = conn.prepare_cached(&sql).map_err(|e| e.to_string())?;
        stmt.query_row(params![id], row_to_tab).optional().map_err(|e| e.to_string())
    }

    /// Appends an empty tab after the note's last one. Fails if the note is gone.
    pub fn create_tab(&self, id: &str, note_id: &str) -> Result<NoteTab, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT INTO note_tabs (id, note_id, position, content_blocks)
             SELECT ?1, ?2, COALESCE(MAX(position), 0) + 1, '[{\"type\":\"text\",\"content\":\"\"}]'
             FROM note_tabs WHERE note_id = ?2",
            params![id, note_id],
        )
        .map_err(|e| e.to_string())?;
        let sql = format!("SELECT {TAB_COLS} FROM note_tabs WHERE id = ?1");
        conn.query_row(&sql, params![id], row_to_tab).map_err(|e| e.to_string())
    }

    pub fn update_tab(&self, tab: &NoteTab) -> Result<(), String> {
        if tab.content_blocks.len() > MAX_NOTE_CONTENT_BYTES {
            return Err("Note content exceeds 5 MB".into());
        }
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let n = conn
            .execute(
                "UPDATE note_tabs SET icon = ?2, content_blocks = ?3, updated_at = datetime('now') WHERE id = ?1",
                params![tab.id, tab.icon, tab.content_blocks],
            )
            .map_err(|e| e.to_string())?;
        if n == 0 {
            return Err("Tab not found".into());
        }
        Ok(())
    }

    /// Deletes a tab and closes the gap in its note's positions, atomically.
    pub fn delete_tab(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        let (note_id, position): (String, i32) = tx
            .query_row("SELECT note_id, position FROM note_tabs WHERE id = ?1", params![id], |r| Ok((r.get(0)?, r.get(1)?)))
            .optional()
            .map_err(|e| e.to_string())?
            .ok_or("Tab not found")?;
        tx.execute("DELETE FROM note_tabs WHERE id = ?1", params![id]).map_err(|e| e.to_string())?;
        tx.execute(
            "UPDATE note_tabs SET position = position - 1 WHERE note_id = ?1 AND position > ?2",
            params![note_id, position],
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())
    }

    /// FTS5-backed search. Caller is expected to have already escaped the raw
    /// user query into a safe FTS5 expression (see `lib.rs::fts_query`).
    pub fn search_notes_fts(&self, fts_query: &str) -> Result<Vec<Note>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!("SELECT {SELECT_COLS_N} {FTS_SEARCH_FROM}");
        let mut stmt = conn.prepare_cached(&sql).map_err(|e| e.to_string())?;
        let notes = stmt
            .query_map(params![fts_query], row_to_note)
            .map_err(|e| e.to_string())?;
        let mut result = Vec::new();
        for note in notes {
            result.push(note.map_err(|e| e.to_string())?);
        }
        Ok(result)
    }

    /// The shell already has the notes; filtering needs IDs, not their bodies/images.
    /// Notes whose text matches come first in rank order, then notes matched
    /// only through an extra tab (Omarchy edition).
    pub fn search_note_ids_fts(&self, fts_query: &str) -> Result<Vec<String>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!("SELECT n.id {FTS_SEARCH_FROM}");
        let mut stmt = conn.prepare_cached(&sql).map_err(|e| e.to_string())?;
        let ids = stmt
            .query_map(params![fts_query], |row| row.get(0))
            .map_err(|e| e.to_string())?;
        let mut ids = ids.collect::<Result<Vec<String>, _>>().map_err(|e| e.to_string())?;
        let mut tabs = conn
            .prepare_cached(
                "SELECT t.note_id FROM tabs_fts t JOIN notes n ON n.id = t.note_id \
                 WHERE tabs_fts MATCH ?1 ORDER BY rank LIMIT 200",
            )
            .map_err(|e| e.to_string())?;
        let hits = tabs
            .query_map(params![fts_query], |row| row.get::<_, String>(0))
            .map_err(|e| e.to_string())?;
        for hit in hits {
            let id = hit.map_err(|e| e.to_string())?;
            if ids.len() >= 200 {
                break;
            }
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
        Ok(ids)
    }

    pub fn create_note(&self, note: &Note) -> Result<(), String> {
        validate_note_storage(note)?;
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        insert_note(&conn, note)
    }

    pub fn create_notes(&self, notes: &[Note]) -> Result<(), String> {
        for note in notes {
            validate_note_storage(note)?;
        }
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        for note in notes {
            insert_note(&tx, note)?;
        }
        tx.commit().map_err(|e| e.to_string())
    }

    pub fn get_note(&self, id: &str) -> Result<Option<Note>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!("SELECT {} FROM notes WHERE id = ?1", SELECT_COLS);
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let note = stmt.query_row(params![id], row_to_note).ok();
        Ok(note)
    }

    pub fn get_all_notes(&self) -> Result<Vec<Note>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!(
            "SELECT {} FROM notes WHERE piled = 0 ORDER BY z_order ASC",
            SELECT_COLS
        );
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let notes = stmt.query_map([], row_to_note).map_err(|e| e.to_string())?;
        let mut result = Vec::new();
        for note in notes {
            result.push(note.map_err(|e| e.to_string())?);
        }
        Ok(result)
    }

    pub fn get_piled_notes(&self) -> Result<Vec<Note>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!(
            "SELECT {} FROM notes WHERE piled = 1 ORDER BY updated_at DESC",
            SELECT_COLS
        );
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let notes = stmt.query_map([], row_to_note).map_err(|e| e.to_string())?;
        let mut result = Vec::new();
        for note in notes {
            result.push(note.map_err(|e| e.to_string())?);
        }
        Ok(result)
    }

    pub fn update_note(&self, note: &Note) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        validate_note_update(&conn, note)?;
        let opacity = if note.opacity.is_finite() {
            note.opacity.clamp(0.3, 1.0)
        } else {
            1.0
        };
        conn.execute(
            "UPDATE notes SET title=?2, content_blocks=?3, position_x=?4, position_y=?5,
                width=?6, height=?7, theme_name=?8, display_id=?9, z_order=?10,
                pinned=?11, always_on_top=?12, opacity=?13, font_size=?14, zoom=?15,
                icon=?16, icon_size=?17, piled=?18, workspace_id=?19, workspace_name=?20,
                tab_icon=?21, updated_at=datetime('now')
             WHERE id=?1",
            params![
                note.id,
                note.title,
                note.content_blocks,
                note.position_x,
                note.position_y,
                note.width,
                note.height,
                note.theme_name,
                note.display_id,
                note.z_order,
                note.pinned,
                note.always_on_top,
                opacity,
                note.font_size,
                note.zoom,
                note.icon,
                note.icon_size,
                note.piled,
                note.workspace_id,
                note.workspace_name,
                note.tab_icon
            ],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn delete_note(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM notes WHERE id=?1", params![id])
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn pile_note(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "UPDATE notes SET piled = 1, updated_at = datetime('now') WHERE id = ?1",
            params![id],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn pile_all_notes(&self) -> Result<(), String> {
        self.set_all_notes_piled(true).map(|_| ())
    }

    /// Atomically change the matching rows, without loading note bodies into memory.
    pub fn set_all_notes_piled(&self, piled: bool) -> Result<usize, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "UPDATE notes SET piled = ?1, updated_at = datetime('now') WHERE piled = ?2",
            params![piled, !piled],
        )
        .map_err(|e| e.to_string())
    }

    pub fn unpile_note(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "UPDATE notes SET piled = 0, updated_at = datetime('now') WHERE id = ?1",
            params![id],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn reset_all_opacities(&self) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "UPDATE notes SET opacity = 1.0, updated_at = datetime('now')",
            [],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_all_for_search(&self) -> Result<Vec<Note>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let sql = format!("SELECT {} FROM notes ORDER BY updated_at DESC", SELECT_COLS);
        let mut stmt = conn.prepare(&sql).map_err(|e| e.to_string())?;
        let notes = stmt.query_map([], row_to_note).map_err(|e| e.to_string())?;
        let mut result = Vec::new();
        for note in notes {
            result.push(note.map_err(|e| e.to_string())?);
        }
        Ok(result)
    }

    pub fn get_setting(&self, key: &str) -> Result<Option<String>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let result = conn
            .query_row(
                "SELECT value FROM app_settings WHERE key=?1",
                params![key],
                |row| row.get(0),
            )
            .ok();
        Ok(result)
    }

    pub fn set_setting(&self, key: &str, value: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT OR REPLACE INTO app_settings (key, value) VALUES (?1, ?2)",
            params![key, value],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn remove_setting(&self, key: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM app_settings WHERE key=?1", params![key])
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_all_settings(&self) -> Result<std::collections::HashMap<String, String>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT key, value FROM app_settings")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?)))
            .map_err(|e| e.to_string())?;
        let mut map = std::collections::HashMap::new();
        for row in rows {
            let (k, v) = row.map_err(|e| e.to_string())?;
            map.insert(k, v);
        }
        Ok(map)
    }

    pub fn set_all_settings(&self, settings: &std::collections::HashMap<String, String>) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("INSERT OR REPLACE INTO app_settings (key, value) VALUES (?1, ?2)")
            .map_err(|e| e.to_string())?;
        for (key, value) in settings {
            stmt.execute(params![key, value])
                .map_err(|e| e.to_string())?;
        }
        Ok(())
    }

    pub fn replace_all_settings(&self, settings: &std::collections::HashMap<String, String>) -> Result<(), String> {
        let mut conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.transaction().map_err(|e| e.to_string())?;
        tx.execute("DELETE FROM app_settings", [])
            .map_err(|e| e.to_string())?;
        {
            let mut stmt = tx
                .prepare("INSERT INTO app_settings (key, value) VALUES (?1, ?2)")
                .map_err(|e| e.to_string())?;
            for (key, value) in settings {
                stmt.execute(params![key, value])
                    .map_err(|e| e.to_string())?;
            }
        }
        tx.commit().map_err(|e| e.to_string())
    }

    pub fn get_custom_themes(&self) -> Result<Vec<CustomTheme>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare(
                "SELECT id, name, theme_data, created_at, updated_at FROM custom_themes ORDER BY name ASC",
            )
            .map_err(|e| e.to_string())?;
        let themes = stmt
            .query_map([], |row| {
                Ok(CustomTheme {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    theme_data: row.get(2)?,
                    created_at: row.get(3)?,
                    updated_at: row.get(4)?,
                })
            })
            .map_err(|e| e.to_string())?;
        let mut result = Vec::new();
        for t in themes {
            result.push(t.map_err(|e| e.to_string())?);
        }
        Ok(result)
    }

    pub fn save_custom_theme(&self, theme: &CustomTheme) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute(
            "INSERT OR REPLACE INTO custom_themes (id, name, theme_data, created_at, updated_at)
             VALUES (?1, ?2, ?3, COALESCE((SELECT created_at FROM custom_themes WHERE id=?1), datetime('now')), datetime('now'))",
            params![theme.id, theme.name, theme.theme_data],
        )
        .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn delete_custom_theme(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM custom_themes WHERE id=?1", params![id])
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn replace_all_icon_packs(&self, pack: &IconPack) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute("DELETE FROM icon_packs", [])
            .map_err(|e| e.to_string())?;
        tx.execute(
            "INSERT INTO icon_packs (id, name, folder_path, icon_count) VALUES (?1, ?2, ?3, ?4)",
            params![pack.id, pack.name, pack.folder_path, pack.icon_count],
        )
        .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn replace_icon_pack(&self, old_id: &str, pack: &IconPack) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let tx = conn.unchecked_transaction().map_err(|e| e.to_string())?;
        tx.execute(
            "INSERT INTO icon_packs (id, name, folder_path, icon_count) VALUES (?1, ?2, ?3, ?4)",
            params![pack.id, pack.name, pack.folder_path, pack.icon_count],
        )
        .map_err(|e| e.to_string())?;
        tx.execute("DELETE FROM icon_packs WHERE id=?1", params![old_id])
            .map_err(|e| e.to_string())?;
        tx.commit().map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_icon_packs(&self) -> Result<Vec<IconPack>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT id, name, folder_path, icon_count, created_at FROM icon_packs ORDER BY name")
            .map_err(|e| e.to_string())?;
        let packs = stmt
            .query_map([], |row| {
                Ok(IconPack {
                    id: row.get(0)?,
                    name: row.get(1)?,
                    folder_path: row.get(2)?,
                    icon_count: row.get(3)?,
                    created_at: row.get(4)?,
                })
            })
            .map_err(|e| e.to_string())?;
        let mut result = Vec::new();
        for p in packs {
            result.push(p.map_err(|e| e.to_string())?);
        }
        Ok(result)
    }

    pub fn icon_pack_is_referenced(&self, pack_id: &str) -> Result<bool, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.query_row(
            "SELECT EXISTS(
                SELECT 1 FROM notes
                WHERE instr(content_blocks, ?1) > 0
                   OR instr(COALESCE(icon, ''), ?1) > 0
            )",
            params![pack_id],
            |row| row.get::<_, bool>(0),
        )
        .map_err(|e| e.to_string())
    }

    pub fn delete_icon_pack(&self, id: &str) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM icon_packs WHERE id=?1", params![id])
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    pub fn get_all_note_summaries(&self) -> Result<Vec<NoteSummary>, String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        let mut stmt = conn
            .prepare("SELECT id, title, piled, theme_name FROM notes ORDER BY updated_at DESC")
            .map_err(|e| e.to_string())?;
        let rows = stmt
            .query_map([], |row| {
                Ok(NoteSummary {
                    id: row.get(0)?,
                    title: row.get(1)?,
                    piled: row.get(2)?,
                    theme_name: row.get(3)?,
                })
            })
            .map_err(|e| e.to_string())?;
        let mut result = Vec::new();
        for r in rows {
            result.push(r.map_err(|e| e.to_string())?);
        }
        Ok(result)
    }

    pub fn delete_all_notes(&self) -> Result<(), String> {
        let conn = self.conn.lock().map_err(|e| e.to_string())?;
        conn.execute("DELETE FROM notes", [])
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_db() -> Database {
        let db = Database {
            conn: Mutex::new(Connection::open_in_memory().unwrap()),
        };
        db.run_migrations().unwrap();
        db
    }

    fn note(id: &str) -> Note {
        Note {
            id: id.into(),
            title: "Test".into(),
            content_blocks: "[]".into(),
            position_x: 100.0,
            position_y: 100.0,
            width: 300.0,
            height: 350.0,
            theme_name: "dracula".into(),
            display_id: 0,
            z_order: 0,
            pinned: false,
            always_on_top: false,
            opacity: 1.0,
            font_size: None,
            zoom: 100.0,
            icon: None,
            icon_size: None,
            piled: false,
            workspace_id: 0,
            workspace_name: String::new(),
            tab_icon: String::new(),
            created_at: String::new(),
            updated_at: String::new(),
        }
    }

    fn note_with_icon_reference(id: &str, content_blocks: &str, icon: Option<&str>) -> Note {
        let mut note = note(id);
        note.content_blocks = content_blocks.into();
        note.icon = icon.map(str::to_string);
        note
    }

    fn icon_pack(id: &str, name: &str) -> IconPack {
        IconPack {
            id: id.into(),
            name: name.into(),
            folder_path: format!("/managed/{id}"),
            icon_count: 1,
            created_at: String::new(),
        }
    }

    #[test]
    fn search_ids_preserve_ranked_results_limit_and_stacked_notes() {
        let db = test_db();
        let mut notes = Vec::new();
        for i in 0..205 {
            let mut n = note(&format!("search-{i:03}"));
            n.title = if i == 0 { "needle needle needle" } else { "needle" }.into();
            n.content_blocks = r#"[{"type":"text","content":"needle body"}]"#.into();
            n.piled = i % 2 == 0;
            notes.push(n);
        }
        db.create_notes(&notes).unwrap();
        let full = db.search_notes_fts("needle*").unwrap();
        let ids = db.search_note_ids_fts("needle*").unwrap();
        assert_eq!(ids, full.iter().map(|n| n.id.clone()).collect::<Vec<_>>());
        assert_eq!(ids.len(), 200);
        assert!(full.iter().any(|n| n.piled));
        assert!(db.search_note_ids_fts("absent*").unwrap().is_empty());
    }

    #[test]
    fn bulk_stack_counts_changes_and_preserves_content_and_search() {
        let db = test_db();
        let mut a = note("a");
        a.content_blocks = r#"[{"type":"text","content":"needle"}]"#.into();
        a.pinned = true;
        let mut b = note("b");
        b.piled = true;
        db.create_notes(&[a.clone(), b]).unwrap();
        db.conn.lock().unwrap().execute(
            "UPDATE notes SET updated_at='2000-01-01 00:00:00'", [],
        ).unwrap();
        assert_eq!(db.set_all_notes_piled(true).unwrap(), 1);
        assert_eq!(db.get_note("b").unwrap().unwrap().updated_at, "2000-01-01 00:00:00");
        assert_eq!(db.set_all_notes_piled(true).unwrap(), 0);
        assert_eq!(db.set_all_notes_piled(false).unwrap(), 2);
        assert_eq!(db.set_all_notes_piled(false).unwrap(), 0);
        let saved = db.get_note("a").unwrap().unwrap();
        assert_eq!(saved.content_blocks, a.content_blocks);
        assert!(saved.pinned);
        assert_eq!(db.search_note_ids_fts("needle*").unwrap(), vec!["a"]);
    }

    #[test]
    fn workspace_columns_default_unbound_and_round_trip() {
        let db = test_db();
        db.create_notes(&[note("a")]).unwrap();
        let fresh = db.get_note("a").unwrap().unwrap();
        assert_eq!((fresh.workspace_id, fresh.workspace_name.as_str()), (0, ""));

        let mut bound = fresh.clone();
        bound.workspace_id = -98;
        bound.workspace_name = "special:notes".into();
        db.update_note(&bound).unwrap();
        let saved = db.get_note("a").unwrap().unwrap();
        assert_eq!((saved.workspace_id, saved.workspace_name.as_str()), (-98, "special:notes"));
        assert_eq!(saved.title, fresh.title);
        assert_eq!(saved.content_blocks, fresh.content_blocks);

        // Older clients (Tauri frontend) may send notes without the new fields.
        let legacy: Note = serde_json::from_str(
            r#"{"id":"a","title":"T","contentBlocks":"[]","positionX":0,"positionY":0,"width":300,
                "height":350,"themeName":"dracula","displayId":0,"zOrder":0,"pinned":false,
                "alwaysOnTop":false,"opacity":1.0,"fontSize":null,"zoom":100,"icon":null,
                "iconSize":null,"piled":false,"createdAt":"","updatedAt":""}"#,
        )
        .unwrap();
        assert_eq!((legacy.workspace_id, legacy.workspace_name.as_str()), (0, ""));
    }

    #[test]
    fn workspace_migration_upgrades_an_existing_database() {
        let db = Database {
            conn: Mutex::new(Connection::open_in_memory().unwrap()),
        };
        db.run_migrations().unwrap();
        db.create_notes(&[note("a")]).unwrap();
        {
            let conn = db.conn.lock().unwrap();
            // Rewind to a pre-workspace, pre-tabs schema like an old DB.
            conn.execute_batch(
                "DELETE FROM schema_version WHERE version >= 10;
                 DROP TABLE mirror_files;
                 DROP TABLE tabs_fts;
                 DROP TABLE note_tabs;
                 ALTER TABLE notes DROP COLUMN tab_icon;
                 ALTER TABLE notes DROP COLUMN workspace_id;
                 ALTER TABLE notes DROP COLUMN workspace_name;",
            )
            .unwrap();
        }
        db.run_migrations().unwrap();
        let n = db.get_note("a").unwrap().unwrap();
        assert_eq!((n.workspace_id, n.workspace_name.as_str(), n.tab_icon.as_str()), (0, "", ""));
        assert_eq!(db.create_tab("t", "a").unwrap().position, 1);
        let version: i32 = db
            .conn
            .lock()
            .unwrap()
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, 12);
        db.set_mirror_path("a", "/tmp/x.md").unwrap();
        assert_eq!(db.mirror_path_owner("/tmp/x.md").unwrap().as_deref(), Some("a"));
    }

    #[test]
    fn interrupted_migration_is_completed_on_the_next_launch() {
        // A build without transactions could die after the first ALTER of
        // migration 10 committed but before the version row was written.
        let db = Database {
            conn: Mutex::new(Connection::open_in_memory().unwrap()),
        };
        db.run_migrations().unwrap();
        db.create_notes(&[note("a")]).unwrap();
        {
            let conn = db.conn.lock().unwrap();
            conn.execute_batch(
                "DELETE FROM schema_version WHERE version >= 10;
                 DROP TABLE mirror_files;
                 DROP TABLE tabs_fts;
                 DROP TABLE note_tabs;
                 ALTER TABLE notes DROP COLUMN tab_icon;
                 ALTER TABLE notes DROP COLUMN workspace_name;",
            )
            .unwrap();
            // workspace_id stays: that ALTER already ran.
        }
        db.run_migrations().unwrap();
        let version: i32 = db
            .conn
            .lock()
            .unwrap()
            .query_row("SELECT MAX(version) FROM schema_version", [], |r| r.get(0))
            .unwrap();
        assert_eq!(version, 12);
        let n = db.get_note("a").unwrap().unwrap();
        assert_eq!((n.workspace_id, n.workspace_name.as_str(), n.tab_icon.as_str()), (0, "", ""));
        assert_eq!(db.create_tab("t", "a").unwrap().position, 1);
        // Running again is a no-op.
        db.run_migrations().unwrap();
    }

    #[test]
    fn mirror_path_cannot_be_given_to_two_notes() {
        let db = test_db();
        db.create_notes(&[note("a"), note("b")]).unwrap();
        db.set_mirror_path("a", "/tmp/one.md").unwrap();
        assert!(db.set_mirror_path("b", "/tmp/one.md").is_err());
        assert_eq!(db.mirror_path_owner("/tmp/one.md").unwrap().as_deref(), Some("a"));
        db.set_mirror_path("a", "/tmp/two.md").unwrap();
        assert_eq!(db.mirror_path("a").unwrap().as_deref(), Some("/tmp/two.md"));
        assert_eq!(db.mirror_path_owner("/tmp/one.md").unwrap(), None);
    }

    #[test]
    fn tabs_append_renumber_cascade_and_search() {
        let db = test_db();
        db.create_notes(&[note("a"), note("b")]).unwrap();
        let t1 = db.create_tab("t1", "a").unwrap();
        let t2 = db.create_tab("t2", "a").unwrap();
        assert_eq!((t1.position, t2.position), (1, 2));
        assert_eq!(t1.content_blocks, r#"[{"type":"text","content":""}]"#);
        assert!(db.create_tab("tx", "missing").is_err(), "tab needs an existing note");

        let mut edited = t2.clone();
        edited.icon = "\u{f005}".into();
        edited.content_blocks = r#"[{"type":"text","content":"pineapple on page two"}]"#.into();
        db.update_tab(&edited).unwrap();
        let saved = db.get_tab("t2").unwrap().unwrap();
        assert_eq!((saved.icon.as_str(), saved.position), ("\u{f005}", 2));
        // Only the tab mentions it: found through the shell search, not the Tauri one.
        assert_eq!(db.search_note_ids_fts("pineapple*").unwrap(), vec!["a"]);
        assert!(db.search_notes_fts("pineapple*").unwrap().is_empty());

        db.delete_tab("t1").unwrap();
        let rest = db.tabs_for("a").unwrap();
        assert_eq!(rest.len(), 1);
        assert_eq!((rest[0].id.as_str(), rest[0].position), ("t2", 1));
        assert!(db.delete_tab("t1").is_err());

        let mut big = rest[0].clone();
        big.content_blocks = "x".repeat(MAX_NOTE_CONTENT_BYTES + 1);
        assert!(db.update_tab(&big).unwrap_err().contains("5 MB"));

        db.delete_note("a").unwrap();
        assert!(db.list_tabs().unwrap().is_empty(), "tabs go with their note");
        assert!(db.search_note_ids_fts("pineapple*").unwrap().is_empty(), "tab index cleaned by cascade");

        let mut n = db.get_note("b").unwrap().unwrap();
        n.tab_icon = "\u{f02d}".into();
        db.update_note(&n).unwrap();
        assert_eq!(db.get_note("b").unwrap().unwrap().tab_icon, "\u{f02d}");
    }

    #[test]
    fn bulk_stack_rolls_back_all_rows_on_database_failure() {
        let db = test_db();
        db.create_notes(&[note("a"), note("b")]).unwrap();
        db.conn.lock().unwrap().execute_batch(
            "CREATE TRIGGER reject_stack BEFORE UPDATE OF piled ON notes
             WHEN new.id='b' AND new.piled=1
             BEGIN SELECT RAISE(ABORT, 'test failure'); END;",
        ).unwrap();
        assert!(db.set_all_notes_piled(true).is_err());
        assert_eq!(db.get_all_notes().unwrap().len(), 2);
        assert!(db.get_piled_notes().unwrap().is_empty());
    }

    #[test]
    fn icon_pack_replacement_is_atomic() {
        let db = Database::new(std::path::Path::new(":memory:")).unwrap();
        let original = icon_pack("old", "Original");
        db.replace_all_icon_packs(&original).unwrap();

        let conflicting = icon_pack("old", "Conflicting");
        assert!(db.replace_icon_pack("old", &conflicting).is_err());
        let after_failure = db.get_icon_packs().unwrap();
        assert_eq!(after_failure.len(), 1);
        assert_eq!(after_failure[0].name, "Original");

        let replacement = icon_pack("new", "Replacement");
        db.replace_icon_pack("old", &replacement).unwrap();
        let after_success = db.get_icon_packs().unwrap();
        assert_eq!(after_success.len(), 1);
        assert_eq!(after_success[0].id, "new");
    }

    #[test]
    fn icon_pack_reference_query_checks_content_and_title_icons() {
        let db = Database::new(std::path::Path::new(":memory:")).unwrap();
        db.create_note(&note_with_icon_reference(
            "note-a",
            r#"[{"content":"![icon](asset://localhost/icon-packs/pack-a/icon.png)"}]"#,
            None,
        ))
        .unwrap();
        db.create_note(&note_with_icon_reference(
            "note-b",
            "[]",
            Some("asset://localhost/icon-packs/pack-b/icon.png"),
        ))
        .unwrap();

        assert!(db.icon_pack_is_referenced("pack-a").unwrap());
        assert!(db.icon_pack_is_referenced("pack-b").unwrap());
        assert!(!db.icon_pack_is_referenced("pack-c").unwrap());
    }

    #[test]
    fn create_notes_rolls_back_the_whole_batch() {
        let db = test_db();
        let duplicate_id = [note("same-id"), note("same-id")];

        assert!(db.create_notes(&duplicate_id).is_err());
        assert!(db.get_all_for_search().unwrap().is_empty());
    }

    #[test]
    fn settings_restore_replaces_absent_keys_atomically() {
        let db = test_db();
        db.set_setting("old", "stale").unwrap();
        db.set_setting("shared", "before").unwrap();
        let restored = std::collections::HashMap::from([
            ("shared".to_string(), "after".to_string()),
            ("new".to_string(), "value".to_string()),
        ]);

        db.replace_all_settings(&restored).unwrap();

        assert_eq!(db.get_all_settings().unwrap(), restored);
        assert_eq!(db.get_setting("old").unwrap(), None);

        db.replace_all_settings(&std::collections::HashMap::new()).unwrap();
        assert!(db.get_all_settings().unwrap().is_empty());
    }

    #[test]
    fn oversized_note_content_is_rejected_at_storage_boundary() {
        let db = test_db();
        let mut oversized = note("oversized");
        oversized.content_blocks = "x".repeat(MAX_NOTE_CONTENT_BYTES + 1);

        assert_eq!(
            db.create_note(&oversized).unwrap_err(),
            "Note content exceeds 5 MB"
        );
        assert!(db.get_all_for_search().unwrap().is_empty());
    }

    #[test]
    fn failed_oversized_update_preserves_existing_note() {
        let db = test_db();
        let mut existing = note("existing");
        db.create_note(&existing).unwrap();
        existing.content_blocks = "x".repeat(MAX_NOTE_CONTENT_BYTES + 1);

        assert!(db.update_note(&existing).is_err());
        assert_eq!(
            db.get_note("existing").unwrap().unwrap().content_blocks,
            "[]"
        );
    }

    #[test]
    fn legacy_oversized_note_can_be_updated_without_growing_content() {
        let db = test_db();
        let mut legacy = note("legacy");
        legacy.content_blocks = "x".repeat(MAX_NOTE_CONTENT_BYTES + 100);
        {
            let conn = db.conn.lock().unwrap();
            insert_note(&conn, &legacy).unwrap();
        }

        legacy.title = "Moved and renamed".into();
        legacy.position_x = 250.0;
        db.update_note(&legacy).unwrap();

        legacy.content_blocks.truncate(MAX_NOTE_CONTENT_BYTES + 50);
        db.update_note(&legacy).unwrap();
        assert_eq!(
            db.get_note("legacy")
                .unwrap()
                .unwrap()
                .content_blocks
                .len(),
            MAX_NOTE_CONTENT_BYTES + 50
        );
    }

    #[test]
    fn legacy_oversized_note_cannot_grow_further() {
        let db = test_db();
        let mut legacy = note("legacy-growth");
        legacy.content_blocks = "x".repeat(MAX_NOTE_CONTENT_BYTES + 100);
        {
            let conn = db.conn.lock().unwrap();
            insert_note(&conn, &legacy).unwrap();
        }

        legacy.content_blocks.push('x');
        assert_eq!(
            db.update_note(&legacy).unwrap_err(),
            "Note content exceeds 5 MB"
        );
    }

    #[test]
    fn legacy_oversized_icon_can_stay_or_shrink_but_not_grow() {
        let db = test_db();
        let mut legacy = note("legacy-icon");
        legacy.icon = Some("x".repeat(MAX_NOTE_ICON_BYTES + 100));
        {
            let conn = db.conn.lock().unwrap();
            insert_note(&conn, &legacy).unwrap();
        }

        legacy.title = "Renamed".into();
        db.update_note(&legacy).unwrap();

        legacy.icon = Some("x".repeat(MAX_NOTE_ICON_BYTES + 50));
        db.update_note(&legacy).unwrap();

        legacy.icon = Some("x".repeat(MAX_NOTE_ICON_BYTES + 51));
        assert_eq!(
            db.update_note(&legacy).unwrap_err(),
            "Note icon exceeds 2 MB"
        );
    }
}
