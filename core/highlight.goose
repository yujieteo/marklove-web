// Syntax highlights, as the app's Text/Highlighter.swift: CodeHighlighter for
// code blocks, and MarkdownHighlighter for the Markdown source in the editor.
//
// Public functions:
//   highlight_html(out, code, lang)
//       The HTML of HTMLWriter.highlightCode: the code, escaped, with
//       <span class="kw|str|num|com|type|fn|attr"> around the tokens. Lines
//       stay separated by "\n". An unknown language gets no spans.
//   highlight_markdown(out, src)
//       JSON array of [start, end, "role"] for the editor. Offsets are UTF-8
//       byte offsets in src. Spans overlap: apply them in order, so that a
//       later span wins. The role names are the keys of "roles" in
//       theme_palette (theme.goose), such as "heading" or "keyword".

import base;
import parse;

// Highlight roles (HighlightRole). The numbers index HL_ROLES.
let HR_HEADING_MARKER = 0;
let HR_HEADING = 1;
let HR_EMPHASIS_MARKER = 2;
let HR_LIST_MARKER = 3;
let HR_QUOTE_MARKER = 4;
let HR_CODE_SPAN = 5;
let HR_FENCE = 6;
let HR_CODE_TEXT = 7;
let HR_MATH_DELIMITER = 8;
let HR_MATH = 9;
let HR_LINK = 10;
let HR_URL = 11;
let HR_IMAGE_MARKER = 12;
let HR_DIRECTIVE = 13;
let HR_COMMENT = 14;
let HR_PAUSE = 15;
let HR_RULE = 16;
let HR_FRONT_MATTER = 17;
let HR_TABLE_BAR = 18;
let HR_ESCAPE = 19;
let HR_NOTES = 20;
let HR_NARRATION = 21;
let HR_KEYWORD = 22;
let HR_STRING = 23;
let HR_NUMBER = 24;
let HR_CODE_COMMENT = 25;
let HR_TYPE = 26;
let HR_FUNCTION = 27;
let HR_ATTRIBUTE = 28;

let HL_ROLES: (const u8[:])[] = [
    "headingMarker", "heading", "emphasisMarker", "listMarker", "quoteMarker", "codeSpan", "fence",
    "codeText", "mathDelimiter", "math", "link", "url", "imageMarker", "directive", "comment", "pause",
    "rule", "frontMatter", "tableBar", "escape", "notes", "narration", "keyword", "string", "number",
    "codeComment", "type", "function", "attribute",
];

// A highlight: bytes a..b and a role.
struct HSpan { a: i64, b: i64, r: i64 }

fn hl_add(spans: HSpan[>..]&, a: i64, b: i64, r: i64) { spans.push(HSpan { a, b, r }); }

// --- code ---------------------------------------------------------------

