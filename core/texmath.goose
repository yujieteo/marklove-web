// LaTeX math to MathML Core, as the app's MathMLConverter does.
//
// The parser writes MathML straight into `MO`. Where MathML puts an element
// around content that the parser has already written (scripts, `\over`),
// it inserts the opening tag at the remembered start. The accepted commands
// are the app's: the SwiftMath list in mathtable.goose.

import base;
import mathtable;

let MT_CMD = 1;
let MT_CHAR = 2;
let MT_OPEN = 3;
let MT_CLOSE = 4;
let MT_SUP = 5;
let MT_SUB = 6;
let MT_AMP = 7;
let MT_ROW = 8;
let MT_PRIME = 9;

// Font styles, as SwiftMath's MTFontStyle.
let FS_NONE = -1;
let FS_DEFAULT = 0;
let FS_ROMAN = 1;
let FS_BOLD = 2;
let FS_CAL = 3;
let FS_TT = 4;
let FS_ITALIC = 5;
let FS_SANS = 6;
let FS_FRAKTUR = 7;
let FS_BB = 8;
let FS_BOLDITALIC = 9;

struct MTok { k: i64, o: i64, n: i64 }

var MSRC: u8[>..] = [];
var MTK: MTok[>..] = [];
var MO: u8[>..] = [];
var MTMP: u8[>..] = [];
var MI = 0;
var MFONT = FS_NONE;
// The unsupported commands of the last conversion, separated by new lines.
var MUNSUP: u8[>..] = [];

fn mt_text(t: MTok) -> u8[:] { MSRC[t.o..t.o + t.n] }

fn sym_find(name: u8[:]) -> i64 {
    var lo = 0;
    var hi = MATH_SYMBOLS.len;
    while lo < hi {
        let mid = (lo + hi) / 2;
        let c = compare(MATH_SYMBOLS[mid].name, name);
        if c == 0 { return mid; }
        if c < 0 { lo = mid + 1; } else { hi = mid; }
    }
    return -1;
}

fn str_find(table: MStr[:], name: u8[:]) -> i64 {
    var lo = 0;
    var hi = table.len;
    while lo < hi {
        let mid = (lo + hi) / 2;
        let c = compare(table[mid].name, name);
        if c == 0 { return mid; }
        if c < 0 { lo = mid + 1; } else { hi = mid; }
    }
    return -1;
}

fn int_find(table: MInt[:], name: u8[:]) -> i64 {
    for e, i in table { if e.name == name { return i; } }
    return -1;
}

fn in_list(list: (const u8[:])[:], name: u8[:]) -> bool {
    for x in list { if x == name { return true; } }
    return false;
}

fn math_command_supported(name: u8[:]) -> bool {
    if name.len == 1 && contains_byte("{}$#%_|,>;!\\&", name[0]) { return true; }
    if sym_find(name) >= 0 || str_find(MATH_ALIASES, name) >= 0 || str_find(MATH_ACCENTS, name) >= 0 { return true; }
    if int_find(MATH_FONTS, name) >= 0 || int_find(MATH_SPACES, name) >= 0 { return true; }
    if in_list(MATH_STYLES, name) || in_list(MATH_STRUCTURAL, name) { return true; }
    for b in ["begin", "end", "left", "right", "limits", "nolimits", "atop", "choose", "brack", "brace",
              "big", "Big", "bigg", "Bigg", "bigl", "Bigl", "biggl", "Biggl",
              "bigr", "Bigr", "biggr", "Biggr", "bigm", "Bigm", "biggm", "Biggm"] {
        if name == b { return true; }
    }
    return str_find(MATH_DELIMITERS, name) >= 0;
}

fn math_tokenize() {
    MTK.clear();
    let s = MSRC;
    var i = 0;
    while i < s.len {
        let c = s[i];
        if c == '\\' {
            if i + 1 >= s.len { i++; continue; }
            let n = s[i + 1];
            if is_alpha(n) {
                var j = i + 1;
                while j < s.len && is_alpha(s[j]) { j++; }
                if j < s.len && s[j] == '*' { j++; }
                if s[i + 1..j] == "cr" { MTK.push(MTok { MT_ROW, i, 0 }); }
                else { MTK.push(MTok { MT_CMD, i + 1, j - i - 1 }); }
                i = j;
            } else if n == '\\' {
                MTK.push(MTok { MT_ROW, i, 0 });
                i += 2;
            } else {
                let l = utf8_len(n);
                MTK.push(MTok { MT_CMD, i + 1, l });
                i += 1 + l;
            }
        } else if c == '{' { MTK.push(MTok { MT_OPEN, i, 1 }); i++; }
        else if c == '}' { MTK.push(MTok { MT_CLOSE, i, 1 }); i++; }
        else if c == '^' { MTK.push(MTok { MT_SUP, i, 1 }); i++; }
        else if c == '_' { MTK.push(MTok { MT_SUB, i, 1 }); i++; }
        else if c == '&' { MTK.push(MTok { MT_AMP, i, 1 }); i++; }
        else if c == '\'' { MTK.push(MTok { MT_PRIME, i, 1 }); i++; }
        else if c == '%' { while i < s.len && s[i] != '\n' { i++; } }
        else if is_ws(c) { i++; }
        else {
            let l = min(utf8_len(c), s.len - i);
            MTK.push(MTok { MT_CHAR, i, l });
            i += l;
        }
    }
}

