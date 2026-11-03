import type * as Real from "../../src/ui.ts";
import { FakeElement } from "../fakedom.ts";

const menus: Record<string, Real.MenuItems> = {};
export const announced: string[] = [];
export const picked: { files: File[] } = { files: [] };

const uiStub = {
    announce: (text: string | null | undefined): void => { if (text) announced.push(text); },
    attachMenu: (button: HTMLElement, items: Real.MenuItems): void => { menus[button.id] = items; },
    closeMenu: (): void => {},
    alertBox: async (): Promise<void> => {},
    confirmBox: async <T>(): Promise<T | null> => null,
    download: (): void => {},
    pickFile: async (): Promise<File[]> => picked.files,
    copyText: async (): Promise<boolean> => true,
    isMac: false,
    cmdKey: "Ctrl+",
} satisfies Partial<typeof Real>;

export function menuItems(id: string): Real.MenuItem[] {
    const items = menus[id];
    if (items === undefined) throw new Error("No menu on #" + id);
    return typeof items === "function" ? items() : items;
}

export const uiModule = {
    ...uiStub,
    h: (): FakeElement => new FakeElement(),
    segmented: (): FakeElement => new FakeElement(),
};