let HL_CLIKE: (const u8[:])[] = ["if", "else", "for", "while", "do", "switch", "case", "default", "break", "continue", "return", "goto", "struct", "enum", "union", "typedef", "static", "const", "void", "int", "char", "float", "double", "long", "short", "unsigned", "signed", "sizeof", "true", "false", "null", "nullptr", "class", "public", "private", "protected", "new", "delete", "this", "try", "catch", "throw", "namespace", "using", "template", "virtual", "override", "final", "import", "package", "extends", "implements", "interface", "abstract", "var", "let", "func", "fn", "mut", "impl", "trait", "pub", "use", "mod", "match", "loop", "in", "as", "self", "Self", "super", "where", "guard", "defer", "init", "deinit", "throws", "rethrows", "async", "await", "inout", "some", "any", "protocol", "extension", "typealias", "associatedtype", "nil", "is", "lazy", "weak", "unowned", "fileprivate", "internal", "open", "mutating", "nonmutating", "subscript", "operator", "get", "set", "willSet", "didSet", "function", "export", "from", "of", "typeof", "instanceof", "yield", "undefined", "go", "chan", "select", "type", "map", "range", "val", "fun", "when", "object", "data", "sealed", "companion", "crate", "dyn", "ref", "move", "unsafe", "auto", "register", "volatile", "extern", "inline", "bool", "string"];
let HL_PYTHON: (const u8[:])[] = ["False", "None", "True", "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield", "match", "case", "self", "print"];
let HL_SHELL: (const u8[:])[] = ["if", "then", "else", "elif", "fi", "for", "in", "do", "done", "while", "until", "case", "esac", "function", "return", "export", "local", "readonly", "echo", "cd", "set", "unset", "source", "exit"];
let HL_SQL: (const u8[:])[] = ["select", "from", "where", "and", "or", "not", "insert", "into", "values", "update", "set", "delete", "create", "table", "drop", "alter", "join", "left", "right", "inner", "outer", "on", "group", "by", "order", "having", "limit", "as", "null", "is", "in", "primary", "key", "distinct", "union", "all"];
let HL_JSON: (const u8[:])[] = ["true", "false", "null"];
let HL_YAML: (const u8[:])[] = ["true", "false", "null", "yes", "no"];
let HL_MATLAB: (const u8[:])[] = ["function", "end", "if", "else", "elseif", "for", "while", "return", "switch", "case", "otherwise", "break"];
let HL_R: (const u8[:])[] = ["function", "if", "else", "for", "while", "return", "TRUE", "FALSE", "NULL", "in"];
let HL_JULIA: (const u8[:])[] = ["function", "end", "if", "else", "elseif", "for", "while", "return", "using", "import", "module", "struct", "mutable", "begin", "let", "true", "false", "nothing"];

let HG_NONE = 0;
let HG_CLIKE = 1;
let HG_PYTHON = 2;
let HG_SHELL = 3;
let HG_JSON = 4;
let HG_YAML = 5;
let HG_SQL = 6;
let HG_TEX = 7;
let HG_HTML = 8;
let HG_MATLAB = 9;
let HG_R = 10;
let HG_JULIA = 11;

// A grammar (CodeHighlighter.Grammar). `strings` lists the quote bytes.
struct HGram {
    kind: i64,
    line_comment: const u8[:],
    block_open: const u8[:],
    block_close: const u8[:],
    strings: const u8[:],
    triple: bool,
    types_cap: bool,
    attr: u8,
}

fn hl_in(word: u8[:], list: (const u8[:])[:]) -> bool {
    for x in list { if x == word { return true; } }
    return false;
}

fn hl_grammar(lang: u8[:]) -> HGram {
    var l: u8[..24] = [];
    if lang.len > 24 { return HGram { HG_NONE, "", "", "", "", false, false, 0 }; }
    for c in lang { l.push(lower(c)); }
    for x in ["swift", "c", "cpp", "c++", "objc", "objective-c", "java", "javascript", "js", "typescript", "ts", "rust", "rs", "go", "kotlin", "kt", "csharp", "cs", "c#", "scala", "dart", "jsx", "tsx", "glsl", "metal"] {
        if l == x { return HGram { HG_CLIKE, "//", "/*", "*/", "\"'`", false, true, '@' }; }
    }
    if l == "python" || l == "py" { return HGram { HG_PYTHON, "#", "", "", "\"'", true, true, '@' }; }
    for x in ["bash", "sh", "shell", "zsh", "console"] {
        if l == x { return HGram { HG_SHELL, "#", "", "", "\"'", false, false, 0 }; }
    }
    if l == "json" { return HGram { HG_JSON, "", "", "", "\"", false, false, 0 }; }
    for x in ["yaml", "yml", "toml", "ini"] {
        if l == x { return HGram { HG_YAML, "#", "", "", "\"'", false, false, 0 }; }
    }
    if l == "sql" { return HGram { HG_SQL, "--", "/*", "*/", "'\"", false, false, 0 }; }
    if l == "tex" || l == "latex" { return HGram { HG_TEX, "%", "", "", "", false, false, 0 }; }
    if l == "html" || l == "xml" || l == "svg" { return HGram { HG_HTML, "", "<!--", "-->", "\"'", false, false, 0 }; }
    if l == "matlab" || l == "octave" { return HGram { HG_MATLAB, "%", "", "", "'\"", false, true, 0 }; }
    if l == "r" { return HGram { HG_R, "#", "", "", "\"'", false, true, 0 }; }
    if l == "julia" || l == "jl" { return HGram { HG_JULIA, "#", "#=", "=#", "\"", false, true, 0 }; }
    return HGram { HG_NONE, "", "", "", "", false, false, 0 };
}

