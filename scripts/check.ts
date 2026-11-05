import { resolve } from "node:path";
import { requirePinnedBun } from "./bun-pin.ts";

requirePinnedBun();

const root = resolve(import.meta.dir, "..");

interface Step {
    name: string;
    cmd: string[];
}

const STEPS: readonly Step[] = [
    { name: "types", cmd: ["bunx", "tsc", "--noEmit", "-p", "tsconfig.json"] },
    { name: "lint", cmd: ["bun", "scripts/lint.ts"] },
    { name: "dead code", cmd: ["bunx", "knip", "--no-progress"] },
    { name: "state models", cmd: ["bun", "scripts/state-models.ts"] },
    { name: "web bundles", cmd: ["bun", "scripts/build-web.ts", "--check"] },
    { name: "tests", cmd: ["bun", "scripts/test.ts"] },
    { name: "page budget", cmd: ["bun", "scripts/budget.ts"] },
    { name: "C sanitizers", cmd: ["sh", "scripts/sanitize.sh"] },
    { name: "C warnings", cmd: ["sh", "scripts/c-warnings.sh"] },
    { name: "process replay", cmd: ["bun", "scripts/replay.ts"] },
];

const only = process.argv.slice(2).filter((a) => !a.startsWith("-"));
let failed = 0;
for (const step of STEPS) {
    if (only.length > 0 && !only.includes(step.name)) continue;
    console.log("\n== " + step.name);
    const r = Bun.spawnSync(step.cmd, { cwd: root, stdout: "inherit", stderr: "inherit" });
    if (r.exitCode !== 0) {
        failed++;
        console.log("FAILED: " + step.name);
    }
}
if (failed > 0) process.exit(1);
console.log("\nall checks passed");
