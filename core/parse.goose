// The Markdown parser: front matter, blocks, inlines, and frames.
//
// The parser follows the app's MarkdownParser, BlockParser and InlineParser.
// The document is one flat list of events in `EV`. A container (paragraph,
// list, division, link, emphasis) is an open event, its content, and a close
// event. Each open event's `end` is the index after its close event, so a
// walk can jump over a whole block. A leaf event (code, math, figure, text)
// has `end` = its own index + 1.

import base;

// Block events.
let K_PARA = 1;
let K_HEAD = 2;
let K_LIST = 3;
let K_ITEM = 4;
let K_QUOTE = 5;
let K_CODE = 6;
let K_MATH = 7;
let K_TABLE = 8;
let K_ROW = 9;
let K_CELL = 10;
let K_FIG = 11;
let K_RULE = 12;
let K_PAUSE = 13;
let K_DIV = 14;
let K_RAW = 15;
// Inline events.
let I_TEXT = 20;
let I_EM = 21;
let I_STRONG = 22;
let I_DEL = 23;
let I_CODE = 24;
let I_MATH = 25;
let I_LINK = 26;
let I_IMG = 27;
let I_SOFT = 28;
let I_HARD = 29;
let I_HTML = 30;

// Division kinds (the `n` of a K_DIV event).
let D_BOX = 1;
let D_COLUMNS = 2;
let D_COLUMN = 3;
let D_MORPH = 4;
let D_PLOT = 5;
let D_CHART = 6;
let D_NOTES = 7;
let D_NARRATION = 8;
let D_PUBLIC = 9;
let D_EXPLAIN = 10;
let D_UNKNOWN = 11;

// Media kinds (the `n` of a K_FIG event).
let M_IMAGE = 0;
let M_VIDEO = 1;
let M_AUDIO = 2;

// Scopes from `<!-- article -->` and `<!-- slides -->`.
let SC_NONE = 0;
let SC_ARTICLE = 1;
let SC_SLIDES = 2;

// Frame kinds.
let F_TITLE = 0;
let F_SECTION = 1;
let F_FRAME = 2;

// Event fields by kind:
//   K_HEAD: n = level.  K_LIST: n = start, fl = 1 ordered + 2 tight.
//   K_ITEM: fl = 0 plain, 1 unchecked, 2 checked.  K_CODE: a = text, b = language.
//   K_MATH, I_MATH: a = LaTeX.  K_ROW: fl = 1 for the header row.
//   K_CELL: fl = 0 none, 1 left, 2 center, 3 right.
//   K_FIG: a = description, b = path, c = caption, n = media kind, fl = 1 decorative.
//   K_DIV: n = division kind, a = title, b = name, c = raw text, fl = 1 unclosed.
//   K_RAW, I_TEXT, I_CODE, I_HTML: a = text.  I_LINK: b = URL, c = title.
//   I_IMG: a = description, b = URL, c = title.
struct Ev {
    k: i64,
    close: bool,
    fl: i64,
    n: i64,
    end: i64,
    a: Span,
    b: Span,
    c: Span,
    s0: i64,
    s1: i64,
    scope: i64,
}

struct Line { s: i64, e: i64 }

struct Meta { k: Span, v: Span }

// A structural problem. kind: 1 unclosed division (a = name), 2 unclosed
// fence, 3 unclosed math, 4 unclosed scope, 5 stray scope end, 6 nested
// scope, 7 unclosed comment, 8 unclosed front matter.
struct Issue { kind: i64, s0: i64, s1: i64, a: Span, scope: i64 }

// An inline element with its source range. kind: 1 math, 2 image, 3 link.
struct Anchor { kind: i64, a: Span, b: Span, s0: i64, s1: i64 }

struct Frame {
    kind: i64,
    head: i64,       // the heading event, or -1
    lo: i64,         // the body: top-level events lo..hi
    hi: i64,
    s0: i64,         // the heading and its body in the source
    s1: i64,
    hs0: i64,        // the heading line
    hs1: i64,
    id: Span,
    title: Span,     // plain text
    section: Span,
    scope: i64,
}

var EV: Ev[>..] = [];
var LN: Line[>..] = [];
var META: Meta[>..] = [];
var ISS: Issue[>..] = [];
var ANC: Anchor[>..] = [];
var FR: Frame[>..] = [];
// UTF-16 offset of each byte of the source, for the editor.
var U16: i32[>..] = [];
var FRONT_S0 = -1;
var FRONT_S1 = -1;

fn ev_push(k: i64, s0: i64, s1: i64, scope: i64) -> i64 {
    let i = EV.len;
    EV.push(Ev { k: k, close: false, fl: 0, n: 0, end: i + 1, a: Span { 0, 0 }, b: Span { 0, 0 },
                 c: Span { 0, 0 }, s0: s0, s1: s1, scope: scope });
    return i;
}

fn ev_close(i: i64) {
    let k = EV[i].k;
    let s0 = EV[i].s0;
    let s1 = EV[i].s1;
    let sc = EV[i].scope;
    EV.push(Ev { k: k, close: true, fl: 0, n: 0, end: EV.len + 1, a: Span { 0, 0 }, b: Span { 0, 0 },
                 c: Span { 0, 0 }, s0: s0, s1: s1, scope: sc });
    EV[i].end = EV.len;
}

fn issue(kind: i64, s0: i64, s1: i64) { ISS.push(Issue { kind: kind, s0: s0, s1: s1, a: Span { 0, 0 }, scope: 0 }); }

// --- front matter -------------------------------------------------------

fn meta(key: u8[:]) -> u8[:] {
    var i = META.len - 1;
    while i >= 0 {
        if sp_text(META[i].k) == key { return sp_text(META[i].v); }
        i--;
    }
    return "";
}

fn has_meta(key: u8[:]) -> bool {
    for m in META { if sp_text(m.k) == key { return true; } }
    return false;
}

fn meta_lang() -> u8[:] {
    let l = meta("lang");
    if l.len > 0 { return l; }
    let l2 = meta("language");
    if l2.len > 0 { return l2; }
    return "en";
}

fn parse_front_line(t: u8[:]) {
    if t.len == 0 || t[0] == ' ' || t[0] == '\t' { return; }
    let colon = index_of_byte(t, ':');
    if colon < 0 { return; }
    let key = trim_sp(t[..colon]);
    if key.len == 0 { return; }
    for c in key { if !(is_alnum(c) || c == '-' || c == '_' || c >= 0x80) { return; } }
    var v = trim_sp(t[colon + 1..]);
    if v.len >= 2 && ((v[0] == '"' && v[v.len - 1] == '"') || (v[0] == '\'' && v[v.len - 1] == '\'')) {
        v = v[1..v.len - 1];
    }
    let ko = S.len;
    for c in key { S.push(lower(c)); }
    let k = Span { ko, key.len };
    META.push(Meta { k: k, v: sp_add(v) });
}

// --- lines --------------------------------------------------------------

fn ln_text(l: Line) -> u8[:] { SRC[l.s..l.e] }

fn ln_blank(l: Line) -> bool {
    for i in l.s..l.e { let c = SRC[i]; if c != ' ' && c != '\t' && c != '\r' { return false; } }
    return true;
}

fn ln_indent(l: Line) -> i64 {
    var col = 0;
    var i = l.s;
    while i < l.e {
        let c = SRC[i];
        if c == ' ' { col++; } else if c == '\t' { col += 4 - col % 4; } else { break; }
        i++;
    }
    return col;
}

// Removes up to n columns of leading white space.
fn ln_drop_indent(l: Line, n: i64) -> Line {
    var col = 0;
    var i = l.s;
    while i < l.e && col < n {
        let c = SRC[i];
        if c == ' ' { col++; } else if c == '\t' { col += 4 - col % 4; } else { break; }
        i++;
    }
    return Line { i, l.e };
}

fn ln_drop(l: Line, k: i64) -> Line { Line { min(l.s + k, l.e), l.e } }

fn ln_trim(l: Line) -> u8[:] { trim_sp(ln_text(l)) }