fn hl_is_keyword(g: HGram, word: u8[:]) -> bool {
    if g.kind == HG_CLIKE { return hl_in(word, HL_CLIKE); }
    if g.kind == HG_PYTHON { return hl_in(word, HL_PYTHON); }
    if g.kind == HG_SHELL { return hl_in(word, HL_SHELL); }
    if g.kind == HG_JSON { return hl_in(word, HL_JSON); }
    if g.kind == HG_YAML { return hl_in(word, HL_YAML); }
    if g.kind == HG_MATLAB { return hl_in(word, HL_MATLAB); }
    if g.kind == HG_R { return hl_in(word, HL_R); }
    if g.kind == HG_JULIA { return hl_in(word, HL_JULIA); }
    if g.kind == HG_SQL {
        if hl_in(word, HL_SQL) { return true; }
        var lw: u8[..24] = [];
        if word.len > 24 { return false; }
        for c in word { lw.push(lower(c)); }
        return hl_in(lw, HL_SQL);
    }
    return false;
}

// Character classes of code points. Swift's Character classes are Unicode
// wide; outside ASCII these are close approximations.
fn hl_letter(c: i64) -> bool {
    if c < 0x80 { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
    if c < 0xC0 { return c == 0xAA || c == 0xB5 || c == 0xBA; }
    if c == 0xD7 || c == 0xF7 { return false; }
    if c >= 0x300 && c <= 0x36F { return false; }
    if c >= 0x2000 && c <= 0x2BFF { return false; }
    if c >= 0x3000 && c <= 0x303F { return false; }
    if c >= 0xFF00 && c <= 0xFF20 { return false; }
    if c >= 0x1F000 { return false; }
    return true;
}
fn hl_combining(c: i64) -> bool { c >= 0x300 && c <= 0x36F }
fn hl_digit(c: i64) -> bool { c >= '0' && c <= '9' }
fn hl_hex(c: i64) -> bool { hl_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') }
fn hl_upper(c: i64) -> bool {
    (c >= 'A' && c <= 'Z') || (c >= 0xC0 && c <= 0xDE && c != 0xD7) || (c >= 0x391 && c <= 0x3A9) || (c >= 0x400 && c <= 0x42F)
}
// A letter, a digit, `_`, or a mark that joins the character before it.
fn hl_word(c: i64) -> bool { hl_letter(c) || hl_digit(c) || c == '_' || hl_combining(c) }

fn hl_decode(s: u8[:], i: i64) -> i64 {
    let c = s[i];
    let n = utf8_len(c);
    if n == 1 || i + n > s.len { return c; }
    var v: i64 = if n == 2 { c & 0x1F } else if n == 3 { c & 0x0F } else { c & 0x07 };
    for k in 1..n { v = (v << 6) | (s[i + k] & 0x3F); }
    return v;
}

// TeX: `%` comments and control sequences.
fn hl_tex_line(line: u8[:], base: i64, spans: HSpan[>..]&) {
    var i = 0;
    while i < line.len {
        if line[i] == '%' { hl_add(spans, base + i, base + line.len, HR_CODE_COMMENT); break; }
        if line[i] == '\\' {
            var j = i + 1;
            while j < line.len && is_alpha(line[j]) { j++; }
            if j == i + 1 { j += if j < line.len { utf8_len(line[j]) } else { 1 }; }
            hl_add(spans, base + i, base + min(j, line.len), HR_KEYWORD);
            i = j;
            continue;
        }
        i++;
    }
}

// CodeHighlighter.highlight: one line of code. Spans are byte offsets in
// the line plus `base`. Block comments that span lines are per line only.
fn hl_code_line(line: u8[:], lang: u8[:], base: i64, spans: HSpan[>..]&) {
    let g = hl_grammar(lang);
    if g.kind == HG_NONE { return; }
    if g.kind == HG_TEX { hl_tex_line(line, base, spans); return; }
    // Code points and their byte offsets; off has one more entry at the end.
    var cp: i64[>..] = [];
    var off: i64[>..] = [];
    var p = 0;
    while p < line.len {
        cp.push(hl_decode(line, p));
        off.push(p);
        p += min(utf8_len(line[p]), line.len - p);
    }
    off.push(line.len);
    let n = cp.len;
    fn add(a: i64, b: i64, r: i64) { hl_add(spans, base + off[a], base + off[b], r); }
    fn starts(s: u8[:], i: i64) -> bool { off[i] + s.len <= line.len && line[off[i]..off[i] + s.len] == s }
    var i = 0;
    while i < n {
        let c = cp[i];
        if g.line_comment.len > 0 && starts(g.line_comment, i) { add(i, n, HR_CODE_COMMENT); break; }
        if g.block_open.len > 0 && starts(g.block_open, i) {
            var j = i + char_count(g.block_open);
            while j < n && !starts(g.block_close, j) { j++; }
            let end = min(n, j + char_count(g.block_close));
            add(i, end, HR_CODE_COMMENT);
            i = end;
            continue;
        }
        if c < 0x80 && contains_byte(g.strings, c as u8) {
            var q3: u8[..3] = [];
            for k in 3 { q3.push(c as u8); }
            let triple = g.triple && starts(q3, i);
            let q = if triple { 3 } else { 1 };
            var j = i + q;
            while j < n {
                if cp[j] == '\\' { j += 2; continue; }
                if triple {
                    if starts(q3, j) { j += q; break; }
                } else if cp[j] == c { j += q; break; }
                j++;
            }
            let end = min(j, n);
            add(i, end, HR_STRING);
            i = end;
            continue;
        }
        if hl_digit(c) || (c == '.' && i + 1 < n && hl_digit(cp[i + 1])) {
            if i > 0 && (hl_letter(cp[i - 1]) || cp[i - 1] == '_') { i++; continue; }
            var j = i;
            while j < n && (hl_hex(cp[j]) || cp[j] == '.' || cp[j] == 'x' || cp[j] == '_' || cp[j] == 'e') { j++; }
            add(i, j, HR_NUMBER);
            i = j;
            continue;
        }
        if g.attr != 0 && c == g.attr && i + 1 < n && hl_letter(cp[i + 1]) {
            var j = i + 1;
            while j < n && hl_word(cp[j]) { j++; }
            add(i, j, HR_ATTRIBUTE);
            i = j;
            continue;
        }
        if hl_letter(c) || c == '_' {
            var j = i;
            while j < n && hl_word(cp[j]) { j++; }
            let word = line[off[i]..off[j]];
            if hl_is_keyword(g, word) {
                add(i, j, HR_KEYWORD);
            } else if g.types_cap && hl_upper(c) {
                add(i, j, HR_TYPE);
            } else if j < n && cp[j] == '(' {
                add(i, j, HR_FUNCTION);
            }
            i = j;
            continue;
        }
        i++;
    }
}

// MathMLConverter.escapeXML: & < > and ".
fn hl_esc(out: u8[>..]&, s: u8[:]) {
    for c in s {
        if c == '&' { out.append("&amp;"); }
        else if c == '<' { out.append("&lt;"); }
        else if c == '>' { out.append("&gt;"); }
        else if c == '"' { out.append("&quot;"); }
        else { out.push(c); }
    }
}

fn hl_class(r: i64) -> u8[:] {
    if r == HR_KEYWORD { return "kw"; }
    if r == HR_STRING { return "str"; }
    if r == HR_NUMBER { return "num"; }
    if r == HR_CODE_COMMENT { return "com"; }
    if r == HR_TYPE { return "type"; }
    if r == HR_FUNCTION { return "fn"; }
    if r == HR_ATTRIBUTE { return "attr"; }
    return "";
}

fn highlight_html(out: u8[>..]&, code: u8[:], lang: u8[:]) {
    var s = 0;
    var first = true;
    while s <= code.len {
        var e = index_of_byte(code, '\n', s);
        if e < 0 { e = code.len; }
        let line = code[s..e];
        if !first { out.push('\n'); }
        first = false;
        var spans: HSpan[>..] = [];
        hl_code_line(line, lang, 0, spans);
        var cursor = 0;
        for sp in spans {
            if sp.a < cursor { continue; }
            hl_esc(out, line[cursor..sp.a]);
            let end = min(line.len, sp.b);
            out.append("<span class=\"");
            out.append(hl_class(sp.r));
            out.append("\">");
            hl_esc(out, line[sp.a..end]);
            out.append("</span>");
            cursor = end;
        }
        hl_esc(out, line[min(cursor, line.len)..]);
        s = e + 1;
    }
}

// --- Markdown -----------------------------------------------------------

fn hl_alnum(c: u8) -> bool { is_alnum(c) || c > 0x7F }

// Inline markers: emphasis, code spans, math, links and images.
recursive fn hl_inline(u: u8[:], base: i64, spans: HSpan[>..]&) {
    fn span(a: i64, len: i64, r: i64) { if len > 0 { hl_add(spans, base + a, base + a + len, r); } }
    var i = 0;
    while i < u.len {
        let c = u[i];
        if c == '\\' {
            if i + 1 < u.len && u[i + 1] == '(' {
                var j = i + 2;
                while j + 1 < u.len && !(u[j] == '\\' && u[j + 1] == ')') { j++; }
                if j + 1 < u.len {
                    span(i, 2, HR_MATH_DELIMITER); span(i + 2, j - i - 2, HR_MATH); span(j, 2, HR_MATH_DELIMITER);
                    i = j + 2;
                    continue;
                }
            }
            // The backslash and the whole character after it.
            let n = if i + 1 < u.len { 1 + utf8_len(u[i + 1]) } else { 1 };
            span(i, min(n, u.len - i), HR_ESCAPE);
            i += max(n, 2);
        } else if c == '`' {
            var run = 0;
            while i + run < u.len && u[i + run] == '`' { run++; }
            var j = i + run;
            var found = -1;
            while j < u.len {
                if u[j] == '`' {
                    var r = 0;
                    while j + r < u.len && u[j + r] == '`' { r++; }
                    if r == run { found = j; break; }
                    j += r;
                } else { j++; }
            }
            if found >= 0 { span(i, found + run - i, HR_CODE_SPAN); i = found + run; } else { i += run; }
        } else if c == '$' {
            let dbl = i + 1 < u.len && u[i + 1] == '$';
            let open = if dbl { 2 } else { 1 };
            var j = i + open;
            if !dbl && j < u.len && u[j] == ' ' { i++; continue; }
            var found = -1;
            while j < u.len {
                if u[j] == '\\' { j += 2; continue; }
                if u[j] == '$' && (!dbl || (j + 1 < u.len && u[j + 1] == '$')) { found = j; break; }
                j++;
            }
            if found > i + open {
                span(i, open, HR_MATH_DELIMITER); span(i + open, found - i - open, HR_MATH); span(found, open, HR_MATH_DELIMITER);
                i = found + open;
            } else { i += open; }
        } else if c == '*' || c == '_' || c == '~' {
            var run = 0;
            while i + run < u.len && u[i + run] == c { run++; }
            let prev: u8 = if i > 0 { u[i - 1] } else { ' ' };
            let next: u8 = if i + run < u.len { u[i + run] } else { ' ' };
            let inside = c == '_' && hl_alnum(prev) && hl_alnum(next);
            if !inside && (c != '~' || run == 2) && !(prev == ' ' && next == ' ') {
                span(i, run, HR_EMPHASIS_MARKER);
            }
            i += run;
        } else if c == '!' || c == '[' {
            let image = c == '!';
            let start = i;
            let bracket = if image { i + 1 } else { i };
            if bracket >= u.len || u[bracket] != '[' { i++; continue; }
            var depth = 0;
            var j = bracket;
            var close = -1;
            while j < u.len {
                if u[j] == '\\' { j += 2; continue; }
                if u[j] == '[' { depth++; }
                if u[j] == ']' { depth--; if depth == 0 { close = j; break; } }
                j++;
            }
            if close > 0 && close + 1 < u.len && u[close + 1] == '(' {
                var k = close + 2;
                var parens = 0;
                while k < u.len {
                    if u[k] == '(' { parens++; }
                    if u[k] == ')' { if parens == 0 { break; } parens--; }
                    k++;
                }
                if k < u.len {
                    if image { span(start, 2, HR_IMAGE_MARKER); } else { span(start, 1, HR_LINK); }
                    // The text keeps its inline highlights.
                    hl_inline(u[bracket + 1..close], base + bracket + 1, spans);
                    span(close, 1, if image { HR_IMAGE_MARKER } else { HR_LINK });
                    span(close + 1, k - close, HR_URL);
                    i = k + 1;
                    continue;
                }
            }
            i++;
        } else if c == '<' {
            var j = i + 1;
            while j < u.len && u[j] != '>' && u[j] != ' ' { j++; }
            if j < u.len && u[j] == '>' && j > i + 1 {
                span(i, j - i + 1, HR_URL);
                i = j + 1;
            } else { i++; }
        } else {
            i++;
        }
    }
}

fn hl_blank(t: u8[:]) -> bool {
    for c in t { if c != ' ' && c != '\t' { return false; } }
    return true;
}

// MarkdownHighlighter.highlight. Spans are byte offsets in src.
fn hl_markdown(src: u8[:], spans: HSpan[>..]&) {
    // Lines, as sourceLines: "\n" and "\r\n" end a line.
    var ls: i64[>..] = [];
    var le: i64[>..] = [];
    var s = 0;
    for c, k in src {
        if c == '\n' {
            ls.push(s);
            le.push(if k > s && src[k - 1] == '\r' { k - 1 } else { k });
            s = k + 1;
        }
    }
    ls.push(s);
    le.push(src.len);
    let count = ls.len;
    fn whole(i: i64, r: i64) { hl_add(spans, ls[i], le[i], r); }
    var i = 0;
    // Front matter.
    if trim_sp(src[ls[0]..le[0]]) == "---" {
        var j = 1;
        while j < count {
            let t = trim_sp(src[ls[j]..le[j]]);
            if t == "---" || t == "..." { break; }
            j++;
        }
        if j < count {
            hl_add(spans, ls[0], le[j], HR_FRONT_MATTER);
            i = j + 1;
        }
    }
    var in_fence = false;
    var fence_ch: u8 = '`';
    var fence_len = 0;
    var lang: u8[..32] = [];
    var raw_div = -1;
    var in_math = false;
    var in_comment = false;
    while i < count {
        let o = ls[i];
        let t = src[o..le[i]];
        let n = i;
        i++;
        if in_comment {
            whole(n, HR_COMMENT);
            if index_of(t, "-->") >= 0 { in_comment = false; }
            continue;
        }
        if in_fence {
            if is_fence_close(t, fence_ch, fence_len) {
                whole(n, HR_FENCE);
                in_fence = false;
            } else {
                whole(n, HR_CODE_TEXT);
                hl_code_line(t, lang, o, spans);
            }
            continue;
        }
        let f = fence(t);
        if f.ok {
            in_fence = true;
            fence_ch = f.ch;
            fence_len = f.len;
            lang.clear();
            var e = index_of_byte(f.info, ' ');
            if e < 0 { e = f.info.len; }
            if e <= 32 { lang.append(f.info[..e]); }
            whole(n, HR_FENCE);
            continue;
        }
        if in_math {
            whole(n, HR_MATH);
            if index_of(t, "$$") >= 0 || index_of(t, "\\]") >= 0 || hl_blank(t) { in_math = false; }
            continue;
        }
        if raw_div >= 0 {
            if is_div_close(t) {
                whole(n, HR_DIRECTIVE);
                raw_div = -1;
            } else {
                whole(n, raw_div);
            }
            continue;
        }
        let trimmed = trim_sp(t);
        if has_prefix(trimmed, "$$") || has_prefix(trimmed, "\\[") {
            whole(n, HR_MATH);
            let rest = trimmed[2..];
            if !(index_of(rest, "$$") >= 0 || index_of(rest, "\\]") >= 0) { in_math = true; }
            continue;
        }
        let d = div_open(t);
        if d.ok {
            whole(n, HR_DIRECTIVE);
            let k = div_kind(d.name);
            if k == D_NOTES { raw_div = HR_NOTES; }
            else if k == D_NARRATION || k == D_EXPLAIN || k == D_PUBLIC { raw_div = HR_NARRATION; }
            else if k == D_PLOT { raw_div = HR_MATH; }
            continue;
        }
        if is_div_close(t) || is_pause(t) {
            whole(n, if is_pause(t) { HR_PAUSE } else { HR_DIRECTIVE });
            continue;
        }
        if has_prefix(trimmed, "<!--") {
            whole(n, HR_COMMENT);
            if index_of(t, "-->") < 0 { in_comment = true; }
            continue;
        }
        let h = atx(t);
        if h.ok {
            hl_add(spans, o, o + h.a, HR_HEADING_MARKER);
            hl_add(spans, o + h.a, o + t.len, HR_HEADING);
            var k = 0;
            while k < t.len && (t[k] == '#' || t[k] == ' ') { k++; }
            hl_inline(t[k..], o + h.a, spans);
            continue;
        }
        if is_rule(t) {
            whole(n, HR_RULE);
            continue;
        }
        // Block quote markers.
        var cs = 0;
        loop {
            var lead = 0;
            while cs + lead < t.len && t[cs + lead] == ' ' { lead++; }
            if cs + lead >= t.len || t[cs + lead] != '>' { break; }
            hl_add(spans, o + cs + lead, o + cs + lead + 1, HR_QUOTE_MARKER);
            cs = cs + lead + 1;
        }
        let m = list_marker(t[cs..]);
        if m.ok {
            hl_add(spans, o + cs, o + cs + m.chars, HR_LIST_MARKER);
            cs += m.chars;
        }
        if contains_byte(t, '|') && is_delimiter_row(t) {
            whole(n, HR_TABLE_BAR);
            continue;
        }
        hl_inline(t[cs..], o + cs, spans);
        // Table bars.
        if has_prefix(trimmed, "|") {
            for c, k in t { if c == '|' { hl_add(spans, o + k, o + k + 1, HR_TABLE_BAR); } }
        }
    }
}

fn highlight_markdown(out: u8[>..]&, src: u8[:]) {
    var spans: HSpan[>..] = [];
    hl_markdown(src, spans);
    out.push('[');
    var first = true;
    for sp in spans {
        if sp.b <= sp.a { continue; }
        if !first { out.push(','); }
        first = false;
        out.push('[');
        format(out, sp.a);
        out.push(',');
        format(out, sp.b);
        out.append(",\"");
        for name, k in HL_ROLES { if k == sp.r { out.append(name); } }
        out.append("\"]");
    }
    out.push(']');
}
