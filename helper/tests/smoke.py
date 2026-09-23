#!/usr/bin/env python3
"""Protocol smoke test for onote-helper.

Runs against a throwaway copy of a database, never the live one:
    ONOTE_DB=/tmp/dn-test.db python3 tests/smoke.py [path/to/onote-helper]
Without ONOTE_DB it creates an empty temp DB.
"""
import json, os, subprocess, sys, tempfile

helper = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "target", "release", "onote-helper")
db = os.environ.get("ONOTE_DB")
tmpdir = None
if not db:
    tmpdir = tempfile.mkdtemp(prefix="onote-smoke-")
    db = os.path.join(tmpdir, "desknotes.db")
assert "com.desknotes.omarchy" not in db, "refusing to run against the live database"

p = subprocess.Popen([helper], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                     env={**os.environ, "ONOTE_DB": db}, text=True, bufsize=1)
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
assert w and w["title"] == "Welcome to Onote" and w["pinned"] is True and w["positionX"] == 800, w
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
# A content save sent after "hide all" still carries the shell's cached "open" row; stacking is the helper's.
late = dict(stacked, piled=False)
assert ok("updateNote", note=late)["piled"] is True, "a content save never changes the stacked state"
restored = ok("unstackNote", noteId=note["id"])
assert restored["piled"] is False
assert ok("updateNote", note=dict(restored, piled=True))["piled"] is False
assert ok("stackAll") >= 1
assert ok("stackAll") == 0
assert ok("restoreAll") >= 1
assert ok("restoreAll") == 0

md = ok("renderMarkdown", noteId=note["id"])
assert md == "# Smoke test\n\nhello omarchy\n- [x] ship\n", repr(md)

assert note["fontSize"] is None, "unset: the note follows the shell font size"
ok("setSetting", key="onote.defaultFontSize", value="22")
bigger = ok("createNote"); assert bigger["fontSize"] == 22, bigger
ok("setSetting", key="onote.defaultFontSize", value="900"); assert ok("createNote")["fontSize"] == 40, "clamped"
ok("setSetting", key="onote.defaultFontSize", value="")
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
# Only open notes' tabs are listed; a stacked note's come with tabsFor on restore.
tab = ok("createTab", noteId=note["id"])
stacked = ok("stackNote", noteId=note["id"])
assert stacked["piled"] is True and stacked["contentBlocks"] == note["contentBlocks"], "stackNote returns the full row"
rows = {n["id"]: n for n in ok("listNotes")}
assert rows[note["id"]]["contentBlocks"] == "" and rows[note["id"]]["preview"].startswith("hello omarchy"), rows[note["id"]]
# A metadata save on the body-less row the helper handed out keeps the stored body.
slim = dict(rows[note["id"]]); slim["title"] = "Smoke kept"
assert ok("updateNote", note=slim)["contentBlocks"] == note["contentBlocks"], "an empty body never replaces the stored one"
assert ok("getNote", noteId=note["id"])["title"] == "Smoke kept"
slim["title"] = note["title"]; slim["bodyPending"] = True; slim["contentBlocks"] = "x"
assert ok("updateNote", note=slim)["contentBlocks"] == note["contentBlocks"], "nor a bodyPending row"
tab_row = dict(ok("tabsFor", noteId=note["id"])[0]); tab_row["contentBlocks"] = ""; tab_row["icon"] = "\uf004"
assert ok("updateTab", tab=tab_row)["contentBlocks"] == ok("getTab", tabId=tab_row["id"])["contentBlocks"] != "", "a tab's empty body is kept too"
assert ok("listTabs") == []
assert [t["id"] for t in ok("tabsFor", noteId=note["id"])] == [tab["id"]]
restored = ok("unstackNote", noteId=note["id"])
assert restored["contentBlocks"] == note["contentBlocks"]
rows = {n["id"]: n for n in ok("listNotes")}
assert rows[note["id"]]["contentBlocks"] == note["contentBlocks"] and "preview" in rows[note["id"]]
assert [t["id"] for t in ok("listTabs")] == [tab["id"]]

# listTabs is bounded like listNotes: past the 8 MB body budget, a tab travels
# as metadata with bodyPending, and getTab fetches it whole.
big_tabs = [tab] + [ok("createTab", noteId=note["id"]) for _ in range(2)]
for i, t in enumerate(big_tabs):
    t["contentBlocks"] = json.dumps([{"type": "text", "content": chr(ord("a") + i) * (3 * 1024 * 1024)}])
    ok("updateTab", tab=t)
