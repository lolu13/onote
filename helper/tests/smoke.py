#!/usr/bin/env python3
"""Protocol smoke test for desknotes-helper.

Runs against a throwaway copy of a database, never the live one:
    DESKNOTES_DB=/tmp/dn-test.db python3 tests/smoke.py [path/to/desknotes-helper]
Without DESKNOTES_DB it creates an empty temp DB.
"""
import json, os, subprocess, sys, tempfile

helper = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "target", "release", "desknotes-helper")
db = os.environ.get("DESKNOTES_DB")
tmpdir = None
if not db:
    tmpdir = tempfile.mkdtemp(prefix="dn-smoke-")
    db = os.path.join(tmpdir, "desknotes.db")
assert "com.desknotes.omarchy" not in db, "refusing to run against the live database"

p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env={**os.environ, "DESKNOTES_DB": db}, text=True, bufsize=1)
_id = 0
def call(op, **args):
    global _id
    _id += 1
    p.stdin.write(json.dumps({"id": _id, "op": op, **args}) + "\n")
    p.stdin.flush()
    resp = json.loads(p.stdout.readline())
    assert resp["id"] == _id, resp
    return resp

def ok(op, **args):
    r = call(op, **args)
    assert r["ok"], f"{op}: {r.get('error')}"
    return r["result"]

assert ok("ping") == "pong"
before = ok("listNotes")
w = ok("ensureWelcomeNote", x=800, y=60, width=380, height=560)
assert w and w["title"] == "Welcome to DeskNotes" and w["pinned"] is True and w["positionX"] == 800, w
assert ok("ensureWelcomeNote") is None, "only once"
assert ok("deleteNote", noteId=w["id"]) is True
assert ok("ensureWelcomeNote") is None, "remembered even after deletion"
assert ok("ensureWelcomeNote", force=True)["pinned"] is True
for n in ok("listNotes"): ok("deleteNote", noteId=n["id"])
note = ok("createNote")
assert note["piled"] is False and note["contentBlocks"] == '[{"type":"text","content":""}]'
assert note["createdAt"], "createNote must return the stored row with timestamps"

note["title"] = "Smoke test"
note["contentBlocks"] = json.dumps([{"type": "text", "content": "hello omarchy"},
                                    {"type": "todo", "content": "ship", "checked": True}])
updated = ok("updateNote", note=note)
assert updated["title"] == "Smoke test"
assert (updated["workspaceId"], updated["workspaceName"]) == (0, ""), updated
moved = dict(updated, workspaceId=-98, workspaceName="special:notes")
saved = ok("updateNote", note=moved)
assert (saved["workspaceId"], saved["workspaceName"]) == (-98, "special:notes"), saved
assert saved["contentBlocks"] == updated["contentBlocks"]

hits = ok("search", q="omarchy")
assert any(n["id"] == note["id"] for n in hits), hits
assert ok("searchNoteIds", q="omarchy") == [n["id"] for n in hits]
assert ok("searchNoteIds", q="   ") == []
assert ok("search", q="   ") == []

stacked = ok("stackNote", noteId=note["id"])
assert stacked["piled"] is True
restored = ok("unstackNote", noteId=note["id"])
assert restored["piled"] is False
assert ok("stackAll") >= 1
assert ok("stackAll") == 0
assert ok("restoreAll") >= 1
assert ok("restoreAll") == 0

md = ok("renderMarkdown", noteId=note["id"])
assert md == "# Smoke test\n\nhello omarchy\n- [x] ship\n", repr(md)

assert note["fontSize"] is None, "unset: the note follows the shell font size"
ok("setSetting", key="defaultFontSize", value="22")
bigger = ok("createNote"); assert bigger["fontSize"] == 22, bigger
ok("setSetting", key="defaultFontSize", value="900"); assert ok("createNote")["fontSize"] == 40, "clamped"
ok("setSetting", key="defaultFontSize", value="")
for n in ok("listNotes"):
    if n["id"] != note["id"]: ok("deleteNote", noteId=n["id"])
assert ok("listTabs") == []
tab = ok("createTab", noteId=note["id"])
assert (tab["noteId"], tab["position"]) == (note["id"], 1), tab
tab["icon"] = "\uf005"
tab["contentBlocks"] = json.dumps([{"type": "text", "content": "pineapple page"}])
saved = ok("updateTab", tab=tab)
assert saved["icon"] == "\uf005" and "pineapple" in saved["contentBlocks"], saved
assert ok("searchNoteIds", q="pineapple") == [note["id"]]
assert [t["id"] for t in ok("listTabs")] == [tab["id"]]
md2 = ok("renderMarkdown", noteId=note["id"])
assert md2 == md + "\n---\n\n<!-- tab 2 -->\npineapple page\n", repr(md2)
assert ok("deleteTab", tabId=tab["id"]) is True
assert ok("listTabs") == [] and ok("searchNoteIds", q="pineapple") == []
r = call("deleteTab", tabId=tab["id"]); assert not r["ok"] and "not found" in r["error"].lower(), r

# Stacked notes travel as metadata plus a bounded preview; open notes whole.
stacked = ok("stackNote", noteId=note["id"])
assert stacked["piled"] is True and stacked["contentBlocks"] == note["contentBlocks"], "stackNote returns the full row"
rows = {n["id"]: n for n in ok("listNotes")}
assert rows[note["id"]]["contentBlocks"] == "" and rows[note["id"]]["preview"].startswith("hello omarchy"), rows[note["id"]]
restored = ok("unstackNote", noteId=note["id"])
assert restored["contentBlocks"] == note["contentBlocks"]
rows = {n["id"]: n for n in ok("listNotes")}
assert rows[note["id"]]["contentBlocks"] == note["contentBlocks"] and "preview" in rows[note["id"]]
r = call("exportMarkdown", noteId=note["id"], path="/tmp/x"); assert not r["ok"] and "unknown op" in r["error"], r

