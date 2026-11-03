import { test, expect, mock } from "bun:test";
import { installDom, fakeDocument, FakeElement } from "./fakedom.ts";
import { storeStub, failSaves } from "./app_stubs/store.ts";
import { uiModule, menuItems } from "./app_stubs/ui.ts";
import { previewModule } from "./app_stubs/preview.ts";
import { findStub } from "./app_stubs/find.ts";
import { exportStub } from "./app_stubs/export.ts";
import { panelsStub } from "./app_stubs/panels.ts";

const dom = installDom();
const generic = new Map<string, FakeElement>();
fakeDocument.getElementById = (id: string): FakeElement => {
    if (id === "source") return dom.textarea;
    if (id === "highlight") return dom.highlight;
    if (id === "editor") return dom.box;
    if (id === "placeholder") return dom.placeholder;
    let el = generic.get(id);
    if (!el) {
        el = new FakeElement();
        el.id = id;
        generic.set(id, el);
    }
    return el;
};
Reflect.set(globalThis, "matchMedia", () => ({ matches: false, addEventListener() {} }));
Reflect.set(globalThis, "addEventListener", () => {});

mock.module("../src/store.ts", () => storeStub);
mock.module("../src/ui.ts", () => uiModule);
mock.module("../src/preview.ts", () => previewModule);
mock.module("../src/find.ts", () => findStub);
mock.module("../src/export.ts", () => exportStub);
mock.module("../src/panels.ts", () => panelsStub);

await import("../src/app.ts");
const E = await import("../src/editor.ts");
const settle = (): Promise<void> => new Promise((r) => setTimeout(r, 50));
await settle();


async function openFromMenu(label: string): Promise<void> {
    const item = menuItems("title-menu").find((i) => i.label === label);
    if (!item?.action) throw new Error("project " + label + " is not in the title menu");
    await item.action();
    await settle();
}

test("project-save.sm.md row saving/save_failed: an edit whose save failed is still there when the project opens again", async () => {
    dom.textarea.key("x");
    expect(E.text()).toBe("lpha\n");
    failSaves.remaining = 1;
    await openFromMenu("B");
    await openFromMenu("A");
    expect(E.text()).toBe("lpha\n");
});
