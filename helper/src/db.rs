//! The database layer shared with the Tauri edition, vendored as shared/db.rs
//! by the sync script. It only depends on rusqlite and serde.
#![allow(dead_code)]
#[path = "shared/db.rs"]
mod inner;
pub use inner::*;
