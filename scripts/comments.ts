import ts from "typescript";

export interface Comment {
    line: number;
    start: number;
    end: number;
    text: string;
}

const LINK = /https?:\/\//;

function lineOf(text: string, offset: number): number {
    let line = 1;
    for (let i = 0; i < offset; i++) if (text.charCodeAt(i) === 10) line++;
    return line;
}

function scanTypeScript(text: string): Comment[] {
    const scanner = ts.createScanner(ts.ScriptTarget.ES2022, false, ts.LanguageVariant.Standard, text);
    const found: Comment[] = [];
    let kind = scanner.scan();
    while (kind !== ts.SyntaxKind.EndOfFileToken) {
        if (kind === ts.SyntaxKind.SlashToken || kind === ts.SyntaxKind.SlashEqualsToken) {
            const re = scanner.reScanSlashToken();
            if (re === ts.SyntaxKind.RegularExpressionLiteral) {
                kind = scanner.scan();
                continue;
            }
        }
        if (kind === ts.SyntaxKind.CloseBraceToken) {
            kind = scanner.reScanTemplateToken(false);
        }
        if (kind === ts.SyntaxKind.SingleLineCommentTrivia || kind === ts.SyntaxKind.MultiLineCommentTrivia) {
            const start = scanner.getTokenStart();
            const end = scanner.getTokenEnd();
            found.push({ line: lineOf(text, start), start, end, text: text.slice(start, end) });
        }
        kind = scanner.scan();
    }
    return found;
}

function scanCStyle(text: string, lineMarker: string, blockComments: boolean, chars: boolean): Comment[] {
    const found: Comment[] = [];
    let i = 0;
    while (i < text.length) {
        const c = text.charAt(i);
        if (c === '"' || (chars && c === "'")) {
            i++;
            while (i < text.length && text.charAt(i) !== c) {
                if (text.charAt(i) === "\\") i++;
                i++;
            }
            i++;
        } else if (text.startsWith(lineMarker, i)) {
            let end = text.indexOf("\n", i);
            if (end < 0) end = text.length;
            found.push({ line: lineOf(text, i), start: i, end, text: text.slice(i, end) });
            i = end;
        } else if (blockComments && text.startsWith("/*", i)) {
            const close = text.indexOf("*/", i + 2);
            const end = close < 0 ? text.length : close + 2;
            found.push({ line: lineOf(text, i), start: i, end, text: text.slice(i, end) });
            i = end;
        } else {
            i++;
        }
    }
    return found;
}

function scanShell(text: string): Comment[] {
    const found: Comment[] = [];
    let i = 0;
    let wordStart = true;
    while (i < text.length) {
        const c = text.charAt(i);
        if (c === "'") {
            const close = text.indexOf("'", i + 1);
            i = close < 0 ? text.length : close + 1;
            wordStart = false;
        } else if (c === '"') {
            i++;
            while (i < text.length && text.charAt(i) !== '"') {
                if (text.charAt(i) === "\\") i++;
                i++;
            }
            i++;
            wordStart = false;
        } else if (c === "\\") {
            i += 2;
            wordStart = false;
        } else if (c === "#" && wordStart && !(i === 0 && text.startsWith("#!"))) {
            let end = text.indexOf("\n", i);
            if (end < 0) end = text.length;
            found.push({ line: lineOf(text, i), start: i, end, text: text.slice(i, end) });
            i = end;
        } else {
            wordStart = c === " " || c === "\t" || c === "\n" || c === ";" || c === "(" || c === "|" || c === "&";
            if (c === "#") wordStart = false;
            i++;
        }
    }
    return found;
}

export function findComments(path: string, text: string): Comment[] {
    const all = path.endsWith(".ts") ? scanTypeScript(text)
        : path.endsWith(".goose") ? scanCStyle(text, "//", false, true)
        : path.endsWith(".h") ? scanCStyle(text, "//", true, true)
        : path.endsWith(".sh") ? scanShell(text)
        : [];
    return all.filter((c) => !LINK.test(c.text) && !c.text.startsWith("/// <reference"));
}

export function stripComments(path: string, text: string): string {
    const found = findComments(path, text);
    let out = "";
    let at = 0;
    for (const c of found) {
        const lineStart = text.lastIndexOf("\n", c.start - 1) + 1;
        const nextBreak = text.indexOf("\n", c.end);
        const lineEnd = nextBreak < 0 ? text.length : nextBreak;
        const alone = text.slice(lineStart, c.start).trim() === "" && text.slice(c.end, lineEnd).trim() === "";
        if (alone && lineStart >= at) {
            out += text.slice(at, lineStart);
            at = Math.min(lineEnd + 1, text.length);
        } else {
            out += text.slice(at, c.start).replace(/[ \t]+$/, "");
            at = c.end;
        }
    }
    out += text.slice(at);
    return out;
}
