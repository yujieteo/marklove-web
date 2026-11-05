import ts from "typescript";
import { Glob } from "bun";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const JPL_GOOSE_GLOBS = ["core/**/*.goose"];
const SOURCE_GLOBS = ["src/**/*.ts", "scripts/**/*.ts", "tests/**/*.ts", "docs/**/*.ts"];
const JPL_MAX_LINES = 60;
export const JPL_RECURSIVE_FUNCTIONS: readonly string[] = [
    "core/deck.goose:tk_blocks",
    "core/edit.goose:rx_alt",
    "core/edit.goose:rx_cat",
    "core/edit.goose:rx_atom",
    "core/edit.goose:rx_emit",
    "core/edit.goose:rx_add",
    "core/edit.goose:sm_compound",
    "core/edit.goose:sm_command",
    "core/edit.goose:sm_addr",
    "core/edit.goose:sm_run",
    "core/extras.goose:ms_sequence",
    "core/extras.goose:ms_argument",
    "core/extras.goose:ms_item",
    "core/extras.goose:ms_limits",
    "core/extras.goose:ms_command_words",
    "core/gitexport.goose:gx_tree",
    "core/highlight.goose:hl_inline",
    "core/layout.goose:make_stack",
    "core/layout.goose:make",
    "core/layout.goose:el_items",
    "core/layout.goose:block_items",
    "core/lint.goose:walk",
    "core/narr.goose:collect",
    "core/narr.goose:collect_explain",
    "core/pagesvg.goose:box_svg",
    "core/parse.goose:parse_blocks",
    "core/parse.goose:parse_list",
    "core/plot.goose:pl_sum",
    "core/plot.goose:pl_prod",
    "core/plot.goose:pl_unary",
    "core/plot.goose:pl_pow",
    "core/plot.goose:pl_atom",
    "core/plot.goose:pl_eval",
    "core/render.goose:r_block",
    "core/render.goose:r_elements",
    "core/render.goose:md_block",
    "core/texmath.goose:math_sequence",
    "core/texmath.goose:math_argument",
    "core/texmath.goose:math_atom_scripts",
    "core/texmath.goose:math_atom",
    "core/texmath.goose:command_atom",
    "core/texmath.goose:math_rows",
    "core/texmath.goose:math_environment",
    "core/vim.goose:vre_nullable",
    "core/vim.goose:vre_emit",
    "scripts/budget.ts:visit",
    "scripts/replay-codec.ts:encode",
    "scripts/replay-codec.ts:decode",
    "src/article.ts:sum",
    "src/article.ts:prod",
    "src/article.ts:unary",
    "src/article.ts:pow",
    "src/article.ts:atom",
    "src/runtime.ts:sum",
    "src/runtime.ts:prod",
    "src/runtime.ts:unary",
    "src/runtime.ts:pow",
    "src/runtime.ts:atom",
];
export const JPL_LONG_FUNCTIONS: Record<string, number> = {
    "core/edit.goose:rx_first": 77,
    "core/edit.goose:sm_command": 92,
    "core/edit.goose:sm_addr": 74,
    "core/edit.goose:sm_run": 122,
    "core/edit.goose:edit_sam": 66,
    "core/edit.goose:cm_changes": 140,
    "core/extras.goose:math_at": 68,
    "core/extras.goose:ms_command_words": 81,
    "core/extras.goose:listener_markdown": 80,
    "core/extras.goose:tour_markdown": 102,
    "core/extras.goose:pt_rules": 69,
    "core/highlight.goose:hl_code_line": 78,
    "core/highlight.goose:hl_inline": 101,
    "core/highlight.goose:hl_markdown": 142,
    "core/layout.goose:make": 76,
    "core/layout.goose:table_item": 83,
    "core/layout.goose:el_items": 115,
    "core/layout.goose:block_items": 73,
    "core/layout.goose:tk_page": 63,
    "core/layout.goose:continuation": 69,
    "core/layout.goose:layout_article": 86,
    "core/layout.goose:layout_handout": 62,
    "core/layout.goose:poster_build": 93,
    "core/lint.goose:check_math": 66,
    "core/lint.goose:walk": 65,
    "core/lint.goose:lint": 90,
    "core/pack.goose:inflate": 69,
    "core/pack.goose:pack_import": 98,
    "core/pagesvg.goose:draw_text": 79,
    "core/pagesvg.goose:plot_svg": 72,
    "core/pagesvg.goose:chart_svg": 61,
    "core/parse.goose:parse_blocks": 326,
    "core/parse.goose:parse_list": 85,
    "core/parse.goose:link_like": 73,
    "core/parse.goose:inline_parse": 244,
    "core/parse.goose:build_frames": 76,
    "core/plot.goose:pl_parse": 126,
    "core/plot.goose:plot_html": 107,
    "core/render.goose:r_block": 77,
    "core/render.goose:chart_spec": 70,
    "core/render.goose:r_chart": 91,
    "core/render.goose:r_elements": 92,
    "core/render.goose:r_slide": 69,
    "core/render.goose:epub_begin": 166,
    "core/texmath.goose:command_atom": 219,
    "core/theme.goose:th_init": 89,
    "core/video.goose:trak": 91,
    "core/vim.goose:vb_text_object": 97,
    "core/vim.goose:vre_compile": 342,
    "core/vim.goose:vre_emit": 73,
    "core/vim.goose:vb_motion": 102,
    "core/vim.goose:vm_apply_op": 61,
    "core/vim.goose:vm_normal": 252,
    "core/vim.goose:vm_visual": 152,
    "core/vim.goose:vm_parse_range": 79,
    "core/vim.goose:vm_substitute": 97,
    "core/vim.goose:vm_global": 66,
    "core/vim.goose:vm_ex": 79,
    "core/vim.goose:vim_key": 77,
    "src/article.ts:compile": 62,
    "src/export.ts:build": 61,
    "src/export.ts:exportSheet": 157,
    "src/find.ts:build": 65,
    "src/preview.ts:speakerReady": 132,
    "src/runtime.ts:compile": 62,
};

