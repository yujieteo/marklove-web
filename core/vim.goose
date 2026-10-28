// The Marklove Vim mode, ported from MarkloveCore Vim/VimEngine.swift,
// Vim/VimBuffer.swift and Text/VimRegex.swift.
//
// Public functions:
//   vim_reset()
//       Normal mode, no pending keys, and an empty undo history. Call it when
//       Vim mode is turned on and when another document is opened.
//   vim_clipboard(text: u8[:])
//       The system clipboard text, for the "+ and "* registers (p and P).
//   vim_key(out: u8[>..]&, text: u8[:], cursor: i64, sel_start: i64, sel_end: i64, key: u8[:])
//       Handles one key. Offsets are UTF-8 byte offsets. `cursor` is not used:
//       the engine reads the cursor from the selection, as the Swift engine does.
//       Appends one JSON object to out:
//       {"handled":bool,"text":string|null,"cursor":n,"sel":[a,b],
//        "mode":"normal|insert|visual|visual-line|command","status":string,
//        "action":""|"save"|"discard"|"copy"[,"clip":string]}
//       handled=false: the textarea must do its default action (typed text in
//       Insert mode, and Ctrl keys that Vim does not use). text=null: no change.
//       status: the command line (with its ":", "/" or "?") or a message.
//       action save is :w, discard is :q! and :e! (go back to the saved
//       version), copy puts clip on the system clipboard ("+y).
//   vim_find(out, text, pattern, ignore_case)
//   vim_replace(out, text, pattern, ignore_case, replacement, sel_s, sel_e, all)
//       Find and Replace with Vim patterns. The output is as edit_find and
//       edit_replace.
//
// Key names: one character as UTF-8, "Escape", "Enter", "Backspace", "Tab",
// "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", and "Ctrl-x" for a
// Control key (Ctrl-[ is Escape).
//
// The engine keeps its own undo history (u and Ctrl-r), because the text
// view gets its new text as one value. A change that the engine did not make
// (Insert mode typing, a toolbar command) becomes one undo step at the next key
// outside Insert mode.
//
// Text positions in the engine are code point indexes (Swift uses Characters).

import base;

// ---------------------------------------------------------------------------
// Characters (code points)