// --- line classes -------------------------------------------------------

struct Fence { ch: u8, len: i64, info: const u8[:], ok: bool }

fn fence(t: u8[:]) -> Fence {
    var i = 0;
    while i < t.len && t[i] == ' ' { i++; }
    if i > 3 || i >= t.len || (t[i] != '`' && t[i] != '~') { return Fence { '`', 0, "", false }; }
    let ch = t[i];
    var j = i;
    while j < t.len && t[j] == ch { j++; }
    if j - i < 3 { return Fence { '`', 0, "", false }; }
    let info = trim_sp(t[j..]);
    if ch == '`' && contains_byte(info, '`') { return Fence { '`', 0, "", false }; }
    return Fence { ch, j - i, info, true };
}

fn is_fence_close(t: u8[:], ch: u8, len: i64) -> bool {
    var i = 0;
    while i < t.len && t[i] == ' ' { i++; }
    if i > 3 { return false; }
    var j = i;
    while j < t.len && t[j] == ch { j++; }
    if j - i < len { return false; }
    for c in t[j..] { if c != ' ' && c != '\t' && c != '\r' { return false; } }
    return true;
}

struct Atx { level: i64, a: i64, b: i64, ok: bool }

// An ATX heading: the level and the content as offsets in t.
fn atx(t: u8[:]) -> Atx {
    var i = 0;
    while i < t.len && t[i] == ' ' { i++; }
    if i > 3 { return Atx { 0, 0, 0, false }; }
    var h = i;
    while h < t.len && t[h] == '#' { h++; }
    let level = h - i;
    if level < 1 || level > 6 { return Atx { 0, 0, 0, false }; }
    if h < t.len && t[h] != ' ' && t[h] != '\t' { return Atx { 0, 0, 0, false }; }
    var a = h;
    while a < t.len && (t[a] == ' ' || t[a] == '\t') { a++; }
    var b = t.len;
    while b > a && (t[b - 1] == ' ' || t[b - 1] == '\t' || t[b - 1] == '\r') { b--; }
    // An optional closing sequence of #.
    var k = b;
    while k > a && t[k - 1] == '#' { k--; }
    if k < b && (k == a || t[k - 1] == ' ' || t[k - 1] == '\t') {
        b = k;
        while b > a && (t[b - 1] == ' ' || t[b - 1] == '\t') { b--; }
    }
    return Atx { level, a, b, true };
}

fn is_rule(t: u8[:]) -> bool {
    var i = 0;
    while i < t.len && t[i] == ' ' { i++; }
    if i > 3 || i >= t.len { return false; }
    let ch = t[i];
    if ch != '-' && ch != '*' && ch != '_' { return false; }
    var count = 0;
    for c in t[i..] {
        if c == ch { count++; } else if c != ' ' && c != '\t' && c != '\r' { return false; }
    }
    return count >= 3;
}

fn is_pause(t: u8[:]) -> bool {
    let s = trim_all(t);
    if s.len < 5 || s[0] != '.' || s[s.len - 1] != '.' { return false; }
    var dots = 0;
    var i = 0;
    while i < s.len {
        if s[i] == '.' {
            dots++;
            i++;
            if dots < 3 {
                if i >= s.len || !is_ws(s[i]) { return false; }
                while i < s.len && is_ws(s[i]) { i++; }
            }
        } else { return false; }
    }
    return dots == 3;
}

struct DivOpen { name: const u8[:], title: const u8[:], ok: bool }

fn div_open(t0: u8[:]) -> DivOpen {
    let t = trim_all(t0);
    if !has_prefix(t, ":::") { return DivOpen { "", "", false }; }
    var i = 0;
    while i < t.len && t[i] == ':' { i++; }
    var rest = trim_sp(t[i..]);
    while rest.len > 0 && rest[rest.len - 1] == ':' { rest = rest[..rest.len - 1]; }
    rest = trim_sp(rest);
    if rest.len == 0 { return DivOpen { "", "", false }; }
    var r = rest;
    var braced = false;
    if r[0] == '{' { r = r[1..]; braced = true; }
    if r.len > 0 && r[0] == '.' { r = r[1..]; }
    var n = 0;
    while n < r.len && (is_alnum(r[n]) || r[n] == '-' || r[n] == '_') { n++; }
    let name = r[..n];
    var rem = r[n..];
    if braced {
        let close = index_of_byte(rem, '}');
        if close >= 0 { rem = rem[close + 1..]; }
    }
    if name.len == 0 || !is_alpha(name[0]) { return DivOpen { "", "", false }; }
    return DivOpen { name, trim_sp(rem), true };
}

fn is_div_close(t0: u8[:]) -> bool {
    let t = trim_all(t0);
    return t.len >= 3 && all_bytes(t, ':');
}

fn div_kind(name: u8[:]) -> i64 {
    if eq_nocase(name, "columns") { return D_COLUMNS; }
    if eq_nocase(name, "column") { return D_COLUMN; }
    if eq_nocase(name, "morph") || eq_nocase(name, "steps") { return D_MORPH; }
    if eq_nocase(name, "plot") { return D_PLOT; }
    if eq_nocase(name, "chart") { return D_CHART; }
    if eq_nocase(name, "notes") { return D_NOTES; }
    if eq_nocase(name, "narration") { return D_NARRATION; }
    if eq_nocase(name, "public-notes") || eq_nocase(name, "handout") || eq_nocase(name, "listener-notes") { return D_PUBLIC; }
    if eq_nocase(name, "explain") || eq_nocase(name, "explanation") { return D_EXPLAIN; }
    for b in ["block", "theorem", "example", "alert", "key", "definition", "proof", "lemma", "note"] {
        if eq_nocase(name, b) { return D_BOX; }
    }
    return D_UNKNOWN;
}

fn div_is_raw(k: i64) -> bool { k == D_NOTES || k == D_NARRATION || k == D_PUBLIC || k == D_EXPLAIN || k == D_PLOT }

struct Marker {
    ordered: bool,
    bullet: u8,
    delim: u8,
    start: i64,
    indent: i64,     // columns from the line start to the content
    chars: i64,      // bytes from the line start to the content
    empty: bool,
    ok: bool,
}

fn no_marker() -> Marker { Marker { false, '-', '.', 1, 0, 0, false, false } }

fn list_marker(t: u8[:]) -> Marker {
    var i = 0;
    while i < t.len && t[i] == ' ' { i++; }
    if i > 3 || i >= t.len { return no_marker(); }
    var ordered = false;
    var bullet: u8 = '-';
    var delim: u8 = '.';
    var start = 1;
    var end = i;
    let c = t[i];
    if c == '-' || c == '*' || c == '+' {
        bullet = c;
        end = i + 1;
    } else if is_digit(c) {
        var j = i;
        while j < t.len && j - i < 9 && is_digit(t[j]) { j++; }
        if j >= t.len || (t[j] != '.' && t[j] != ')') { return no_marker(); }
        ordered = true;
        delim = t[j];
        let v, ok = parse_int(t[i..j]);
        start = if ok { v } else { 1 };
        end = j + 1;
    } else {
        return no_marker();
    }
    var rest_blank = true;
    for x in t[end..] { if x != ' ' && x != '\t' && x != '\r' { rest_blank = false; } }
    if end == t.len || (rest_blank && end < t.len && t[end] == '\r') {
        return Marker { ordered, bullet, delim, start, end + 1, end, true, true };
    }
    if t[end] != ' ' && t[end] != '\t' { return no_marker(); }
    var spaces = 0;
    var k = end;
    while k < t.len && t[k] == ' ' { spaces++; k++; }
    let empty = rest_blank;
    if spaces > 4 || empty { spaces = 1; k = end + 1; }
    return Marker { ordered, bullet, delim, start, end + spaces, min(k, t.len), empty, true };
}

fn is_quote(t: u8[:]) -> bool {
    var i = 0;
    while i < t.len && t[i] == ' ' { i++; }
    return i <= 3 && i < t.len && t[i] == '>';
}

