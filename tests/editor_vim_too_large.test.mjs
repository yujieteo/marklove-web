// Row: vim | key | text > 512 KB | (same mode, key prevented) — editor.js:432
// catches TooLarge and returns true, so the browser never gets the key. With a
// small text, the engine gives Ctrl keys that Vim does not use to the browser
// (core/vim.goose vm_ctrl_used). Targets web/editor.js at 2fd4a95.
//   node --test <this file>   (from the root of a marklove-web copy, with tests/fakedom.mjs)

import { test } from "node:test";
import assert from "node:assert/strict";
import { installDom } from "./fakedom.mjs";

const dom = installDom();
const C = await import("../web/core.js");
await C.load();
const E = await import("../web/editor.js");
E.init(dom);

// Insert mode, as after "i" and a paste of a long text (Ctrl+V in Insert mode
// goes to the browser).
function insertMode(text) {
    E.setText("short\n");
    E.setVim(true);
    dom.textarea.key("i");
    assert.equal(E.editor.vimMode, "insert");
    if (text !== E.text()) E.replaceAll(text);
}

const big = "x".repeat(C.MAX_SOURCE_BYTES) + "\nmore\n";

test("small text: Ctrl+Z and Ctrl+X in Insert mode go to the browser", () => {
    insertMode("short\n");
    for (const k of ["z", "x"]) assert.equal(dom.textarea.key(k, { ctrlKey: true }), false, "Ctrl+" + k);
});

test("text over 512 KB: Ctrl+Z and Ctrl+X in Insert mode still go to the browser", () => {
    insertMode(big);
    // Undo the paste, or cut a part to split the project (the banner says
    // "Split the text into more projects").
    assert.equal(dom.textarea.key("z", { ctrlKey: true }), false, "Ctrl+Z (undo) does nothing");
    assert.equal(dom.textarea.key("x", { ctrlKey: true }), false, "Ctrl+X (cut) does nothing");
});

test("text over 512 KB: Escape keeps Insert mode and says why", () => {
    insertMode(big);
    dom.textarea.key("Escape");
    assert.equal(E.editor.vimMode, "insert");
    assert.match(E.editor.vimStatus, /512 KB/);
});

test("text over 512 KB: i in Normal mode enters Insert mode", () => {
    E.setText(big);
    E.setVim(true);
    dom.textarea.key("i");
    assert.equal(E.editor.vimMode, "insert", "Vim stays in Normal mode: " + E.editor.vimStatus);
});
