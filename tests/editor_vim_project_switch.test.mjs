// Row: vim | open_project | vim on | (same Vim state) — app.js:62 calls setVim
// only when the Vim setting changes, so another project keeps the engine's
// undo history. core/vim.goose:5 says: call vim_reset "when another document
// is opened". Targets web/editor.js and web/app.js:62 at 2fd4a95.
//   node --test <this file>   (from the root of a marklove-web copy, with tests/fakedom.mjs)

import { test } from "node:test";
import assert from "node:assert/strict";
import { installDom } from "./fakedom.mjs";

const dom = installDom();
const C = await import("../web/core.js");
await C.load();
const E = await import("../web/editor.js");
E.init(dom);
let saved = null;
E.editor.onChange = (t) => { saved = t; };

test("Vim u in a new project does not bring back the text of the old project", () => {
    // Project A is open with Vim on, as openProject and applySettings do it.
    E.setText("alpha\n");
    E.setVim(true);
    dom.textarea.key("x");
    assert.equal(E.text(), "lpha\n");
    // openProject(B): setText, then applySettings(true), which calls setVim and so C.vimReset.
    E.setText("beta\n");
    E.setVim(true);
    saved = null;
    dom.textarea.key("u");
    // Nothing to undo in project B: its text stays.
    assert.equal(E.text(), "beta\n");
    assert.equal(saved, null, "the change goes to onChange, and app.js saves it to project B");
});
