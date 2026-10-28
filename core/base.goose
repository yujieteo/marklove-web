// Shared state and text helpers for the Marklove core.
//
// The core keeps its data in global grow-only arrays. Each call from
// JavaScript starts with `reset` and parses the source again, so no state
// lives between calls except the source itself.

import std;
import math;

extern fn ml_arg(i: i32, out: u8[>..]&);

// A run of bytes in the string arena `S`.
struct Span { o: i64, n: i64 }

// The source text of the current document.
var SRC: u8[>..] = [];
// The string arena: decoded text, joined paragraph lines, and titles.
var S: u8[>..] = [];
// The output of the current call.
var OUT: u8[>..] = [];

// The largest text that the core takes or makes, and the most matches that
// Find and sam keep. A data stack holds 8 MB with no guard page (see io.h).
let MAX_TEXT = 512 * 1024;
let MAX_MATCHES = 100000;

fn sp_text(sp: Span) -> u8[:] { S[sp.o..sp.o + sp.n] }

fn sp_add(t: u8[:]) -> Span {
    let o = S.len;
    S.append(t);
    return Span { o: o, n: t.len };
}

fn sp_empty(sp: Span) -> bool { sp.n == 0 }

// Copies a part of the source into the arena.
fn sp_src(a: i64, b: i64) -> Span {
    let o = S.len;
    for i in a..b { S.push(SRC[i]); }
    return Span { o: o, n: b - a };
}