// The text of `<!-- text -->` on one line, in lower case, or "".
fn directive(out: u8[>..]&, t0: u8[:]) -> bool {
    let t = trim_all(t0);
    if !has_prefix(t, "<!--") || !has_suffix(t, "-->") || t.len < 7 { return false; }
    for c in trim_all(t[4..t.len - 3]) { out.push(lower(c)); }
    return true;
}

// Splits a table row into cells, as slices of t. Escaped pipes stay in the
// cell text; the inline parser reads `\|` as `|`.
fn table_cells(t0: u8[:]) -> const u8[:][>..] {
    var t = trim_all(t0);
    if t.len > 0 && t[0] == '|' { t = t[1..]; }
    if t.len > 0 && t[t.len - 1] == '|' && !(t.len > 1 && t[t.len - 2] == '\\') { t = t[..t.len - 1]; }
    var cells: const u8[:][>..] = [];
    var start = 0;
    var escaped = false;
    var in_code = false;
    for c, i in t {
        if escaped { escaped = false; continue; }
        if c == '\\' { escaped = true; continue; }
        if c == '`' { in_code = !in_code; }
        if c == '|' && !in_code { cells.push(trim_sp(t[start..i])); start = i + 1; }
    }
    cells.push(trim_sp(t[start..]));
    return cells;
}

// The alignments of a delimiter row (0 none, 1 left, 2 center, 3 right),
// or an empty array when the line is not a delimiter row.
fn delimiter_row(t: u8[:]) -> i64[>..] {
    var out: i64[>..] = [];
    if !contains_byte(t, '-') { return out; }
    let cells = table_cells(t);
    for cell in cells {
        let c = trim_sp(cell);
        if c.len == 0 { out.clear(); return out; }
        var a = 0;
        var b = c.len;
        let left = c[0] == ':';
        let right = c[c.len - 1] == ':';
        if left { a = 1; }
        if right && b > a { b--; }
        if b <= a { out.clear(); return out; }
        for x in c[a..b] { if x != '-' { out.clear(); return out; } }
        out.push(if left && right { 2 } else if right { 3 } else if left { 1 } else { 0 });
    }
    return out;
}

fn is_delimiter_row(t: u8[:]) -> bool { delimiter_row(t).len > 0 }

fn starts_display_math(t: u8[:]) -> bool {
    let s = trim_sp(t);
    return has_prefix(s, "$$") || has_prefix(s, "\\[");
}

fn interrupts_paragraph(t: u8[:]) -> bool {
    if fence(t).ok || atx(t).ok || is_quote(t) || is_rule(t) { return true; }
    if is_pause(t) || div_open(t).ok || is_div_close(t) { return true; }
    if starts_display_math(t) { return true; }
    var d: u8[>..] = [];
    if directive(d, t) { return true; }
    let m = list_marker(t);
    if m.ok && !m.empty && (!m.ordered || m.start == 1) { return true; }
    return false;
}

fn is_top_heading(t: u8[:]) -> bool {
    let h = atx(t);
    return h.ok && h.level <= 2;
}

fn is_html_block_start(t: u8[:]) -> bool {
    let s = trim_sp(t);
    if s.len < 2 || s[0] != '<' { return false; }
    var i = 1;
    if i < s.len && s[i] == '/' { i++; }
    if i >= s.len || !is_alpha(s[i]) { return false; }
    while i < s.len && (is_alnum(s[i]) || s[i] == '-') { i++; }
    if i == s.len { return true; }
    let c = s[i];
    return c == ' ' || c == '\t' || c == '>' || c == '\r' || (c == '/' && i + 1 < s.len && s[i + 1] == '>');
}

fn media_kind(path: u8[:]) -> i64 {
    var p = path;
    let q = index_of_byte(p, '?');
    if q >= 0 { p = p[..q]; }
    var ext: u8[>..] = [];
    let dot = rfind(p, ".");
    if dot >= 0 { for c in p[dot + 1..] { ext.push(lower(c)); } }
    for e in ["mp4", "mov", "m4v", "webm"] { if ext == e { return M_VIDEO; } }
    for e in ["mp3", "m4a", "wav", "aac", "caf"] { if ext == e { return M_AUDIO; } }
    return M_IMAGE;
}

// --- blocks -------------------------------------------------------------