fn pk() -> i64 { if MI < MTK.len { MTK[MI].k } else { 0 } }
fn pk_cmd(name: u8[:]) -> bool { MI < MTK.len && MTK[MI].k == MT_CMD && mt_text(MTK[MI]) == name }
fn pk_char(c: u8) -> bool { MI < MTK.len && MTK[MI].k == MT_CHAR && MTK[MI].n == 1 && MSRC[MTK[MI].o] == c }

// Inserts text at position p of MO.
fn mo_insert(p: i64, t: u8[:]) {
    let n = MO.len;
    MO.append(t);
    reverse(MO[p..n]);
    reverse(MO[n..]);
    reverse(MO[p..]);
}

fn unsupported(name: u8[:]) {
    if MUNSUP.len > 0 { MUNSUP.push('\n'); }
    MUNSUP.append(name);
}

// One code point of a letter or digit in a math alphabet.
fn math_alpha(out: u8[>..]&, c: u8, style: i64) {
    let up = c >= 'A' && c <= 'Z';
    let lo = c >= 'a' && c <= 'z';
    let dg = c >= '0' && c <= '9';
    if !(up || lo || dg) { out.push(c); return; }
    var ex = 0;
    if style == FS_BB {
        if c == 'C' { ex = 0x2102; } else if c == 'H' { ex = 0x210D; } else if c == 'N' { ex = 0x2115; }
        else if c == 'P' { ex = 0x2119; } else if c == 'Q' { ex = 0x211A; } else if c == 'R' { ex = 0x211D; }
        else if c == 'Z' { ex = 0x2124; }
    } else if style == FS_CAL {
        if c == 'B' { ex = 0x212C; } else if c == 'E' { ex = 0x2130; } else if c == 'F' { ex = 0x2131; }
        else if c == 'H' { ex = 0x210B; } else if c == 'I' { ex = 0x2110; } else if c == 'L' { ex = 0x2112; }
        else if c == 'M' { ex = 0x2133; } else if c == 'R' { ex = 0x211B; } else if c == 'e' { ex = 0x212F; }
        else if c == 'g' { ex = 0x210A; } else if c == 'o' { ex = 0x2134; }
    } else if style == FS_FRAKTUR {
        if c == 'C' { ex = 0x212D; } else if c == 'H' { ex = 0x210C; } else if c == 'I' { ex = 0x2111; }
        else if c == 'R' { ex = 0x211C; } else if c == 'Z' { ex = 0x2128; }
    } else if style == FS_ITALIC && c == 'h' { ex = 0x210E; }
    if ex != 0 { push_utf8(out, ex); return; }
    var base = 0;
    var dbase = 0;
    if style == FS_BOLD { base = 0x1D400; dbase = 0x1D7CE; }
    else if style == FS_ITALIC { base = 0x1D434; }
    else if style == FS_BOLDITALIC { base = 0x1D468; dbase = 0x1D7CE; }
    else if style == FS_CAL { base = 0x1D49C; }
    else if style == FS_FRAKTUR { base = 0x1D504; }
    else if style == FS_BB { base = 0x1D538; dbase = 0x1D7D8; }
    else if style == FS_SANS { base = 0x1D5A0; dbase = 0x1D7E2; }
    else if style == FS_TT { base = 0x1D670; dbase = 0x1D7F6; }
    if dg {
        if dbase == 0 { out.push(c); } else { push_utf8(out, dbase + (c - '0')); }
    } else if base == 0 {
        out.push(c);
    } else if up {
        push_utf8(out, base + (c - 'A'));
    } else {
        push_utf8(out, base + 26 + (c - 'a'));
    }
}

fn math_alpha_text(out: u8[>..]&, t: u8[:], style: i64) {
    for c in t {
        if c < 0x80 && is_alnum(c) { math_alpha(out, c, style); } else { out.push(c); }
    }
}