fn is_digit(c: u8) -> bool { c >= '0' && c <= '9' }
fn is_alpha(c: u8) -> bool { (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') }
fn is_alnum(c: u8) -> bool { is_alpha(c) || is_digit(c) }
fn is_ws(c: u8) -> bool { c == ' ' || c == '\t' || c == '\n' || c == '\r' }
fn lower(c: u8) -> u8 { if c >= 'A' && c <= 'Z' { return c + 32; } return c; }
fn upper(c: u8) -> u8 { if c >= 'a' && c <= 'z' { return c - 32; } return c; }

fn is_ascii_punct(c: u8) -> bool {
    (c >= '!' && c <= '/') || (c >= ':' && c <= '@') || (c >= '[' && c <= '`') || (c >= '{' && c <= '~')
}

fn eq_nocase(a: u8[:], b: u8[:]) -> bool {
    if a.len != b.len { return false; }
    for i in a.len { if lower(a[i]) != lower(b[i]) { return false; } }
    return true;
}

fn has_prefix(s: u8[:], p: u8[:]) -> bool { p.len <= s.len && s[..p.len] == p }
fn has_suffix(s: u8[:], p: u8[:]) -> bool { p.len <= s.len && s[s.len - p.len..] == p }

fn index_of(s: u8[:], p: u8[:], from: i64 = 0) -> i64 {
    if p.len == 0 { return from; }
    var i = from;
    while i + p.len <= s.len {
        if s[i] == p[0] && s[i..i + p.len] == p { return i; }
        i++;
    }
    return -1;
}

fn index_of_byte(s: u8[:], c: u8, from: i64 = 0) -> i64 {
    var i = from;
    while i < s.len { if s[i] == c { return i; } i++; }
    return -1;
}

fn contains_byte(s: u8[:], c: u8) -> bool { index_of_byte(s, c) >= 0 }

// Trims spaces and tabs.
fn trim_sp(s: u8[:]) -> u8[:] {
    var a = 0;
    var b = s.len;
    while a < b && (s[a] == ' ' || s[a] == '\t') { a++; }
    while b > a && (s[b - 1] == ' ' || s[b - 1] == '\t') { b--; }
    return s[a..b];
}

// Trims all white space, new lines too.
fn trim_all(s: u8[:]) -> u8[:] {
    var a = 0;
    var b = s.len;
    while a < b && is_ws(s[a]) { a++; }
    while b > a && is_ws(s[b - 1]) { b--; }
    return s[a..b];
}

fn all_bytes(s: u8[:], c: u8) -> bool {
    for x in s { if x != c { return false; } }
    return true;
}

// The number of characters (code points) in UTF-8 text.
fn char_count(s: u8[:]) -> i64 {
    var n = 0;
    for c in s { if (c & 0xC0) != 0x80 { n++; } }
    return n;
}

// The byte length of the UTF-8 sequence that starts with c.
fn utf8_len(c: u8) -> i64 {
    if c < 0x80 { return 1; }
    if c < 0xE0 { return 2; }
    if c < 0xF0 { return 3; }
    return 4;
}

// The UTF-16 length of UTF-8 text. JavaScript offsets are UTF-16 units.
fn utf16_len(s: u8[:]) -> i64 {
    var n = 0;
    for c in s {
        if (c & 0xC0) != 0x80 { n++; }
        if (c & 0xF8) == 0xF0 { n++; }
    }
    return n;
}

// HTML and XML escapes for text and attribute values.
fn esc(out: u8[>..]&, s: u8[:]) {
    for c in s {
        if c == '&' { out.append("&amp;"); }
        else if c == '<' { out.append("&lt;"); }
        else if c == '>' { out.append("&gt;"); }
        else if c == '"' { out.append("&quot;"); }
        else { out.push(c); }
    }
}

// A JSON string literal.
fn json_str(out: u8[>..]&, s: u8[:]) {
    out.push('"');
    for c in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\r' { out.append("\\r"); }
        else if c == '\t' { out.append("\\t"); }
        else if c < 0x20 { out.append("\\u00"); format_int(out, c, 16, 2, '0'); }
        else { out.push(c); }
    }
    out.push('"');
}

// A number with fixed decimals, for SVG coordinates.
fn fmt_fixed(out: u8[>..]&, v: f64, d: i64) {
    if is_nan(v) || is_inf(v) { out.append("0"); return; }
    format_flt(out, v, d);
}

// Reads a number such as "1.5", "-2", "1e3" or "pi". Returns false when the
// text is not a number.
fn parse_number(s: u8[:]) -> f64, bool {
    let t = trim_sp(s);
    if t.len == 0 { return 0.0, false; }
    if eq_nocase(t, "pi") { return PI, true; }
    if eq_nocase(t, "-pi") { return -PI, true; }
    let v, ok = parse_flt(t);
    return v, ok;
}

// A URL-safe slug: lower-case ASCII letters and digits with dashes.
fn slug(out: u8[>..]&, s: u8[:]) {
    let start = out.len;
    var last_dash = false;
    for c in s {
        if is_alnum(c) { out.push(lower(c)); last_dash = false; }
        else if !last_dash && out.len > start { out.push('-'); last_dash = true; }
    }
    while out.len > start && out[out.len - 1] == '-' { out.pop(); }
    if out.len - start > 60 { out.resize(start + 60); }
}

// Base64, for images and fonts inside exported files.
fn base64(out: u8[>..]&, data: u8[:]) {
    let T = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var i = 0;
    while i + 2 < data.len {
        let v = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8) | data[i + 2];
        out.push(T[(v >> 18) & 63]); out.push(T[(v >> 12) & 63]);
        out.push(T[(v >> 6) & 63]); out.push(T[v & 63]);
        i += 3;
    }
    let r = data.len - i;
    if r == 1 {
        let v = (data[i] as u32) << 16;
        out.push(T[(v >> 18) & 63]); out.push(T[(v >> 12) & 63]); out.append("==");
    } else if r == 2 {
        let v = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8);
        out.push(T[(v >> 18) & 63]); out.push(T[(v >> 12) & 63]); out.push(T[(v >> 6) & 63]); out.push('=');
    }
}

// --- Unicode, as Swift's Character properties ------------------------------

// One code point at byte i: the value and its length in bytes.
fn uni_decode(t: u8[:], i: i64) -> i64, i64 {
    let b = t[i] as i64;
    let n = min(utf8_len(t[i]), t.len - i);
    if n <= 1 { return b, 1; }
    var cp = b & (0x7F >> n);
    for k in 1..n { cp = (cp << 6) | ((t[i + k] as i64) & 0x3F); }
    return cp, n;
}

fn uni_extends(cp: i64) -> bool {
    return (cp >= 0x300 && cp <= 0x36F) || (cp >= 0x1AB0 && cp <= 0x1AFF) || (cp >= 0x1DC0 && cp <= 0x1DFF)
        || (cp >= 0x20D0 && cp <= 0x20FF) || (cp >= 0xFE20 && cp <= 0xFE2F) || (cp >= 0xFE00 && cp <= 0xFE0F)
        || (cp >= 0x1F3FB && cp <= 0x1F3FF) || cp == 0x200D || (cp >= 0xE0020 && cp <= 0xE007F);
}