type Fn = { file: string; name: string; start: number; lines: number; calls: Set<string>; method: boolean; declaredRecursive: boolean };

function files(root: string, patterns: readonly string[]): string[] {
  const found = new Set<string>();
  for (const pattern of patterns) for (const f of new Glob(pattern).scanSync({ cwd: root })) found.add(f);
  return [...found].sort();
}

function blankCommentsAndStrings(text: string): string {
  return text.replace(/\/\/[^\n]*|"(?:[^"\\\n]|\\.)*"|'(?:[^'\\\n]|\\.)+'/g, (m) => " ".repeat(m.length));
}

function gooseFunctions(file: string, text: string): Fn[] {
  const code = blankCommentsAndStrings(text);
  const found: Fn[] = [];
  const header = /^(?:export\s+)?(recursive\s+)?fn\s+(\w+)/gm;
  for (let m = header.exec(code); m !== null; m = header.exec(code)) {
    const open = code.indexOf("{", m.index);
    let depth = 0;
    let end = open;
    for (; end < code.length; end++) {
      if (code[end] === "{") depth++;
      else if (code[end] === "}" && --depth === 0) break;
    }
    const line = (at: number): number => code.slice(0, at).split("\n").length;
    const calls = new Set([...code.slice(open, end).matchAll(/\b(\w+)\s*\(/g)].map((c) => c[1] ?? ""));
    found.push({ file, name: m[2] ?? "", start: line(m.index), lines: line(end) - line(m.index) + 1, calls, method: false, declaredRecursive: m[1] !== undefined });
  }
  return found;
}

const FUNCTION_KINDS = [ts.SyntaxKind.FunctionDeclaration, ts.SyntaxKind.FunctionExpression, ts.SyntaxKind.ArrowFunction, ts.SyntaxKind.MethodDeclaration, ts.SyntaxKind.Constructor];

function callsIn(function_: ts.Node): Set<string> {
  const calls = new Set<string>();
  const stack = [...function_.getChildren()];
  for (let c = stack.pop(); c !== undefined; c = stack.pop()) {
    if (FUNCTION_KINDS.includes(c.kind)) continue;
    if (ts.isCallExpression(c)) {
      const callee = c.expression;
      if (ts.isIdentifier(callee)) calls.add(callee.text);
      else if (ts.isPropertyAccessExpression(callee) && callee.expression.kind === ts.SyntaxKind.ThisKeyword) calls.add(`this.${callee.name.text}`);
    }
    stack.push(...c.getChildren());
  }
  return calls;
}

function tsFunctions(file: string, text: string): Fn[] {
  const source = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true);
  const found: Fn[] = [];
  const seen = new Map<string, number>();
  const nameOf = (node: ts.Node, outer: string): string => {
    const parent = node.parent;
    let own = "";
    if ((ts.isFunctionDeclaration(node) || ts.isMethodDeclaration(node) || ts.isFunctionExpression(node)) && node.name) own = node.name.getText(source);
    else if (ts.isVariableDeclaration(parent) || ts.isPropertyAssignment(parent) || ts.isPropertyDeclaration(parent)) own = parent.name.getText(source);
    else if (ts.isConstructorDeclaration(node)) own = "constructor";
    return own === "" ? `${outer}>anonymous` : own;
  };
  const pending: [ts.Node, string][] = [[source, "file"]];
  for (let item = pending.shift(); item !== undefined; item = pending.shift()) {
    const [node, outer] = item;
    let scope = outer;
    if (FUNCTION_KINDS.includes(node.kind)) {
      const base = nameOf(node, outer);
      const n = (seen.get(base) ?? 0) + 1;
      seen.set(base, n);
      const name = n === 1 ? base : `${base}#${n}`;
      const first = source.getLineAndCharacterOfPosition(node.getStart(source)).line + 1;
      const last = source.getLineAndCharacterOfPosition(node.getEnd()).line + 1;
      const method = ts.isMethodDeclaration(node) || ts.isConstructorDeclaration(node) || ts.isPropertyAssignment(node.parent) || ts.isPropertyDeclaration(node.parent);
      found.push({ file, name, start: first, lines: last - first + 1, calls: callsIn(node), method, declaredRecursive: false });
      scope = name;
    }
    for (const child of node.getChildren(source)) pending.push([child, scope]);
  }
  return found;
}