fn char_atom(t: MTok) {
    let s = mt_text(t);
    let c = s[0];
    if is_digit(c) || c == '.' {
        MO.append("<mn>");
        if MFONT != FS_NONE { math_alpha_text(MO, s, MFONT); } else { MO.append(s); }
        MO.append("</mn>");
        return;
    }
    if is_alpha(c) || c >= 0x80 {
        MO.append("<mi>");
        if MFONT == FS_NONE || MFONT == FS_ITALIC || c >= 0x80 { esc(MO, s); } else { math_alpha_text(MO, s, MFONT); }
        MO.append("</mi>");
        return;
    }
    if c == '-' { MO.append("<mo>−</mo>"); return; }
    if c == '*' { MO.append("<mo>∗</mo>"); return; }
    if c == '~' { MO.append("<mspace width=\"0.333em\"></mspace>"); return; }
    MO.append("<mo>");
    esc(MO, s);
    MO.append("</mo>");
}

fn symbol_atom(i: i64) {
    let s = MATH_SYMBOLS[i];
    let k = s.kind;
    let multi = char_count(s.text) > 1;
    if k == 1 {
        if MFONT != FS_NONE && MFONT != FS_ITALIC { MO.append("<mi>"); math_alpha_text(MO, s.text, MFONT); MO.append("</mi>"); return; }
        MO.append("<mi>"); esc(MO, s.text); MO.append("</mi>");
    } else if k == 2 {
        // Swift's isAlphabetic: letters yes, the ordinary symbols below no.
        let alpha = !multi && s.text.len > 0 && (is_alpha(s.text[0]) || (s.text[0] >= 0xC3 && index_of("□∠⊥⋯⋱∅∃∀∞…∡℧∇∄𝜕′⊤△⋮℘‖", s.text) < 0));
        MO.append(if alpha { "<mi>" } else { "<mi mathvariant=\"normal\">" });
        esc(MO, s.text);
        MO.append("</mi>");
    } else if k == 3 || k == 4 {
        MO.append("<mo>"); esc(MO, s.text); MO.append("</mo>");
    } else if k == 5 || k == 6 {
        MO.append("<mo fence=\"true\" stretchy=\"false\">"); esc(MO, s.text); MO.append("</mo>");
    } else if k == 7 {
        MO.append("<mo separator=\"true\">"); esc(MO, s.text); MO.append("</mo>");
    } else if k == 8 {
        if multi { MO.append("<mi>"); esc(MO, s.text); MO.append("</mi><mo>⁡</mo>"); return; }
        MO.append("<mo largeop=\"true\" movablelimits=\"false\">"); esc(MO, s.text); MO.append("</mo>");
    } else {
        if multi { MO.append("<mo movablelimits=\"true\" form=\"prefix\">"); esc(MO, s.text); MO.append("</mo>"); return; }
        MO.append("<mo largeop=\"true\" movablelimits=\"true\">"); esc(MO, s.text); MO.append("</mo>");
    }
}

fn accent_mark(out: u8[>..]&, comb: u8[:]) {
    var cp = 0;
    each_utf8(comb) { cp = it; };
    var m = cp;
    if cp == 0x0300 { m = 0x60; } else if cp == 0x0301 { m = 0xB4; } else if cp == 0x0302 { m = 0x5E; }
    else if cp == 0x0303 { m = 0x7E; } else if cp == 0x0304 { m = 0xAF; } else if cp == 0x0306 { m = 0x2D8; }
    else if cp == 0x0307 { m = 0x2D9; } else if cp == 0x0308 { m = 0xA8; } else if cp == 0x030C { m = 0x2C7; }
    else if cp == 0x20D7 { m = 0x2192; } else if cp == 0x20D6 { m = 0x2190; } else if cp == 0x20E1 { m = 0x2194; }
    push_utf8(out, m);
}

// Writes a delimiter after \left, \right or \big.
fn delimiter() {
    guard MI < MTK.len else { return; }
    let t = MTK[MI];
    MI++;
    if t.k == MT_CHAR {
        let s = mt_text(t);
        if s == "." { return; }
        esc(MO, s);
        return;
    }
    if t.k == MT_CMD {
        let n = mt_text(t);
        let d = str_find(MATH_DELIMITERS, n);
        if d >= 0 {
            let v = MATH_DELIMITERS[d].text;
            if v == "〈" { MO.append("⟨"); }
            else if v == "〉" { MO.append("⟩"); }
            else { esc(MO, v); }
            return;
        }
        let s = sym_find(n);
        if s >= 0 { esc(MO, MATH_SYMBOLS[s].text); return; }
        MTMP.clear();
        MTMP.push('\\');
        MTMP.append(n);
        unsupported(MTMP);
    }
}

