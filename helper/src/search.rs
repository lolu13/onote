//! Ported from `src-tauri/src/lib.rs` (`fts_query`). Keep in sync.

/// Convert a raw user search string to a safe FTS5 MATCH expression.
/// Tokens are reduced to alphanumerics/underscore (so we never inject FTS5
/// operators) and lowercased (FTS5 keywords AND/OR/NOT/NEAR are case-sensitive).
/// Tokens are prefix-matched and AND-joined. Empty string if nothing usable remains.
pub fn fts_query(user: &str) -> String {
    user.split_whitespace()
        .map(|t| {
            t.chars()
                .filter(|c| c.is_alphanumeric() || *c == '_')
                .collect::<String>()
                .to_lowercase()
        })
        .filter(|t| !t.is_empty())
        .map(|t| format!("{t}*"))
        .collect::<Vec<_>>()
        .join(" AND ")
}

#[cfg(test)]
mod tests {
    use super::fts_query;

    #[test]
    fn strips_operators_and_prefix_matches() {
        assert_eq!(fts_query("hello world"), "hello* AND world*");
        assert_eq!(fts_query("  AND  "), "and*");
        assert_eq!(fts_query("a\"b OR c*"), "ab* AND or* AND c*");
        assert_eq!(fts_query("***"), "");
        assert_eq!(fts_query(""), "");
    }
}
