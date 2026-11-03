import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { CLOSURE_MARK, decode, encode, type CallRecord, type Wire } from "./replay-codec.ts";

const [root, logFile, outFile] = process.argv.slice(2);
if (root === undefined || logFile === undefined || outFile === undefined) throw new Error("usage: replay-run <root> <log> <out>");

const entry = ["src/core.ts", "web/core.js"].map((p) => join(root, p)).find((p) => existsSync(p));
if (entry === undefined) throw new Error("No core module in " + root);
const core: Record<string, unknown> = await import(entry);

function isRecordList(v: unknown): v is CallRecord[] {
    return Array.isArray(v) && v.every((r) => typeof r === "object" && r !== null && "fn" in r && "args" in r && "result" in r);
}

const parsed: unknown = JSON.parse(readFileSync(logFile, "utf8"));
if (!isRecordList(parsed)) throw new Error("Bad capture log " + logFile);

const closures = new Map<number, unknown>();
const results: Wire[] = [];
for (const [index, rec] of parsed.entries()) {
    const mark = rec.fn.indexOf(CLOSURE_MARK);
    const fn = mark < 0 ? core[rec.fn] : closures.get(Number(rec.fn.slice(mark + 1)));
    if (typeof fn !== "function") {
        results.push({ error: "missing export " + rec.fn });
        continue;
    }
    const args = rec.args.map(decode);
    try {
        const value: unknown = await Reflect.apply(fn, undefined, args);
        if (typeof value === "function") closures.set(index, value);
        results.push(await encode(value));
    } catch (e) {
        results.push(await encode(e));
    }
}
writeFileSync(outFile, JSON.stringify(results));