// Lines lo..hi of LN are one block container's lines.
recursive fn parse_blocks(lo: i64, hi: i64, inherited: i64) {
    var i = lo;
    var scope = SC_NONE;
    var scope_s0 = -1;
    var scope_s1 = -1;
    var decorative = false;

    while i < hi {
        let line = LN[i];
        if ln_blank(line) { i++; continue; }
        let text = ln_text(line);
        let sc = if scope != SC_NONE { scope } else { inherited };

        // Indented code.
        if ln_indent(line) >= 4 {
            var j = i;
            while j < hi && (ln_blank(LN[j]) || ln_indent(LN[j]) >= 4) { j++; }
            while j > i + 1 && ln_blank(LN[j - 1]) { j--; }
            let o = S.len;
            for k in i..j {
                if k > i { S.push('\n'); }
                S.append(ln_text(ln_drop_indent(LN[k], 4)));
            }
            let e = ev_push(K_CODE, line.s, LN[j - 1].e, sc);
            EV[e].a = Span { o, S.len - o };
            i = j;
            continue;
        }

        // Fenced code.
        let f = fence(text);
        if f.ok {
            let fi = ln_indent(line);
            var j = i + 1;
            var closed = false;
            let o = S.len;
            while j < hi {
                if is_fence_close(ln_text(LN[j]), f.ch, f.len) { closed = true; break; }
                if j > i + 1 { S.push('\n'); }
                S.append(ln_text(ln_drop_indent(LN[j], fi)));
                j++;
            }
            let last = if closed { j } else { hi - 1 };
            if !closed { issue(2, line.s, line.e); }
            let e = ev_push(K_CODE, line.s, LN[last].e, sc);
            EV[e].a = Span { o, S.len - o };
            var ln = 0;
            while ln < f.info.len && f.info[ln] != ' ' { ln++; }
            EV[e].b = sp_add(f.info[..ln]);
            i = last + 1;
            continue;
        }

        let trimmed = ln_trim(line);

        // Display math.
        if has_prefix(trimmed, "$$") || has_prefix(trimmed, "\\[") {
            let dollars = trimmed[0] == '$';
            let close = if dollars { "$$" } else { "\\]" };
            let after = trimmed[2..];
            let r = rfind(after, close);
            if r >= 0 && trim_all(after[r + 2..]).len == 0 {
                let e = ev_push(K_MATH, line.s, line.e, sc);
                EV[e].a = sp_add(trim_all(after[..r]));
                i++;
                continue;
            }
            let o = S.len;
            S.append(after);
            var j = i + 1;
            var closed = false;
            while j < hi {
                if ln_blank(LN[j]) { break; }
                let t = ln_text(LN[j]);
                let p = index_of(t, close);
                S.push('\n');
                if p >= 0 { S.append(t[..p]); closed = true; break; }
                S.append(t);
                j++;
            }
            let last = if closed { j } else { max(i, j - 1) };
            if !closed { issue(3, line.s, line.e); }
            let whole = Span { o, S.len - o };
            let e = ev_push(K_MATH, line.s, LN[last].e, sc);
            EV[e].a = sp_add(trim_all(sp_text(whole)));
            i = last + 1;
            continue;
        }

        // Fenced division.
        let d = div_open(text);
        if d.ok {
            let kind = div_kind(d.name);
            let raw = div_is_raw(kind);
            var j = i + 1;
            var depth = 0;
            var in_fence = false;
            var fch: u8 = '`';
            var flen = 0;
            var closed = false;
            while j < hi {
                let t = ln_text(LN[j]);
                if in_fence {
                    if is_fence_close(t, fch, flen) { in_fence = false; }
                    j++;
                    continue;
                }
                let ff = fence(t);
                if ff.ok { in_fence = true; fch = ff.ch; flen = ff.len; j++; continue; }
                if is_top_heading(t) { break; }
                if is_div_close(t) {
                    if depth == 0 { closed = true; break; }
                    depth--;
                } else if !raw && div_open(t).ok {
                    depth++;
                }
                j++;
            }
            let last = if closed { j } else { j - 1 };
            let s1 = LN[max(i, last)].e;
            if !closed {
                ISS.push(Issue { kind: 1, s0: line.s, s1: line.e, a: sp_add(d.name), scope: 0 });
            }
            let e = ev_push(K_DIV, line.s, s1, sc);
            EV[e].n = kind;
            EV[e].a = sp_add(d.title);
            let no = S.len;
            for c in d.name { S.push(lower(c)); }
            EV[e].b = Span { no, d.name.len };
            // The raw text, without leading and trailing new lines.
            let o = S.len;
            for k in i + 1..j {
                if k > i + 1 { S.push('\n'); }
                S.append(ln_text(LN[k]));
            }
            var a = o;
            var b = S.len;
            while a < b && (S[a] == '\n' || S[a] == '\r') { a++; }
            while b > a && (S[b - 1] == '\n' || S[b - 1] == '\r') { b--; }
            EV[e].c = Span { a, b - a };
            if !closed { EV[e].fl = 1; }
            if !raw { parse_blocks(i + 1, j, sc); }
            ev_close(e);
            i = if closed { j + 1 } else { j };
            continue;
        }

        // A stray division close.
        if is_div_close(text) { i++; continue; }

        // HTML comments: scope markers, the decorative marker, and comments.
        if has_prefix(trimmed, "<!--") {
            var j = i;
            var closed = false;
            while j < hi {
                if index_of(ln_text(LN[j]), "-->") >= 0 { closed = true; break; }
                j++;
            }
            if !closed { issue(7, line.s, line.e); j = hi - 1; }
            var dir: u8[>..] = [];
            if j == i && directive(dir, text) {
                if dir == "article" || dir == "article-only" || dir == "slides" || dir == "slides-only" || dir == "slide-only" {
                    let s = if has_prefix(dir, "article") { SC_ARTICLE } else { SC_SLIDES };
                    if scope != SC_NONE {
                        ISS.push(Issue { kind: 6, s0: line.s, s1: line.e, a: Span { 0, 0 }, scope: s });
                    } else {
                        scope = s;
                        scope_s0 = line.s;
                        scope_s1 = line.e;
                    }
                } else if dir == "/article" || dir == "end article" || dir == "/article-only" || dir == "/slides" ||
                          dir == "/slides-only" || dir == "/slide-only" || dir == "end slides" {
                    let s = if index_of(dir, "article") >= 0 { SC_ARTICLE } else { SC_SLIDES };
                    if scope == s { scope = SC_NONE; } else {
                        ISS.push(Issue { kind: 5, s0: line.s, s1: line.e, a: Span { 0, 0 }, scope: s });
                    }
                } else if dir == "decorative" {
                    decorative = true;
                }
            }
            i = j + 1;
            continue;
        }

        // Pause.
        if is_pause(text) {
            ev_push(K_PAUSE, line.s, line.e, sc);
            i++;
            continue;
        }

        // ATX heading.
        let h = atx(text);
        if h.ok {
            let e = ev_push(K_HEAD, line.s, line.e, sc);
            EV[e].n = h.level;
            let o = S.len;
            S.append(text[h.a..h.b]);
            SEG.clear();
            SEG.push(Seg { 0, line.s + h.a });
            inline_parse(o, h.b - h.a);
            inline_emit();
            ev_close(e);
            i++;
            continue;
        }

        // Thematic break.
        if is_rule(text) {
            ev_push(K_RULE, line.s, line.e, sc);
            i++;
            continue;
        }

        // Block quote.
        if is_quote(text) {
            var j = i;
            let first = LN.len;
            var last_para = false;
            while j < hi {
                let l = LN[j];
                if is_quote(ln_text(l)) {
                    var st = ln_drop(ln_drop_indent(l, 3), 1);
                    if st.s < st.e && SRC[st.s] == ' ' { st = ln_drop(st, 1); }
                    LN.push(st);
                    last_para = !ln_blank(st);
                    j++;
                } else if !ln_blank(l) && last_para && !interrupts_paragraph(ln_text(l)) {
                    LN.push(l);
                    j++;
                } else {
                    break;
                }
            }
            let e = ev_push(K_QUOTE, line.s, LN[j - 1].e, sc);
            parse_blocks(first, LN.len, sc);
            ev_close(e);
            i = j;
            continue;
        }

        // List.
        let m = list_marker(text);
        if m.ok {
            i = parse_list(i, hi, m, sc);
            continue;
        }

        // Table.
        if contains_byte(text, '|') && i + 1 < hi {
            let aligns = delimiter_row(ln_text(LN[i + 1]));
            if aligns.len > 0 {
                let header = table_cells(text);
                if header.len == aligns.len {
                    var j = i + 2;
                    while j < hi && !ln_blank(LN[j]) && contains_byte(ln_text(LN[j]), '|') &&
                          (!interrupts_paragraph(ln_text(LN[j])) || has_prefix(ln_trim(LN[j]), "|")) { j++; }
                    let e = ev_push(K_TABLE, line.s, LN[j - 1].e, sc);
                    table_row(LN[i], aligns, true, sc);
                    for k in i + 2..j { table_row(LN[k], aligns, false, sc); }
                    ev_close(e);
                    i = j;
                    continue;
                }
            }
        }

        // Raw HTML block.
        if is_html_block_start(text) {
            var j = i;
            while j < hi && !ln_blank(LN[j]) { j++; }
            let o = S.len;
            for k in i..j {
                if k > i { S.push('\n'); }
                S.append(ln_text(LN[k]));
            }
            let e = ev_push(K_RAW, line.s, LN[j - 1].e, sc);
            EV[e].a = Span { o, S.len - o };
            i = j;
            continue;
        }

        // Paragraph, with setext headings.
        var j = i;
        var setext = 0;
        while j < hi {
            let l = LN[j];
            if ln_blank(l) { break; }
            if j > i {
                let t = ln_trim(l);
                let ind = ln_indent(l);
                if ind <= 3 && t.len > 0 && all_bytes(trim_all(t), '=') { setext = 1; break; }
                if ind <= 3 && trim_all(t).len >= 2 && all_bytes(trim_all(t), '-') { setext = 2; break; }
                if interrupts_paragraph(ln_text(l)) { break; }
                if j == i + 1 && contains_byte(ln_text(l), '|') && is_delimiter_row(ln_text(l)) { break; }
            }
            j++;
        }
        SEG.clear();
        let o = S.len;
        for k in i..j {
            let l = ln_drop_indent(LN[k], ln_indent(LN[k]));
            if k > i { S.push(if setext > 0 { ' ' } else { '\n' }); }
            SEG.push(Seg { S.len - o, l.s });
            var t = ln_text(l);
            if t.len > 0 && t[t.len - 1] == '\r' { t = t[..t.len - 1]; }
            S.append(t);
        }
        if setext > 0 {
            let e = ev_push(K_HEAD, line.s, LN[j].e, sc);
            EV[e].n = setext;
            inline_parse(o, S.len - o);
            inline_emit();
            ev_close(e);
            i = j + 1;
            continue;
        }
        let s0 = ln_drop_indent(LN[i], 99).s;
        let s1 = LN[j - 1].e;
        inline_parse(o, S.len - o);
        let fig = inline_figure();
        if fig >= 0 {
            let t = TK[fig];
            let e = ev_push(K_FIG, s0, s1, sc);
            EV[e].a = t.a;
            EV[e].b = t.b;
            EV[e].c = t.c;
            EV[e].n = media_kind(sp_text(t.b));
            if decorative { EV[e].fl = 1; }
        } else {
            let e = ev_push(K_PARA, s0, s1, sc);
            inline_emit();
            ev_close(e);
        }
        decorative = false;
        i = j;
    }
    if scope != SC_NONE {
        ISS.push(Issue { kind: 4, s0: scope_s0, s1: scope_s1, a: Span { 0, 0 }, scope: scope });
    }
}

