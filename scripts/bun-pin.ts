import { readFileSync } from "node:fs";
import { resolve } from "node:path";

function pinnedBun(): string {
    const pkg: unknown = JSON.parse(readFileSync(resolve(import.meta.dir, "../package.json"), "utf8"));
    const field = typeof pkg === "object" && pkg !== null && "packageManager" in pkg ? pkg.packageManager : undefined;
    if (typeof field !== "string" || !field.startsWith("bun@")) throw new Error("package.json must set packageManager to bun@<version>");
    return field.slice("bun@".length);
}

export function requirePinnedBun(): void {
    const pin = pinnedBun();
    if (Bun.version === pin) return;
    console.error("Bun " + Bun.version + " is not the pinned Bun " + pin + " (package.json packageManager). Use Bun " + pin + ".");
    process.exit(1);
}