// Letters and numbers outside ASCII (an approximation of Unicode's tables).
fn uni_alnum(cp: i64) -> bool {
    if cp < 0x80 { return is_alnum(cp as u8); }
    if cp < 0xC0 { return cp == 0xAA || cp == 0xB5 || cp == 0xBA || cp == 0xB2 || cp == 0xB3 || cp == 0xB9 || (cp >= 0xBC && cp <= 0xBE); }
    if cp == 0xD7 || cp == 0xF7 { return false; }
    if cp >= 0x2000 && cp <= 0x2BFF {
        if cp >= 0x2070 && cp <= 0x209F { return cp != 0x207A && cp != 0x207B && cp != 0x207C && cp != 0x207D && cp != 0x207E && (cp < 0x208A || cp > 0x208E); }
        if cp >= 0x2100 && cp <= 0x214F { return uni_in_set("ℂℇℊℋℌℍℎℏℐℑℒℓℕℙℚℛℜℝℤΩℨKÅℬℭℯℰℱℲℳℴℵℶℷℸℹℼℽℾℿⅅⅆⅇⅈⅉⅎ", cp); }
        if cp >= 0x2150 && cp <= 0x218B { return true; }
        if cp >= 0x2460 && cp <= 0x249B { return true; }
        if cp >= 0x24EA && cp <= 0x24FF { return true; }
        if cp >= 0x2776 && cp <= 0x2793 { return true; }
        if cp >= 0x2C00 { return true; }
        return false;
    }
    if cp >= 0x3000 && cp <= 0x303F { return (cp >= 0x3005 && cp <= 0x3007) || (cp >= 0x3021 && cp <= 0x3029) || (cp >= 0x3031 && cp <= 0x3035) || (cp >= 0x3038 && cp <= 0x303C); }
    if cp >= 0xE000 && cp <= 0xF8FF { return false; }
    if cp >= 0xFE10 && cp <= 0xFE6F { return false; }
    if cp >= 0xFF00 && cp <= 0xFF0F { return false; }
    if cp >= 0xFF1A && cp <= 0xFF20 { return false; }
    if cp >= 0xFF3B && cp <= 0xFF40 { return false; }
    if cp >= 0xFF5B && cp <= 0xFF65 { return false; }
    if cp >= 0x1F000 && cp <= 0x1FAFF { return cp >= 0x1F100 && cp <= 0x1F10C; }
    if cp >= 0xFFF0 && cp <= 0xFFFF { return false; }
    return true;
}

fn uni_in_set(set: u8[:], cp: i64) -> bool {
    var i = 0;
    while i < set.len {
        let c, n = uni_decode(set, i);
        if c == cp { return true; }
        i += n;
    }
    return false;
}

fn uni_lower(cp: i64) -> i64 {
    if cp < 0x80 { return lower(cp as u8) as i64; }
    if cp >= 0xC0 && cp <= 0xDE && cp != 0xD7 { return cp + 0x20; }
    if cp >= 0x100 && cp <= 0x137 && cp != 0x130 { return cp | 1; }
    if cp >= 0x139 && cp <= 0x148 { return if (cp & 1) == 1 { cp + 1 } else { cp }; }
    if cp >= 0x14A && cp <= 0x177 { return cp | 1; }
    if cp == 0x178 { return 0xFF; }
    if cp >= 0x179 && cp <= 0x17E { return if (cp & 1) == 1 { cp + 1 } else { cp }; }
    if cp == 0x386 { return 0x3AC; }
    if cp >= 0x388 && cp <= 0x38A { return cp + 37; }
    if cp == 0x38C { return 0x3CC; }
    if cp == 0x38E || cp == 0x38F { return cp + 63; }
    if cp >= 0x391 && cp <= 0x3AB && cp != 0x3A2 { return cp + 0x20; }
    if cp >= 0x400 && cp <= 0x40F { return cp + 0x50; }
    if cp >= 0x410 && cp <= 0x42F { return cp + 0x20; }
    if cp >= 0x460 && cp <= 0x4FF && cp != 0x482 && (cp < 0x483 || cp > 0x489) && cp != 0x4C0 { if cp >= 0x4C1 && cp <= 0x4CE { return if (cp & 1) == 1 { cp + 1 } else { cp }; } return cp | 1; }
    if cp >= 0x531 && cp <= 0x556 { return cp + 0x30; }
    if cp >= 0x1E00 && cp <= 0x1E95 { return cp | 1; }
    if cp >= 0x1EA0 && cp <= 0x1EFF { return cp | 1; }
    if cp >= 0xFF21 && cp <= 0xFF3A { return cp + 0x20; }
    return cp;
}