fn table_row(l: Line, aligns: i64[:], header: bool, sc: i64) {
    let cells = table_cells(ln_text(l));
    let r = ev_push(K_ROW, l.s, l.e, sc);
    if header { EV[r].fl = 1; }
    for k in aligns.len {
        let e = ev_push(K_CELL, l.s, l.e, sc);
        EV[e].fl = aligns[k];
        if k < cells.len {
            let o = S.len;
            // As Swift's tableCells: "\\|" becomes "|" in each cell.
            let cell = cells[k];
            var ci = 0;
            while ci < cell.len {
                if cell[ci] == '\\' && ci + 1 < cell.len && cell[ci + 1] == '|' { S.push('|'); ci += 2; continue; }
                S.push(cell[ci]);
                ci++;
            }
            SEG.clear();
            SEG.push(Seg { 0, l.s });
            inline_parse(o, S.len - o);
            // Cell offsets are approximate: anchors point at the row.
            for &a in ANC[ANC_MARK..] { a.s0 = l.s; a.s1 = l.e; }
            inline_emit();
        }
        ev_close(e);
    }
    ev_close(r);
}

fn parse_list(start: i64, hi: i64, first: Marker, sc: i64) -> i64 {
    var i = start;
    var tight = true;
    var blank_between = false;
    let e = ev_push(K_LIST, LN[start].s, LN[start].e, sc);
    EV[e].n = if first.ordered { first.start } else { 0 };
    var items = 0;
    while i < hi {
        let line = LN[i];
        let m = list_marker(ln_text(line));
        if !m.ok || m.ordered != first.ordered { break; }
        if m.ordered && m.delim != first.delim { break; }
        if !m.ordered && m.bullet != first.bullet { break; }
        if is_rule(ln_text(line)) && !m.ordered { break; }
        if items > 0 && blank_between { tight = false; }
        let ci = m.indent;
        let firstln = LN.len;
        LN.push(ln_drop(line, m.chars));
        var j = i + 1;
        var last_para = !m.empty;
        var blank_inside = false;
        while j < hi {
            let l = LN[j];
            if ln_blank(l) {
                var k = j;
                while k < hi && ln_blank(LN[k]) { k++; }
                if k < hi && ln_indent(LN[k]) >= ci {
                    for b in j..k { LN.push(Line { LN[b].s, LN[b].s }); }
                    blank_inside = true;
                    j = k;
                    continue;
                }
                break;
            }
            if ln_indent(l) >= ci {
                let dl = ln_drop_indent(l, ci);
                LN.push(dl);
                last_para = !interrupts_paragraph(ln_text(dl));
                j++;
                continue;
            }
            if list_marker(ln_text(l)).ok || interrupts_paragraph(ln_text(l)) { break; }
            if last_para {
                LN.push(ln_drop_indent(l, ln_indent(l)));
                j++;
                continue;
            }
            break;
        }
        // A task item.
        var checked = 0;
        let fl = LN[firstln];
        let ft = ln_text(fl);
        if has_prefix(ft, "[ ] ") || ft == "[ ]" { checked = 1; LN[firstln] = ln_drop(fl, min(4, ft.len)); }
        else if has_prefix(ft, "[x] ") || has_prefix(ft, "[X] ") || ft == "[x]" || ft == "[X]" {
            checked = 2;
            LN[firstln] = ln_drop(fl, min(4, ft.len));
        }
        let it = ev_push(K_ITEM, line.s, LN[j - 1].e, sc);
        EV[it].fl = checked;
        let before = EV.len;
        parse_blocks(firstln, LN.len, sc);
        // More than one child block after a blank line makes a loose list.
        var children = 0;
        var c = before;
        while c < EV.len { children++; c = EV[c].end; }
        if blank_inside && children > 1 { tight = false; }
        ev_close(it);
        EV[e].s1 = LN[j - 1].e;
        items++;
        var k = j;
        while k < hi && ln_blank(LN[k]) { k++; }
        blank_between = k > j;
        if k < hi {
            let next = list_marker(ln_text(LN[k]));
            if next.ok && next.ordered == first.ordered && ln_indent(LN[k]) < ci {
                i = k;
                continue;
            }
        }
        i = j;
        break;
    }
    EV[e].fl = (if first.ordered { 1 } else { 0 }) + (if tight { 2 } else { 0 });
    ev_close(e);
    return i;
}

// --- inlines ------------------------------------------------------------

let T_TEXT = 1;
let T_DELIM = 2;
let T_ATOM = 3;
let T_LOPEN = 4;
let T_LCLOSE = 5;

struct Tok {
    k: i64,
    ek: i64,       // the event kind of an atom
    ch: u8,
    cnt: i64,
    op: bool,
    cl: bool,
    act: bool,
    partner: i64,  // the other end of a link
    a: Span,
    b: Span,
    c: Span,
}

struct Match { o: i64, c: i64, kind: i64 }

// Maps offsets of joined paragraph text to source offsets.
struct Seg { j: i64, s: i64 }

var TK: Tok[>..] = [];
var MT: Match[>..] = [];
var SEG: Seg[>..] = [];
var ANC_MARK = 0;

fn map_off(j: i64) -> i64 {
    if SEG.len == 0 { return j; }
    var best = SEG[0];
    for g in SEG { if g.j <= j { best = g; } }
    return best.s + (j - best.j);
}

fn tok(k: i64) -> Tok {
    Tok { k: k, ek: 0, ch: 0, cnt: 0, op: false, cl: false, act: true, partner: -1,
          a: Span { 0, 0 }, b: Span { 0, 0 }, c: Span { 0, 0 } }
}

fn entity(name: u8[:], out: u8[>..]&) -> bool {
    if name == "amp" { out.push('&'); return true; }
    if name == "lt" { out.push('<'); return true; }
    if name == "gt" { out.push('>'); return true; }
    if name == "quot" { out.push('"'); return true; }
    if name == "apos" { out.push('\''); return true; }
    if name == "nbsp" { push_utf8(out, 0xA0); return true; }
    if name == "ndash" { push_utf8(out, 0x2013); return true; }
    if name == "mdash" { push_utf8(out, 0x2014); return true; }
    if name == "hellip" { push_utf8(out, 0x2026); return true; }
    if name == "copy" { push_utf8(out, 0xA9); return true; }
    if name == "times" { push_utf8(out, 0xD7); return true; }
    if name == "minus" { push_utf8(out, 0x2212); return true; }
    if name == "deg" { push_utf8(out, 0xB0); return true; }
    if name == "plusmn" { push_utf8(out, 0xB1); return true; }
    if name.len >= 2 && name[0] == '#' {
        var v = 0;
        var ok = false;
        if name[1] == 'x' || name[1] == 'X' {
            let n, k = parse_int(name[2..], 16);
            v = n;
            ok = k;
        } else {
            let n, k = parse_int(name[1..]);
            v = n;
            ok = k;
        }
        if ok && v > 0 && v < 0x110000 { push_utf8(out, v); return true; }
    }
    return false;
}

fn is_uni_ws(t: u8[:], i: i64) -> bool { i < 0 || i >= t.len || is_ws(t[i]) }
fn is_uni_punct(t: u8[:], i: i64) -> bool { i >= 0 && i < t.len && is_ascii_punct(t[i]) }

struct LinkM { close: i64, url: Span, title: Span, end: i64, ok: bool }

fn no_link() -> LinkM { LinkM { 0, Span { 0, 0 }, Span { 0, 0 }, 0, false } }