rows = ok("listTabs")
assert [t["id"] for t in rows] == [t["id"] for t in big_tabs], rows
assert [t.get("bodyPending", False) for t in rows] == [False, False, True], [len(t["contentBlocks"]) for t in rows]
assert rows[2]["contentBlocks"] == "" and len(ok("getTab", tabId=rows[2]["id"])["contentBlocks"]) > 3 * 1024 * 1024
for t in big_tabs[1:]:
    ok("deleteTab", tabId=t["id"])
# The desktop edition's image title icon (up to 2 MB) rides in every listNotes
# row; past the 8 MB budget it is left out with iconPending, getNote has it
# whole, and a save from a row without it keeps the stored one.
icon = "data:image/png;base64," + "A" * (2 * 1024 * 1024 - 64)
iconed = []
for i in range(5):
    n = ok("createNote"); n["icon"] = icon; n["title"] = "Iconed %d" % i
    assert ok("updateNote", note=n)["icon"] == icon
    iconed.append(n["id"])
rows = {n["id"]: n for n in ok("listNotes")}
left_out = [i for i in iconed if rows[i].get("iconPending")]
assert len(left_out) >= 1 and all(rows[i]["icon"] is None for i in left_out), "icons past the budget are left out"
assert all(rows[i]["icon"] == icon for i in iconed if i not in left_out)
whole = ok("getNote", noteId=left_out[0]); assert whole["icon"] == icon
pending_row = dict(rows[left_out[0]]); pending_row["title"] = "Iconed, renamed"
assert ok("updateNote", note=pending_row)["icon"] == icon, "a save from the row without its icon keeps it"
no_key = dict(whole); del no_key["icon"]; no_key["title"] = "Iconed, renamed again"
assert ok("updateNote", note=no_key)["icon"] == icon, "a row that never carried the icon keeps it"
for i in iconed:
    ok("deleteNote", noteId=i)
tab["contentBlocks"] = json.dumps([{"type": "text", "content": "pineapple page"}])
ok("updateTab", tab=tab)

# Deleting a tab or a note takes the shell's `note.<id>.*` settings with it.
tab_key = "note.%s.label.%s" % (note["id"], tab["id"])
ok("setSetting", key=tab_key, value="Prices")
ok("setSetting", key="note.%s.title.main" % note["id"], value="Groceries")
assert ok("deleteTab", tabId=tab["id"]) is True
s = ok("listSettings")
assert tab_key not in s and s["note.%s.title.main" % note["id"]] == "Groceries", s
scratch = ok("createNote")
ok("setSetting", key="note.%s.titleLocked" % scratch["id"], value="true")
assert ok("deleteNote", noteId=scratch["id"]) is True
assert not [k for k in ok("listSettings") if k.startswith("note.%s." % scratch["id"])]
assert ok("listSettings")["note.%s.title.main" % note["id"]] == "Groceries", "another note's settings stay"
r = call("exportMarkdown", noteId=note["id"], path="/tmp/x"); assert not r["ok"] and "unknown op" in r["error"], r

# Private on disk: 0700 directory, 0600 database.
import stat
assert stat.S_IMODE(os.stat(os.path.dirname(db)).st_mode) == 0o700 or os.path.dirname(db) == tempfile.gettempdir(), oct(os.stat(os.path.dirname(db)).st_mode)
assert stat.S_IMODE(os.stat(db).st_mode) == 0o600, oct(os.stat(db).st_mode)

