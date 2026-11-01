// Row: vim | open_project | vim on | (same Vim state) — openProject must call
// applySettings(true), so the Vim engine resets. core/vim.goose:5 says: call
// vim_reset "when another document is opened". This test loads the real web/app.js
// with a fake DOM and stub modules (tests/app_stubs), then opens project B
// through the title menu, as a user does.
//   node --import ./tests/app_stubs/register.mjs --test <this file>

import { test } from "node:test";
import assert from "node:assert/strict";
import { installDom } from "./fakedom.mjs";

const dom = installDom();
const El = dom.box.constructor;
Object.assign(El.prototype, { setAttribute() {}, remove() {} });
const els = {};
document.getElementById = (id) => (els[id] ||= Object.assign(id === "source" ? dom.textarea : id === "highlight" ? dom.highlight : id === "editor" ? dom.box : id === "placeholder" ? dom.placeholder : new El(), { id }));
globalThis.matchMedia = () => ({ matches: false, addEventListener() {} });
globalThis.addEventListener = () => {};
document.title = "";

const UI = await import("./app_stubs/ui.mjs");
const Store = await import("./app_stubs/store.mjs");
await import("../web/app.js");
const E = await import("../web/editor.js");
const settle = () => new Promise((r) => setTimeout(r, 50));
await settle();

test("Vim u in a new project does not bring back the text of the old project", async () => {
    // Project A is open with Vim on.
    assert.equal(E.text(), "alpha\n");
    assert.equal(E.editor.vim, true);
    dom.textarea.key("x");
    assert.equal(E.text(), "lpha\n");
    // Open project B from the title menu.
    const item = UI.menus["title-menu"]().find((i) => i.label === "B");
    await item.action();
    await settle();
    assert.equal(E.text(), "beta\n");
    Store.log.length = 0;
    dom.textarea.key("u");
    // Nothing to undo in project B: its text stays and nothing is saved.
    assert.equal(E.text(), "beta\n");
    await settle();
    assert.deepEqual(Store.log.filter((s) => s.startsWith("b:")), []);
});