// `[text](url "title")` at `start`, which is the `[`. Offsets are in t.
fn link_like(t: u8[:], start: i64, to: i64) -> LinkM {
    var depth = 0;
    var i = start;
    var close = -1;
    while i < to {
        let c = t[i];
        if c == '\\' { i += 2; continue; }
        if c == '`' {
            var run = 0;
            while i + run < to && t[i + run] == '`' { run++; }
            var j = i + run;
            while j < to {
                if t[j] == '`' {
                    var r = 0;
                    while j + r < to && t[j + r] == '`' { r++; }
                    if r == run { break; }
                    j += r;
                } else { j++; }
            }
            i = j + run;
            continue;
        }
        if c == '[' { depth++; }
        if c == ']' {
            depth--;
            if depth == 0 { close = i; break; }
        }
        i++;
    }
    if close <= 0 || close + 1 >= to || t[close + 1] != '(' { return no_link(); }
    var j = close + 2;
    while j < to && (t[j] == ' ' || t[j] == '\n') { j++; }
    let uo = S.len;
    if j < to && t[j] == '<' {
        let gt = index_of_byte(t[..to], '>', j + 1);
        if gt < 0 { return no_link(); }
        for c in t[j + 1..gt] { S.push(c); }
        j = gt + 1;
    } else {
        var parens = 0;
        while j < to {
            let c = t[j];
            if c == '\\' && j + 1 < to { S.push(t[j + 1]); j += 2; continue; }
            if c == ' ' || c == '\n' { break; }
            if c == '(' { parens++; }
            if c == ')' {
                if parens == 0 { break; }
                parens--;
            }
            S.push(c);
            j++;
        }
    }
    let url = Span { uo, S.len - uo };
    while j < to && (t[j] == ' ' || t[j] == '\n') { j++; }
    var title = Span { 0, 0 };
    if j < to && (t[j] == '"' || t[j] == '\'' || t[j] == '(') {
        let cc = if t[j] == '(' { ')' } else { t[j] };
        var k = j + 1;
        let to0 = S.len;
        while k < to && t[k] != cc {
            if t[k] == '\\' && k + 1 < to { S.push(t[k + 1]); k += 2; continue; }
            S.push(t[k]);
            k++;
        }
        if k >= to { return no_link(); }
        title = Span { to0, S.len - to0 };
        j = k + 1;
        while j < to && (t[j] == ' ' || t[j] == '\n') { j++; }
    }
    if j >= to || t[j] != ')' { return no_link(); }
    return LinkM { close, url, title, j + 1, true };
}

// The plain text of link text, for an image description.
fn plain_of(t: u8[:]) -> Span {
    let o = S.len;
    var i = 0;
    while i < t.len {
        let c = t[i];
        if c == '\\' && i + 1 < t.len && is_ascii_punct(t[i + 1]) { S.push(t[i + 1]); i += 2; continue; }
        if c == '*' || c == '_' || c == '`' { i++; continue; }
        if c == '\n' { S.push(' '); i++; continue; }
        S.push(c);
        i++;
    }
    return Span { o, S.len - o };
}

fn is_scheme_autolink(s: u8[:]) -> bool {
    let colon = index_of_byte(s, ':');
    if colon < 2 || colon > 32 || !is_alpha(s[0]) { return false; }
    for c in s[1..colon] { if !(is_alnum(c) || c == '+' || c == '.' || c == '-') { return false; } }
    for c in s[colon + 1..] { if is_ws(c) || c == '<' || c == '>' { return false; } }
    return true;
}

fn is_email(s: u8[:]) -> bool {
    let at = index_of_byte(s, '@');
    if at < 1 { return false; }
    for c in s[..at] {
        if !(is_alnum(c) || contains_byte(".!#$%&'*+/=?^_`{|}~-", c)) { return false; }
    }
    let dom = s[at + 1..];
    if dom.len == 0 { return false; }
    var dots = 0;
    var part = 0;
    for c in dom {
        if c == '.' { if part == 0 { return false; } dots++; part = 0; }
        else if is_alnum(c) || c == '-' { part++; }
        else { return false; }
    }
    return dots > 0 && part > 0;
}

fn is_inline_tag(s: u8[:]) -> bool {
    if has_prefix(s, "!--") { return true; }
    var i = 0;
    if i < s.len && s[i] == '/' { i++; }
    if i >= s.len || !is_alpha(s[i]) { return false; }
    while i < s.len && (is_alnum(s[i]) || s[i] == '-') { i++; }
    if i == s.len { return true; }
    if s[i] == '/' && i == s.len - 1 { return true; }
    if !is_ws(s[i]) { return false; }
    for c in s[i..] { if c == '<' || c == '>' { return false; } }
    return true;
}

fn add_anchor(kind: i64, a: Span, b: Span, j0: i64, j1: i64) {
    ANC.push(Anchor { kind: kind, a: a, b: b, s0: map_off(j0), s1: map_off(j1) });
}