with tempfile.TemporaryDirectory(prefix="onote-smoke-") as tmp:
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
    gone = ok("createNote"); gone["title"] = "Gone"; ok("updateNote", note=gone)
    assert "Gone.md" in os.listdir(tmp + "/mirror")
    assert ok("deleteNote", noteId=gone["id"]) is True
    assert sorted(os.listdir(tmp + "/mirror")) == ["Smoke renamed.md"], "deleting a note removes its mirror file"
    assert ok("setMirrorDir", dir="off") == {"dir": "", "written": 0}
    # A folder that already holds a file with the note's name (an existing vault):
    # the note gets a suffixed name, the user's file is neither replaced nor deleted.
    os.makedirs(tmp + "/vault"); open(tmp + "/vault/Smoke renamed.md", "w").write("USER DOCUMENT")
    assert ok("setMirrorDir", dir=tmp + "/vault")["written"] >= 1
    assert os.listdir(tmp + "/mirror") == ["Smoke renamed.md"], "off, then another folder: the old folder's files are left behind, not moved away"
    assert open(tmp + "/vault/Smoke renamed.md").read() == "USER DOCUMENT"
    own = [f for f in os.listdir(tmp + "/vault") if f != "Smoke renamed.md"]
    assert own == ["Smoke renamed " + note["id"].replace("-", "")[:12] + ".md"], own
    # The same folder under another spelling is not a switch: nothing is removed.
    alias = tmp + "/vault/../vault"
    assert ok("setMirrorDir", dir=alias)["dir"] == os.path.realpath(tmp + "/vault"), "stored canonical"
    assert sorted(os.listdir(tmp + "/vault")) == sorted(own + ["Smoke renamed.md"]), os.listdir(tmp + "/vault")
    assert ok("setMirrorDir", dir=tmp + "/vault")["written"] >= 1
    assert sorted(os.listdir(tmp + "/vault")) == sorted(own + ["Smoke renamed.md"])
    # A folder that cannot be used leaves the working mirror in place.
    r = call("setMirrorDir", dir="/proc/desknotes-cannot-write"); assert not r["ok"] and "kept on the previous folder" in r["error"], r
    assert ok("getSetting", key="markdownMirrorDir") == os.path.realpath(tmp + "/vault")
    # The setting removed behind the helper's back (the desktop edition's settings
    # reset): the rows are stale, and a new folder must not move the old files away.
    ok("setSetting", key="markdownMirrorDir", value="")
    assert ok("setMirrorDir", dir=tmp + "/vault2")["written"] >= 1
    assert sorted(os.listdir(tmp + "/vault")) == sorted(own + ["Smoke renamed.md"]), "left behind, not moved"
    assert ok("setMirrorDir", dir=tmp + "/vault")["written"] >= 1
    assert sorted(os.listdir(tmp + "/vault")) == sorted(own + ["Smoke renamed.md"]), "reclaimed its own file, the user's untouched"
    assert ok("setMirrorDir", dir="off")["written"] == 0
    assert sorted(os.listdir(tmp + "/vault")) == sorted(own + ["Smoke renamed.md"])
    r = call("setMirrorDir", dir="/proc/desknotes-cannot-write"); assert not r["ok"] and "mirror not enabled" in r["error"], r
    r = call("setMirrorDir", dir="relative-folder"); assert not r["ok"] and "absolute" in r["error"], r
    assert not os.path.exists("relative-folder") and ok("getSetting", key="markdownMirrorDir") in ("", None), "refused before anything is created or stored"
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
    assert ok("clipboardImage", sources=[img["src"]] * 19) == img, "nineteen images: room for one more"
    r = call("clipboardImage", sources=[img["src"]] * 20)
    assert not r["ok"] and "20" in r["error"], r
    big = "data:image/png;base64," + __import__("base64").b64encode(png(4000, 4000)[:33]).decode()   # header only: 16 MP
    r = call("clipboardImage", sources=[big])
    assert not r["ok"] and "16 megapixels" in r["error"], r
    r = call("clipboardImage", sources=[], titleIcon=big)
    assert not r["ok"] and "16 megapixels" in r["error"], "a 16 MP title icon (the desktop edition's) fills the note's budget"
    assert ok("clipboardImage", sources=[img["src"]] * 19, titleIcon=img["src"]) == img, "the icon is not one of the 20"
    assert ok("clipboardImage", sources=[], titleIcon="\U0001F600") == img, "an emoji icon is no image"
    # An animation is held to the desktop edition's frame and pixel budgets, so
    # a note Onote accepts is one the desktop can still back up.
    def gif(w, h, frames):
        return b"GIF89a" + struct.pack("<HH", w, h) + b"\x00\x00\x00" + bytes([0x2C, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 1, 0, 0]) * frames + b"\x3B"
    subprocess.run(["wl-copy", "-t", "image/gif"], input=gif(1, 1, 61), **quiet)
    r = call("clipboardImage"); assert not r["ok"] and "60" in r["error"], r
    subprocess.run(["wl-copy", "-t", "image/gif"], input=gif(3000, 3000, 2), **quiet)
    r = call("clipboardImage"); assert not r["ok"] and "16 megapixels" in r["error"], r
    subprocess.run(["wl-copy", "-t", "image/gif"], input=gif(2000, 2000, 2), **quiet)
    anim = ok("clipboardImage"); assert anim and anim["mime"] == "image/gif", anim
    r = call("clipboardImage", sources=[anim["src"], anim["src"]])
    assert not r["ok"] and "16 megapixels" in r["error"], "two stored 8 MP animations fill the note's budget"
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
                   env={**os.environ, "ONOTE_DB": db})
assert r.returncode == 0 and '"pong"' in r.stdout, (r.returncode, r.stderr)
with sqlite3.connect(db) as conn:
    assert conn.execute("SELECT MAX(version) FROM schema_version").fetchone()[0] == 12
print("smoke: all checks passed")
