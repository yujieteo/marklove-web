import ts from "typescript";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { findComments } from "./comments.ts";
import { checkJpl } from "./jpl.ts";

const root = resolve(import.meta.dir, "..");

export const EXCLUDED_FROM_LINT: readonly string[] = [
    "web/marklove.mjs",
    "web/marklove.wasm",
    "web/app.js",
    "web/runtime.js",
    "web/article.js",
    "web/marklove.d.mts",
    "bun.lock",
];

const ALLOWED_JAVASCRIPT: readonly string[] = ["web/marklove.mjs", "web/app.js", "web/runtime.js", "web/article.js"];
const COMMENT_EXTENSIONS = [".ts", ".goose", ".h", ".sh"];
const TYPE_SYNTAX_EXTENSIONS = [".ts"];

const listed = Bun.spawnSync(["git", "ls-files", "--cached", "--others", "--exclude-standard"], { cwd: root });
const files = listed.stdout.toString().split("\n").filter((f) => f !== "" && !EXCLUDED_FROM_LINT.includes(f));

const problems: string[] = [];
const fail = (file: string, line: number, what: string) => problems.push(file + ":" + String(line) + " " + what);

for (const file of files) {
    const dot = file.lastIndexOf(".");
    const ext = dot < 0 ? "" : file.slice(dot);
    if ((ext === ".js" || ext === ".mjs" || ext === ".cjs" || ext === ".jsx") && !ALLOWED_JAVASCRIPT.includes(file)) {
        fail(file, 1, "JavaScript source is not allowed: use TypeScript");
    }
    const text = readFileSync(resolve(root, file), "utf8");
    if (COMMENT_EXTENSIONS.includes(ext)) {
        for (const c of findComments(file, text)) fail(file, c.line, "comment: " + c.text.slice(0, 60));
    }
    if (TYPE_SYNTAX_EXTENSIONS.includes(ext)) {
        const sf = ts.createSourceFile(file, text, ts.ScriptTarget.ES2022, true, ts.ScriptKind.TS);
        const at = (n: ts.Node) => sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1;
        const visit = (n: ts.Node): void => {
            if (n.kind === ts.SyntaxKind.AnyKeyword) fail(file, at(n), "explicit any");
            if (ts.isAsExpression(n) && !(ts.isTypeReferenceNode(n.type) && n.type.typeName.getText(sf) === "const")) fail(file, at(n), "type assertion (as)");
            if (ts.isTypeAssertionExpression(n)) fail(file, at(n), "type assertion (<T>)");
            if (ts.isNonNullExpression(n)) fail(file, at(n), "non-null assertion (!)");
            ts.forEachChild(n, visit);
        };
        visit(sf);
    }
}

for (const p of checkJpl(root)) problems.push(p);

if (problems.length > 0) {
    console.log(problems.join("\n"));
    console.log(String(problems.length) + " lint problem(s)");
    process.exit(1);
}
console.log("lint: " + String(files.length) + " files clean");