fn big_size(name: u8[:]) -> const u8[:] {
    if name == "big" || name == "bigl" || name == "bigr" || name == "bigm" { return "1.2"; }
    if name == "Big" || name == "Bigl" || name == "Bigr" || name == "Bigm" { return "1.623"; }
    if name == "bigg" || name == "biggl" || name == "biggr" || name == "biggm" { return "2.047"; }
    if name == "Bigg" || name == "Biggl" || name == "Biggr" || name == "Biggm" { return "2.470"; }
    return "";
}

// Reads a `{...}` argument as raw text into MTMP, for \text and friends.
fn raw_argument() {
    MTMP.clear();
    if pk() != MT_OPEN {
        if MI < MTK.len {
            let t = MTK[MI];
            MI++;
            if t.k == MT_CHAR { MTMP.append(mt_text(t)); }
        }
        return;
    }
    MI++;
    var depth = 0;
    while MI < MTK.len {
        let t = MTK[MI];
        MI++;
        if t.k == MT_OPEN { depth++; MTMP.push('{'); }
        else if t.k == MT_CLOSE {
            if depth == 0 { return; }
            depth--;
            MTMP.push('}');
        }
        else if t.k == MT_CHAR { MTMP.append(mt_text(t)); }
        else if t.k == MT_CMD {
            let n = mt_text(t);
            if n.len == 1 && !is_alpha(n[0]) { MTMP.append(n); } else { MTMP.push(' '); }
        }
        else if t.k == MT_SUP { MTMP.push('^'); }
        else if t.k == MT_SUB { MTMP.push('_'); }
        else if t.k == MT_AMP { MTMP.push('&'); }
        else if t.k == MT_ROW { MTMP.push(' '); }
        else if t.k == MT_PRIME { MTMP.push('\''); }
    }
}

fn css_color(out: u8[>..]&, raw: u8[:]) {
    let t = trim_sp(raw);
    var h = t;
    if h.len > 0 && h[0] == '#' { h = h[1..]; }
    var hex = h.len == 6;
    for c in h { if !(is_digit(c) || (lower(c) >= 'a' && lower(c) <= 'f')) { hex = false; } }
    if hex { out.push('#'); out.append(h); return; }
    var alpha = t.len > 0;
    for c in t { if !is_alpha(c) { alpha = false; } }
    if alpha { for c in t { out.push(lower(c)); } return; }
    out.append("inherit");
}

// Atoms until `}`, `\right`, `&`, `\\`, or the end, with infix `\over`.
recursive fn math_sequence(stop_close: bool, stop_right: bool, stop_cell: bool) {
    let start = MO.len;
    var infix = 0;
    while MI < MTK.len {
        let k = MTK[MI].k;
        if stop_close && k == MT_CLOSE { break; }
        if stop_cell && (k == MT_AMP || k == MT_ROW) { break; }
        if stop_right && (pk_cmd("right") || pk_cmd("end")) { break; }
        if infix == 0 && (pk_cmd("over") || pk_cmd("atop") || pk_cmd("choose") || pk_cmd("brack") || pk_cmd("brace")) {
            let n = mt_text(MTK[MI]);
            infix = if n == "over" { 1 } else if n == "atop" { 2 } else if n == "choose" { 3 } else if n == "brack" { 4 } else { 5 };
            MI++;
            MO.append("</mrow><mrow>");
            continue;
        }
        if pk_cmd("end") { break; }
        let before = MI;
        math_atom_scripts();
        if MI == before { MI++; }
    }
    if infix > 0 {
        var open: const u8[:] = "<mfrac><mrow>";
        var close: const u8[:] = "</mrow></mfrac>";
        if infix == 2 { open = "<mfrac linethickness=\"0\"><mrow>"; }
        else if infix == 3 { open = "<mrow><mo>(</mo><mfrac linethickness=\"0\"><mrow>"; close = "</mrow></mfrac><mo>)</mo></mrow>"; }
        else if infix == 4 { open = "<mrow><mo>[</mo><mfrac linethickness=\"0\"><mrow>"; close = "</mrow></mfrac><mo>]</mo></mrow>"; }
        else if infix == 5 { open = "<mrow><mo>{</mo><mfrac linethickness=\"0\"><mrow>"; close = "</mrow></mfrac><mo>}</mo></mrow>"; }
        mo_insert(start, open);
        MO.append(close);
    }
}

