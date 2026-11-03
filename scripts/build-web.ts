import { readFileSync, writeFileSync, mkdtempSync, rmSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

import { requirePinnedBun } from "./bun-pin.ts";

const root = resolve(import.meta.dir, "..");
const CORE_IMPORT = /(["'])[^"'\n]*marklove\.mjs\1/g;
const CORE_FROM_BUNDLE = '"./marklove.mjs"';

requirePinnedBun();

interface Bundle {
    entry: string;
    out: string;
    format: "esm" | "iife";
}

export const BUNDLES: readonly Bundle[] = [
    { entry: "src/app.ts", out: "web/app.js", format: "esm" },
    { entry: "src/runtime.ts", out: "web/runtime.js", format: "iife" },
    { entry: "src/article.ts", out: "web/article.js", format: "iife" },
];

async function bundle(b: Bundle, outdir: string): Promise<string> {
    const result = await Bun.build({
        entrypoints: [join(root, b.entry)],
        outdir,
        naming: "[name].js",
        target: "browser",
        format: b.format,
        minify: false,
        external: ["*/marklove.mjs"],
    });
    if (!result.success) throw new Error(result.logs.map(String).join("\n"));
    const file = result.outputs[0];
    if (file === undefined) throw new Error("No output for " + b.entry);
    return (await file.text()).replaceAll(CORE_IMPORT, CORE_FROM_BUNDLE);
}

const check = process.argv.includes("--check");
const scratch = mkdtempSync(join(tmpdir(), "marklove-build-"));
let stale = 0;
for (const b of BUNDLES) {
    const text = await bundle(b, scratch);
    const target = join(root, b.out);
    if (check) {
        const current = existsSync(target) ? readFileSync(target, "utf8") : "";
        if (current !== text) {
            console.log(b.out + " is out of date: run bun run build:web");
            stale++;
        }
    } else {
        writeFileSync(target, text);
        console.log("Built " + b.out);
    }
}
rmSync(scratch, { recursive: true, force: true });
if (stale > 0) process.exit(1);
