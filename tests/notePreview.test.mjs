import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

// Execute the same plain-JS function used by QML; only its QML pragma is removed.
const source = readFileSync(new URL("../NotePreview.js", import.meta.url), "utf8");
const context = vm.createContext({});
vm.runInContext(source.replace(/^\.pragma library\s*/, ""), context);
const preview = blocks => context.text(JSON.stringify(blocks));

test("note preview preserves mixed-block labels without image payloads", () => {
  assert.equal(preview([
    { type: "text", content: "Hello" },
    { type: "label", label: "Status", content: "Ready" },
    { type: "image", src: "data:image/png;base64,private-image-data" },
    { type: "divider" },
    { type: "todo", content: "Next" },
  ]), "Hello  ·  Status: Ready  ·  [image]  ·  —  ·  Next");
});

test("one large block cannot send megabytes to the library text layout", () => {
  const text = preview([{ type: "text", content: "a".repeat(1024 * 1024) }]);
  assert.equal(text, "a".repeat(400));
  assert.equal(preview([{ type: "label", label: "b".repeat(1000), content: "c".repeat(1000) }]), "b".repeat(400));
});

test("preview bound includes separators and preserves Unicode boundaries", () => {
  assert.equal(preview([{ content: "a".repeat(398) }, { content: "tail" }]).length, 400);
  assert.equal(preview([{ content: "a".repeat(399) + "🌻" }]), "a".repeat(399));
  assert.equal(preview([{ content: "Romanian: ș ț â î ă 🌻" }]), "Romanian: ș ț â î ă 🌻");
});

test("invalid and empty note content has an empty preview", () => {
  for (const raw of ["bad JSON", "null", "{}", "[]", ""]) assert.equal(context.text(raw), "");
  assert.equal(preview([null, {}, { type: "text", content: "" }]), "");
});