// `{...}` or one atom, for a command argument.
recursive fn math_argument() {
    if MI >= MTK.len { MO.append("<mrow></mrow>"); return; }
    if MTK[MI].k == MT_OPEN {
        MI++;
        MO.append("<mrow>");
        math_sequence(true, false, false);
        MO.append("</mrow>");
        if pk() == MT_CLOSE { MI++; }
        return;
    }
    let p = MO.len;
    if !math_atom() || MO.len == p { MO.append("<mrow></mrow>"); }
}

recursive fn math_atom_scripts() {
    let base = MO.len;
    if !math_atom() { return; }
    let movable = index_of(MO[base..], "movablelimits=\"true\"") >= 0;
    var limits = 0;
    var primes = 0;
    var sub0 = -1;
    var sub1 = -1;
    var sup0 = -1;
    var sup1 = -1;
    let scripts = MO.len;
    // The scripts go to MO after the base, then are put in MathML order.
    loop {
        let k = pk();
        if k == MT_SUP {
            MI++;
            sup0 = MO.len;
            math_argument();
            sup1 = MO.len;
        } else if k == MT_SUB {
            MI++;
            sub0 = MO.len;
            math_argument();
            sub1 = MO.len;
        } else if k == MT_PRIME { MI++; primes++; }
        else if pk_cmd("limits") { MI++; limits = 1; }
        else if pk_cmd("nolimits") { MI++; limits = 2; }
        else { break; }
    }
    if sub0 < 0 && sup0 < 0 && primes == 0 { return; }
    // Copy the scripts out, then write them back in order.
    let t0 = MTMP.len;
    if sub0 >= 0 { MTMP.append(MO[sub0..sub1]); }
    let t1 = MTMP.len;
    if primes > 0 {
        if sup0 >= 0 { MTMP.append("<mrow>"); }
        MTMP.append("<mo>");
        for k in primes { MTMP.append("′"); }
        MTMP.append("</mo>");
        if sup0 >= 0 { MTMP.append(MO[sup0..sup1]); MTMP.append("</mrow>"); }
    } else if sup0 >= 0 {
        MTMP.append(MO[sup0..sup1]);
    }
    let t2 = MTMP.len;
    MO.resize(scripts);
    let under = if limits == 1 { true } else if limits == 2 { false } else { movable };
    let has_sub = t1 > t0;
    let has_sup = t2 > t1;
    let tag = if has_sub && has_sup { if under { "munderover" } else { "msubsup" } }
              else if has_sub { if under { "munder" } else { "msub" } }
              else { if under { "mover" } else { "msup" } };
    MO.append(MTMP[t0..t2]);
    MTMP.resize(t0);
    var open: u8[..16] = [];
    open.push('<');
    open.append(tag);
    open.push('>');
    mo_insert(base, open);
    MO.append("</");
    MO.append(tag);
    MO.push('>');
}

// One atom. Returns false at a token that ends a sequence.
recursive fn math_atom() -> bool {
    if MI >= MTK.len { return false; }
    let t = MTK[MI];
    MI++;
    if t.k == MT_OPEN {
        MO.append("<mrow>");
        math_sequence(true, false, false);
        MO.append("</mrow>");
        if pk() == MT_CLOSE { MI++; }
        return true;
    }
    if t.k == MT_CLOSE || t.k == MT_AMP || t.k == MT_ROW { return false; }
    if t.k == MT_SUP || t.k == MT_SUB {
        MO.append(if t.k == MT_SUP { "<msup><mrow></mrow>" } else { "<msub><mrow></mrow>" });
        math_argument();
        MO.append(if t.k == MT_SUP { "</msup>" } else { "</msub>" });
        return true;
    }
    if t.k == MT_PRIME { MO.append("<mo>′</mo>"); return true; }
    if t.k == MT_CHAR { char_atom(t); return true; }
    command_atom(t);
    return true;
}

