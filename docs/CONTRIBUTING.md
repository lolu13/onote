# Contributing to Onote

## Scope

Onote is a small, Omarchy-only notes plugin. It is its own project, not a port to keep in step
with anything else.

- The database stays at `~/.local/share/com.desknotes.omarchy/desknotes.db` and its schema only
  grows through migrations in `helper/src/db.rs`. People's notes live there.
- The plugin runs inside the user's shell. Read [LESSONS.md](LESSONS.md) before touching window
  rules, the helper protocol, the installer or the update check, and [DESIGN.md](DESIGN.md) for
  how the parts fit.
- No agent instruction files (`CLAUDE.md`, `AGENTS.md`, `.claude/`, `.codex/`) in the repository:
  `omarchy plugin add` copies the tree verbatim onto users' machines. `.gitignore` keeps local
  ones out.

## Checks

Run all of them from the repository root before opening a pull request.

```sh
python3 scripts/test-qml.py
cargo test --release --manifest-path helper/Cargo.toml
cargo build --release --locked --manifest-path helper/Cargo.toml
python3 helper/tests/smoke.py helper/target/release/onote-helper
node --test tests/notePreview.test.mjs
omarchy-plugin-validate .
python3 scripts/test-workspace-rules.py     # needs the running Omarchy session
```

The smoke test uses a throwaway database; `ONOTE_DB=/abs/path` points it at a copy of a real one.
After installing, also look at `hyprctl configerrors` and
`journalctl --user -t omarchy-shell -o cat | grep WARN`.

## Pull requests and releases

- Work on a branch, open a pull request against `main`. CI (`.github/workflows/helper.yml`) must
  be green.
- A change a user can notice gets a line in [CHANGELOG.md](../CHANGELOG.md) under the next version,
  written for that user. A shortcut change also updates `KEYBINDINGS.md`, the README table and
  the welcome note (`helper/src/welcome.rs`).
- A release bumps `version` in `manifest.json`, is squash-merged, and is then submitted to the
  Omarchy plugin marketplace as a newer commit to verify. The listing keeps the previous commit
  until that review passes.