fn vch_ws(c: i64) -> bool {
    c == 32 || (c >= 9 && c <= 13) || c == 0x85 || c == 0xA0 || c == 0x1680 || (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000
}

fn vch_digit(c: i64) -> bool { c >= '0' && c <= '9' }

fn vch_punct_hi(c: i64) -> bool {
    (c >= 0xA1 && c <= 0xBF && !(c == 0xAA || c == 0xB2 || c == 0xB3 || c == 0xB5 || c == 0xB9 || c == 0xBA || (c >= 0xBC && c <= 0xBE))) ||
    c == 0xD7 || c == 0xF7 || (c >= 0x2010 && c <= 0x2027) || (c >= 0x2030 && c <= 0x205E) ||
    (c >= 0x2190 && c <= 0x2BFF) || (c >= 0x3001 && c <= 0x3003) || (c >= 0x3008 && c <= 0x3011) ||
    (c >= 0xFF01 && c <= 0xFF0F) || (c >= 0x1F000 && c <= 0x1FAFF)
}

fn vch_letter(c: i64) -> bool {
    if c < 0x80 { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
    return !vch_ws(c) && !vch_punct_hi(c);
}

// Letter, number or "_": the Vim word characters and ICU \w.
fn vch_word(c: i64) -> bool { vch_letter(c) || vch_digit(c) || c == '_' }

fn vch_lower(c: i64) -> i64 {
    if c < 0x80 { if c >= 'A' && c <= 'Z' { return c + 32; } return c; }
    if c >= 0xC0 && c <= 0xDE && c != 0xD7 { return c + 32; }
    if (c >= 0x100 && c <= 0x12E) || (c >= 0x132 && c <= 0x136) || (c >= 0x14A && c <= 0x176) { if c % 2 == 0 { return c + 1; } return c; }
    if (c >= 0x139 && c <= 0x147) || (c >= 0x179 && c <= 0x17D) { if c % 2 == 1 { return c + 1; } return c; }
    if c == 0x178 { return 0xFF; }
    if c >= 0x391 && c <= 0x3A9 && c != 0x3A2 { return c + 32; }
    if c >= 0x410 && c <= 0x42F { return c + 32; }
    if c >= 0x400 && c <= 0x40F { return c + 80; }
    return c;
}

fn vch_upper(c: i64) -> i64 {
    if c < 0x80 { if c >= 'a' && c <= 'z' { return c - 32; } return c; }
    if c >= 0xE0 && c <= 0xFE && c != 0xF7 { return c - 32; }
    if c == 0xFF { return 0x178; }
    if (c >= 0x101 && c <= 0x12F) || (c >= 0x133 && c <= 0x137) || (c >= 0x14B && c <= 0x177) { if c % 2 == 1 { return c - 1; } return c; }
    if (c >= 0x13A && c <= 0x148) || (c >= 0x17A && c <= 0x17E) { if c % 2 == 0 { return c - 1; } return c; }
    if c >= 0x3B1 && c <= 0x3C9 && c != 0x3C2 { return c - 32; }
    if c >= 0x430 && c <= 0x44F { return c - 32; }
    if c >= 0x450 && c <= 0x45F { return c - 80; }
    return c;
}

// Swift: s == s.uppercased() ? s.lowercased() : s.uppercased()
fn vch_toggle(c: i64) -> i64 { if vch_upper(c) == c { return vch_lower(c); } return vch_upper(c); }

fn vm_put_cp(out: u8[>..]&, c: i64) {
    if c < 0x80 { out.push(c as u8); }
    else if c < 0x800 { out.push((0xC0 | (c >> 6)) as u8); out.push((0x80 | (c & 63)) as u8); }
    else if c < 0x10000 { out.push((0xE0 | (c >> 12)) as u8); out.push((0x80 | ((c >> 6) & 63)) as u8); out.push((0x80 | (c & 63)) as u8); }
    else {
        out.push((0xF0 | (c >> 18)) as u8); out.push((0x80 | ((c >> 12) & 63)) as u8);
        out.push((0x80 | ((c >> 6) & 63)) as u8); out.push((0x80 | (c & 63)) as u8);
    }
}

// The code point at byte i of s, and its byte length.
fn vm_cp_at(s: u8[:], i: i64) -> i64, i64 {
    let c = s[i] as i64;
    var len = utf8_len(s[i]);
    if i + len > s.len { len = 1; }
    if len == 1 { return c, 1; }
    var v = 0;
    if len == 2 { v = c & 0x1F; } else if len == 3 { v = c & 0x0F; } else { v = c & 0x07; }
    for j in 1..len { v = (v << 6) | ((s[i + j] as i64) & 63); }
    return v, len;
}

fn vm_decode(out: i64[>..]&, s: u8[:]) {
    var i = 0;
    while i < s.len { let c, l = vm_cp_at(s, i); out.push(c); i += l; }
}

// ---------------------------------------------------------------------------
// The buffer: the text as code points, as VimBuffer.

var VTXT: u8[>..] = [];
var VCH: i64[>..] = [];
// The byte offset of each code point, plus one entry for the end.
var VOFF: i64[>..] = [];

fn vb_load() {
    VCH.clear();
    VOFF.clear();
    var i = 0;
    while i < VTXT.len {
        let c, l = vm_cp_at(VTXT, i);
        VCH.push(c);
        VOFF.push(i);
        i += l;
    }
    VOFF.push(VTXT.len);
}

// The code point index at a byte offset.
fn vb_char_at(byte: i64) -> i64 {
    var lo = 0;
    var hi = VCH.len;
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        if VOFF[mid] <= byte { lo = mid; } else { hi = mid - 1; }
    }
    return lo;
}

fn vb_str(out: u8[>..]&, lo: i64, hi: i64) {
    let a = max(0, min(lo, VCH.len));
    let b = max(a, min(hi, VCH.len));
    out.append(VTXT[VOFF[a]..VOFF[b]]);
}

fn vb_ls(i: i64) -> i64 {
    var k = min(i, VCH.len);
    while k > 0 && VCH[k - 1] != '\n' { k--; }
    return k;
}

fn vb_le(i: i64) -> i64 {
    var k = max(0, min(i, VCH.len));
    while k < VCH.len && VCH[k] != '\n' { k++; }
    return k;
}

fn vb_leb(i: i64) -> i64 {
    let e = vb_le(i);
    if e < VCH.len { return e + 1; }
    return e;
}

fn vb_is_le(i: i64) -> bool { i >= VCH.len || VCH[i] == '\n' }

fn vb_col(i: i64) -> i64 { i - vb_ls(i) }

fn vb_line_count() -> i64 {
    var breaks = 0;
    for c in VCH { if c == '\n' { breaks++; } }
    var last = 0;
    if VCH.len > 0 && VCH[VCH.len - 1] == '\n' { last = 1; }
    return max(1, breaks + 1 - last);
}

fn vb_line_no(i: i64) -> i64 {
    var n = 0;
    for k in min(i, VCH.len) { if VCH[k] == '\n' { n++; } }
    return n;
}

fn vb_line_start_of(n: i64) -> i64 {
    if n <= 0 { return 0; }
    var line = 0;
    for k in VCH.len {
        if VCH[k] == '\n' {
            line++;
            if line == n { return k + 1; }
        }
    }
    return vb_ls(VCH.len);
}

fn vb_fnb(s: i64) -> i64 {
    var k = s;
    while k < VCH.len && (VCH[k] == ' ' || VCH[k] == '\t') { k++; }
    return k;
}

fn vb_indent(out: u8[>..]&, i: i64) {
    let s = vb_ls(i);
    vb_str(out, s, vb_fnb(s));
}

// In Normal mode the cursor sits on a character, not after the last one.
fn vb_clamp(i0: i64) -> i64 {
    let i = max(0, min(i0, VCH.len));
    let s = vb_ls(i);
    let e = vb_le(i);
    if e > s && i >= e { return e - 1; }
    return i;
}

// desired < 0: keep the column of i.
fn vb_move_lines(i: i64, delta: i64, desired: i64) -> i64 {
    var col = desired;
    if col < 0 { col = vb_col(i); }
    let line = max(0, min(vb_line_count() - 1, vb_line_no(i) + delta));
    let s = vb_line_start_of(line);
    let e = vb_le(s);
    var last = e - 1;
    if last < s { last = s; }
    return min(s + col, max(s, last));
}

let CC_SPACE = 0;
let CC_WORD = 1;
let CC_PUNCT = 2;
let CC_NL = 3;

fn vb_cls(c: i64, big: bool) -> i64 {
    if c == '\n' { return CC_NL; }
    if vch_ws(c) { return CC_SPACE; }
    if big { return CC_WORD; }
    if vch_word(c) { return CC_WORD; }
    return CC_PUNCT;
}

fn vb_next_word(i: i64, big: bool) -> i64 {
    let n = VCH.len;
    if i >= n { return n; }
    var k = i;
    let start = vb_cls(VCH[k], big);
    if start != CC_SPACE && start != CC_NL {
        while k < n && vb_cls(VCH[k], big) == start { k++; }
    }
    // Skip white space, but stop at an empty line.
    while k < n {
        let c = vb_cls(VCH[k], big);
        if c == CC_NL {
            if k + 1 < n && VCH[k + 1] == '\n' { return k + 1; }
            k++;
            continue;
        }
        if c == CC_SPACE { k++; continue; }
        break;
    }
    return k;
}

fn vb_prev_word(i: i64, big: bool) -> i64 {
    var k = i - 1;
    while k > 0 && (vb_cls(VCH[k], big) == CC_SPACE || (VCH[k] == '\n' && !(k > 0 && VCH[k - 1] == '\n'))) { k--; }
    if k <= 0 { return 0; }
    let cls = vb_cls(VCH[k], big);
    if cls == CC_NL { return k; }
    while k > 0 && vb_cls(VCH[k - 1], big) == cls { k--; }
    return k;
}

fn vb_word_end(i: i64, big: bool) -> i64 {
    let n = VCH.len;
    var k = i + 1;
    while k < n && (VCH[k] == '\n' || vch_ws(VCH[k])) { k++; }
    if k >= n { return max(0, n - 1); }
    let cls = vb_cls(VCH[k], big);
    while k + 1 < n && vb_cls(VCH[k + 1], big) == cls { k++; }
    return k;
}

fn vb_is_blank_line(s: i64) -> bool {
    let e = vb_le(s);
    for k in s..e { if VCH[k] != ' ' && VCH[k] != '\t' { return false; } }
    return true;
}

fn vb_next_para(i: i64) -> i64 {
    let n = VCH.len;
    var k = vb_leb(i);
    while k < n && vb_is_blank_line(k) { k = vb_leb(k); }
    while k < n && !vb_is_blank_line(k) { k = vb_leb(k); }
    return min(k, n);
}

fn vb_prev_para(i: i64) -> i64 {
    var k = vb_ls(i);
    if k <= 0 { return 0; }
    k = vb_ls(k - 1);
    while k > 0 && vb_is_blank_line(k) { k = vb_ls(k - 1); }
    while k > 0 && !vb_is_blank_line(k) { k = vb_ls(k - 1); }
    return k;
}

fn vb_end_mark(c: i64) -> bool { c == '.' || c == '!' || c == '?' }
fn vb_white(c: i64) -> bool { c == '\n' || vch_ws(c) }

fn vb_next_sentence(i: i64) -> i64 {
    let n = VCH.len;
    var k = i;
    while k < n {
        if vb_end_mark(VCH[k]) && k + 1 < n && vb_white(VCH[k + 1]) {
            var j = k + 1;
            while j < n && vb_white(VCH[j]) { j++; }
            return j;
        }
        if VCH[k] == '\n' && k + 1 < n && VCH[k + 1] == '\n' { return k + 1; }
        k++;
    }
    return n;
}

fn vb_prev_sentence(i: i64) -> i64 {
    let n = VCH.len;
    var k = max(0, i - 2);
    while k > 0 {
        if k < n && vb_end_mark(VCH[k - 1]) && vb_white(VCH[k]) {
            var j = k;
            while j < n && vb_white(VCH[j]) { j++; }
            if j < i { return j; }
        }
        k--;
    }
    return 0;
}

// f F t T. Returns the target and true, or false when there is none.
fn vb_find(cmd: i64, target: i64, i: i64, n: i64, repeating: bool) -> i64, bool {
    let s = vb_ls(i);
    let e = vb_le(i);
    var k = i;
    for _ in n {
        if cmd == 'f' || cmd == 't' {
            var j = k + 1;
            if cmd == 't' && repeating && j < e && VCH[j] == target { j++; }
            while j < e && VCH[j] != target { j++; }
            if j >= e { return 0, false; }
            k = j;
        } else {
            var j = k - 1;
            if cmd == 'T' && repeating && j >= s && VCH[j] == target { j--; }
            while j >= s && VCH[j] != target { j--; }
            if j < s { return 0, false; }
            k = j;
        }
    }
    if cmd == 't' { return k - 1, true; }
    if cmd == 'T' { return k + 1, true; }
    return k, true;
}

fn vb_pair(c: i64) -> i64, bool {
    if c == '(' { return ')', true; }
    if c == '[' { return ']', true; }
    if c == '{' { return '}', true; }
    if c == ')' { return '(', false; }
    if c == ']' { return '[', false; }
    if c == '}' { return '{', false; }
    return 0, false;
}

fn vb_is_bracket(c: i64) -> bool { c == '(' || c == ')' || c == '[' || c == ']' || c == '{' || c == '}' }

fn vb_matching_bracket(i: i64) -> i64, bool {
    let n = VCH.len;
    var k = i;
    let e = vb_le(i);
    while k < e && !vb_is_bracket(VCH[k]) { k++; }
    if k >= n || !vb_is_bracket(VCH[k]) { return 0, false; }
    let open = VCH[k];
    let other, forward = vb_pair(open);
    var depth = 0;
    var j = k;
    while j >= 0 && j < n {
        if VCH[j] == open { depth++; }
        if VCH[j] == other { depth--; if depth == 0 { return j, true; } }
        if forward { j++; } else { j--; }
    }
    return 0, false;
}

var VTO_LO = 0;
var VTO_HI = 0;
var VTO_LW = false;

fn vb_text_object(c: i64, around: bool, i: i64) -> bool {
    let n = VCH.len;
    VTO_LW = false;
    if c == 'w' || c == 'W' {
        if i >= n { return false; }
        let big = c == 'W';
        let cls = vb_cls(VCH[i], big);
        let ls = vb_ls(i);
        let le = vb_le(i);
        var s = i;
        var e = i;
        while s > ls && vb_cls(VCH[s - 1], big) == cls { s--; }
        while e < le && vb_cls(VCH[e], big) == cls { e++; }
        if around {
            var e2 = e;
            while e2 < le && (VCH[e2] == ' ' || VCH[e2] == '\t') { e2++; }
            if e2 > e { e = e2; } else {
                while s > ls && (VCH[s - 1] == ' ' || VCH[s - 1] == '\t') { s--; }
            }
        }
        VTO_LO = s; VTO_HI = e;
        return true;
    }
    if c == '"' || c == '\'' || c == '`' || c == '$' {
        let s = vb_ls(i);
        let e = vb_le(i);
        var pos: i64[>..] = [];
        var k = s;
        while k < e {
            if VCH[k] == '\\' { k += 2; continue; }
            if VCH[k] == c { pos.push(k); }
            k++;
        }
        var a = -1;
        var b = -1;
        var p = 0;
        while p + 1 < pos.len {
            if pos[p] <= i && i <= pos[p + 1] { a = pos[p]; b = pos[p + 1]; break; }
            p += 2;
        }
        if a < 0 {
            p = 0;
            while p < pos.len - 1 {
                if pos[p] > i { a = pos[p]; b = pos[p + 1]; break; }
                p += 2;
            }
        }
        if a < 0 { return false; }
        if around { VTO_LO = a; VTO_HI = b + 1; } else { VTO_LO = a + 1; VTO_HI = b; }
        return true;
    }
    if c == '(' || c == ')' || c == 'b' || c == '[' || c == ']' || c == '{' || c == '}' || c == 'B' || c == '<' || c == '>' {
        var open = '{';
        var close = '}';
        if c == '(' || c == ')' || c == 'b' { open = '('; close = ')'; }
        else if c == '[' || c == ']' { open = '['; close = ']'; }
        else if c == '<' || c == '>' { open = '<'; close = '>'; }
        var depth = 0;
        var a = i;
        var found = false;
        while a >= 0 {
            if a < n {
                if VCH[a] == close && a != i { depth++; }
                if VCH[a] == open {
                    if depth == 0 { found = true; break; }
                    depth--;
                }
            }
            a--;
        }
        if !found { return false; }
        depth = 0;
        var b = a + 1;
        while b < n {
            if VCH[b] == open { depth++; }
            if VCH[b] == close {
                if depth == 0 { break; }
                depth--;
            }
            b++;
        }
        if b >= n { return false; }
        if around { VTO_LO = a; VTO_HI = b + 1; } else { VTO_LO = a + 1; VTO_HI = b; }
        return true;
    }
    if c == 'p' {
        var s = vb_ls(i);
        if vb_is_blank_line(s) { return false; }
        while s > 0 && !vb_is_blank_line(vb_ls(s - 1)) { s = vb_ls(s - 1); }
        var e = vb_leb(i);
        while e < n && !vb_is_blank_line(e) { e = vb_leb(e); }
        if around { while e < n && vb_is_blank_line(e) { e = vb_leb(e); } }
        VTO_LO = s; VTO_HI = e; VTO_LW = true;
        return true;
    }
    return false;
}

// The word under i: start and end, or false.
fn vb_word_under(i: i64) -> i64, i64, bool {
    if i >= VCH.len || vb_cls(VCH[i], false) != CC_WORD { return 0, 0, false; }
    var s = i;
    var e = i;
    while s > 0 && vb_cls(VCH[s - 1], false) == CC_WORD { s--; }
    while e < VCH.len && vb_cls(VCH[e], false) == CC_WORD { e++; }
    return s, e, true;
}

// Escapes the characters that are special in a magic Vim pattern.
fn vb_escape_vim(out: u8[>..]&, t: u8[:]) {
    for c in t {
        if c == '\\' || c == '.' || c == '*' || c == '[' || c == ']' || c == '~' || c == '^' || c == '$' || c == '/' { out.push('\\'); }
        out.push(c);
    }
}

// The next match from i: the search continues at the other end of the text.
// Status: 0 no match, 1 found, 2 error (the message is in VRE_ERR).
fn vb_search(pat: u8[:], from: i64, fwd: bool) -> i64, i64 {
    if !vre_compile(pat, -1, true) { return 0, 2; }
    vre_budget();
    let n = VCH.len;
    var first = -1;
    var last = -1;
    var before = -1;
    var pos = 0;
    while pos <= n {
        if !vre_find(0, n, pos) { break; }
        let s = VRM_S;
        if first < 0 { first = s; }
        last = s;
        if fwd && s > from { return s, 1; }
        if s < from { before = s; }
        pos = vre_next_pos();
    }
    if VRE_OVER { vre_too_complex(); return 0, 2; }
    if first < 0 { return 0, 0; }
    if fwd { return first, 1; }
    if before >= 0 { return before, 1; }
    return last, 1;
}

// ---------------------------------------------------------------------------
// Vim regular expressions, as VimRegex: the Vim syntax is parsed to a tree,
// compiled to a program, and run by a backtracking matcher on VCH.

let RK_CHAR = 1;
let RK_ANY = 2;
let RK_ANYNL = 3;
let RK_SET = 4;
let RK_CAT = 5;
let RK_ALT = 6;
let RK_GROUP = 7;
let RK_REP = 8;
let RK_BOL = 9;
let RK_EOL = 10;
let RK_BOT = 11;
let RK_EOT = 12;
let RK_WS = 13;
let RK_WE = 14;
let RK_BREF = 15;
let RK_ZS = 16;
let RK_ZE = 17;
let OP_SPLIT = 20;
let OP_JMP = 21;
let OP_SAVE = 22;
let OP_CHECK = 23;
let OP_MATCH = 24;

// Slots: 2k and 2k+1 for group k (1 to 9), 20 and 21 for \zs and \ze, then
// the loop marks that stop a loop on an empty match.
let VRE_SLOTS = 64;
let VRE_FIRST_MARK = 22;
let VRE_LIMIT = 20000000;

struct VRNode { k: i64, x: i64, y: i64, g: i64, c: i64, nx: i64 }
struct VRInst { op: i64, x: i64, y: i64 }
struct VRSet { neg: bool, o: i64, n: i64 }
// k 0: the range lo..hi. k 1: the class lo ('d', 's', 'w' or a POSIX code).
struct VRItem { k: i64, lo: i64, hi: i64, neg: bool }
struct VRFrame { ib: i64, ab: i64, grp: i64 }
struct VRBt { pc: i64, sp: i64, slot: i64, old: i64 }

var VRN: VRNode[>..] = [];
var VRP: VRInst[>..] = [];
var VRS: VRSet[>..] = [];
var VRI: VRItem[>..] = [];
var VRITEMS: i64[>..] = [];
var VRALTS: i64[>..] = [];
var VRFR: VRFrame[>..] = [];
var VRJ: i64[>..] = [];
var VRBT: VRBt[>..] = [];
var VRSL: i64[64] = [-1; 64];
var VRE_ERR: u8[>..] = [];
var VRE_ICASE = false;
var VRE_MARKS = 0;
var VRE_STEPS = 0;
var VRE_OVER = false;
// The last match: the match range (\zs and \ze) and the whole match.
var VRM_S = 0;
var VRM_E = 0;
var VRM_WS = 0;
var VRM_WE = 0;

fn vre_add(k: i64, x: i64, y: i64) -> i64 {
    VRN.push(VRNode { k: k, x: x, y: y, g: 1, c: -1, nx: -1 });
    return VRN.len - 1;
}

fn vre_set_begin(neg: bool) -> i64 {
    VRS.push(VRSet { neg: neg, o: VRI.len, n: 0 });
    return VRS.len - 1;
}

fn vre_set_range(s: i64, lo: i64, hi: i64) {
    VRI.push(VRItem { k: 0, lo: lo, hi: hi, neg: false });
    VRS[s].n = VRI.len - VRS[s].o;
}

fn vre_set_class(s: i64, cls: i64, neg: bool) {
    VRI.push(VRItem { k: 1, lo: cls, hi: 0, neg: neg });
    VRS[s].n = VRI.len - VRS[s].o;
}

fn vre_class_has(cls: i64, c: i64) -> bool {
    if cls == 'd' { return vch_digit(c); }
    if cls == 's' { return vch_ws(c); }
    if cls == 'w' { return vch_word(c); }
    if cls == 'A' { return vch_letter(c); }
    if cls == 'N' { return vch_letter(c) || vch_digit(c); }
    if cls == 'L' { return vch_upper(c) != c; }
    if cls == 'U' { return vch_lower(c) != c; }
    if cls == 'B' { return c == ' ' || c == '\t'; }
    if cls == 'P' { return c < 0x80 && is_ascii_punct(c as u8); }
    if cls == 'X' { return vch_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }
    if cls == 'C' { return c < 0x20 || c == 0x7F; }
    if cls == 'G' { return c > 0x20 && c != 0x7F && !vch_ws(c); }
    if cls == 'R' { return c >= 0x20 && c != 0x7F; }
    return false;
}

fn vre_items_has(s: VRSet, c: i64) -> bool {
    for j in s.o..s.o + s.n {
        let it = VRI[j];
        if it.k == 0 { if c >= it.lo && c <= it.hi { return true; } }
        else if vre_class_has(it.lo, c) != it.neg { return true; }
    }
    return false;
}

fn vre_set_has(id: i64, c: i64) -> bool {
    let s = VRS[id];
    var hit = vre_items_has(s, c);
    if !hit && VRE_ICASE {
        let l = vch_lower(c);
        let u = vch_upper(c);
        hit = (l != c && vre_items_has(s, l)) || (u != c && vre_items_has(s, u));
    }
    return hit != s.neg;
}

fn vre_set_node(neg: bool, a1: i64, b1: i64, a2: i64, b2: i64, a3: i64, b3: i64) -> i64 {
    let s = vre_set_begin(neg);
    vre_set_range(s, a1, b1);
    if a2 >= 0 { vre_set_range(s, a2, b2); }
    if a3 >= 0 { vre_set_range(s, a3, b3); }
    return vre_add(RK_SET, s, 0);
}

fn vre_class_node(cls: i64, neg: bool) -> i64 {
    let s = vre_set_begin(false);
    vre_set_class(s, cls, neg);
    return vre_add(RK_SET, s, 0);
}

// Joins the items from ib into one sequence node.
fn vre_seq_end(ib: i64) -> i64 {
    let cnt = VRITEMS.len - ib;
    if cnt == 1 {
        let nd = VRITEMS[ib];
        VRITEMS.resize(ib);
        return nd;
    }
    let cat = vre_add(RK_CAT, 0, 0);
    if cnt > 0 {
        VRN[cat].c = VRITEMS[ib];
        for j in ib..VRITEMS.len - 1 { VRN[VRITEMS[j]].nx = VRITEMS[j + 1]; }
    }
    VRITEMS.resize(ib);
    return cat;
}

fn vre_alts_end(ab: i64) -> i64 {
    let cnt = VRALTS.len - ab;
    if cnt == 1 {
        let nd = VRALTS[ab];
        VRALTS.resize(ab);
        return nd;
    }
    let alt = vre_add(RK_ALT, 0, 0);
    VRN[alt].c = VRALTS[ab];
    for j in ab..VRALTS.len - 1 { VRN[VRALTS[j]].nx = VRALTS[j + 1]; }
    VRALTS.resize(ab);
    return alt;
}

fn vre_invalid(pattern: u8[:]) {
    if VRE_ERR.len == 0 { VRE_ERR.append("The pattern is not valid: "); VRE_ERR.append(pattern); }
}

fn vre_fail(msg: u8[:]) {
    if VRE_ERR.len == 0 { VRE_ERR.append(msg); }
}

fn vre_too_complex() {
    VRE_ERR.clear();
    VRE_ERR.append("The pattern is too complex.");
}

fn vre_has_upper(pattern: u8[:]) -> bool {
    var i = 0;
    while i < pattern.len {
        let c, l = vm_cp_at(pattern, i);
        if vch_lower(c) != c { return true; }
        i += l;
    }
    return false;
}

// Compiles a Vim pattern. ignore: -1 not given, 0 no, 1 yes. Without \c or \C,
// smart ignores case when the pattern has no capital letter. Returns false
// with the message in VRE_ERR when the pattern is not valid.
fn vre_compile(pattern: u8[:], ignore: i64, smart: bool) -> bool {
    VRN.clear(); VRP.clear(); VRS.clear(); VRI.clear();
    VRITEMS.clear(); VRALTS.clear(); VRFR.clear(); VRJ.clear();
    VRE_ERR.clear();
    VRE_MARKS = 0;
    var ch: i64[>..] = [];
    vm_decode(ch, pattern);
    let n = ch.len;
    // 0 very magic, 1 magic, 2 nomagic, 3 very nomagic
    var mode = 1;
    var icase = -1;
    var i = 0;
    var groups = 0;
    var at_start = true;
    VRFR.push(VRFrame { ib: 0, ab: 0, grp: -2 });

    fn lit(c: i64) { VRITEMS.push(vre_add(RK_CHAR, c, 0)); }
    fn item(nd: i64) { VRITEMS.push(nd); }
    fn can_quantify() -> bool { !at_start && VRITEMS.len > VRFR[VRFR.len - 1].ib }
    fn quant(mn: i64, mx: i64, greedy: bool) {
        if VRITEMS.len <= VRFR[VRFR.len - 1].ib { vre_invalid(pattern); return; }
        if mx >= 0 && mx < mn { vre_invalid(pattern); return; }
        let child = VRITEMS.pop();
        let r = vre_add(RK_REP, mn, mx);
        VRN[r].c = child;
        if !greedy { VRN[r].g = 0; }
        VRITEMS.push(r);
    }
    fn open(grp: i64) {
        VRFR.push(VRFrame { ib: VRITEMS.len, ab: VRALTS.len, grp: grp });
        at_start = true;
    }
    fn alt() {
        let s = vre_seq_end(VRFR[VRFR.len - 1].ib);
        VRALTS.push(s);
        at_start = true;
    }
    fn close() {
        if VRFR.len <= 1 { vre_invalid(pattern); return; }
        let f = VRFR[VRFR.len - 1];
        let s = vre_seq_end(f.ib);
        VRALTS.push(s);
        let body = vre_alts_end(f.ab);
        VRFR.pop();
        let g = vre_add(RK_GROUP, f.grp, 0);
        VRN[g].c = body;
        VRITEMS.push(g);
        at_start = false;
    }
    fn open_group() {
        groups++;
        if groups <= 9 { open(groups); } else { open(-1); }
    }
    // After \{ or {: [-][n][,[m]] then } or \}.
    fn brace(start: i64) -> i64 {
        var j = start;
        var lazy = false;
        if j < n && ch[j] == '-' { lazy = true; j++; }
        var a = -1;
        var b = -1;
        var commas = 0;
        var empty = true;
        while j < n && (vch_digit(ch[j]) || ch[j] == ',' || ch[j] == ' ') {
            let c = ch[j];
            if c == ',' { commas++; empty = false; }
            else if c != ' ' {
                empty = false;
                if commas == 0 { a = max(a, 0) * 10 + (c - '0'); } else { b = max(b, 0) * 10 + (c - '0'); }
            }
            j++;
        }
        if j < n && ch[j] == '\\' { j++; }
        if j >= n || ch[j] != '}' { vre_fail("A \\{ quantifier has no closing }."); return n; }
        if empty { quant(0, -1, !lazy); }
        else if commas > 1 { vre_invalid(pattern); }
        else if commas == 0 { if a < 0 { vre_invalid(pattern); } else { quant(a, a, !lazy); } }
        else { quant(max(a, 0), b, !lazy); }
        return j + 1;
    }
    // A POSIX class name at ch[a..b] as a class code, or 0.
    fn posix(a: i64, b: i64) -> i64 {
        var name: u8[..16] = [];
        for k in a..b { if ch[k] < 128 && name.len < 16 { name.push(ch[k] as u8); } }
        if name == "alpha" { return 'A'; }
        if name == "digit" { return 'd'; }
        if name == "alnum" { return 'N'; }
        if name == "lower" { return 'L'; }
        if name == "upper" { return 'U'; }
        if name == "space" { return 's'; }
        if name == "blank" { return 'B'; }
        if name == "punct" { return 'P'; }
        if name == "xdigit" { return 'X'; }
        if name == "cntrl" { return 'C'; }
        if name == "graph" { return 'G'; }
        if name == "print" { return 'R'; }
        return 0;
    }
    // `start` is after `[`. Returns the index after `]`, or -1 when there is no `]`.
    // The set is in *set_out.
    var set_out = -1;
    fn collection(start: i64) -> i64 {
        var j = start;
        var neg = false;
        if j < n && ch[j] == '^' { neg = true; j++; }
        let s = vre_set_begin(neg);
        if j < n && ch[j] == ']' { vre_set_range(s, ']', ']'); j++; }
        fn add_lit(c: i64) {
            // A range such as a-z.
            if j + 1 < n && ch[j] == '-' && ch[j + 1] != ']' && ch[j + 1] != '\\' && ch[j + 1] != '[' {
                let hi = ch[j + 1];
                if hi < c { vre_invalid(pattern); }
                vre_set_range(s, c, hi);
                j += 2;
                return;
            }
            vre_set_range(s, c, c);
        }
        while j < n && ch[j] != ']' {
            let c = ch[j];
            if c == '[' && j + 1 < n && ch[j + 1] == ':' {
                var end = j + 2;
                while end + 1 < n && !(ch[end] == ':' && ch[end + 1] == ']') { end++; }
                if end + 1 < n {
                    let code = posix(j + 2, end);
                    if code == 0 { vre_invalid(pattern); } else { vre_set_class(s, code, false); }
                    j = end + 2;
                    continue;
                }
            }
            if c == '\\' && j + 1 < n {
                let e = ch[j + 1];
                j += 2;
                if e == 'e' { add_lit(0x1B); }
                else if e == 't' { add_lit('\t'); }
                else if e == 'r' { add_lit('\r'); }
                else if e == 'n' { add_lit('\n'); }
                else if e == '\\' || e == ']' || e == '^' || e == '-' { add_lit(e); }
                else if e == 'd' || e == 's' || e == 'w' { vre_set_class(s, e, false); }
                else if e == 'D' || e == 'S' || e == 'W' { vre_set_class(s, vch_lower(e), true); }
                else { vre_set_range(s, '\\', '\\'); add_lit(e); }
                continue;
            }
            j++;
            add_lit(c);
        }
        if j >= n { return -1; }
        set_out = s;
        return j + 1;
    }

    while i < n && VRE_ERR.len == 0 {
        let c = ch[i];
        // Characters that are special without a backslash in the current mode.
        if c != '\\' {
            if mode == 0 {
                if c == '(' { open_group(); i++; continue; }
                if c == ')' { close(); i++; continue; }
                if c == '|' { alt(); i++; continue; }
                if c == '+' || c == '?' || c == '=' {
                    if can_quantify() { if c == '+' { quant(1, -1, true); } else { quant(0, 1, true); } } else { lit(c); }
                    i++; continue;
                }
                if c == '{' { i = brace(i + 1); continue; }
                if c == '<' { item(vre_add(RK_WS, 0, 0)); i++; continue; }
                if c == '>' { item(vre_add(RK_WE, 0, 0)); i++; continue; }
                if c == '@' { vre_fail("Marklove does not support @ (look-around) in patterns."); break; }
                if c == '%' {
                    if i + 1 < n && ch[i + 1] == '(' { open(-1); i += 2; continue; }
                    lit(c); i++; continue;
                }
            }
            let magic_like = mode == 0 || mode == 1;
            if c == '^' {
                if at_start { item(vre_add(RK_BOL, 0, 0)); } else { lit('^'); }
                i++; continue;
            }
            if c == '$' {
                var next_is_end = i + 1 >= n;
                if !next_is_end && ch[i + 1] == '\\' && i + 2 < n && (ch[i + 2] == '|' || ch[i + 2] == ')') { next_is_end = true; }
                if !next_is_end && mode == 0 && (ch[i + 1] == '|' || ch[i + 1] == ')') { next_is_end = true; }
                if next_is_end { item(vre_add(RK_EOL, 0, 0)); } else { lit('$'); }
                i++; at_start = false; continue;
            }
            if c == '.' && magic_like { item(vre_add(RK_ANY, 0, 0)); i++; at_start = false; continue; }
            if c == '*' && magic_like {
                if can_quantify() { quant(0, -1, true); } else { lit('*'); }
                i++; continue;
            }
            if c == '[' && magic_like {
                let next = collection(i + 1);
                if next >= 0 { item(vre_add(RK_SET, set_out, 0)); i = next; at_start = false; continue; }
                lit('['); i++; at_start = false; continue;
            }
            lit(c); i++; at_start = false; continue;
        }

        // A backslash sequence.
        if i + 1 >= n { lit('\\'); i++; continue; }
        let e = ch[i + 1];
        i += 2;
        // In very magic mode, a backslash makes the special characters literal.
        if mode == 0 && (e == '(' || e == ')' || e == '|' || e == '+' || e == '?' || e == '=' || e == '{' || e == '}' ||
                         e == '<' || e == '>' || e == '@' || e == '%') {
            lit(e); at_start = false; continue;
        }
        if e == 'v' { mode = 0; }
        else if e == 'm' { mode = 1; }
        else if e == 'M' { mode = 2; }
        else if e == 'V' { mode = 3; }
        else if e == 'c' { icase = 1; }
        else if e == 'C' { icase = 0; }
        else if e == '(' { open_group(); }
        else if e == ')' { close(); }
        else if e == '|' { alt(); }
        else if e == '+' { if can_quantify() { quant(1, -1, true); } else { lit('+'); } }
        else if e == '?' || e == '=' { if can_quantify() { quant(0, 1, true); } else { lit(e); } }
        else if e == '{' { i = brace(i); }
        else if e == '<' { item(vre_add(RK_WS, 0, 0)); at_start = false; }
        else if e == '>' { item(vre_add(RK_WE, 0, 0)); at_start = false; }
        else if e == 'z' {
            if i >= n { vre_fail("\\z needs s or e."); break; }
            let k = ch[i];
            i++;
            if k == 's' { item(vre_add(RK_ZS, 0, 0)); }
            else if k == 'e' { item(vre_add(RK_ZE, 0, 0)); }
            else {
                vre_fail("Marklove does not support \\z");
                var t: u8[..8] = [];
                if k < 128 { t.push(k as u8); }
                VRE_ERR.append(t);
                VRE_ERR.append(".");
                break;
            }
        }
        else if e == '%' {
            if i >= n { vre_fail("\\% needs a character after it."); break; }
            let k = ch[i];
            i++;
            if k == '(' { open(-1); }
            else if k == '^' { item(vre_add(RK_BOT, 0, 0)); }
            else if k == '$' { item(vre_add(RK_EOT, 0, 0)); }
            else if k == 'V' { }
            else if k == 'd' || k == 'x' || k == 'u' || k == 'U' || k == 'o' {
                var radix = 16;
                if k == 'd' { radix = 10; } else if k == 'o' { radix = 8; }
                var v = 0;
                var digits = 0;
                while i < n {
                    let d = ch[i];
                    var dv = -1;
                    if vch_digit(d) { dv = d - '0'; }
                    else if d >= 'a' && d <= 'f' { dv = d - 'a' + 10; }
                    else if d >= 'A' && d <= 'F' { dv = d - 'A' + 10; }
                    if dv < 0 || dv >= radix { break; }
                    v = v * radix + dv;
                    digits++;
                    i++;
                }
                if digits == 0 { vre_fail("\\% needs a number."); break; }
                lit(v); at_start = false;
            }
            else { vre_fail("Marklove does not support this \\% item."); break; }
        }
        else if e == '@' { vre_fail("Marklove does not support \\@ (look-around) in patterns."); break; }
        else if e == '&' { vre_fail("Marklove does not support \\& in patterns."); break; }
        else if e == 's' || e == 'd' || e == 'w' { item(vre_class_node(e, false)); at_start = false; }
        else if e == 'S' || e == 'D' || e == 'W' { item(vre_class_node(vch_lower(e), true)); at_start = false; }
        else if e == 'a' { item(vre_set_node(false, 'A', 'Z', 'a', 'z', -1, -1)); at_start = false; }
        else if e == 'A' { item(vre_set_node(true, 'A', 'Z', 'a', 'z', -1, -1)); at_start = false; }
        else if e == 'l' { item(vre_set_node(false, 'a', 'z', -1, -1, -1, -1)); at_start = false; }
        else if e == 'L' { item(vre_set_node(true, 'a', 'z', -1, -1, -1, -1)); at_start = false; }
        else if e == 'u' { item(vre_set_node(false, 'A', 'Z', -1, -1, -1, -1)); at_start = false; }
        else if e == 'U' { item(vre_set_node(true, 'A', 'Z', -1, -1, -1, -1)); at_start = false; }
        else if e == 'x' { item(vre_set_node(false, '0', '9', 'A', 'F', 'a', 'f')); at_start = false; }
        else if e == 'X' { item(vre_set_node(true, '0', '9', 'A', 'F', 'a', 'f')); at_start = false; }
        else if e == 'o' { item(vre_set_node(false, '0', '7', -1, -1, -1, -1)); at_start = false; }
        else if e == 'O' { item(vre_set_node(true, '0', '7', -1, -1, -1, -1)); at_start = false; }
        else if e == 'h' { item(vre_set_node(false, 'A', 'Z', 'a', 'z', '_', '_')); at_start = false; }
        else if e == 'H' { item(vre_set_node(true, 'A', 'Z', 'a', 'z', '_', '_')); at_start = false; }
        else if e == 'k' || e == 'i' || e == 'f' || e == 'p' { item(vre_class_node('w', false)); at_start = false; }
        else if e == 'K' || e == 'I' || e == 'F' || e == 'P' {
            // [^\W\d]: a word character that is not a digit.
            let s = vre_set_begin(true);
            vre_set_class(s, 'w', true);
            vre_set_class(s, 'd', false);
            item(vre_add(RK_SET, s, 0));
            at_start = false;
        }
        else if e == '_' {
            if i >= n { vre_fail("\\_ needs a character after it."); break; }
            let k = ch[i];
            i++;
            if k == '.' { item(vre_add(RK_ANYNL, 0, 0)); }
            else if k == '^' { item(vre_add(RK_BOL, 0, 0)); }
            else if k == '$' { item(vre_add(RK_EOL, 0, 0)); }
            else if k == '[' {
                let next = collection(i);
                if next >= 0 {
                    // Add the line break to the collection.
                    vre_set_range(set_out, '\n', '\n');
                    item(vre_add(RK_SET, set_out, 0));
                    i = next;
                } else { lit('['); }
            } else {
                // A class or the line break.
                let s = vre_set_begin(false);
                vre_set_range(s, '\n', '\n');
                let lk = vch_lower(k);
                let neg = k != lk;
                if lk == 's' || lk == 'd' || lk == 'w' { vre_set_class(s, lk, neg); }
                else if k == 'a' { vre_set_range(s, 'A', 'Z'); vre_set_range(s, 'a', 'z'); }
                else if k == 'l' { vre_set_range(s, 'a', 'z'); }
                else if k == 'u' { vre_set_range(s, 'A', 'Z'); }
                else if k == 'x' { vre_set_range(s, '0', '9'); vre_set_range(s, 'A', 'F'); vre_set_range(s, 'a', 'f'); }
                else if k == 'h' { vre_set_range(s, 'A', 'Z'); vre_set_range(s, 'a', 'z'); vre_set_range(s, '_', '_'); }
                else { vre_set_range(s, k, k); }
                item(vre_add(RK_SET, s, 0));
            }
            at_start = false;
        }
        else if e == 'n' { lit('\n'); at_start = false; }
        else if e == 't' { lit('\t'); at_start = false; }
        else if e == 'e' { lit(0x1B); at_start = false; }
        else if e == 'r' { lit('\r'); at_start = false; }
        else if e >= '1' && e <= '9' { item(vre_add(RK_BREF, e - '0', 0)); at_start = false; }
        else if e == '.' || e == '*' || e == '[' || e == '~' {
            if mode == 0 || mode == 1 { lit(e); }
            else if e == '.' { item(vre_add(RK_ANY, 0, 0)); }
            else if e == '*' { if can_quantify() { quant(0, -1, true); } else { lit('*'); } }
            else if e == '[' {
                let next = collection(i);
                if next >= 0 { item(vre_add(RK_SET, set_out, 0)); i = next; } else { lit('['); }
            }
            else { lit('~'); }
            at_start = false;
        }
        else { lit(e); at_start = false; }
    }
    if VRE_ERR.len > 0 { return false; }
    if VRFR.len != 1 { vre_invalid(pattern); return false; }
    let s = vre_seq_end(0);
    VRALTS.push(s);
    let root = vre_alts_end(0);

    var ign = false;
    if icase >= 0 { ign = icase == 1; } else if ignore >= 0 { ign = ignore == 1; }
    if icase < 0 && ignore < 0 && smart { ign = !vre_has_upper(pattern) || pattern.len == 0; }
    VRE_ICASE = ign;

    vre_emit(root);
    VRP.push(VRInst { op: OP_MATCH, x: 0, y: 0 });
    if VRE_ERR.len > 0 { return false; }
    return true;
}

recursive fn vre_nullable(nd: i64) -> bool {
    let k = VRN[nd].k;
    if k == RK_CHAR || k == RK_ANY || k == RK_ANYNL || k == RK_SET { return false; }
    if k == RK_CAT {
        var c = VRN[nd].c;
        while c >= 0 { if !vre_nullable(c) { return false; } c = VRN[c].nx; }
        return true;
    }
    if k == RK_ALT {
        var c = VRN[nd].c;
        while c >= 0 { if vre_nullable(c) { return true; } c = VRN[c].nx; }
        return false;
    }
    if k == RK_GROUP { let c = VRN[nd].c; if c < 0 { return true; } return vre_nullable(c); }
    if k == RK_REP { if VRN[nd].x == 0 { return true; } return vre_nullable(VRN[nd].c); }
    return true;
}

fn vre_inst(op: i64, x: i64, y: i64) -> i64 {
    VRP.push(VRInst { op: op, x: x, y: y });
    return VRP.len - 1;
}

recursive fn vre_emit(nd: i64) {
    if VRP.len > 200000 { vre_too_complex(); return; }
    let node = VRN[nd];
    let k = node.k;
    if k == RK_CAT {
        var c = node.c;
        while c >= 0 { vre_emit(c); c = VRN[c].nx; }
        return;
    }
    if k == RK_ALT {
        let jb = VRJ.len;
        var c = node.c;
        while c >= 0 {
            let next = VRN[c].nx;
            if next >= 0 {
                let split = vre_inst(OP_SPLIT, VRP.len + 1, 0);
                vre_emit(c);
                VRJ.push(vre_inst(OP_JMP, 0, 0));
                VRP[split].y = VRP.len;
            } else {
                vre_emit(c);
            }
            c = next;
        }
        let end = VRP.len;
        for j in jb..VRJ.len { VRP[VRJ[j]].x = end; }
        VRJ.resize(jb);
        return;
    }
    if k == RK_GROUP {
        if node.x >= 1 { vre_inst(OP_SAVE, 2 * node.x, 0); }
        if node.c >= 0 { vre_emit(node.c); }
        if node.x >= 1 { vre_inst(OP_SAVE, 2 * node.x + 1, 0); }
        return;
    }
    if k == RK_REP {
        let greedy = node.g == 1;
        for _ in node.x { vre_emit(node.c); }
        if node.y < 0 {
            let top = VRP.len;
            let split = vre_inst(OP_SPLIT, 0, 0);
            let body = VRP.len;
            var mark = -1;
            if vre_nullable(node.c) {
                if VRE_FIRST_MARK + VRE_MARKS >= VRE_SLOTS { vre_too_complex(); return; }
                mark = VRE_FIRST_MARK + VRE_MARKS;
                VRE_MARKS++;
                vre_inst(OP_SAVE, mark, 0);
            }
            vre_emit(node.c);
            if mark >= 0 { vre_inst(OP_CHECK, mark, 0); }
            vre_inst(OP_JMP, top, 0);
            let exit = VRP.len;
            if greedy { VRP[split].x = body; VRP[split].y = exit; } else { VRP[split].x = exit; VRP[split].y = body; }
        } else {
            let jb = VRJ.len;
            for _ in node.y - node.x {
                VRJ.push(vre_inst(OP_SPLIT, 0, 0));
                vre_emit(node.c);
            }
            let end = VRP.len;
            for j in jb..VRJ.len {
                let s = VRJ[j];
                if greedy { VRP[s].x = s + 1; VRP[s].y = end; } else { VRP[s].x = end; VRP[s].y = s + 1; }
            }
            VRJ.resize(jb);
        }
        return;
    }
    if k == RK_ZS { vre_inst(OP_SAVE, 20, 0); return; }
    if k == RK_ZE { vre_inst(OP_SAVE, 21, 0); return; }
    vre_inst(k, node.x, 0);
}

fn vre_eq(a: i64, b: i64) -> bool { a == b || (VRE_ICASE && vch_lower(a) == vch_lower(b)) }

fn vre_word_at(lo: i64, hi: i64, i: i64) -> bool { i >= lo && i < hi && vch_word(VCH[i]) }

fn vre_budget() { VRE_STEPS = 0; VRE_OVER = false; }

// One match attempt at `start`, with lo..hi as the whole text.
fn vre_try(lo: i64, hi: i64, start: i64) -> bool {
    for k in VRE_SLOTS { VRSL[k] = -1; }
    VRBT.clear();
    var pc = 0;
    var sp = start;
    loop {
        VRE_STEPS++;
        if VRE_STEPS > VRE_LIMIT { VRE_OVER = true; return false; }
        let ins = VRP[pc];
        let op = ins.op;
        var good = true;
        if op == RK_CHAR { if sp < hi && vre_eq(VCH[sp], ins.x) { sp++; pc++; } else { good = false; } }
        else if op == RK_ANY { if sp < hi && VCH[sp] != '\n' && VCH[sp] != '\r' { sp++; pc++; } else { good = false; } }
        else if op == RK_ANYNL { if sp < hi { sp++; pc++; } else { good = false; } }
        else if op == RK_SET { if sp < hi && vre_set_has(ins.x, VCH[sp]) { sp++; pc++; } else { good = false; } }
        else if op == OP_SPLIT { VRBT.push(VRBt { pc: ins.y, sp: sp, slot: -1, old: 0 }); pc = ins.x; }
        else if op == OP_JMP { pc = ins.x; }
        else if op == OP_SAVE {
            VRBT.push(VRBt { pc: 0, sp: 0, slot: ins.x, old: VRSL[ins.x] });
            VRSL[ins.x] = sp;
            pc++;
        }
        else if op == OP_CHECK { if VRSL[ins.x] == sp { good = false; } else { pc++; } }
        else if op == RK_BOL { if sp == lo || VCH[sp - 1] == '\n' { pc++; } else { good = false; } }
        else if op == RK_EOL { if sp == hi || VCH[sp] == '\n' { pc++; } else { good = false; } }
        else if op == RK_BOT { if sp == lo { pc++; } else { good = false; } }
        else if op == RK_EOT { if sp == hi { pc++; } else { good = false; } }
        else if op == RK_WS { if vre_word_at(lo, hi, sp) && !vre_word_at(lo, hi, sp - 1) { pc++; } else { good = false; } }
        else if op == RK_WE { if vre_word_at(lo, hi, sp - 1) && !vre_word_at(lo, hi, sp) { pc++; } else { good = false; } }
        else if op == RK_BREF {
            let s = VRSL[2 * ins.x];
            let e = VRSL[2 * ins.x + 1];
            if s < 0 || e < 0 || sp + (e - s) > hi { good = false; }
            else {
                for j in e - s { if !vre_eq(VCH[sp + j], VCH[s + j]) { good = false; break; } }
                if good { sp += e - s; pc++; }
            }
        }
        else if op == OP_MATCH {
            VRM_WS = start;
            VRM_WE = sp;
            VRM_S = start;
            if VRSL[20] >= 0 { VRM_S = VRSL[20]; }
            VRM_E = sp;
            if VRSL[21] >= 0 { VRM_E = VRSL[21]; }
            if VRM_E < VRM_S { VRM_E = VRM_S; }
            return true;
        }
        if !good {
            var resumed = false;
            while VRBT.len > 0 {
                let b = VRBT.pop();
                if b.slot >= 0 { VRSL[b.slot] = b.old; }
                else { pc = b.pc; sp = b.sp; resumed = true; break; }
            }
            if !resumed { return false; }
        }
    }
    return false;
}

// The first match that starts at `from` or later, inside lo..hi.
fn vre_find(lo: i64, hi: i64, from: i64) -> bool {
    var first = -1;
    if VRP.len > 0 && VRP[0].op == RK_CHAR && !VRE_ICASE { first = VRP[0].x; }
    var s = from;
    while s <= hi {
        if first >= 0 {
            while s < hi && VCH[s] != first { s++; }
            if s >= hi { return false; }
        }
        if vre_try(lo, hi, s) { return true; }
        if VRE_OVER { return false; }
        s++;
    }
    return false;
}

// Where the search for the next match starts: after an empty match, one further.
fn vre_next_pos() -> i64 {
    if VRM_WE > VRM_WS { return VRM_WE; }
    return VRM_WE + 1;
}

// Appends the text of group k of the last match (0: the match).
fn vre_group(out: u8[>..]&, k: i64) {
    if k == 0 { vb_str(out, VRM_S, VRM_E); return; }
    let s = VRSL[2 * k];
    let e = VRSL[2 * k + 1];
    if s < 0 || e < 0 { return; }
    vb_str(out, s, e);
}

// Expands a Vim replacement for the last match.
fn vre_expand(out: u8[>..]&, tmpl: u8[:], prev: u8[:], has_prev: bool) {
    // 0 none, 1 upper, 2 lower
    var one = 0;
    var run = 0;
    var piece: u8[>..] = [];
    fn add(s: u8[:]) {
        if out.len > MAX_TEXT { return; }
        var i = 0;
        while i < s.len {
            var c, l = vm_cp_at(s, i);
            if one != 0 {
                if one == 1 { c = vch_upper(c); } else { c = vch_lower(c); }
                one = 0;
            } else if run != 0 {
                if run == 1 { c = vch_upper(c); } else { c = vch_lower(c); }
            }
            vm_put_cp(out, c);
            i += l;
        }
    }
    var i = 0;
    while i < tmpl.len {
        let c, l = vm_cp_at(tmpl, i);
        if c == '&' { piece.clear(); vre_group(piece, 0); add(piece); i++; continue; }
        if c == '~' { if has_prev { add(prev); } else { add("~"); } i++; continue; }
        if c == '\\' && i + 1 < tmpl.len {
            let e, el = vm_cp_at(tmpl, i + 1);
            if e >= '0' && e <= '9' { piece.clear(); vre_group(piece, e - '0'); add(piece); }
            else if e == '&' { add("&"); }
            else if e == '~' { add("~"); }
            else if e == 'u' { one = 1; }
            else if e == 'l' { one = 2; }
            else if e == 'U' { run = 1; }
            else if e == 'L' { run = 2; }
            else if e == 'e' || e == 'E' { run = 0; }
            else if e == 'r' || e == 'n' { out.push('\n'); }
            else if e == 't' { out.push('\t'); }
            else if e == '\\' { out.push('\\'); }
            else { add(tmpl[i + 1..i + 1 + el]); }
            i += 1 + el;
            continue;
        }
        add(tmpl[i..i + l]);
        i += l;
    }
}

// ---------------------------------------------------------------------------
// The engine state, as VimEngine.

let M_NORMAL = 0;
let M_INSERT = 1;
let M_VISUAL = 2;
let M_VLINE = 3;
let M_CMD = 4;

let SP_ESC = 1;
let SP_ENTER = 2;
let SP_BS = 3;
let SP_TAB = 4;
let SP_LEFT = 5;
let SP_RIGHT = 6;
let SP_UP = 7;
let SP_DOWN = 8;

let ACT_NONE = 0;
let ACT_SAVE = 1;
let ACT_DISCARD = 2;
let ACT_COPY = 3;

struct VKey { sp: i64, ctrl: bool, ch: i64 }

var VMODE = 0;
// The command line prefix: ':', '/' or '?'.
var VPREFIX = ':';
var VCMD: u8[>..] = [];
var VCOUNT = -1;
var VOP = 0;
var VOPCOUNT = -1;
var VAWAIT = 0;
var VGPRE = false;
var VREGPRE = false;
var VREG = 0;
// The last character of Swift's pendingKeys, for cw.
var VPLAST = 0;
var VUN: u8[>..] = [];
var VUNLW = false;
var VLF_CMD = 0;
var VLF_CH = 0;
var VLS: u8[>..] = [];
var VLS_SET = false;
var VLS_FWD = true;
var VLREP: u8[>..] = [];
var VLREP_SET = false;
var VLSUB_PAT: u8[>..] = [];
var VLSUB_REP: u8[>..] = [];
var VLSUB_FLAGS: u8[>..] = [];
var VLSUB_SET = false;
var VDESCOL = -1;
var VANCHOR = 0;
var VLV_A = 0;
var VLV_B = 0;
var VLV_LINE = false;
var VLV_SET = false;
// Dot repeat.
var VREC: VKey[>..] = [];
var VLASTKEYS: VKey[>..] = [];
var VREPKEYS: VKey[>..] = [];
var VINS: u8[>..] = [];
var VLASTINS: u8[>..] = [];
var VREPLAY = false;
var VWANT_REPEAT = false;
// The clipboard text from JavaScript.
var VCLIPIN: u8[>..] = [];

// The result of one key.
var VSELLOC = 0;
var VSELLEN = 0;
var VMSG: u8[>..] = [];
var VACTION = 0;
var VCLIPOUT: u8[>..] = [];

// The edits of one change: code point ranges of the current text, in order.
struct VEd { lo: i64, hi: i64, ro: i64, rn: i64 }
var VED: VEd[>..] = [];
var VEDB: u8[>..] = [];

// Undo history: each record replaces nnew bytes at pos with the nold bytes
// at the top of the byte stack.
struct VURec { pos: i64, nold: i64, nnew: i64 }
var VUR: VURec[>..] = [];
var VUB: u8[>..] = [];
var VRR: VURec[>..] = [];
var VRB: u8[>..] = [];
// The text after the last committed change.
var VLAST: u8[>..] = [];
var VHAVELAST = false;

fn vm_clear_pending() {
    VCOUNT = -1;
    VOP = 0;
    VOPCOUNT = -1;
    VAWAIT = 0;
    VGPRE = false;
    VREGPRE = false;
    VREG = 0;
    VPLAST = 0;
}

fn vm_cnt1() -> i64 { if VCOUNT < 0 { return 1; } return VCOUNT; }
fn vm_opcnt1() -> i64 { if VOPCOUNT < 0 { return 1; } return VOPCOUNT; }

fn vm_msg(t: u8[:]) { VMSG.clear(); VMSG.append(t); }

fn vm_sel(loc: i64, len: i64) {
    VSELLOC = max(0, min(loc, VCH.len));
    VSELLEN = max(0, min(len, VCH.len - VSELLOC));
}

// A block cursor covers one character in Normal mode.
fn vm_sel_block(i0: i64) {
    let i = max(0, min(i0, VCH.len));
    var len = 0;
    if i < VCH.len && VCH[i] != '\n' { len = 1; }
    vm_sel(i, len);
}

fn ed_add(lo: i64, hi: i64, rep: u8[:]) {
    VED.push(VEd { lo: lo, hi: hi, ro: VEDB.len, rn: rep.len });
    VEDB.append(rep);
}

// Applies VED to the text. Returns the new place of the old position `at`.
fn ed_apply(at: i64) -> i64 {
    var nb: u8[>..] = [];
    var prev = 0;
    var delta = 0;
    var mapped = -1;
    for e in VED {
        nb.append(VTXT[VOFF[prev]..VOFF[e.lo]]);
        nb.append(VEDB[e.ro..e.ro + e.rn]);
        prev = e.hi;
        if mapped < 0 {
            if at < e.lo { mapped = at + delta; }
            else if at < e.hi { mapped = e.lo + delta; }
            else { delta += char_count(VEDB[e.ro..e.ro + e.rn]) - (e.hi - e.lo); }
        }
    }
    nb.append(VTXT[VOFF[prev]..]);
    if mapped < 0 { mapped = at + delta; }
    VED.clear();
    VEDB.clear();
    VTXT.clear();
    VTXT.append(nb);
    vb_load();
    return mapped;
}

fn vm_edit1(lo: i64, hi: i64, rep: u8[:]) {
    ed_add(lo, hi, rep);
    ed_apply(0);
}

// ---------------------------------------------------------------------------
// Undo

fn vm_commit() {
    var same = VHAVELAST && VLAST.len == VTXT.len;
    if same { for j in VTXT.len { if VLAST[j] != VTXT[j] { same = false; break; } } }
    if VHAVELAST && !same {
        let a = VLAST.len;
        let b = VTXT.len;
        var p = 0;
        while p < a && p < b && VLAST[p] == VTXT[p] { p++; }
        var s = 0;
        while s < a - p && s < b - p && VLAST[a - 1 - s] == VTXT[b - 1 - s] { s++; }
        VUR.push(VURec { pos: p, nold: a - s - p, nnew: b - s - p });
        for j in p..a - s { VUB.push(VLAST[j]); }
        VRR.clear();
        VRB.clear();
    }
    if !same {
        VLAST.clear();
        for j in VTXT.len { VLAST.push(VTXT[j]); }
    }
    VHAVELAST = true;
}

// Puts `old` at pos in place of nnew bytes.
fn vm_undo_text(pos: i64, nnew: i64, old: u8[:]) {
    var nb: u8[>..] = [];
    nb.append(VTXT[..pos]);
    nb.append(old);
    nb.append(VTXT[pos + nnew..]);
    VTXT.clear();
    VTXT.append(nb);
}

fn vm_undo(n: i64, redo: bool) {
    var pos = -1;
    for _ in n {
        if redo {
            if VRR.len == 0 { break; }
            let r = VRR.pop();
            var old: u8[>..] = [];
            for j in VRB.len - r.nold..VRB.len { old.push(VRB[j]); }
            VRB.resize(VRB.len - r.nold);
            for j in r.pos..r.pos + r.nnew { VUB.push(VTXT[j]); }
            VUR.push(VURec { pos: r.pos, nold: r.nnew, nnew: r.nold });
            vm_undo_text(r.pos, r.nnew, old);
            pos = r.pos;
        } else {
            if VUR.len == 0 { break; }
            let r = VUR.pop();
            var old: u8[>..] = [];
            for j in VUB.len - r.nold..VUB.len { old.push(VUB[j]); }
            VUB.resize(VUB.len - r.nold);
            for j in r.pos..r.pos + r.nnew { VRB.push(VTXT[j]); }
            VRR.push(VURec { pos: r.pos, nold: r.nnew, nnew: r.nold });
            vm_undo_text(r.pos, r.nnew, old);
            pos = r.pos;
        }
    }
    vb_load();
    VLAST.clear();
    for j in VTXT.len { VLAST.push(VTXT[j]); }
    VHAVELAST = true;
    if pos >= 0 { vm_sel_block(vb_clamp(vb_char_at(pos))); }
}

// ---------------------------------------------------------------------------
// Motions

struct VMo { ok: bool, t: i64, incl: bool, lw: bool, vert: bool, msg: bool, srch: bool }

var VMO_MSG: u8[>..] = [];
var VMO_SRCH: u8[>..] = [];
var VMO_FWD = true;

fn vmo(t: i64) -> VMo { VMo { ok: true, t: t, incl: false, lw: false, vert: false, msg: false, srch: false } }

fn vmo_msg(t: i64, m: u8[:]) -> VMo {
    VMO_MSG.clear();
    VMO_MSG.append(m);
    var r = vmo(t);
    r.msg = true;
    return r;
}

fn vb_motion(c: i64, i: i64, n: i64, desired: i64) -> VMo {
    if c == 'h' { return vmo(max(vb_ls(i), i - n)); }
    if c == 'l' || c == ' ' { let e = vb_le(i); return vmo(min(max(i, e), i + n)); }
    if c == 'j' || c == '+' {
        var d = desired;
        if c == '+' { d = 0; }
        var m = vmo(vb_move_lines(i, n, d));
        m.lw = true;
        m.vert = c == 'j';
        if c == '+' { m.t = vb_fnb(vb_ls(m.t)); }
        return m;
    }
    if c == 'k' || c == '-' {
        var d = desired;
        if c == '-' { d = 0; }
        var m = vmo(vb_move_lines(i, -n, d));
        m.lw = true;
        m.vert = c == 'k';
        if c == '-' { m.t = vb_fnb(vb_ls(m.t)); }
        return m;
    }
    if c == 'w' || c == 'W' { var k = i; for _ in n { k = vb_next_word(k, c == 'W'); } return vmo(k); }
    if c == 'b' || c == 'B' { var k = i; for _ in n { k = vb_prev_word(k, c == 'B'); } return vmo(k); }
    if c == 'e' || c == 'E' {
        var k = i;
        for _ in n { k = vb_word_end(k, c == 'E'); }
        var m = vmo(k);
        m.incl = true;
        return m;
    }
    if c == '0' { return vmo(vb_ls(i)); }
    if c == '^' || c == '_' { return vmo(vb_fnb(vb_ls(i))); }
    if c == '$' {
        var target = vb_le(i);
        if n > 1 { target = vb_le(vb_move_lines(i, n - 1, -1)); }
        var m = vmo(max(vb_ls(target), target - 1));
        m.incl = true;
        return m;
    }
    if c == 'G' {
        var m = vmo(vb_fnb(vb_line_start_of(vb_line_count() - 1)));
        m.lw = true;
        return m;
    }
    if c == '%' {
        let t, ok = vb_matching_bracket(i);
        if !ok { var m = vmo(i); m.ok = false; return m; }
        var m = vmo(t);
        m.incl = true;
        return m;
    }
    if c == '}' { var k = i; for _ in n { k = vb_next_para(k); } return vmo(k); }
    if c == '{' { var k = i; for _ in n { k = vb_prev_para(k); } return vmo(k); }
    if c == ')' { var k = i; for _ in n { k = vb_next_sentence(k); } return vmo(k); }
    if c == '(' { var k = i; for _ in n { k = vb_prev_sentence(k); } return vmo(k); }
    if c == 'n' || c == 'N' {
        if !VLS_SET { return vmo_msg(i, "No previous search."); }
        var pat: u8[>..] = [];
        for b in VLS { pat.push(b); }
        let dir = if c == 'n' { VLS_FWD } else { !VLS_FWD };
        var k = i;
        var wrapped = false;
        for _ in n {
            let r, st = vb_search(pat, k, dir);
            if st == 2 { return vmo_msg(i, VRE_ERR); }
            if st == 0 {
                var m: u8[>..] = [];
                m.append("Pattern not found: ");
                m.append(pat);
                return vmo_msg(i, m);
            }
            if (dir && r <= k) || (!dir && r >= k) { wrapped = true; }
            k = r;
        }
        if wrapped {
            if dir { return vmo_msg(k, "Search reached the end and continued at the top."); }
            return vmo_msg(k, "Search reached the top and continued at the end.");
        }
        return vmo(k);
    }
    if c == '*' || c == '#' {
        let s, e, ok = vb_word_under(i);
        if !ok { return vmo_msg(i, "No word under the cursor."); }
        var word: u8[>..] = [];
        vb_str(word, s, e);
        // A whole-word Vim pattern, case as typed.
        var pat: u8[>..] = [];
        pat.append("\\<");
        vb_escape_vim(pat, word);
        pat.append("\\>\\C");
        let r, st = vb_search(pat, i, c == '*');
        if st != 1 { return vmo(i); }
        var m = vmo(r);
        m.srch = true;
        VMO_SRCH.clear();
        VMO_SRCH.append(pat);
        VMO_FWD = c == '*';
        return m;
    }
    var none = vmo(i);
    none.ok = false;
    return none;
}

// ---------------------------------------------------------------------------
// Normal mode

fn vm_set_desired(vert: bool, cursor: i64) {
    if vert { if VDESCOL < 0 { VDESCOL = vb_col(cursor); } } else { VDESCOL = -1; }
}

fn vm_motion_only(c: i64, cursor: i64) {
    let m = vb_motion(c, cursor, vm_cnt1(), VDESCOL);
    if !m.ok { return; }
    vm_set_desired(m.vert, cursor);
    vm_clear_pending();
    VREC.clear();
    vm_sel_block(vb_clamp(m.t));
}

fn vm_motion_result(target: i64, incl: bool, lw: bool, cursor: i64) {
    if VOP == 0 {
        vm_clear_pending();
        VREC.clear();
        vm_sel_block(vb_clamp(target));
        return;
    }
    let a = min(cursor, target);
    let b = max(cursor, target);
    var lo = a;
    var hi = 0;
    if lw { lo = vb_ls(a); hi = vb_leb(b); }
    else { var x = 0; if incl { x = 1; } hi = min(VCH.len, b + x); }
    // cw acts like ce on a word.
    if VOP == 'c' && (VPLAST == 'w' || VPLAST == 'W') && lo < VCH.len {
        var end = hi;
        while end > lo + 1 && vb_white(VCH[end - 1]) { end--; }
        hi = end;
    }
    vm_apply_op(VOP, lo, hi, lw, cursor);
}

fn vm_store(t: u8[:], lw: bool, reg: i64) {
    if reg == '_' { return; }
    VUN.clear();
    VUN.append(t);
    VUNLW = lw;
    if reg == '+' || reg == '*' { VACTION = ACT_COPY; VCLIPOUT.clear(); VCLIPOUT.append(t); }
}

fn vm_finish_change() {
    if !VREPLAY {
        VLASTKEYS.clear();
        for j in VREC.len { VLASTKEYS.push(VREC[j]); }
        VLASTINS.clear();
    }
    VREC.clear();
    vm_clear_pending();
}

fn vm_apply_op(op: i64, lo0: i64, hi0: i64, lw: bool, cursor: i64) {
    var t: u8[>..] = [];
    vb_str(t, lo0, hi0);
    let reg = VREG;
    var lo = lo0;
    var hi = hi0;
    if op == 'y' {
        vm_store(t, lw, reg);
        VREC.clear();
        vm_sel_block(min(lo, cursor));
        vm_clear_pending();
        return;
    }
    if op == 'd' {
        vm_store(t, lw, reg);
        // Deleting the last lines also removes the line break before them.
        if lw && hi == VCH.len && lo > 0 && !has_suffix(t, "\n") { lo--; }
        vm_finish_change();
        let after = lo;
        vm_edit1(lo, hi, "");
        var caret = 0;
        if lw { caret = vb_fnb(vb_ls(min(after, max(VCH.len - 1, 0)))); } else { caret = vb_clamp(after); }
        vm_sel(caret, 0);
        return;
    }
    if op == 'c' {
        vm_store(t, lw, reg);
        var rep: u8[>..] = [];
        if lw {
            // Keep the line break and the indentation.
            vb_indent(rep, lo);
            if has_suffix(t, "\n") { hi--; }
        }
        VMODE = M_INSERT;
        VINS.clear();
        VPLAST = 0;
        VOP = 0;
        vm_edit1(lo, hi, rep);
        vm_sel(lo + char_count(rep), 0);
        return;
    }
    if op == '>' || op == '<' {
        let start_line = vb_line_no(lo);
        let end_line = vb_line_no(max(lo, hi - 1));
        for line in start_line..end_line + 1 {
            let s = vb_line_start_of(line);
            if op == '>' {
                if vb_le(s) > s { ed_add(s, s, "    "); }
            } else {
                var k = s;
                while k < VCH.len && k < s + 4 && VCH[k] == ' ' { k++; }
                if k == s && k < VCH.len && VCH[k] == '\t' { k++; }
                if k > s { ed_add(s, k, ""); }
            }
        }
        vm_finish_change();
        let first = vb_line_start_of(start_line);
        ed_apply(0);
        vm_sel(first, 0);
        return;
    }
    vm_clear_pending();
}

fn vm_enter_insert(at: i64) {
    VMODE = M_INSERT;
    VINS.clear();
    VCOUNT = -1;
    VPLAST = 0;
    vm_sel(at, 0);
}

fn vm_replace_char(c: i64, cursor: i64) {
    let n = vm_cnt1();
    let end = cursor + n;
    if end > vb_le(cursor) { vm_clear_pending(); VREC.clear(); return; }
    var rep: u8[>..] = [];
    for _ in n { vm_put_cp(rep, c); }
    vm_finish_change();
    vm_edit1(cursor, end, rep);
    vm_sel(end - 1, 0);
}

fn vm_join(cursor: i64, count: i64, spaces: bool) {
    var line = vb_line_no(cursor);
    var caret = cursor;
    let n = VCH.len;
    for _ in count - 1 {
        let ls = vb_line_start_of(line);
        let end = vb_le(ls);
        if end >= n { break; }
        var next = end + 1;
        if spaces { while next < n && (VCH[next] == ' ' || VCH[next] == '\t') { next++; } }
        let space = spaces && end > ls && next < n && VCH[next] != '\n' && VCH[next] != ')';
        if space { ed_add(end, next, " "); } else { ed_add(end, next, ""); }
        caret = end;
        line++;
    }
    if VED.len == 0 { vm_clear_pending(); VREC.clear(); return; }
    vm_finish_change();
    let at = ed_apply(caret);
    vm_sel(at, 0);
}

fn vm_put(after: bool, cursor: i64, n: i64) {
    var t: u8[>..] = [];
    var lw = VUNLW;
    if VREG == '+' || VREG == '*' {
        t.append(VCLIPIN);
        lw = has_suffix(t, "\n");
    } else {
        t.append(VUN);
    }
    if t.len == 0 { vm_clear_pending(); VREC.clear(); return; }
    var content: u8[>..] = [];
    for _ in n { content.append(t); }
    vm_finish_change();
    if lw {
        var ins: u8[>..] = [];
        var at = 0;
        if after {
            at = vb_leb(cursor);
            if at == VCH.len && !(VCH.len > 0 && VCH[VCH.len - 1] == '\n') {
                ins.push('\n');
                var drop = 0;
                if has_suffix(content, "\n") { drop = 1; }
                ins.append(content[..content.len - drop]);
            } else {
                ins.append(content);
            }
        } else {
            at = vb_ls(cursor);
            ins.append(content);
        }
        var off = 0;
        if ins.len > 0 && ins[0] == '\n' { off = 1; }
        vm_edit1(at, at, ins);
        vm_sel(at + off, 0);
        return;
    }
    var at = cursor;
    if after && !vb_is_le(cursor) { at = cursor + 1; }
    let cc = char_count(content);
    vm_edit1(at, at, content);
    vm_sel(at + max(0, cc - 1), 0);
}

fn vm_repeat(cursor: i64) {
    VREPKEYS.clear();
    for j in VLASTKEYS.len { VREPKEYS.push(VLASTKEYS[j]); }
    var inserted: u8[>..] = [];
    inserted.append(VLASTINS);
    vm_clear_pending();
    VREC.clear();
    if VREPKEYS.len == 0 { return; }
    VREPLAY = true;
    vm_sel_block(cursor);
    for j in VREPKEYS.len { vm_handle(VREPKEYS[j]); }
    if VMODE == M_INSERT {
        let at = VSELLOC;
        vm_edit1(at, at, inserted);
        VMODE = M_NORMAL;
        let c = at + char_count(inserted);
        vm_sel_block(max(vb_ls(c), c - 1));
    }
    VREPLAY = false;
    // Swift keeps only the edits and the selection of the replayed keys.
    VMSG.clear();
    VACTION = ACT_NONE;
    VCLIPOUT.clear();
}

fn vm_toggle_text(out: u8[>..]&, lo: i64, hi: i64, how: i64) {
    for k in lo..hi {
        let c = VCH[k];
        if how == 0 { vm_put_cp(out, vch_toggle(c)); }
        else if how == 1 { vm_put_cp(out, vch_lower(c)); }
        else { vm_put_cp(out, vch_upper(c)); }
    }
}

fn vm_normal(k: VKey, cursor: i64) {
    if !VREPLAY { VREC.push(k); }
    if k.sp == SP_ESC {
        vm_clear_pending();
        VREC.clear();
        vm_sel_block(cursor);
        return;
    }
    if k.ctrl {
        let n = vm_cnt1();
        vm_clear_pending();
        VREC.clear();
        let c = k.ch;
        if c == 'r' { vm_undo(n, true); }
        else if c == 'd' { vm_sel_block(vb_move_lines(cursor, 15 * n, -1)); }
        else if c == 'u' { vm_sel_block(vb_move_lines(cursor, -15 * n, -1)); }
        else if c == 'f' { vm_sel_block(vb_move_lines(cursor, 30 * n, -1)); }
        else if c == 'b' { vm_sel_block(vb_move_lines(cursor, -30 * n, -1)); }
        return;
    }
    if k.sp != 0 {
        if k.sp == SP_LEFT || k.sp == SP_BS { vm_motion_only('h', cursor); }
        else if k.sp == SP_RIGHT { vm_motion_only('l', cursor); }
        else if k.sp == SP_UP { vm_motion_only('k', cursor); }
        else if k.sp == SP_DOWN { vm_motion_only('j', cursor); }
        else if k.sp == SP_ENTER { vm_motion_only('+', cursor); }
        return;
    }
    let c = k.ch;
    VPLAST = c;

    // A character argument for f, t, r, or a text object.
    if VAWAIT != 0 {
        let aw = VAWAIT;
        VAWAIT = 0;
        if aw == 'r' { vm_replace_char(c, cursor); return; }
        if aw == 'i' || aw == 'a' {
            if VOP == 0 || !vb_text_object(c, aw == 'a', cursor) {
                vm_clear_pending();
                VREC.clear();
                vm_msg("This text object is not supported.");
                return;
            }
            vm_apply_op(VOP, VTO_LO, VTO_HI, VTO_LW, cursor);
            return;
        }
        let n = vm_opcnt1() * vm_cnt1();
        VLF_CMD = aw;
        VLF_CH = c;
        let t, ok = vb_find(aw, c, cursor, n, false);
        if !ok { vm_clear_pending(); VREC.clear(); return; }
        vm_motion_result(t, aw == 'f' || aw == 't', false, cursor);
        return;
    }

    if VREGPRE { VREGPRE = false; VREG = c; return; }

    if VGPRE {
        VGPRE = false;
        if c == 'g' {
            let line = vm_cnt1() - 1;
            vm_motion_result(vb_fnb(vb_line_start_of(line)), false, true, cursor);
        } else if c == 'v' {
            if VLV_SET {
                if VLV_LINE { VMODE = M_VLINE; } else { VMODE = M_VISUAL; }
                VANCHOR = min(VLV_A, VCH.len);
                vm_clear_pending();
                vm_visual_sel(min(VLV_B, VCH.len));
                return;
            }
            vm_clear_pending();
        } else if c == 'J' {
            var cnt = 2;
            if VCOUNT >= 0 { cnt = VCOUNT; }
            vm_join(cursor, max(2, cnt), false);
        } else {
            vm_clear_pending();
            VREC.clear();
            VMSG.clear();
            VMSG.push('g');
            vm_put_cp(VMSG, c);
            VMSG.append(" is not supported.");
        }
        return;
    }

    // Counts.
    if vch_digit(c) && !(c == '0' && VCOUNT < 0) {
        VCOUNT = max(VCOUNT, 0) * 10 + (c - '0');
        return;
    }

    // Operators.
    if VOP != 0 {
        if c == VOP {
            // dd, cc, yy, >>, <<: whole lines.
            let n = vm_opcnt1() * vm_cnt1();
            let start = vb_ls(cursor);
            let last_line = vb_move_lines(cursor, n - 1, -1);
            let end = vb_leb(last_line);
            vm_apply_op(VOP, start, end, true, cursor);
            return;
        }
        if c == 'i' || c == 'a' { VAWAIT = c; return; }
    }
    if (c == 'd' || c == 'c' || c == 'y' || c == '<' || c == '>') && VOP == 0 {
        VOP = c;
        VOPCOUNT = VCOUNT;
        VCOUNT = -1;
        return;
    }

    if c == '"' { VREGPRE = true; return; }
    if c == 'g' { VGPRE = true; return; }
    if c == 'f' || c == 'F' || c == 't' || c == 'T' || c == 'r' { VAWAIT = c; return; }
    if c == ';' || c == ',' {
        if VLF_CMD == 0 { vm_clear_pending(); return; }
        var cmd = VLF_CMD;
        if c == ',' {
            if cmd == 'f' { cmd = 'F'; } else if cmd == 'F' { cmd = 'f'; } else if cmd == 't' { cmd = 'T'; } else { cmd = 't'; }
        }
        let t, ok = vb_find(cmd, VLF_CH, cursor, vm_cnt1(), true);
        if !ok { vm_clear_pending(); VREC.clear(); return; }
        vm_motion_result(t, cmd == 'f' || cmd == 't', false, cursor);
        return;
    }

    if c == 'G' && VCOUNT >= 0 {
        VDESCOL = -1;
        vm_motion_result(vb_fnb(vb_line_start_of(VCOUNT - 1)), false, true, cursor);
        return;
    }
    var mcount = vm_cnt1();
    if VOP != 0 { mcount = vm_opcnt1() * vm_cnt1(); }
    let m = vb_motion(c, cursor, mcount, VDESCOL);
    if m.ok {
        vm_set_desired(m.vert, cursor);
        if m.msg && m.t == cursor {
            vm_clear_pending();
            VREC.clear();
            VMSG.clear();
            VMSG.append(VMO_MSG);
            return;
        }
        if c == '*' || c == '#' {
            VLS_SET = m.srch;
            if m.srch { VLS.clear(); VLS.append(VMO_SRCH); VLS_FWD = VMO_FWD; }
        }
        vm_motion_result(m.t, m.incl, m.lw, cursor);
        if m.msg { VMSG.clear(); VMSG.append(VMO_MSG); }
        return;
    }

    // Commands without a motion.
    if VOP != 0 { vm_clear_pending(); VREC.clear(); return; }
    let n = vm_cnt1();
    if c == 'i' { vm_enter_insert(cursor); return; }
    if c == 'a' {
        var x = 1;
        if vb_is_le(cursor) { x = 0; }
        vm_enter_insert(min(cursor + x, VCH.len));
        return;
    }
    if c == 'I' { vm_enter_insert(vb_fnb(vb_ls(cursor))); return; }
    if c == 'A' { vm_enter_insert(vb_le(cursor)); return; }
    if c == 'o' || c == 'O' {
        var at = vb_ls(cursor);
        if c == 'o' { at = vb_le(cursor); }
        var indent: u8[>..] = [];
        vb_indent(indent, cursor);
        var ins: u8[>..] = [];
        if c == 'o' { ins.push('\n'); ins.append(indent); } else { ins.append(indent); ins.push('\n'); }
        VMODE = M_INSERT;
        VINS.clear();
        var x = 0;
        if c == 'o' { x = 1; }
        let loc = at + x + char_count(indent);
        VPLAST = 0;
        vm_edit1(at, at, ins);
        vm_sel(loc, 0);
        return;
    }
    if c == 'x' {
        if vb_is_le(cursor) { vm_clear_pending(); VREC.clear(); return; }
        let end = min(vb_le(cursor), cursor + n);
        vm_apply_op('d', cursor, end, false, cursor);
        return;
    }
    if c == 'X' {
        let start = max(vb_ls(cursor), cursor - n);
        if start >= cursor { vm_clear_pending(); VREC.clear(); return; }
        vm_apply_op('d', start, cursor, false, cursor);
        return;
    }
    if c == 's' {
        let end = min(vb_le(cursor), cursor + n);
        vm_apply_op('c', cursor, end, false, cursor);
        return;
    }
    if c == 'S' {
        let start = vb_fnb(vb_ls(cursor));
        let end = vb_le(vb_move_lines(cursor, n - 1, -1));
        vm_apply_op('c', start, end, false, cursor);
        return;
    }
    if c == 'D' || c == 'C' {
        let end = vb_le(vb_move_lines(cursor, n - 1, -1));
        var op = 'c';
        if c == 'D' { op = 'd'; }
        vm_apply_op(op, cursor, end, false, cursor);
        return;
    }
    if c == 'Y' {
        let start = vb_ls(cursor);
        let end = vb_leb(vb_move_lines(cursor, n - 1, -1));
        vm_apply_op('y', start, end, true, cursor);
        return;
    }
    if c == 'J' { vm_join(cursor, max(2, n), true); return; }
    if c == '~' {
        let end = min(vb_le(cursor), cursor + n);
        if cursor >= end { vm_clear_pending(); VREC.clear(); return; }
        var t: u8[>..] = [];
        vm_toggle_text(t, cursor, end, 0);
        let cc = char_count(t);
        vm_finish_change();
        vm_edit1(cursor, end, t);
        vm_sel(cursor + cc, 0);
        return;
    }
    if c == 'p' || c == 'P' { vm_put(c == 'p', cursor, n); return; }
    if c == 'u' {
        vm_clear_pending();
        VREC.clear();
        vm_undo(n, false);
        return;
    }
    if c == '.' { VWANT_REPEAT = true; return; }
    if c == 'v' || c == 'V' {
        if c == 'v' { VMODE = M_VISUAL; } else { VMODE = M_VLINE; }
        VANCHOR = cursor;
        vm_clear_pending();
        VREC.clear();
        vm_visual_sel(cursor);
        return;
    }
    if c == ':' || c == '/' || c == '?' {
        VMODE = M_CMD;
        VPREFIX = c;
        VCMD.clear();
        vm_clear_pending();
        VREC.clear();
        return;
    }
    vm_clear_pending();
    VREC.clear();
}

// ---------------------------------------------------------------------------
// Visual mode

fn vm_visual_sel(cursor: i64) {
    let a = min(VANCHOR, cursor);
    let b = max(VANCHOR, cursor);
    if VMODE == M_VLINE {
        let s = vb_ls(a);
        let e = vb_leb(b);
        vm_sel(s, e - s);
        return;
    }
    let e = min(VCH.len, b + 1);
    vm_sel(a, e - a);
}

fn vm_visual_cursor() -> i64 {
    let start = VSELLOC;
    let end = VSELLOC + VSELLEN;
    // The cursor is the end away from the anchor.
    if VMODE == M_VLINE {
        if start == vb_ls(VANCHOR) || start < VANCHOR {
            if start < VANCHOR { return start; }
            return max(start, end - 1);
        }
        return start;
    }
    if start < VANCHOR { return start; }
    return max(start, end - 1);
}

fn vm_visual(k: VKey, cursor: i64) {
    let lw = VMODE == M_VLINE;
    let a = min(VANCHOR, cursor);
    let b = max(VANCHOR, cursor);
    var rlo = a;
    var rhi = min(VCH.len, b + 1);
    if lw { rlo = vb_ls(a); rhi = vb_leb(b); }
    fn exit_visual() {
        VLV_A = VANCHOR;
        VLV_B = cursor;
        VLV_LINE = lw;
        VLV_SET = true;
        VMODE = M_NORMAL;
    }
    if k.sp == SP_ESC {
        exit_visual();
        vm_clear_pending();
        vm_sel_block(vb_clamp(cursor));
        return;
    }
    if k.sp != 0 {
        var c = 0;
        if k.sp == SP_LEFT { c = 'h'; } else if k.sp == SP_RIGHT { c = 'l'; } else if k.sp == SP_UP { c = 'k'; } else if k.sp == SP_DOWN { c = 'j'; }
        if c == 0 { return; }
        let m = vb_motion(c, cursor, 1, VDESCOL);
        if !m.ok { return; }
        vm_visual_sel(m.t);
        return;
    }
    let c = k.ch;
    if VAWAIT != 0 {
        let aw = VAWAIT;
        VAWAIT = 0;
        if aw == 'i' || aw == 'a' {
            if vb_text_object(c, aw == 'a', cursor) {
                VANCHOR = VTO_LO;
                vm_visual_sel(max(VTO_LO, VTO_HI - 1));
            }
            return;
        }
        if aw == 'r' {
            var t: u8[>..] = [];
            for j in rlo..rhi { if VCH[j] == '\n' { t.push('\n'); } else { vm_put_cp(t, c); } }
            exit_visual();
            vm_finish_change();
            vm_edit1(rlo, rhi, t);
            vm_sel(rlo, 0);
            return;
        }
        let t, ok = vb_find(aw, c, cursor, vm_cnt1(), false);
        if !ok { return; }
        VLF_CMD = aw;
        VLF_CH = c;
        VCOUNT = -1;
        vm_visual_sel(t);
        return;
    }
    if vch_digit(c) && !(c == '0' && VCOUNT < 0) {
        VCOUNT = max(VCOUNT, 0) * 10 + (c - '0');
        return;
    }
    if VGPRE {
        VGPRE = false;
        if c == 'g' { vm_visual_sel(vb_line_start_of(vm_cnt1() - 1)); }
        return;
    }
    if c == 'o' {
        let other = VANCHOR;
        VANCHOR = cursor;
        vm_visual_sel(other);
        return;
    }
    if c == 'v' || c == 'V' {
        var target = M_VISUAL;
        if c == 'V' { target = M_VLINE; }
        if VMODE == target { exit_visual(); vm_sel_block(vb_clamp(cursor)); return; }
        VMODE = target;
        vm_visual_sel(cursor);
        return;
    }
    if c == 'g' { VGPRE = true; return; }
    if c == 'i' || c == 'a' || c == 'f' || c == 'F' || c == 't' || c == 'T' || c == 'r' { VAWAIT = c; return; }
    if c == '"' { VREGPRE = true; return; }
    if c == 'd' || c == 'x' || c == 'c' || c == 's' || c == 'y' || c == '>' || c == '<' ||
       c == 'D' || c == 'X' || c == 'Y' || c == 'C' || c == 'S' {
        var lo = rlo;
        var hi = rhi;
        var l = lw;
        if c == 'D' || c == 'X' || c == 'Y' || c == 'C' || c == 'S' {
            lo = vb_ls(a);
            hi = vb_leb(b);
            l = true;
        }
        var op = c;
        if c == 'x' || c == 'd' || c == 'D' || c == 'X' { op = 'd'; }
        else if c == 'c' || c == 's' || c == 'C' || c == 'S' { op = 'c'; }
        else if c == 'y' || c == 'Y' { op = 'y'; }
        exit_visual();
        VREC.clear();
        vm_apply_op(op, lo, hi, l, a);
        return;
    }
    if c == '~' || c == 'u' || c == 'U' {
        var t: u8[>..] = [];
        var how = 0;
        if c == 'u' { how = 1; } else if c == 'U' { how = 2; }
        vm_toggle_text(t, rlo, rhi, how);
        exit_visual();
        vm_finish_change();
        vm_edit1(rlo, rhi, t);
        vm_sel(rlo, 0);
        return;
    }
    if c == 'J' {
        let la = vb_line_no(a);
        let lb = vb_line_no(b);
        exit_visual();
        vm_join(vb_line_start_of(la), max(2, lb - la + 1), true);
        return;
    }
    if c == 'p' || c == 'P' {
        var t: u8[>..] = [];
        if VREG == '+' || VREG == '*' { t.append(VCLIPIN); } else { t.append(VUN); }
        var replaced: u8[>..] = [];
        vb_str(replaced, rlo, rhi);
        exit_visual();
        vm_finish_change();
        VUN.clear();
        VUN.append(replaced);
        VUNLW = lw;
        vm_edit1(rlo, rhi, t);
        vm_sel(rlo, 0);
        return;
    }
    if c == ':' {
        VLV_A = VANCHOR;
        VLV_B = cursor;
        VLV_LINE = lw;
        VLV_SET = true;
        VMODE = M_CMD;
        VPREFIX = ':';
        VCMD.clear();
        VCMD.append("'<,'>");
        return;
    }
    let m = vb_motion(c, cursor, vm_cnt1(), VDESCOL);
    if m.ok {
        vm_set_desired(m.vert, cursor);
        VCOUNT = -1;
        vm_visual_sel(min(m.t, max(VCH.len - 1, 0)));
    }
}

// ---------------------------------------------------------------------------
// The command line and the Ex commands

fn vm_cmdline(k: VKey, cursor: i64) {
    if k.sp == SP_ESC || (k.ctrl && k.ch == 'c') {
        VMODE = M_NORMAL;
        VCMD.clear();
        vm_sel_block(vb_clamp(cursor));
        return;
    }
    if k.sp == SP_BS {
        if VCMD.len == 0 { VMODE = M_NORMAL; return; }
        var n = VCMD.len - 1;
        while n > 0 && (VCMD[n] & 0xC0) == 0x80 { n--; }
        VCMD.resize(n);
        return;
    }
    if k.sp == SP_ENTER {
        var line: u8[>..] = [];
        line.append(VCMD);
        VCMD.clear();
        VMODE = M_NORMAL;
        if VPREFIX == '/' || VPREFIX == '?' {
            var pat: u8[>..] = [];
            if line.len == 0 { if VLS_SET { pat.append(VLS); } } else { pat.append(line); }
            if pat.len == 0 { return; }
            VLS.clear();
            VLS.append(pat);
            VLS_SET = true;
            VLS_FWD = VPREFIX == '/';
            let m = vb_motion('n', cursor, 1, -1);
            if !m.ok { return; }
            vm_sel_block(m.t);
            if m.msg { VMSG.clear(); VMSG.append(VMO_MSG); }
            return;
        }
        vm_ex(line, cursor);
        return;
    }
    if k.sp == 0 && !k.ctrl { vm_put_cp(VCMD, k.ch); }
    else if k.sp == SP_TAB { VCMD.push('\t'); }
}

fn vm_is_alnum_cp(c: i64) -> bool { vch_letter(c) || vch_digit(c) }

// The text after a command name (substitute or s), or false.
fn vm_sub_arg(t: u8[:]) -> u8[:], bool {
    if has_prefix(t, "substitute") { return t[10..], true; }
    if has_prefix(t, "s") { return t[1..], true; }
    return t[..0], false;
}

var VRANGE_LO = 0;
var VRANGE_HI = 0;

// Parses an Ex range such as %, .,$, 3,7, '<,'>, .,+2 or /pattern/.
// Returns the index after the range, whether there is a range, and false on
// an error (the message is in VMSG).
fn vm_parse_range(s: u8[:], cursor: i64) -> i64, bool, bool {
    var p = 0;
    let current = vb_line_no(cursor);
    let last = max(0, vb_line_count() - 1);
    if has_prefix(s, "%") { VRANGE_LO = 0; VRANGE_HI = last; return 1, true, true; }
    var failed = false;

    fn address() -> i64, bool {
        var base = 0;
        var has = false;
        let r = s[p..];
        if has_prefix(r, ".") { base = current; has = true; p++; }
        else if has_prefix(r, "$") { base = last; has = true; p++; }
        else if (has_prefix(r, "'<") || has_prefix(r, "'>")) && VLV_SET {
            if has_prefix(r, "'<") { base = vb_line_no(min(VLV_A, VLV_B)); } else { base = vb_line_no(max(VLV_A, VLV_B)); }
            has = true;
            p += 2;
        } else if r.len > 0 && is_digit(r[0]) {
            var v = 0;
            while p < s.len && is_digit(s[p]) { v = v * 10 + (s[p] - '0'); p++; }
            base = max(0, v - 1);
            has = true;
        } else if has_prefix(r, "/") || has_prefix(r, "?") {
            let forward = r[0] == '/';
            let delim = r[0];
            p++;
            var pat: u8[>..] = [];
            while p < s.len && s[p] != delim {
                if s[p] == '\\' && p + 1 < s.len && s[p + 1] == delim { pat.push(delim); p += 2; continue; }
                pat.push(s[p]);
                p++;
            }
            if p < s.len && s[p] == delim { p++; }
            if pat.len == 0 && VLS_SET { pat.append(VLS); }
            let ls = vb_line_start_of(current);
            var from = ls;
            if forward { from = vb_le(ls); }
            let hit, st = vb_search(pat, from, forward);
            if st == 2 { VMSG.clear(); VMSG.append(VRE_ERR); failed = true; return 0, false; }
            if st == 0 {
                VMSG.clear();
                VMSG.append("Pattern not found: ");
                VMSG.append(pat);
                failed = true;
                return 0, false;
            }
            base = vb_line_no(hit);
            has = true;
        }
        // Offsets: +n, -n, or a bare + or -.
        while p < s.len && (s[p] == '+' || s[p] == '-') {
            let plus = s[p] == '+';
            p++;
            var v = 0;
            var digits = 0;
            while p < s.len && is_digit(s[p]) { v = v * 10 + (s[p] - '0'); p++; digits++; }
            if digits == 0 { v = 1; }
            if !has { base = current; has = true; }
            if plus { base += v; } else { base -= v; }
        }
        if !has { return 0, false; }
        return max(0, min(base, last)), true;
    }

    let a, ha = address();
    if failed { return 0, false, false; }
    if !ha { return p, false, true; }
    if p < s.len && (s[p] == ',' || s[p] == ';') {
        p++;
        var b, hb = address();
        if failed { return 0, false, false; }
        if !hb { b = a; }
        VRANGE_LO = min(a, b);
        VRANGE_HI = max(a, b);
        return p, true, true;
    }
    VRANGE_LO = a;
    VRANGE_HI = a;
    return p, true, true;
}

fn vm_count_msg(n: i64, one: u8[:], many: u8[:]) {
    VMSG.clear();
    if n == 1 { VMSG.append(one); return; }
    format(VMSG, n);
    VMSG.append(many);
}

// Deletes the lines in the list (ascending).
fn vm_delete_lines(lines: i64[:]) {
    if lines.len == 0 { return; }
    var nb: u8[>..] = [];
    var line = 0;
    var li = 0;
    var removed = 0;
    var first = true;
    var start = 0;
    var b = 0;
    // The parts of the text between line breaks, as components(separatedBy:).
    while b <= VTXT.len {
        if b == VTXT.len || VTXT[b] == '\n' {
            while li < lines.len && lines[li] < line { li++; }
            let drop = li < lines.len && lines[li] == line;
            if drop { removed++; } else {
                if !first { nb.push('\n'); }
                nb.append(VTXT[start..b]);
                first = false;
            }
            line++;
            start = b + 1;
        }
        b++;
    }
    let first_line = lines[0];
    VTXT.clear();
    VTXT.append(nb);
    vb_load();
    let fl = max(0, min(first_line, vb_line_count() - 1));
    vm_sel(vb_fnb(vb_line_start_of(fl)), 0);
    vm_count_msg(removed, "1 line deleted.", " lines deleted.");
}

// Parses spec as /pattern/replacement/flags into the three buffers.
// Returns false when the spec has fewer than two parts.
fn vm_sub_parse(spec: u8[:], pat: u8[>..]&, rep: u8[>..]&, flags: u8[>..]&) -> bool {
    let dl = utf8_len(spec[0]);
    var d: u8[..4] = [];
    for j in min(dl, spec.len) { d.push(spec[j]); }
    var parts = 0;
    var cur: u8[>..] = [];
    var i = d.len;
    while i < spec.len {
        if spec[i] == '\\' && i + 1 < spec.len {
            let nl = min(utf8_len(spec[i + 1]), spec.len - i - 1);
            if spec[i + 1..i + 1 + nl] == d[..] { cur.append(d); } else { cur.push('\\'); cur.append(spec[i + 1..i + 1 + nl]); }
            i += 1 + nl;
            continue;
        }
        if parts < 2 && has_prefix(spec[i..], d) {
            if parts == 0 { pat.append(cur); } else { rep.append(cur); }
            cur.clear();
            parts++;
            i += d.len;
            continue;
        }
        cur.push(spec[i]);
        i++;
    }
    if parts == 0 { pat.append(cur); }
    else if parts == 1 { rep.append(cur); }
    else { flags.append(trim_sp(cur)); }
    return parts + 1 >= 2;
}

let SUB_DONE = 0;
let SUB_NONE = 1;
let SUB_MSG = 2;

var VSUB_COUNT = 0;
var VSUB_LINES = 0;
var VSUB_LAST = 0;

// :s/pattern/replacement/flags on the lines lo..hi. Adds the edits to VED.
// Returns SUB_DONE with edits, SUB_NONE (nothing to do, VMSG may have a
// message), or SUB_MSG (only a message: the n flag or an error).
fn vm_substitute(spec: u8[:], lo: i64, hi: i64) -> i64 {
    var pat: u8[>..] = [];
    var rep: u8[>..] = [];
    var flags: u8[>..] = [];
    if trim_sp(spec).len == 0 {
        // :s alone repeats the last substitute without its flags.
        if !VLSUB_SET { vm_msg("No previous substitute."); return SUB_MSG; }
        pat.append(VLSUB_PAT);
        rep.append(VLSUB_REP);
    } else {
        var p0: u8[>..] = [];
        if !vm_sub_parse(spec, p0, rep, flags) { vm_msg("Write the command as :s/pattern/replacement/"); return SUB_MSG; }
        if p0.len == 0 { if VLS_SET { pat.append(VLS); } } else { pat.append(p0); }
        if has_prefix(flags, "&") {
            var f2: u8[>..] = [];
            f2.append(flags[1..]);
            if VLSUB_SET { f2.append(VLSUB_FLAGS); }
            flags.clear();
            flags.append(f2);
        }
    }
    if contains_byte(flags, 'c') {
        vm_msg("Marklove does not ask about each change. Remove the c flag, or use / and n to check each match first.");
        return SUB_MSG;
    }
    var ign = -1;
    if contains_byte(flags, 'i') { ign = 1; } else if contains_byte(flags, 'I') { ign = 0; }
    if !vre_compile(pat, ign, false) { VMSG.clear(); VMSG.append(VRE_ERR); return SUB_MSG; }
    var prev: u8[>..] = [];
    let has_prev = VLREP_SET;
    prev.append(VLREP);
    VLSUB_PAT.clear(); VLSUB_PAT.append(pat);
    VLSUB_REP.clear(); VLSUB_REP.append(rep);
    VLSUB_FLAGS.clear(); VLSUB_FLAGS.append(flags);
    VLSUB_SET = true;
    VLS.clear(); VLS.append(pat);
    VLS_SET = true;
    VLS_FWD = true;
    let first_start = vb_line_start_of(lo);
    let last_end = vb_le(vb_line_start_of(hi));
    let global = contains_byte(flags, 'g');
    let ed0 = VED.len;
    var count = 0;
    var lines = 0;
    var last_line = lo;
    var seen_line = -1;
    // The line of position `at`, counted from first_start.
    var line = lo;
    var lpos = first_start;
    let n = VCH.len;
    vre_budget();
    var pos = first_start;
    var piece: u8[>..] = [];
    while pos <= n {
        if !vre_find(first_start, n, pos) { break; }
        pos = vre_next_pos();
        let ms = VRM_S;
        if ms > last_end { break; }
        while lpos < ms { if VCH[lpos] == '\n' { line++; } lpos++; }
        if line < lo || line > hi { continue; }
        if !global && seen_line == line { continue; }
        piece.clear();
        vre_expand(piece, rep, prev, has_prev);
        if count >= MAX_MATCHES || VEDB.len + piece.len > MAX_TEXT {
            VED.resize(ed0);
            vm_msg("The change is too large. Make a smaller change.");
            return SUB_MSG;
        }
        ed_add(ms, VRM_E, piece);
        count++;
        if seen_line != line { lines++; }
        seen_line = line;
        last_line = line;
    }
    if VRE_OVER { VED.resize(ed0); vre_too_complex(); VMSG.clear(); VMSG.append(VRE_ERR); return SUB_MSG; }
    VLREP.clear();
    VLREP.append(rep);
    VLREP_SET = true;
    if count == 0 {
        if !contains_byte(flags, 'e') {
            VMSG.clear();
            VMSG.append("Pattern not found: ");
            VMSG.append(pat);
        }
        return SUB_NONE;
    }
    VMSG.clear();
    if contains_byte(flags, 'n') { VMSG.append("Matches: "); } else { VMSG.append("Substitutions: "); }
    format(VMSG, count);
    VMSG.append(". Lines: ");
    format(VMSG, lines);
    VMSG.append(".");
    if contains_byte(flags, 'n') { VED.resize(ed0); return SUB_MSG; }
    vm_finish_change();
    VSUB_COUNT = count;
    VSUB_LINES = lines;
    VSUB_LAST = last_line;
    return SUB_DONE;
}

fn vm_sub_run(spec: u8[:], lo: i64, hi: i64) {
    VED.clear();
    VEDB.clear();
    if vm_substitute(spec, lo, hi) != SUB_DONE { return; }
    let caret = vb_fnb(vb_line_start_of(VSUB_LAST));
    // Apply the edits, then put the caret on the last changed line.
    let at = ed_apply(caret);
    vm_sel(at, 0);
}

// :g/pattern/cmd and :v/pattern/cmd. The command is d, s/…/…/, or nothing.
fn vm_global(spec: u8[:], invert: bool, lo: i64, hi: i64) {
    if spec.len == 0 { vm_msg("Write the command as :g/pattern/command"); return; }
    let dl = min(utf8_len(spec[0]), spec.len);
    var d: u8[..4] = [];
    for j in dl { d.push(spec[j]); }
    var pat: u8[>..] = [];
    var i = dl;
    while i < spec.len && !has_prefix(spec[i..], d) {
        if spec[i] == '\\' && i + 1 < spec.len && has_prefix(spec[i + 1..], d) { pat.append(d); i += 1 + dl; continue; }
        pat.push(spec[i]);
        i++;
    }
    if i < spec.len { i += dl; }
    var rest: u8[>..] = [];
    rest.append(trim_sp(spec[i..]));
    if pat.len == 0 && VLS_SET { pat.append(VLS); }
    if !vre_compile(pat, -1, true) { VMSG.clear(); VMSG.append(VRE_ERR); return; }
    VLS.clear(); VLS.append(pat);
    VLS_SET = true;
    VLS_FWD = true;
    var marked: i64[>..] = [];
    vre_budget();
    for line in lo..hi + 1 {
        let s = vb_line_start_of(line);
        let e = vb_le(s);
        let hit = vre_find(s, e, s);
        if hit != invert { marked.push(line); }
    }
    if VRE_OVER { vre_too_complex(); VMSG.clear(); VMSG.append(VRE_ERR); return; }
    if rest.len == 0 || rest == "p" || rest == "print" {
        vm_count_msg(marked.len, "1 matching line.", " matching lines.");
        return;
    }
    if marked.len == 0 {
        VMSG.clear();
        VMSG.append("Pattern not found: ");
        VMSG.append(pat);
        return;
    }
    if rest == "d" || rest == "delete" { vm_delete_lines(marked); return; }
    let sub, is_sub = vm_sub_arg(rest);
    if is_sub {
        var spec2: u8[>..] = [];
        spec2.append(sub);
        VED.clear();
        VEDB.clear();
        var count = 0;
        for line in marked {
            let before = VED.len;
            let r = vm_substitute(spec2, line, line);
            if r == SUB_DONE { count += VED.len - before; }
        }
        if VED.len == 0 { vm_msg("Pattern not found."); return; }
        let caret = vb_fnb(vb_line_start_of(marked[marked.len - 1]));
        let at = ed_apply(caret);
        vm_sel(at, 0);
        VMSG.clear();
        VMSG.append("Substitutions: ");
        format(VMSG, count);
        VMSG.append(". Lines: ");
        format(VMSG, marked.len);
        VMSG.append(".");
        return;
    }
    vm_msg("Marklove supports :g with d and s.");
}

fn vm_ex(raw: u8[:], cursor: i64) {
    var cmd: u8[>..] = [];
    cmd.append(trim_sp(raw));
    if cmd.len == 0 { return; }
    if has_prefix(cmd, "!") || has_prefix(cmd, "r !") || has_prefix(cmd, "r!") || has_prefix(cmd, "sh") || has_prefix(cmd, "term") {
        vm_msg("Shell commands are not available in Marklove.");
        return;
    }
    // Marklove saves each change at once. :w also saves a version in the history.
    if cmd == "w" || cmd == "w!" || cmd == "update" || cmd == "wq" || cmd == "x" || cmd == "wq!" || cmd == "x!" {
        VACTION = ACT_SAVE;
        vm_msg("Saved a version.");
        return;
    }
    if cmd == "q" { vm_msg("Marklove saves each change. The document stays open."); return; }
    if cmd == "q!" || cmd == "e!" {
        VACTION = ACT_DISCARD;
        vm_msg("Back to the last version.");
        return;
    }
    if cmd == "noh" || cmd == "nohlsearch" { return; }
    if cmd == "$" { vm_sel_block(vb_fnb(vb_line_start_of(vb_line_count() - 1))); return; }
    let num, isnum = parse_int(cmd);
    if isnum { vm_sel_block(vb_fnb(vb_line_start_of(max(0, num - 1)))); return; }
    // A range, then the command.
    let p, has_range, ok = vm_parse_range(cmd, cursor);
    if !ok { return; }
    let current = vb_line_no(cursor);
    var lo = current;
    var hi = current;
    if has_range { lo = VRANGE_LO; hi = VRANGE_HI; }
    var rest: u8[>..] = [];
    rest.append(trim_sp(cmd[p..]));
    if rest.len == 0 && has_range { vm_sel_block(vb_fnb(vb_line_start_of(hi))); return; }
    let spec, is_sub = vm_sub_arg(rest);
    if is_sub {
        var good = spec.len == 0;
        if !good {
            let c0, l0 = vm_cp_at(spec, 0);
            good = !(vm_is_alnum_cp(c0) || c0 == ' ');
        }
        if good {
            var sp: u8[>..] = [];
            sp.append(spec);
            vm_sub_run(sp, lo, hi);
            return;
        }
    }
    if rest == "&" || rest == "&&" || rest == "~" {
        if !VLSUB_SET { vm_msg("No previous substitute."); return; }
        var sp: u8[>..] = [];
        sp.push('/'); sp.append(VLSUB_PAT); sp.push('/'); sp.append(VLSUB_REP); sp.push('/');
        if rest == "&&" { sp.append(VLSUB_FLAGS); }
        vm_sub_run(sp, lo, hi);
        return;
    }
    if rest == "d" || rest == "delete" {
        var lines: i64[>..] = [];
        for l in lo..hi + 1 { lines.push(l); }
        vm_delete_lines(lines);
        return;
    }
    if has_prefix(rest, "g!") || has_prefix(rest, "global!") || (has_prefix(rest, "v") && !has_prefix(rest, "vi")) ||
       (has_prefix(rest, "g") && !has_prefix(rest, "go")) {
        let invert = has_prefix(rest, "g!") || has_prefix(rest, "global!") || has_prefix(rest, "v");
        var j = 0;
        while j < rest.len && is_alpha(rest[j]) { j++; }
        if j < rest.len && rest[j] == '!' { j++; }
        var spec2: u8[>..] = [];
        spec2.append(rest[j..]);
        var glo = 0;
        var ghi = max(0, vb_line_count() - 1);
        if has_range { glo = lo; ghi = hi; }
        vm_global(spec2, invert, glo, ghi);
        return;
    }
    if has_prefix(rest, "set") { vm_msg("Marklove does not support :set. Use Settings > Editor."); return; }
    VMSG.clear();
    VMSG.append("Not an editor command: ");
    VMSG.append(cmd);
}

// ---------------------------------------------------------------------------
// Entry points

fn vm_handle(k: VKey) {
    let cursor = VSELLOC;
    if VMODE == M_INSERT {
        if k.sp == SP_ESC || (k.ctrl && (k.ch == '[' || k.ch == 'c')) {
            VMODE = M_NORMAL;
            if !VREPLAY {
                VLASTINS.clear();
                VLASTINS.append(VINS);
                if VREC.len > 0 {
                    VLASTKEYS.clear();
                    for j in VREC.len { VLASTKEYS.push(VREC[j]); }
                }
                VREC.clear();
            }
            VINS.clear();
            // The cursor moves one left when leaving Insert mode, as in Vim.
            var c = cursor;
            if c > vb_ls(c) { c--; }
            vm_sel_block(c);
        }
        return;
    }
    if VMODE == M_CMD { vm_cmdline(k, cursor); return; }
    if VMODE == M_VISUAL || VMODE == M_VLINE { vm_visual(k, vm_visual_cursor()); return; }
    vm_normal(k, min(cursor, vb_clamp(cursor)));
}

// Reads a key name. Returns false for a name that Vim does not use.
fn vm_parse_key(key: u8[:]) -> VKey, bool {
    var k = VKey { sp: 0, ctrl: false, ch: 0 };
    if key == "Escape" { k.sp = SP_ESC; return k, true; }
    if key == "Enter" { k.sp = SP_ENTER; return k, true; }
    if key == "Backspace" { k.sp = SP_BS; return k, true; }
    if key == "Tab" { k.sp = SP_TAB; return k, true; }
    if key == "ArrowLeft" { k.sp = SP_LEFT; return k, true; }
    if key == "ArrowRight" { k.sp = SP_RIGHT; return k, true; }
    if key == "ArrowUp" { k.sp = SP_UP; return k, true; }
    if key == "ArrowDown" { k.sp = SP_DOWN; return k, true; }
    var t = key;
    if has_prefix(key, "Ctrl-") && key.len > 5 { k.ctrl = true; t = key[5..]; }
    if t.len == 0 { return k, false; }
    let c, l = vm_cp_at(t, 0);
    if l != t.len { return k, false; }
    if k.ctrl && c == '[' { k.ctrl = false; k.sp = SP_ESC; return k, true; }
    if k.ctrl { k.ch = vch_lower(c); } else { k.ch = c; }
    return k, true;
}

// Ctrl keys that the engine uses in each mode. The others go to the browser.
fn vm_ctrl_used(k: VKey) -> bool {
    if VMODE == M_NORMAL { return k.ch == 'r' || k.ch == 'd' || k.ch == 'u' || k.ch == 'f' || k.ch == 'b'; }
    if VMODE == M_CMD { return k.ch == 'c'; }
    if VMODE == M_INSERT { return k.ch == 'c'; }
    return false;
}

fn vim_reset() {
    VMODE = M_NORMAL;
    vm_clear_pending();
    VCMD.clear();
    VUR.clear(); VUB.clear(); VRR.clear(); VRB.clear();
    VLAST.clear();
    VHAVELAST = false;
}

fn vim_clipboard(text: u8[:]) {
    VCLIPIN.clear();
    VCLIPIN.append(text);
}

fn vim_key(out: u8[>..]&, text: u8[:], cursor: i64, sel_start: i64, sel_end: i64, key: u8[:]) {
    VTXT.clear();
    VTXT.append(text);
    vb_load();
    VMSG.clear();
    VACTION = ACT_NONE;
    VCLIPOUT.clear();
    let a = vb_char_at(max(0, min(sel_start, text.len)));
    let b = vb_char_at(max(0, min(sel_end, text.len)));
    vm_sel(min(a, b), abs(b - a));
    var handled = true;
    let k, known = vm_parse_key(key);
    if !known { handled = false; }
    else if VMODE == M_INSERT {
        if k.sp == SP_ESC || (k.ctrl && k.ch == 'c') {
            vm_commit();
            vm_handle(k);
        } else {
            handled = false;
            // Swift: noteInserted and noteDeletedBackward, for . repeat.
            if k.sp == 0 && !k.ctrl { vm_put_cp(VINS, k.ch); }
            else if k.sp == SP_ENTER { VINS.push('\n'); }
            else if k.sp == SP_TAB { VINS.push('\t'); }
            else if k.sp == SP_BS && VINS.len > 0 {
                var n = VINS.len - 1;
                while n > 0 && (VINS[n] & 0xC0) == 0x80 { n--; }
                VINS.resize(n);
            }
        }
    } else if k.ctrl && !vm_ctrl_used(k) {
        handled = false;
    } else {
        vm_commit();
        vm_handle(k);
        if VWANT_REPEAT {
            VWANT_REPEAT = false;
            vm_repeat(VSELLOC);
        }
        if VMODE != M_INSERT { vm_commit(); }
    }

    out.append("{\"handled\":");
    if handled { out.append("true"); } else { out.append("false"); }
    out.append(",\"text\":");
    var same = VTXT.len == text.len;
    if same { for j in text.len { if VTXT[j] != text[j] { same = false; break; } } }
    if same { out.append("null"); } else { json_str(out, VTXT); }
    var cur = VSELLOC;
    if VMODE == M_VISUAL || VMODE == M_VLINE { cur = vm_visual_cursor(); }
    out.append(",\"cursor\":");
    format(out, VOFF[min(cur, VCH.len)]);
    out.append(",\"sel\":[");
    format(out, VOFF[VSELLOC]);
    out.push(',');
    format(out, VOFF[VSELLOC + VSELLEN]);
    out.append("],\"mode\":\"");
    if VMODE == M_NORMAL { out.append("normal"); }
    else if VMODE == M_INSERT { out.append("insert"); }
    else if VMODE == M_VISUAL { out.append("visual"); }
    else if VMODE == M_VLINE { out.append("visual-line"); }
    else { out.append("command"); }
    out.append("\",\"status\":");
    if VMODE == M_CMD {
        var st: u8[>..] = [];
        st.push(VPREFIX as u8);
        st.append(VCMD);
        json_str(out, st);
    } else {
        json_str(out, VMSG);
    }
    out.append(",\"action\":\"");
    if VACTION == ACT_SAVE { out.append("save"); }
    else if VACTION == ACT_DISCARD { out.append("discard"); }
    else if VACTION == ACT_COPY { out.append("copy"); }
    out.push('"');
    if VACTION == ACT_COPY { out.append(",\"clip\":"); json_str(out, VCLIPOUT); }
    out.push('}');
}

// ---------------------------------------------------------------------------
// Find and Replace with Vim patterns, as FindState with the Vim syntax.
// Offsets are UTF-8 byte offsets. The output is the same as edit_find and
// edit_replace. ignore_case is "Match Case" off: then \c, \C and smart case
// decide, as in Swift.

// The last replacement of Find and Replace, for ~ (FindState.lastReplacement).
var VFIND_REP: u8[>..] = [];
var VFIND_REP_SET = false;

fn vf_compile(out: u8[>..]&, text: u8[:], pattern: u8[:], ignore_case: bool) -> bool {
    VTXT.clear();
    VTXT.append(text);
    vb_load();
    if !vre_compile(pattern, if ignore_case { -1 } else { 0 }, ignore_case) {
        out.append("{\"error\":");
        json_str(out, VRE_ERR);
        out.push('}');
        return false;
    }
    vre_budget();
    return true;
}

fn vf_too_complex(out: u8[>..]&) {
    vre_too_complex();
    out.append("{\"error\":");
    json_str(out, VRE_ERR);
    out.push('}');
}

fn vim_find(out: u8[>..]&, text: u8[:], pattern: u8[:], ignore_case: bool) {
    if pattern.len == 0 { out.append("{\"matches\":[]}"); return; }
    if !vf_compile(out, text, pattern, ignore_case) { return; }
    var m: u8[>..] = [];
    let n = VCH.len;
    var pos = 0;
    var count = 0;
    while pos <= n {
        if !vre_find(0, n, pos) { break; }
        pos = vre_next_pos();
        count++;
        if count > MAX_MATCHES {
            out.append("{\"error\":\"There are too many matches. Use a longer pattern.\"}");
            return;
        }
        if m.len > 0 { m.push(','); }
        format(m, "[", VOFF[VRM_S], ",", VOFF[VRM_E], "]");
    }
    if VRE_OVER { vf_too_complex(out); return; }
    out.append("{\"matches\":[");
    out.append(m);
    out.append("]}");
}

fn vim_replace(out: u8[>..]&, text: u8[:], pattern: u8[:], ignore_case: bool,
               replacement: u8[:], sel_s: i64, sel_e: i64, all: bool) {
    if pattern.len == 0 { out.append("{\"count\":0}"); return; }
    if !vf_compile(out, text, pattern, ignore_case) { return; }
    var result: u8[>..] = [];
    var piece: u8[>..] = [];
    let n = VCH.len;
    var pos = 0;
    var cursor = 0;
    var count = 0;
    var caret = 0;
    while pos <= n {
        if !vre_find(0, n, pos) { break; }
        pos = vre_next_pos();
        let s = VOFF[VRM_S];
        let e = VOFF[VRM_E];
        if !all && (s != sel_s || e != sel_e) { continue; }
        result.append(text[cursor..s]);
        piece.clear();
        vre_expand(piece, replacement, VFIND_REP, VFIND_REP_SET);
        result.append(piece);
        caret = result.len;
        cursor = e;
        count++;
        if result.len > MAX_TEXT { break; }
        if !all { break; }
    }
    if VRE_OVER { vf_too_complex(out); return; }
    if count == 0 { out.append("{\"count\":0}"); return; }
    result.append(text[cursor..]);
    if result.len > MAX_TEXT {
        out.append("{\"error\":\"The result is larger than 512 KB. Make a smaller change.\"}");
        return;
    }
    VFIND_REP.clear();
    VFIND_REP.append(replacement);
    VFIND_REP_SET = true;
    format(out, "{\"count\":", count, ",\"text\":");
    json_str(out, result);
    if !all { format(out, ",\"selection\":[", caret, ",", caret, "]"); }
    out.push('}');
}