recursive fn command_atom(t: MTok) {
    // Copies, because the arguments below change the shared buffers.
    var raw: u8[..48] = [];
    for c in mt_text(t) { if raw.len < 48 { raw.push(c); } }
    var name: u8[..48] = [];
    let al = str_find(MATH_ALIASES, raw);
    if al >= 0 { name.append(MATH_ALIASES[al].text); } else { name.append(raw); }

    if name.len == 1 && !is_alpha(name[0]) {
        let c = name[0];
        if c == ',' { MO.append("<mspace width=\"0.1667em\"></mspace>"); }
        else if c == '>' || c == ':' { MO.append("<mspace width=\"0.2222em\"></mspace>"); }
        else if c == ';' { MO.append("<mspace width=\"0.2778em\"></mspace>"); }
        else if c == '!' { MO.append("<mspace width=\"-0.1667em\"></mspace>"); }
        else if c == '|' { MO.append("<mo>‖</mo>"); }
        else if c == '{' { MO.append("<mo>{</mo>"); }
        else if c == '}' { MO.append("<mo>}</mo>"); }
        else if c == '\\' { }
        else { MO.append("<mo>"); esc(MO, name); MO.append("</mo>"); }
        return;
    }
    let si = sym_find(name);
    if si >= 0 { symbol_atom(si); return; }
    let ai = str_find(MATH_ACCENTS, name);
    if ai >= 0 {
        let wide = has_prefix(name, "wide") || has_prefix(name, "over");
        MO.append("<mover accent=\"true\">");
        math_argument();
        MO.append(if wide { "<mo stretchy=\"true\">" } else { "<mo stretchy=\"false\">" });
        accent_mark(MO, MATH_ACCENTS[ai].text);
        MO.append("</mo></mover>");
        return;
    }
    let fi = int_find(MATH_FONTS, name);
    if fi >= 0 {
        let style = MATH_FONTS[fi].v;
        if name == "text" || name == "textrm" || name == "textbf" || name == "textit" || name == "texttt" || name == "textsf" {
            raw_argument();
            let v = if name == "textbf" { FS_BOLD } else if name == "textit" { FS_ITALIC } else if name == "texttt" { FS_TT }
                    else if name == "textsf" { FS_SANS } else { FS_ROMAN };
            MO.append("<mtext>");
            let p = MO.len;
            math_alpha_text(MO, MTMP, v);
            // Escape what was written.
            var tmp: u8[>..] = [];
            tmp.append(MO[p..]);
            MO.resize(p);
            esc(MO, tmp);
            MO.append("</mtext>");
            return;
        }
        let saved = MFONT;
        MFONT = if style == FS_DEFAULT { FS_NONE } else { style };
        math_argument();
        MFONT = saved;
        return;
    }
    let sp = int_find(MATH_SPACES, name);
    if sp >= 0 {
        MO.append("<mspace width=\"");
        fmt_fixed(MO, MATH_SPACES[sp].v / 18.0, 4);
        MO.append("em\"></mspace>");
        return;
    }
    if in_list(MATH_STYLES, name) {
        let display = name == "displaystyle";
        let level = if name == "scriptstyle" { 1 } else if name == "scriptscriptstyle" { 2 } else { 0 };
        format(MO, "<mstyle displaystyle=\"", display, "\" scriptlevel=\"", level, "\">");
        math_sequence(true, true, true);
        MO.append("</mstyle>");
        return;
    }
    let size = big_size(name);
    if size.len > 0 {
        format(MO, "<mo minsize=\"", size, "em\" maxsize=\"", size, "em\" stretchy=\"true\">");
        delimiter();
        MO.append("</mo>");
        return;
    }
    if name == "frac" || name == "dfrac" || name == "tfrac" || name == "cfrac" {
        if name == "dfrac" || name == "cfrac" { MO.append("<mstyle displaystyle=\"true\">"); }
        if name == "tfrac" { MO.append("<mstyle displaystyle=\"false\">"); }
        MO.append("<mfrac>");
        math_argument();
        math_argument();
        MO.append("</mfrac>");
        if name != "frac" { MO.append("</mstyle>"); }
        return;
    }
    if name == "binom" {
        MO.append("<mrow><mo>(</mo><mfrac linethickness=\"0\">");
        math_argument();
        math_argument();
        MO.append("</mfrac><mo>)</mo></mrow>");
        return;
    }
    if name == "sqrt" {
        if pk_char('[') {
            MI++;
            let d0 = MO.len;
            while MI < MTK.len && !pk_char(']') {
                let before = MI;
                math_atom();
                if MI == before { MI++; }
            }
            MI++;
            // The degree goes after the base in MathML.
            let t0 = MTMP.len;
            MTMP.append(MO[d0..]);
            MO.resize(d0);
            MO.append("<mroot>");
            math_argument();
            MO.append("<mrow>");
            MO.append(MTMP[t0..]);
            MTMP.resize(t0);
            MO.append("</mrow></mroot>");
            return;
        }
        MO.append("<msqrt>");
        math_argument();
        MO.append("</msqrt>");
        return;
    }
    if name == "overline" {
        MO.append("<mover accent=\"true\">");
        math_argument();
        MO.append("<mo stretchy=\"true\">‾</mo></mover>");
        return;
    }
    if name == "underline" {
        MO.append("<munder accentunder=\"true\">");
        math_argument();
        MO.append("<mo stretchy=\"true\">_</mo></munder>");
        return;
    }
    if name == "operatorname" || name == "operatorname*" {
        raw_argument();
        MO.append("<mo form=\"prefix\" lspace=\"0\" rspace=\"0.1667em\"");
        if has_suffix(name, "*") { MO.append(" movablelimits=\"true\""); }
        MO.push('>');
        esc(MO, MTMP);
        MO.append("</mo>");
        return;
    }
    if name == "left" {
        MO.append("<mrow><mo fence=\"true\" stretchy=\"true\">");
        delimiter();
        MO.append("</mo>");
        math_sequence(false, true, false);
        MO.append("<mo fence=\"true\" stretchy=\"true\">");
        if pk_cmd("right") { MI++; delimiter(); }
        MO.append("</mo></mrow>");
        return;
    }
    if name == "right" {
        MO.append("<mo fence=\"true\" stretchy=\"true\">");
        delimiter();
        MO.append("</mo>");
        return;
    }
    if name == "color" || name == "textcolor" {
        raw_argument();
        MO.append("<mrow style=\"color:");
        css_color(MO, MTMP);
        MO.append("\">");
        if name == "textcolor" { math_argument(); } else { math_sequence(true, true, true); }
        MO.append("</mrow>");
        return;
    }
    if name == "colorbox" {
        raw_argument();
        MO.append("<mrow style=\"background:");
        css_color(MO, MTMP);
        MO.append("\">");
        math_argument();
        MO.append("</mrow>");
        return;
    }
    if name == "not" {
        let p = MO.len;
        if !math_atom() { MO.append("<mo>¬</mo>"); return; }
        if MO[p..] == "<mo>=</mo>" { MO.resize(p); MO.append("<mo>≠</mo>"); return; }
        let t0 = MTMP.len;
        format_replaced(MTMP, MO[p..], "</mo>", "̸</mo>");
        MO.resize(p);
        MO.append(MTMP[t0..]);
        MTMP.resize(t0);
        return;
    }
    if name == "pmod" {
        MO.append("<mrow><mspace width=\"1em\"></mspace><mo>(</mo><mo>mod</mo><mspace width=\"0.333em\"></mspace>");
        math_argument();
        MO.append("<mo>)</mo></mrow>");
        return;
    }
    if name == "bra" { MO.append("<mrow><mo>⟨</mo>"); math_argument(); MO.append("<mo>|</mo></mrow>"); return; }
    if name == "ket" { MO.append("<mrow><mo>|</mo>"); math_argument(); MO.append("<mo>⟩</mo></mrow>"); return; }
    if name == "braket" { MO.append("<mrow><mo>⟨</mo>"); math_argument(); MO.append("<mo>⟩</mo></mrow>"); return; }
    if name == "substack" {
        if pk() != MT_OPEN { return; }
        MI++;
        MO.append("<mtable rowspacing=\"0.1em\">");
        math_rows(true, 0);
        MO.append("</mtable>");
        return;
    }
    if name == "begin" {
        raw_argument();
        var env: u8[..32] = [];
        for c in MTMP { if env.len < 32 { env.push(c); } }
        math_environment(env);
        return;
    }
    if name == "end" { raw_argument(); return; }
    MTMP.clear();
    MTMP.push('\\');
    MTMP.append(raw);
    unsupported(MTMP);
    MO.append("<merror><mtext>\\");
    esc(MO, raw);
    MO.append("</mtext></merror>");
}

