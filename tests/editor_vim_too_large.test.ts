import { test, expect } from "bun:test";
import { installDom } from "./fakedom.ts";

const dom = installDom();
const C = await import("../src/core.ts");
await C.load();
const E = await import("../src/editor.ts");
E.init(dom);

function insertMode(text: string): void {
    E.setText("short\n");
    E.setVim(true);
    dom.textarea.key("i");
    expect(E.editor.vimMode).toBe("insert");
    if (text !== E.text()) E.replaceAll(text);
}

const big = "x".repeat(C.MAX_SOURCE_BYTES) + "\nmore\n";

test("small text: Ctrl+Z and Ctrl+X in Insert mode go to the browser", () => {
    insertMode("short\n");
    for (const k of ["z", "x"]) expect(dom.textarea.key(k, { ctrlKey: true })).toBe(false);
});

test("text over 512 KB: Ctrl+Z (undo the paste) and Ctrl+X (cut a part to split the project) in Insert mode still go to the browser", () => {
    insertMode(big);
    expect(dom.textarea.key("z", { ctrlKey: true })).toBe(false);
    expect(dom.textarea.key("x", { ctrlKey: true })).toBe(false);
});

test("text over 512 KB: Escape keeps Insert mode and says why", () => {
    insertMode(big);
    dom.textarea.key("Escape");
    expect(E.editor.vimMode).toBe("insert");
    expect(E.editor.vimStatus).toMatch(/512 KB/);
});

test("text over 512 KB: i in Normal mode enters Insert mode", () => {
    E.setText(big);
    E.setVim(true);
    dom.textarea.key("i");
    expect(E.editor.vimMode).toBe("insert");
});