# Private on disk: 0700 directory, 0600 database.
import stat
assert stat.S_IMODE(os.stat(os.path.dirname(db)).st_mode) == 0o700 or os.path.dirname(db) == tempfile.gettempdir(), oct(os.stat(os.path.dirname(db)).st_mode)
assert stat.S_IMODE(os.stat(db).st_mode) == 0o600, oct(os.stat(db).st_mode)

with tempfile.TemporaryDirectory(prefix="dn-smoke-") as tmp:
    path = ok("exportNote", noteId=note["id"], dir=tmp)
    assert path == os.path.join(tmp, "Smoke test.md") and open(path).read() == md, path
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    # A second export never replaces the first, and a planted symlink is not written through.
    victim = os.path.join(tmp, "victim"); open(victim, "w").write("must survive")
    os.symlink(victim, os.path.join(tmp, "Smoke test (2).md"))
    path2 = ok("exportNote", noteId=note["id"], dir=tmp)
    assert path2 == os.path.join(tmp, "Smoke test (3).md") and open(path2).read() == md, path2
    assert open(victim).read() == "must survive" and open(path).read() == md
    m = ok("setMirrorDir", dir=tmp + "/mirror")
    assert m["written"] >= 1, m
    mirrored = open(os.path.join(tmp, "mirror", "Smoke test.md")).read()
    assert mirrored.startswith("---\nid: " + note["id"]) and mirrored.endswith(md), mirrored
    note["title"] = "Smoke renamed"
    ok("updateNote", note=note)
    assert sorted(os.listdir(tmp + "/mirror")) == ["Smoke renamed.md"], os.listdir(tmp + "/mirror")
    assert ok("setMirrorDir", dir="off") == {"dir": "", "written": 0}
    # A folder that already holds a file with the note's name (an existing vault):
    # the note gets a suffixed name, the user's file is neither replaced nor deleted.
    os.makedirs(tmp + "/vault"); open(tmp + "/vault/Smoke renamed.md", "w").write("USER DOCUMENT")
    assert ok("setMirrorDir", dir=tmp + "/vault")["written"] >= 1
    assert open(tmp + "/vault/Smoke renamed.md").read() == "USER DOCUMENT"
    own = [f for f in os.listdir(tmp + "/vault") if f != "Smoke renamed.md"]
    assert own == ["Smoke renamed " + note["id"].replace("-", "")[:12] + ".md"], own
    assert ok("setMirrorDir", dir="off")["written"] == 0
    assert sorted(os.listdir(tmp + "/vault")) == sorted(own + ["Smoke renamed.md"])
    r = call("setMirrorDir", dir="/proc/desknotes-cannot-write"); assert not r["ok"] and "mirror not enabled" in r["error"], r
    assert ok("getSetting", key="markdownMirrorDir") in ("", None)
if os.environ.get("WAYLAND_DISPLAY"):
    assert ok("copyMarkdown", noteId=note["id"]) > 0
    assert ok("clipboardImage") is None, "text on the clipboard is not an image"
    import struct, zlib
    def png(w, h):
        raw = b"".join(b"\x00" + b"\xff\x00\x00" * w for _ in range(h))
        def chunk(t, d): return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xffffffff)
        return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")
    quiet = dict(check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["wl-copy", "-t", "image/png"], input=png(3, 2), **quiet)
    img = ok("clipboardImage")
    assert img and (img["width"], img["height"], img["mime"]) == (3, 2, "image/png") and img["src"].startswith("data:image/png;base64,"), img
    subprocess.run(["wl-copy", "sentinel"], **quiet)

assert ok("setSetting", key="smokeKey", value="1") is True
assert ok("getSetting", key="smokeKey") == "1"
assert ok("listSettings")["smokeKey"] == "1"

ok("saveTheme", theme={"id": "smoke", "name": "Smoke", "themeData": "{}", "createdAt": "", "updatedAt": ""})
assert any(t["id"] == "smoke" for t in ok("listThemes"))
ok("deleteTheme", themeId="smoke")

big = dict(note); big["contentBlocks"] = json.dumps([{"type": "text", "content": "x" * (6 * 1024 * 1024)}])
r = call("updateNote", note=big)
assert not r["ok"] and "5 MB" in r["error"], r

r = call("nope"); assert not r["ok"] and "unknown op" in r["error"]
p.stdin.write("this is not json\n"); p.stdin.flush()
r = json.loads(p.stdout.readline()); assert not r["ok"] and r["id"] is None

ok("deleteNote", noteId=note["id"])
assert len(ok("listNotes")) == len(before)

p.stdin.close()
assert p.wait(timeout=5) == 0, "helper should exit 0 when stdin closes"

# A database left half-upgraded by an interrupted launch (migration 10's first
# ALTER committed, version row missing) must still open.
import sqlite3
with sqlite3.connect(db) as conn:
    conn.executescript("""DELETE FROM schema_version WHERE version >= 10;
        DROP TABLE mirror_files; DROP TABLE tabs_fts; DROP TABLE note_tabs;
        ALTER TABLE notes DROP COLUMN tab_icon; ALTER TABLE notes DROP COLUMN workspace_name;""")
r = subprocess.run([helper], input='{"id":1,"op":"ping"}\n', text=True, capture_output=True,
                   env={**os.environ, "DESKNOTES_DB": db})
assert r.returncode == 0 and '"pong"' in r.stdout, (r.returncode, r.stderr)
with sqlite3.connect(db) as conn:
    assert conn.execute("SELECT MAX(version) FROM schema_version").fetchone()[0] == 12
print("smoke: all checks passed")