// Column alignments: 0 center, 1 left, 2 right/left pairs, 3 eqnarray.
fn cell_align(mode: i64, k: i64) -> const u8[:] {
    if mode == 1 { return "left"; }
    if mode == 2 { return if k % 2 == 0 { "right" } else { "left" }; }
    if mode == 3 { return if k % 3 == 0 { "right" } else if k % 3 == 1 { "center" } else { "left" }; }
    return "center";
}

// Rows and cells until `\end` or `}`. With mode < 0, cells are plain mtd.
recursive fn math_rows(end_close: bool, mode: i64) {
    var row_start = MO.len;
    var cells = 0;
    var cell_start = 0;
    fn open_cell() {
        if cells == 0 { row_start = MO.len; MO.append("<mtr>"); }
        if end_close { MO.append("<mtd>"); }
        else { MO.append("<mtd style=\"text-align:"); MO.append(cell_align(mode, cells)); MO.append("\">"); }
        cell_start = MO.len;
        cells++;
    }
    var last_empty = false;
    var rows = 0;
    loop {
        open_cell();
        math_sequence(end_close, true, true);
        last_empty = cells == 1 && MO.len == cell_start;
        MO.append("</mtd>");
        if MI >= MTK.len { break; }
        let k = MTK[MI].k;
        if k == MT_AMP { MI++; continue; }
        if k == MT_ROW { MI++; MO.append("</mtr>"); rows++; cells = 0; continue; }
        if k == MT_CLOSE {
            MI++;
            if end_close { break; }
            continue;
        }
        if pk_cmd("end") { MI++; raw_argument(); break; }
        break;
    }
    if rows > 0 && last_empty { MO.resize(row_start); } else { MO.append("</mtr>"); }
}