// Scans S[o..o + n] into tokens in TK and resolves emphasis into MT.
fn inline_parse(o: i64, n: i64) {
    TK.clear();
    MT.clear();
    ANC_MARK = ANC.len;
    var buf: u8[>..] = [];
    // Pending link ends: the `]` offset and the offset after `)`.
    var lclose: i64[>..<] = [];
    var lend: i64[>..<] = [];
    var lopen: i64[>..<] = [];

    fn flush() {
        if buf.len > 0 {
            var t = tok(T_TEXT);
            t.a = sp_add(buf);
            TK.push(t);
            buf.clear();
        }
    }

    fn atom(ek: i64, a: Span) {
        flush();
        var t = tok(T_ATOM);
        t.ek = ek;
        t.a = a;
        TK.push(t);
    }

    let text = S[o..o + n];
    var i = 0;
    while i < n {
        if lclose.len > 0 && i == lclose[lclose.len - 1] {
            flush();
            var t = tok(T_LCLOSE);
            t.partner = lopen[lopen.len - 1];
            TK[t.partner].partner = TK.len;
            TK.push(t);
            i = lend[lend.len - 1];
            lclose.pop();
            lend.pop();
            lopen.pop();
            continue;
        }
        let to = if lclose.len > 0 { lclose[lclose.len - 1] } else { n };
        let c = text[i];
        if c == '\\' {
            if i + 1 < to {
                let nx = text[i + 1];
                if nx == '(' {
                    let end = index_of(text[..to], "\\)", i + 2);
                    if end >= 0 {
                        let latex = sp_add(text[i + 2..end]);
                        atom(I_MATH, latex);
                        add_anchor(1, latex, Span { 0, 0 }, i, end + 2);
                        i = end + 2;
                        continue;
                    }
                }
                if nx == '\n' { flush(); TK.push(tok(T_ATOM)); TK[TK.len - 1].ek = I_HARD; i += 2; continue; }
                if is_ascii_punct(nx) { buf.push(nx); i += 2; continue; }
            }
            buf.push(c);
            i++;
        } else if c == '`' {
            var run = 0;
            while i + run < to && text[i + run] == '`' { run++; }
            var j = i + run;
            var found = -1;
            while j < to {
                if text[j] == '`' {
                    var r = 0;
                    while j + r < to && text[j + r] == '`' { r++; }
                    if r == run { found = j; break; }
                    j += r;
                } else { j++; }
            }
            if found >= 0 {
                let co = S.len;
                for x in text[i + run..found] { S.push(if x == '\n' { ' ' } else { x }); }
                var a = co;
                var b = S.len;
                if b - a >= 2 && S[a] == ' ' && S[b - 1] == ' ' && !all_bytes(S[a..b], ' ') { a++; b--; }
                atom(I_CODE, Span { a, b - a });
                i = found + run;
            } else {
                for k in run { buf.push('`'); }
                i += run;
            }
        } else if c == '$' {
            let latex, end = inline_math(text, i, to);
            if end > 0 {
                atom(I_MATH, latex);
                add_anchor(1, latex, Span { 0, 0 }, i, end);
                i = end;
            } else {
                buf.push(c);
                i++;
            }
        } else if c == '!' && i + 1 < to && text[i + 1] == '[' {
            let lk = link_like(text, i + 1, to);
            if lk.ok {
                let desc = plain_of(text[i + 2..lk.close]);
                flush();
                var t = tok(T_ATOM);
                t.ek = I_IMG;
                t.a = desc;
                t.b = lk.url;
                t.c = lk.title;
                TK.push(t);
                add_anchor(2, desc, lk.url, i, lk.end);
                i = lk.end;
            } else {
                buf.push(c);
                i++;
            }
        } else if c == '[' {
            let lk = link_like(text, i, to);
            if lk.ok {
                flush();
                var t = tok(T_LOPEN);
                t.b = lk.url;
                t.c = lk.title;
                lopen.push(TK.len);
                TK.push(t);
                lclose.push(lk.close);
                lend.push(lk.end);
                add_anchor(3, Span { 0, 0 }, lk.url, i, lk.end);
                i++;
            } else {
                buf.push(c);
                i++;
            }
        } else if c == '<' {
            let close = index_of_byte(text[..to], '>', i + 1);
            var done = false;
            if close >= 0 {
                let inner = text[i + 1..close];
                if is_scheme_autolink(inner) {
                    flush();
                    var t = tok(T_LOPEN);
                    t.b = sp_add(inner);
                    let oi = TK.len;
                    TK.push(t);
                    var tx = tok(T_TEXT);
                    tx.a = sp_add(inner);
                    TK.push(tx);
                    var cl = tok(T_LCLOSE);
                    cl.partner = oi;
                    TK[oi].partner = TK.len;
                    TK.push(cl);
                    add_anchor(3, Span { 0, 0 }, TK[oi].b, i, close + 1);
                    i = close + 1;
                    done = true;
                } else if is_email(inner) {
                    flush();
                    var t = tok(T_LOPEN);
                    let uo = S.len;
                    S.append("mailto:");
                    S.append(inner);
                    t.b = Span { uo, S.len - uo };
                    let oi = TK.len;
                    TK.push(t);
                    var tx = tok(T_TEXT);
                    tx.a = sp_add(inner);
                    TK.push(tx);
                    var cl = tok(T_LCLOSE);
                    cl.partner = oi;
                    TK[oi].partner = TK.len;
                    TK.push(cl);
                    i = close + 1;
                    done = true;
                } else if is_inline_tag(inner) {
                    atom(I_HTML, sp_add(text[i..close + 1]));
                    i = close + 1;
                    done = true;
                }
            }
            if !done { buf.push(c); i++; }
        } else if c == '*' || c == '_' {
            var run = 0;
            while i + run < to && text[i + run] == c { run++; }
            let bw = is_uni_ws(text, i - 1);
            let aw = is_uni_ws(text, i + run);
            let bp = is_uni_punct(text, i - 1);
            let ap = is_uni_punct(text, i + run);
            let left = !aw && (!ap || bw || bp);
            let right = !bw && (!bp || aw || ap);
            var op = left;
            var cl = right;
            if c == '_' {
                op = left && (!right || bp);
                cl = right && (!left || ap);
            }
            flush();
            var t = tok(T_DELIM);
            t.ch = c;
            t.cnt = run;
            t.op = op;
            t.cl = cl;
            TK.push(t);
            i += run;
        } else if c == '~' && i + 1 < to && text[i + 1] == '~' {
            var run = 0;
            while i + run < to && text[i + run] == '~' { run++; }
            if run == 2 {
                flush();
                var t = tok(T_DELIM);
                t.ch = '~';
                t.cnt = 2;
                t.op = !is_uni_ws(text, i + 2);
                t.cl = !is_uni_ws(text, i - 1);
                TK.push(t);
            } else {
                for k in run { buf.push('~'); }
            }
            i += run;
        } else if c == '\n' {
            var trailing = 0;
            while buf.len > 0 && buf[buf.len - 1] == ' ' { buf.pop(); trailing++; }
            flush();
            var t = tok(T_ATOM);
            t.ek = if trailing >= 2 { I_HARD } else { I_SOFT };
            TK.push(t);
            i++;
            while i < to && text[i] == ' ' { i++; }
        } else if c == '&' {
            let semi = index_of_byte(text[..min(to, i + 12)], ';', i + 1);
            var done = false;
            if semi >= 0 { done = entity(text[i + 1..semi], buf); }
            if done { i = semi + 1; } else { buf.push(c); i++; }
        } else {
            buf.push(c);
            i++;
        }
    }
    flush();
    // Links whose `]` was never reached (it cannot happen for a valid match).
    while lopen.len > 0 {
        var t = tok(T_LCLOSE);
        t.partner = lopen.pop();
        TK[t.partner].partner = TK.len;
        TK.push(t);
        lclose.pop();
        lend.pop();
    }
    resolve_emphasis();
}

// Inline math with the Pandoc rules. Returns the LaTeX and the offset after
// the closing `$`, or an end of 0.
fn inline_math(t: u8[:], i: i64, to: i64) -> Span, i64 {
    if i + 1 < to && t[i + 1] == '$' {
        var j = i + 2;
        while j + 1 < to {
            if t[j] == '$' && t[j + 1] == '$' && t[j - 1] != '\\' {
                let latex = trim_all(t[i + 2..j]);
                if latex.len == 0 { return Span { 0, 0 }, 0; }
                return sp_add(latex), j + 2;
            }
            j++;
        }
        return Span { 0, 0 }, 0;
    }
    if i + 1 >= to || is_ws(t[i + 1]) { return Span { 0, 0 }, 0; }
    var j = i + 1;
    while j < to {
        let c = t[j];
        if c == '\\' { j += 2; continue; }
        if c == '\n' && j + 1 < to && t[j + 1] == '\n' { return Span { 0, 0 }, 0; }
        if c == '$' {
            let prev = t[j - 1];
            let next_digit = j + 1 < to && is_digit(t[j + 1]);
            if !is_ws(prev) && !next_digit {
                if j == i + 1 { return Span { 0, 0 }, 0; }
                return sp_add(t[i + 1..j]), j + 1;
            }
            return Span { 0, 0 }, 0;
        }
        j++;
    }
    return Span { 0, 0 }, 0;
}

fn resolve_emphasis() {
    for ci in TK.len {
        loop {
            let t = TK[ci];
            if t.k != T_DELIM || !t.cl || t.cnt == 0 || !t.act { break; }
            var oi = ci - 1;
            var found = -1;
            while oi >= 0 {
                let u = TK[oi];
                if u.k == T_LCLOSE { oi = u.partner - 1; continue; }
                if u.k == T_LOPEN { break; }
                if u.k == T_DELIM && u.act && u.op && u.cnt > 0 && u.ch == t.ch {
                    if t.ch == '~' {
                        if u.cnt != 2 || t.cnt != 2 { oi--; continue; }
                    } else if (u.cl || t.op) && (u.cnt + t.cnt) % 3 == 0 && !(u.cnt % 3 == 0 && t.cnt % 3 == 0) {
                        oi--;
                        continue;
                    }
                    found = oi;
                    break;
                }
                oi--;
            }
            if found < 0 { break; }
            let u = TK[found];
            let use = if t.ch == '~' { 2 } else if u.cnt >= 2 && t.cnt >= 2 { 2 } else { 1 };
            let kind = if t.ch == '~' { I_DEL } else if use == 2 { I_STRONG } else { I_EM };
            MT.push(Match { found, ci, kind });
            TK[found].cnt -= use;
            TK[ci].cnt -= use;
            for k in found + 1..ci { if TK[k].k == T_DELIM { TK[k].act = false; } }
        }
    }
}

// The token of an image that stands alone in its paragraph, or -1.
fn inline_figure() -> i64 {
    var img = -1;
    for t, i in TK {
        if t.k == T_TEXT {
            if trim_all(sp_text(t.a)).len > 0 { return -1; }
        } else if t.k == T_ATOM && t.ek == I_SOFT {
        } else if t.k == T_ATOM && t.ek == I_IMG && img < 0 {
            img = i;
        } else {
            return -1;
        }
    }
    return img;
}

fn emit_text(sp: Span) {
    let e = ev_push(I_TEXT, 0, 0, 0);
    EV[e].a = sp;
}