function recursion(fns: Fn[], allowed: readonly string[]): string[] {
  const problems: string[] = [];
  const listed = new Set<string>();
  const byName = new Map<string, Fn[]>();
  for (const f of fns) byName.set(`${f.file}\0${f.name.split("#")[0]}`, [...(byName.get(`${f.file}\0${f.name.split("#")[0]}`) ?? []), f]);
  const edges = (f: Fn): Fn[] => [...f.calls].flatMap((c) => (byName.get(`${f.file}\0${c.replace("this.", "")}`) ?? []).filter((g) => g.method === c.startsWith("this.")));
  for (const f of fns) {
    const visited = new Set<Fn>();
    const stack = edges(f);
    let recursive = f.declaredRecursive;
    for (let g = stack.pop(); g !== undefined && !recursive; g = stack.pop()) {
      if (g === f) recursive = true;
      else if (!visited.has(g)) { visited.add(g); stack.push(...edges(g)); }
    }
    const key = `${f.file}:${f.name}`;
    if (recursive && !allowed.includes(key)) problems.push(`${f.file}:${f.start}: ${f.name} can call itself (JPL rule 1: no recursion)`);
    if (recursive) listed.add(key);
  }
  for (const key of allowed) if (!listed.has(key)) problems.push(`${key} is in JPL_RECURSIVE_FUNCTIONS but no such recursive function exists: remove it`);
  return problems;
}

export function checkJpl(root: string, allowedLong: Record<string, number> = JPL_LONG_FUNCTIONS, allowedRecursive: readonly string[] = JPL_RECURSIVE_FUNCTIONS): string[] {
  const fns = [
    ...files(root, JPL_GOOSE_GLOBS).flatMap((f) => gooseFunctions(f, readFileSync(`${root}/${f}`, "utf8"))),
    ...files(root, SOURCE_GLOBS).flatMap((f) => tsFunctions(f, readFileSync(`${root}/${f}`, "utf8"))),
  ];
  const problems = recursion(fns, allowedRecursive);
  const listed = new Set<string>();
  for (const f of fns) {
    const key = `${f.file}:${f.name}`;
    const allowed = allowedLong[key];
    if (allowed !== undefined) listed.add(key);
    if (f.lines > (allowed ?? JPL_MAX_LINES)) {
      problems.push(`${f.file}:${f.start}: ${f.name} has ${f.lines} lines (JPL rule 4: at most ${allowed ?? JPL_MAX_LINES})`);
    } else if (allowed !== undefined && f.lines < allowed) {
      problems.push(`${f.file}:${f.start}: ${f.name} has ${f.lines} lines: lower its limit in JPL_LONG_FUNCTIONS to ${f.lines > JPL_MAX_LINES ? f.lines : "nothing (remove it)"}`);
    }
  }
  for (const key of Object.keys(allowedLong)) if (!listed.has(key)) problems.push(`${key} is in JPL_LONG_FUNCTIONS but no such function exists: remove it`);
  return problems;
}

if (import.meta.main) {
  const root = fileURLToPath(new URL("..", import.meta.url)).replace(/\/$/, "");
  const list = process.argv.includes("--list");
  const problems = checkJpl(root);
  if (list) {
    for (const p of problems) {
      const m = /^(.+?):\d+: (\S+) has (\d+) lines \(/.exec(p);
      const r = /^(.+?):\d+: (\S+) can call itself/.exec(p);
      if (m) console.log(`  "${m[1]}:${m[2]}": ${m[3]},`);
      if (r) console.log(`  "${r[1]}:${r[2]}",`);
    }
  } else {
    for (const p of problems) console.log(p);
    if (problems.length > 0) process.exit(1);
  }
}