fn fence_text(fence: i64, open: bool) -> const u8[:] {
    if fence == 1 { return if open { "(" } else { ")" }; }
    if fence == 2 { return if open { "[" } else { "]" }; }
    if fence == 3 || fence == 6 { return if open { "{" } else { "}" }; }
    if fence == 4 { return "|"; }
    return "‖";
}

recursive fn math_environment(env: u8[:]) {
    if !in_list(MATH_ENVIRONMENTS, env) {
        MTMP.clear();
        MTMP.append("\\begin{");
        MTMP.append(env);
        MTMP.push('}');
        unsupported(MTMP);
        let p = MO.len;
        math_rows(false, 0);
        MO.resize(p);
        MO.append("<merror><mtext>\\begin{");
        esc(MO, env);
        MO.append("}</mtext></merror>");
        return;
    }
    var mode = 0;
    var fence = 0;
    if env == "pmatrix" { fence = 1; }
    else if env == "bmatrix" { fence = 2; }
    else if env == "Bmatrix" { fence = 3; }
    else if env == "vmatrix" { fence = 4; }
    else if env == "Vmatrix" { fence = 5; }
    else if env == "cases" { fence = 6; mode = 1; }
    else if env == "aligned" || env == "split" || env == "eqalign" { mode = 2; }
    else if env == "eqnarray" { mode = 3; }
    if fence > 0 { MO.append("<mrow><mo>"); MO.append(fence_text(fence, true)); MO.append("</mo>"); }
    MO.append(if fence == 6 { "<mtable columnspacing=\"1em\" rowspacing=\"0.3em\">" } else { "<mtable columnspacing=\"1em\" rowspacing=\"0.5em\">" });
    math_rows(false, mode);
    MO.append("</mtable>");
    if fence > 0 && fence < 6 { MO.append("<mo>"); MO.append(fence_text(fence, false)); MO.append("</mo>"); }
    if fence > 0 { MO.append("</mrow>"); }
}

// True when the braces of the LaTeX do not balance.
fn unbalanced_brace(t: u8[:]) -> bool {
    var depth = 0;
    var i = 0;
    while i < t.len {
        let c = t[i];
        if c == '\\' { i += 2; continue; }
        if c == '{' { depth++; }
        if c == '}' { depth--; if depth < 0 { return true; } }
        i++;
    }
    return depth != 0;
}

// Converts LaTeX to MathML at the end of out. Returns false (and writes the
// LaTeX as code) when the math has an unsupported command.
fn math_html(out: u8[>..]&, latex: u8[:], display: bool) -> bool {
    MSRC.clear();
    MSRC.append(latex);
    MUNSUP.clear();
    MTMP.clear();
    MO.clear();
    MFONT = FS_NONE;
    math_tokenize();
    MI = 0;
    while MI < MTK.len {
        if pk() == MT_CLOSE { MI++; continue; }
        math_sequence(true, false, false);
        if MI < MTK.len { MI++; }
    }
    if MUNSUP.len > 0 || unbalanced_brace(latex) {
        out.append("<code class=\"tex-fallback\" title=\"This math command is not supported.\">");
        if display { out.append("$$"); } else { out.push('$'); }
        esc(out, latex);
        if display { out.append("$$"); } else { out.push('$'); }
        out.append("</code>");
        return false;
    }
    out.append(if display { "<math display=\"block\">" } else { "<math>" });
    out.append("<semantics><mrow>");
    out.append(MO);
    out.append("</mrow><annotation encoding=\"application/x-tex\">");
    esc(out, latex);
    out.append("</annotation></semantics></math>");
    return true;
}

// The unsupported commands in LaTeX, for the source checks.
fn math_check(latex: u8[:]) -> u8[:] {
    var tmp: u8[>..] = [];
    math_html(tmp, latex, false);
    return MUNSUP;
}
