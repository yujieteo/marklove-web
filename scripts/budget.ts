import { gzipSync } from "node:zlib";
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const webDir = join(root, "web");

const KB = 1024;
export const DEFAULT_BUDGET = 540 * KB;

export const ROUTE_BUDGETS: Readonly<Record<string, number>> = {
    "index.html": 540 * KB,
};

const ATTRIBUTE_FILES = /(?:src|href)="([^"#?]+\.(?:js|css|mjs|wasm))"/g;
const EXTERNAL = /^(?:[a-z]+:)?\/\//;
const SERVER_ROOT_SHARED = /^\//;
const IMPORT_FROM = /(?:import|export)\s[^"']*?from\s*["']([^"']+)["']|import\s*["']([^"']+)["']/g;
const FETCHED_ON_START = ["style.css", "runtime.js", "article.css", "article.js"];
const LOADED_BY_URL = /new URL\(['"]([^'"]+)['"],\s*import\.meta\.url\)/g;

function firstLoadFiles(page: string): string[] {
    const seen = new Set<string>();
    const visit = (rel: string) => {
        if (seen.has(rel)) return;
        seen.add(rel);
        if (!rel.endsWith(".js") && !rel.endsWith(".mjs")) return;
        const text = readFileSync(join(webDir, rel), "utf8");
        for (const m of text.matchAll(IMPORT_FROM)) {
            const spec = m[1] ?? m[2];
            if (spec !== undefined && spec.startsWith(".")) visit(join(dirname(rel), spec));
        }
        for (const m of text.matchAll(LOADED_BY_URL)) {
            const target = m[1];
            if (target !== undefined) visit(join(dirname(rel), target));
        }
    };
    const html = readFileSync(join(webDir, page), "utf8");
    for (const m of html.matchAll(ATTRIBUTE_FILES)) {
        const href = m[1];
        if (href === undefined || EXTERNAL.test(href) || SERVER_ROOT_SHARED.test(href)) continue;
        visit(href);
    }
    for (const f of FETCHED_ON_START) visit(f);
    return [page, ...[...seen].sort()];
}

const gz = (rel: string) => gzipSync(readFileSync(join(webDir, rel)), { level: 9 }).length;

const pages = Bun.spawnSync(["git", "ls-files", "web"], { cwd: root }).stdout.toString().split("\n")
    .filter((f) => f.endsWith(".html")).map((f) => f.slice("web/".length));

let failed = false;
for (const page of pages) {
    const files = firstLoadFiles(page);
    const total = files.reduce((n, f) => n + gz(f), 0);
    const budget = ROUTE_BUDGETS[page] ?? DEFAULT_BUDGET;
    const ok = total <= budget;
    if (!ok) failed = true;
    console.log((ok ? "ok   " : "FAIL ") + page + " first load " + String(Math.round(total / KB * 10) / 10) + " KB gzip, budget " + String(budget / KB) + " KB");
    if (!ok || process.argv.includes("--verbose")) for (const f of files) console.log("       " + f + " " + String(gz(f)) + " B");
}
if (pages.length === 0) throw new Error("No page found in web/");
process.exit(failed ? 1 : 0);
