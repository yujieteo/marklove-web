import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
const SELF = "scripts/state-models.ts";

interface Model {
    machine: string;
    covers: readonly string[];
    hash: string;
}

const MODELS: readonly Model[] = [
    { machine: "docs/state/voice.sm.md", covers: ["src/voice.ts"], hash: "d4a5dbdce6d076d2511773e7d4c110e483094161e796a7aff9234c823781e841" },
    { machine: "docs/state/project-save.sm.md", covers: ["src/app.ts"], hash: "fb632c2e063909f757c8275568d5e10d5900d1d0e660fb70b58fd84da5300174" },
];

function hashOf(model: Model): string {
    const h = createHash("sha256");
    for (const f of [model.machine, ...model.covers]) h.update(f + "\0").update(readFileSync(resolve(root, f)));
    return h.digest("hex");
}

if (process.argv.includes("--update")) {
    let text = readFileSync(resolve(root, SELF), "utf8");
    for (const m of MODELS) {
        const next = hashOf(m);
        const entry = `machine: "${m.machine}", covers: ${JSON.stringify(m.covers)}, hash: "${m.hash}"`;
        text = text.replace(entry, `machine: "${m.machine}", covers: ${JSON.stringify(m.covers)}, hash: "${next}"`);
    }
    writeFileSync(resolve(root, SELF), text);
    console.log("state model hashes updated");
    process.exit(0);
}

let stale = 0;
for (const m of MODELS) {
    if (hashOf(m) !== m.hash) {
        stale++;
        console.log(m.machine + " is out of date for " + m.covers.join(", ") + ": run sm-axi check " + m.machine + ", then bun scripts/state-models.ts --update");
    }
}
if (stale > 0) process.exit(1);
console.log("state models: " + String(MODELS.length) + " current");