// Turns the tokens in TK into inline events.
fn inline_emit() {
    var stack: i64[>..<] = [];
    for t, ti in TK {
        if t.k == T_TEXT { emit_text(t.a); continue; }
        if t.k == T_ATOM {
            let e = ev_push(t.ek, 0, 0, 0);
            EV[e].a = t.a;
            EV[e].b = t.b;
            EV[e].c = t.c;
            continue;
        }
        if t.k == T_LOPEN {
            let e = ev_push(I_LINK, 0, 0, 0);
            EV[e].b = t.b;
            EV[e].c = t.c;
            stack.push(e);
            continue;
        }
        if t.k == T_LCLOSE {
            if stack.len > 0 { ev_close(stack.pop()); }
            continue;
        }
        // A delimiter: the closes, the unused characters, then the opens.
        for m in MT {
            if m.c == ti && stack.len > 0 { ev_close(stack.pop()); }
        }
        if t.cnt > 0 {
            let o = S.len;
            for k in t.cnt { S.push(t.ch); }
            emit_text(Span { o, t.cnt });
        }
        var k = MT.len - 1;
        while k >= 0 {
            if MT[k].o == ti { stack.push(ev_push(MT[k].kind, 0, 0, 0)); }
            k--;
        }
    }
    while stack.len > 0 { ev_close(stack.pop()); }
}

// Parses inline Markdown text that is not in the source, such as a box
// title or a Takahashi sentence, into events at the end of EV.
fn inline_text(t: u8[:]) -> i64, i64 {
    let o = S.len;
    S.append(t);
    SEG.clear();
    let mark = ANC.len;
    inline_parse(o, t.len);
    ANC.resize(mark);
    let lo = EV.len;
    inline_emit();
    return lo, EV.len;
}

// --- the document -------------------------------------------------------

fn reset() {
    EV.clear();
    LN.clear();
    META.clear();
    ISS.clear();
    ANC.clear();
    FR.clear();
    S.clear();
    OUT.clear();
    U16.clear();
    FRONT_S0 = -1;
    FRONT_S1 = -1;
}

// Reads the source from argument 0 and parses it.
fn load() {
    reset();
    SRC.clear();
    ml_arg(0, SRC);
    parse_source();
}

fn parse_source() {
    // UTF-16 offsets, for the editor.
    var u = 0;
    for c in SRC {
        U16.push(u as i32);
        if (c & 0xC0) != 0x80 { u++; }
        if (c & 0xF8) == 0xF0 { u++; }
    }
    U16.push(u as i32);
    // Lines.
    var s = 0;
    if SRC.len >= 3 && SRC[0] == 0xEF && SRC[1] == 0xBB && SRC[2] == 0xBF { s = 3; }
    let first_line = s;
    var i = s;
    while i < SRC.len {
        if SRC[i] == '\n' {
            var e = i;
            if e > s && SRC[e - 1] == '\r' { e--; }
            LN.push(Line { s, e });
            s = i + 1;
        }
        i++;
    }
    // As Swift's sourceLines: the last line is there also when it is empty.
    LN.push(Line { s, SRC.len });
    let nlines = LN.len;
    var body = 0;
    if nlines > 0 && ln_trim(LN[0]) == "---" {
        var j = 1;
        var closed = false;
        while j < nlines {
            let t = trim_all(ln_text(LN[j]));
            if t == "---" || t == "..." { closed = true; break; }
            j++;
        }
        if closed {
            for k in 1..j { parse_front_line(ln_text(LN[k])); }
            FRONT_S0 = first_line;
            FRONT_S1 = LN[j].e;
            body = j + 1;
        } else if nlines > 1 && contains_byte(ln_text(LN[1]), ':') {
            issue(8, LN[0].s, LN[0].e);
        }
    }
    parse_blocks(body, nlines, SC_NONE);
    let body_start = if body < nlines { LN[body].s } else { SRC.len };
    build_frames(body_start);
}

// The plain text of inline events lo..hi: math as LaTeX, markup removed.
fn plain_inline(out: u8[>..]&, lo: i64, hi: i64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        if !e.close {
            let k = e.k;
            if k == I_TEXT || k == I_CODE || k == I_MATH || k == I_HTML || k == I_IMG { out.append(sp_text(e.a)); }
            else if k == I_SOFT { out.push(' '); }
            else if k == I_HARD { out.push('\n'); }
        }
        i++;
    }
}

// The plain text of a block's inline content (heading, paragraph).
fn plain_block(out: u8[>..]&, e: i64) { plain_inline(out, e + 1, EV[e].end - 1); }

fn build_frames(body_start: i64) {
    // Pending frames: kind, heading event, body range, heading range.
    var pk: i64[>..] = [];
    var ph: i64[>..] = [];
    var plo: i64[>..] = [];
    var phi: i64[>..] = [];
    pk.push(F_TITLE);
    ph.push(-1);
    plo.push(0);
    var i = 0;
    while i < EV.len {
        let e = EV[i];
        if e.k == K_HEAD && e.n <= 2 {
            phi.push(i);
            pk.push(if e.n == 1 { F_SECTION } else { F_FRAME });
            ph.push(i);
            plo.push(e.end);
        }
        i = e.end;
    }
    phi.push(EV.len);
    let has_title = has_meta("title") || has_meta("subtitle");
    var section = Span { 0, 0 };
    for k in pk.len {
        let kind = pk[k];
        if kind == F_TITLE && plo[k] == phi[k] && !has_title { continue; }
        var title = Span { 0, 0 };
        let to = S.len;
        if kind == F_TITLE {
            let mt = meta("title");
            if mt.len > 0 { S.append(mt); } else { S.append("Untitled"); }
        } else {
            plain_block(S, ph[k]);
        }
        title = Span { to, S.len - to };
        if kind == F_SECTION { section = title; }
        let hs0 = if kind == F_TITLE { body_start } else { EV[ph[k]].s0 };
        let hs1 = if kind == F_TITLE { body_start } else { EV[ph[k]].s1 };
        var s1 = SRC.len;
        if k + 1 < pk.len { s1 = EV[ph[k + 1]].s0; }
        // The id: a slug of the title, unique in the document.
        let io = S.len;
        slug(S, sp_text(title));
        if S.len == io { format(S, "frame-", FR.len + 1); }
        var id = Span { io, S.len - io };
        var seen = 0;
        for f in FR {
            let t = sp_text(f.id);
            if t == sp_text(id) { seen++; }
            else if t.len > id.n && has_prefix(t, sp_text(id)) && t[id.n] == '-' && is_digit(t[id.n + 1]) {
                let base_len = id.n;
                var only_digits = true;
                for c in t[base_len + 1..] { if !is_digit(c) { only_digits = false; } }
                if only_digits { seen++; }
            }
        }
        if seen > 0 {
            let no = S.len;
            S.append(sp_text(id));
            format(S, "-", seen + 1);
            id = Span { no, S.len - no };
        }
        FR.push(Frame {
            kind: kind,
            head: ph[k],
            lo: plo[k],
            hi: phi[k],
            s0: hs0,
            s1: max(hs1, s1),
            hs0: hs0,
            hs1: hs1,
            id: id,
            title: title,
            section: if kind == F_TITLE { Span { 0, 0 } } else { section },
            scope: if kind == F_TITLE { SC_NONE } else { EV[ph[k]].scope },
        });
    }
}

// The document title: the front matter title, or the first frame title.
fn doc_title() -> u8[:] {
    let t = meta("title");
    if t.len > 0 { return t; }
    for f in FR { if f.kind != F_TITLE { return sp_text(f.title); } }
    return "Untitled";
}

// Collects the raw text of the divisions of one kind in a frame, at any
// depth, separated by blank lines.
fn frame_raw(out: u8[>..]&, f: Frame, kind: i64) {
    let start = out.len;
    var i = f.lo;
    while i < f.hi {
        let e = EV[i];
        if !e.close && e.k == K_DIV && e.n == kind {
            if out.len > start { out.append("\n\n"); }
            out.append(sp_text(e.c));
            i = e.end;
            continue;
        }
        i++;
    }
    let t = trim_all(out[start..]);
    let a = t.len;
    var tmp: u8[>..] = [];
    tmp.append(t);
    out.resize(start);
    out.append(tmp);
    assert(out.len - start == a);
}
