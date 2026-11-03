import type * as Real from "../../src/ui.ts";
import { FakeElement } from "../fakedom.ts";

const menus: Record<string, Real.MenuItems> = {};

const uiStub = {
    announce: (): void => {},
    attachMenu: (button: HTMLElement, items: Real.MenuItems): void => { menus[button.id] = items; },
    closeMenu: (): void => {},
    alertBox: async (): Promise<void> => {},
    confirmBox: async <T>(): Promise<T | null> => null,
    download: (): void => {},
    pickFile: async (): Promise<File[]> => [],
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
