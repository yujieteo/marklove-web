// Find and Replace, sam commands, line differences, and commit messages.
// Ported from MarkloveCore Text/Plan9Regex.swift, Text/Sam.swift,
// Text/LineDiff.swift and Git/CommitMessage.swift.
//
// All text is UTF-8. All offsets in and out are UTF-8 byte offsets.
// `plain` = true finds the text as typed (the Plain text setting).
// Otherwise the pattern is a Plan 9 (sam) regular expression.
//
// edit_find(out, text, pattern, plain, ignore_case)
//     {"matches":[[s,e],...]}  or  {"error":"message"}
//     Every match, without overlap. JS picks next, previous and the count.
// edit_replace(out, text, pattern, plain, ignore_case, replacement, sel_s, sel_e, all)
//     all = true: replaces every match.
//     all = false: replaces the match that is the selection (sel_s..sel_e).
//     {"count":n,"text":"new text","selection":[s,e]}
//     {"count":0} when nothing is replaced, or {"error":"message"}.
//     The selection is the caret after the replacement (replace one only).
// edit_sam(out, command, text, sel_s, sel_e, ignore_case)
//     {"text":"new text" or null,"selection":[s,e],"printed":["...",...],"summary":"..."}
//     or {"error":"message"}. "text" is null when the text did not change.
// edit_diff(out, old, new)
//     [{"op":"same","text":"...","old":1,"new":1},
//      {"op":"remove","text":"...","old":2},{"op":"add","text":"...","new":2},...]
//     old and new are 1-based line numbers.
// edit_commit_message(out, old, new)
//     Plain text: the subject line, then for more than one change a blank
//     line and one "- " line for each change. It uses the parse module.

import base;
import parse;

// --- shared state -------------------------------------------------------

// The code points of the current text, and the byte offset of each one in
// the input (with the full length at the end).
var ED_CP: i64[>..] = [];
var ED_BO: i64[>..] = [];
// Code point strings: patterns, replacements, the text of changes.
var ED_S: i64[>..] = [];
// The error message of the current call. Empty when there is no error.
var ED_ERR: u8[>..] = [];

fn ed_failed() -> bool { ED_ERR.len > 0 }

fn ed_fail(msg: u8[:]) { if ED_ERR.len == 0 { ED_ERR.append(msg); } }

// A message with up to three code points or numbers put in: a c1 b c2 d c3 e.
// A code point < 0 is not written.
fn ed_fail_c(a: u8[:], c1: i64, b: u8[:], c2: i64, d: u8[:], c3: i64, e: u8[:]) {
    if ED_ERR.len > 0 { return; }
    var m: u8[>..] = [];
    m.append(a);
    if c1 >= 0 { push_utf8(m, c1); }
    m.append(b);
    if c2 >= 0 { push_utf8(m, c2); }
    m.append(d);
    if c3 >= 0 { push_utf8(m, c3); }
    m.append(e);
    ED_ERR.append(m);
}

// "a" + the code points ED_S[o..o+n] + "b".
fn ed_fail_s(a: u8[:], o: i64, n: i64, b: u8[:]) {
    if ED_ERR.len > 0 { return; }
    var m: u8[>..] = [];
    m.append(a);
    for i in n { push_utf8(m, ED_S[o + i]); }
    m.append(b);
    ED_ERR.append(m);
}

fn ed_fail_n(a: u8[:], n: i64, b: u8[:]) {
    if ED_ERR.len > 0 { return; }
    var m: u8[>..] = [];
    m.append(a);
    format(m, n);
    m.append(b);
    ED_ERR.append(m);
}

fn ed_reset() {
    ED_CP.clear();
    ED_BO.clear();
    ED_S.clear();
    ED_ERR.clear();
    RX_CODE.clear();
    RX_CR.clear();
    RX_N.clear();
    RX_P.clear();
    RXS.clear();
    RX_PATS.clear();
    RX_ML.clear();
    SM_A.clear();
    SM_C.clear();
    SM_P.clear();
    SM_TOP.clear();
    SM_E.clear();
    SM_PB.clear();
    SM_PS.clear();
}

// Decodes UTF-8 into ED_CP, with the byte offsets in ED_BO.
// A malformed byte is U+FFFD.
fn ed_load(s: u8[:]) {
    ED_CP.clear();
    ED_BO.clear();
    var i = 0;
    while i < s.len {
        let b = s[i] as i64;
        var cp = 0xFFFD;
        var n = 1;
        if b < 0x80 {
            cp = b;
        } else if b >= 0xC0 && b < 0xE0 && i + 1 < s.len {
            cp = ((b & 0x1F) << 6) | ((s[i + 1] as i64) & 0x3F);
            n = 2;
        } else if b >= 0xE0 && b < 0xF0 && i + 2 < s.len {
            cp = ((b & 0x0F) << 12) | (((s[i + 1] as i64) & 0x3F) << 6) | ((s[i + 2] as i64) & 0x3F);
            n = 3;
        } else if b >= 0xF0 && b < 0xF8 && i + 3 < s.len {
            cp = ((b & 0x07) << 18) | (((s[i + 1] as i64) & 0x3F) << 12) |
                 (((s[i + 2] as i64) & 0x3F) << 6) | ((s[i + 3] as i64) & 0x3F);
            n = 4;
        }
        ED_CP.push(cp);
        ED_BO.push(i);
        i += n;
    }
    ED_BO.push(s.len);
}

// The code point index at a byte offset. An offset inside a character moves
// to its start.
fn ed_index(off: i64) -> i64 {
    var lo = 0;
    var hi = ED_CP.len;
    let t = max(0, min(off, ED_BO[ED_CP.len]));
    while lo < hi {
        let mid = (lo + hi + 1) / 2;
        if ED_BO[mid] <= t { lo = mid; } else { hi = mid - 1; }
    }
    return lo;
}

// The lower-case and upper-case forms of a code point, for ASCII, Latin-1,
// Latin Extended-A, Greek and Cyrillic.
fn ed_lower(c: i64) -> i64 {
    if c < 0x80 { if c >= 'A' && c <= 'Z' { return c + 32; } return c; }
    if c >= 0xC0 && c <= 0xDE && c != 0xD7 { return c + 32; }
    if c >= 0x100 && c <= 0x17F {
        if c == 0x130 || c == 0x131 || c == 0x138 || c == 0x149 || c == 0x17F { return c; }
        if c == 0x178 { return 0xFF; }
        if (c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E) { if (c & 1) == 1 { return c + 1; } return c; }
        if (c & 1) == 0 { return c + 1; }
        return c;
    }
    if c >= 0x391 && c <= 0x3A9 && c != 0x3A2 { return c + 32; }
    if c == 0x386 { return 0x3AC; }
    if c >= 0x388 && c <= 0x38A { return c + 37; }
    if c == 0x38C { return 0x3CC; }
    if c == 0x38E || c == 0x38F { return c + 63; }
    if c >= 0x410 && c <= 0x42F { return c + 32; }
    if c >= 0x400 && c <= 0x40F { return c + 80; }
    return c;
}

fn ed_upper(c: i64) -> i64 {
    if c < 0x80 { if c >= 'a' && c <= 'z' { return c - 32; } return c; }
    if c >= 0xE0 && c <= 0xFE && c != 0xF7 { return c - 32; }
    if c == 0xFF { return 0x178; }
    if c >= 0x100 && c <= 0x17F {
        if c == 0x130 || c == 0x131 || c == 0x138 || c == 0x149 || c == 0x17F { return c; }
        if (c >= 0x139 && c <= 0x148) || (c >= 0x179 && c <= 0x17E) { if (c & 1) == 0 { return c - 1; } return c; }
        if (c & 1) == 1 { return c - 1; }
        return c;
    }
    if c >= 0x3B1 && c <= 0x3C9 { if c == 0x3C2 { return 0x3A3; } return c - 32; }
    if c == 0x3AC { return 0x386; }
    if c >= 0x3AD && c <= 0x3AF { return c - 37; }
    if c == 0x3CC { return 0x38C; }
    if c == 0x3CD || c == 0x3CE { return c - 63; }
    if c >= 0x430 && c <= 0x44F { return c - 32; }
    if c >= 0x450 && c <= 0x45F { return c - 80; }
    return c;
}

// Appends the code points ED_CP[a..b] as UTF-8.
fn ed_put_text(out: u8[>..]&, a: i64, b: i64) { for i in a..b { push_utf8(out, ED_CP[i]); } }

// Appends the code points ED_S[o..o+n] as UTF-8.
fn ed_put_s(out: u8[>..]&, o: i64, n: i64) { for i in n { push_utf8(out, ED_S[o + i]); } }

fn ed_error_json(out: u8[>..]&) {
    out.append("{\"error\":");
    json_str(out, ED_ERR);
    out.push('}');
}

// --- Plan 9 regular expressions ------------------------------------------
//
//     .        any character except newline
//     [abc]    a character class; [^abc] does not match newline
//     ^ $      the start and the end of a line
//     * + ?    zero or more, one or more, zero or one
//     |        alternatives
//     ( )      a group; \1 to \9 use it in a replacement
//     \c       the character c; \n is newline, \t is tab
//
// The match is the leftmost-longest match, as in Plan 9.

let RX_CHAR = 1;
let RX_ANY = 2;
let RX_CLS = 3;
let RX_NCLS = 4;
let RX_BOL = 5;
let RX_EOL = 6;
let RX_SPLIT = 7;
let RX_JMP = 8;
let RX_SAVE = 9;
let RX_MATCH = 10;

let N_EMPTY = 0;
let N_CHAR = 1;
let N_ANY = 2;
let N_CLS = 3;
let N_BOL = 4;
let N_EOL = 5;
let N_GROUP = 6;
let N_CAT = 7;
let N_ALT = 8;
let N_STAR = 9;
let N_PLUS = 10;
let N_QUEST = 11;

// An instruction. CHAR: a = code point. CLS, NCLS: a = first range in RX_CR,
// b = number of ranges. SPLIT: a, b = targets. JMP: a = target. SAVE: a = slot.
struct RxI { op: i64, a: i64, b: i64 }
// A syntax node. Children are a list: child, then next; last is the last child.
struct RxN { k: i64, a: i64, b: i64, neg: bool, child: i64, next: i64, last: i64 }
// A compiled pattern: code RX_CODE[o..o+n], and its pattern RX_PATS[po..po+pn].
struct Rx { o: i64, n: i64, groups: i64, icase: bool, po: i64, pn: i64 }

var RX_CODE: RxI[>..] = [];
var RX_CR: i64[>..] = [];     // class ranges: lo, hi
var RX_N: RxN[>..] = [];
var RX_J: i64[>..] = [];      // jumps to patch, for alternatives
var RX_P: i64[>..] = [];      // the pattern to compile
var RX_I = 0;
var RX_G = 0;
var RXS: Rx[>..] = [];
var RX_PATS: i64[>..] = [];

fn rx_peek() -> i64 { if RX_I < RX_P.len { RX_P[RX_I] } else { -1 } }

fn rx_node(k: i64) -> i64 {
    RX_N.push(RxN { k: k, a: 0, b: 0, neg: false, child: -1, next: -1, last: -1 });
    return RX_N.len - 1;
}

fn rx_append(p: i64, c: i64) {
    if RX_N[p].child < 0 { RX_N[p].child = c; } else { RX_N[RX_N[p].last].next = c; }
    RX_N[p].last = c;
}

fn rx_esc(c: i64) -> i64 {
    if c == 'n' { return '\n'; }
    if c == 't' { return '\t'; }
    return c;
}

recursive fn rx_alt() -> i64 {
    let first = rx_cat();
    if ED_ERR.len > 0 || rx_peek() != '|' { return first; }
    let n = rx_node(N_ALT);
    rx_append(n, first);
    while ED_ERR.len == 0 && rx_peek() == '|' {
        RX_I++;
        let c = rx_cat();
        rx_append(n, c);
    }
    return n;
}

recursive fn rx_cat() -> i64 {
    var first = -1;
    var cat = -1;
    while ED_ERR.len == 0 {
        let c = rx_peek();
        if c < 0 || c == '|' || c == ')' { break; }
        var atom = rx_atom();
        if ED_ERR.len > 0 { return 0; }
        while true {
            let r = rx_peek();
            var k = -1;
            if r == '*' { k = N_STAR; } else if r == '+' { k = N_PLUS; } else if r == '?' { k = N_QUEST; }
            if k < 0 { break; }
            RX_I++;
            let w = rx_node(k);
            RX_N[w].child = atom;
            atom = w;
        }
        if first < 0 {
            first = atom;
        } else {
            if cat < 0 { cat = rx_node(N_CAT); rx_append(cat, first); }
            rx_append(cat, atom);
        }
    }
    if first < 0 { return rx_node(N_EMPTY); }
    if cat < 0 { return first; }
    return cat;
}

recursive fn rx_atom() -> i64 {
    let c = RX_P[RX_I];
    RX_I++;
    if c == '*' || c == '+' || c == '?' {
        ed_fail_c("Nothing comes before ", c, ". Write \\", c, " to find the character ", c, ".");
        return 0;
    }
    if c == '.' { return rx_node(N_ANY); }
    if c == '^' { return rx_node(N_BOL); }
    if c == '$' { return rx_node(N_EOL); }
    if c == '(' {
        RX_G++;
        let g = RX_G;
        let inner = rx_alt();
        if ED_ERR.len > 0 { return 0; }
        if rx_peek() != ')' { ed_fail("This ( has no )."); return 0; }
        RX_I++;
        let n = rx_node(N_GROUP);
        RX_N[n].a = g;
        RX_N[n].child = inner;
        return n;
    }
    if c == '[' { return rx_class(); }
    var x = c;
    if c == '\\' {
        if RX_I >= RX_P.len { ed_fail("The pattern ends with \\. Write \\\\ to find a backslash."); return 0; }
        x = rx_esc(RX_P[RX_I]);
        RX_I++;
    }
    let n = rx_node(N_CHAR);
    RX_N[n].a = x;
    return n;
}

fn rx_class_char() -> i64 {
    let c = rx_peek();
    if c < 0 { ed_fail("This [ has no ]."); return 0; }
    RX_I++;
    if c == '\\' {
        let e = rx_peek();
        if e < 0 { ed_fail("This [ has no ]."); return 0; }
        RX_I++;
        return rx_esc(e);
    }
    return c;
}

fn rx_class() -> i64 {
    var neg = false;
    if rx_peek() == '^' { neg = true; RX_I++; }
    let o = RX_CR.len;
    var first = true;
    while true {
        let c = rx_peek();
        if c < 0 { ed_fail("This [ has no ]."); return 0; }
        if c == ']' && !first { RX_I++; break; }
        first = false;
        let a = rx_class_char();
        if ED_ERR.len > 0 { return 0; }
        if rx_peek() == '-' && RX_I + 1 < RX_P.len && RX_P[RX_I + 1] != ']' {
            RX_I++;
            let b = rx_class_char();
            if ED_ERR.len > 0 { return 0; }
            if a > b { ed_fail_c("The range ", a, "-", b, " is in the wrong order.", -1, ""); return 0; }
            RX_CR.push(a);
            RX_CR.push(b);
        } else {
            RX_CR.push(a);
            RX_CR.push(a);
        }
    }
    let n = rx_node(N_CLS);
    RX_N[n].a = o;
    RX_N[n].b = (RX_CR.len - o) / 2;
    RX_N[n].neg = neg;
    return n;
}

fn rx_op(op: i64, a: i64, b: i64) { RX_CODE.push(RxI { op: op, a: a, b: b }); }

recursive fn rx_emit(n: i64) {
    let x = RX_N[n];
    let k = x.k;
    if k == N_EMPTY { return; }
    if k == N_CHAR { rx_op(RX_CHAR, x.a, 0); return; }
    if k == N_ANY { rx_op(RX_ANY, 0, 0); return; }
    if k == N_CLS { rx_op(if x.neg { RX_NCLS } else { RX_CLS }, x.a, x.b); return; }
    if k == N_BOL { rx_op(RX_BOL, 0, 0); return; }
    if k == N_EOL { rx_op(RX_EOL, 0, 0); return; }
    if k == N_GROUP {
        rx_op(RX_SAVE, 2 * x.a, 0);
        rx_emit(x.child);
        rx_op(RX_SAVE, 2 * x.a + 1, 0);
        return;
    }
    if k == N_CAT {
        var c = x.child;
        while c >= 0 { rx_emit(c); c = RX_N[c].next; }
        return;
    }
    if k == N_ALT {
        // split L1, next; L1: a; jmp end; next: split L2, ...
        let mark = RX_J.len;
        var c = x.child;
        while c >= 0 {
            if RX_N[c].next >= 0 {
                let split = RX_CODE.len;
                rx_op(RX_SPLIT, split + 1, 0);
                rx_emit(c);
                RX_J.push(RX_CODE.len);
                rx_op(RX_JMP, 0, 0);
                RX_CODE[split].b = RX_CODE.len;
            } else {
                rx_emit(c);
            }
            c = RX_N[c].next;
        }
        for j in mark..RX_J.len { RX_CODE[RX_J[j]].a = RX_CODE.len; }
        RX_J.resize(mark);
        return;
    }
    if k == N_STAR {
        let split = RX_CODE.len;
        rx_op(RX_SPLIT, split + 1, 0);
        rx_emit(x.child);
        rx_op(RX_JMP, split, 0);
        RX_CODE[split].b = RX_CODE.len;
        return;
    }
    if k == N_PLUS {
        let start = RX_CODE.len;
        rx_emit(x.child);
        let s = RX_CODE.len;
        rx_op(RX_SPLIT, start, s + 1);
        return;
    }
    // N_QUEST
    let split = RX_CODE.len;
    rx_op(RX_SPLIT, split + 1, 0);
    rx_emit(x.child);
    RX_CODE[split].b = RX_CODE.len;
}

// Compiles the pattern in RX_P, or finds it when it is already compiled.
// Returns the index in RXS, or -1 with the message in ED_ERR.
fn rx_get(icase: bool) -> i64 {
    for r, ri in RXS {
        if r.icase == icase && r.pn == RX_P.len {
            var same = true;
            for i in r.pn { if RX_PATS[r.po + i] != RX_P[i] { same = false; break; } }
            if same { return ri; }
        }
    }
    RX_I = 0;
    RX_G = 0;
    RX_N.clear();
    let root = rx_alt();
    if ED_ERR.len > 0 { return -1; }
    if RX_I < RX_P.len {
        if RX_P[RX_I] == ')' { ed_fail("This ) has no (."); } else { ed_fail("The pattern is not correct."); }
        return -1;
    }
    let o = RX_CODE.len;
    rx_op(RX_SAVE, 0, 0);
    rx_emit(root);
    rx_op(RX_SAVE, 1, 0);
    rx_op(RX_MATCH, 0, 0);
    let po = RX_PATS.len;
    for i in RX_P.len { let c = RX_P[i]; RX_PATS.push(c); }
    RXS.push(Rx { o: o, n: RX_CODE.len - o, groups: RX_G, icase: icase, po: po, pn: RX_P.len });
    return RXS.len - 1;
}

// --- matching (a Pike machine with leftmost-longest choice) ---------------

var RX_MARK: i64[>..] = [];
var RX_GEN = 0;
// The current and the next thread lists: the program counter and the slots.
var RX_CPC: i64[>..] = [];
var RX_CCP: i64[>..] = [];
var RX_NPC: i64[>..] = [];
var RX_NCP: i64[>..] = [];
// The slots of the thread that rx_add follows.
var RX_CS: i64[>..] = [];
var RX_BEST: i64[>..] = [];
var RX_HAVE = false;
var RX_O = 0;
var RX_SLOTS = 0;
var RX_IC = false;
// The slots of the last match from rx_first. Slot 2g and 2g+1 are group g.
var RX_M: i64[>..] = [];
// Matches from rx_all, one after the other, RX_SLOTS each. A stack.
var RX_ML: i64[>..] = [];

fn rx_fold(c: i64) -> i64 { if RX_IC { ed_lower(c) } else { c } }

fn rx_in(a: i64, n: i64, c: i64) -> bool {
    for i in n { if c >= RX_CR[a + 2 * i] && c <= RX_CR[a + 2 * i + 1] { return true; } }
    return false;
}

fn rx_cls(a: i64, n: i64, neg: bool, c: i64) -> bool {
    if neg && c == '\n' { return false; }
    var hit = rx_in(a, n, c);
    if !hit && RX_IC { hit = rx_in(a, n, ed_lower(c)) || rx_in(a, n, ed_upper(c)); }
    return hit != neg;
}

// Adds a thread to the next list. Its slots are RX_CS[cso..cso+RX_SLOTS].
recursive fn rx_add(pc: i64, cso: i64, pos: i64) {
    let m = pc - RX_O;
    if RX_MARK[m] == RX_GEN { return; }
    RX_MARK[m] = RX_GEN;
    let ins = RX_CODE[pc];
    let op = ins.op;
    if op == RX_JMP { rx_add(ins.a, cso, pos); return; }
    if op == RX_SPLIT { rx_add(ins.a, cso, pos); rx_add(ins.b, cso, pos); return; }
    if op == RX_SAVE {
        let o = RX_CS.len;
        for k in RX_SLOTS { let v = RX_CS[cso + k]; RX_CS.push(v); }
        RX_CS[o + ins.a] = pos;
        rx_add(pc + 1, o, pos);
        RX_CS.resize(o);
        return;
    }
    if op == RX_BOL {
        if pos == 0 || ED_CP[pos - 1] == '\n' { rx_add(pc + 1, cso, pos); }
        return;
    }
    if op == RX_EOL {
        if pos == ED_CP.len || ED_CP[pos] == '\n' { rx_add(pc + 1, cso, pos); }
        return;
    }
    RX_NPC.push(pc);
    for k in RX_SLOTS { let v = RX_CS[cso + k]; RX_NCP.push(v); }
}

// The leftmost-longest match in ED_CP that starts at or after `from` and ends
// at or before `to` (-1: the end). `^` and `$` see the whole text, as in sam.
// The slots go to RX_M.
fn rx_first(r: i64, from: i64, to: i64) -> bool {
    let rx = RXS[r];
    let count = ED_CP.len;
    let limit = if to < 0 || to > count { count } else { to };
    if from > limit { return false; }
    RX_O = rx.o;
    RX_SLOTS = 2 * (rx.groups + 1);
    RX_IC = rx.icase;
    let slots = RX_SLOTS;
    while RX_MARK.len < rx.n { RX_MARK.push(-1); }
    RX_CPC.clear();
    RX_CCP.clear();
    RX_NPC.clear();
    RX_NCP.clear();
    RX_CS.clear();
    RX_BEST.clear();
    RX_HAVE = false;
    var pos = from;
    while true {
        if !RX_HAVE {
            RX_GEN++;
            // A new start has the lowest priority: it goes at the end of the list.
            for i in RX_CPC.len { RX_MARK[RX_CPC[i] - RX_O] = RX_GEN; }
            for k in slots { RX_CS.push(-1); }
            rx_add(RX_O, 0, pos);
            RX_CS.clear();
            for i in RX_NPC.len { let v = RX_NPC[i]; RX_CPC.push(v); }
            for i in RX_NCP.len { let v = RX_NCP[i]; RX_CCP.push(v); }
            RX_NPC.clear();
            RX_NCP.clear();
        }
        if RX_CPC.len == 0 {
            if RX_HAVE || pos >= limit { break; }
            pos++;
            continue;
        }
        RX_GEN++;
        let c = if pos < limit { ED_CP[pos] } else { -1 };
        for ti in RX_CPC.len {
            let pc = RX_CPC[ti];
            let co = ti * slots;
            let start = RX_CCP[co];
            if RX_HAVE && start > RX_BEST[0] { continue; }
            let ins = RX_CODE[pc];
            if ins.op == RX_MATCH {
                if !RX_HAVE || start < RX_BEST[0] || (start == RX_BEST[0] && RX_CCP[co + 1] > RX_BEST[1]) {
                    RX_BEST.clear();
                    for k in slots { let v = RX_CCP[co + k]; RX_BEST.push(v); }
                    RX_HAVE = true;
                }
            } else if c >= 0 {
                var ok = false;
                if ins.op == RX_CHAR { ok = rx_fold(c) == rx_fold(ins.a); }
                else if ins.op == RX_ANY { ok = c != '\n'; }
                else if ins.op == RX_CLS { ok = rx_cls(ins.a, ins.b, false, c); }
                else if ins.op == RX_NCLS { ok = rx_cls(ins.a, ins.b, true, c); }
                if ok {
                    for k in slots { let v = RX_CCP[co + k]; RX_CS.push(v); }
                    rx_add(pc + 1, 0, pos + 1);
                    RX_CS.clear();
                }
            }
        }
        if c < 0 { break; }
        RX_CPC.clear();
        RX_CCP.clear();
        for i in RX_NPC.len { let v = RX_NPC[i]; RX_CPC.push(v); }
        for i in RX_NCP.len { let v = RX_NCP[i]; RX_CCP.push(v); }
        RX_NPC.clear();
        RX_NCP.clear();
        pos++;
        if RX_CPC.len == 0 && RX_HAVE { break; }
    }
    if !RX_HAVE { return false; }
    RX_M.clear();
    for k in slots { let v = RX_BEST[k]; RX_M.push(v); }
    return true;
}

// All matches in lo..hi, without overlap, pushed on RX_ML. An empty match
// next to the previous match is skipped, as in sam. Returns the index of the
// first match in RX_ML and the number of matches. The caller resizes RX_ML
// back to that index when it is done.
fn rx_all(r: i64, lo: i64, hi: i64) -> i64, i64 {
    let slots = 2 * (RXS[r].groups + 1);
    let mark = RX_ML.len;
    var n = 0;
    var p = lo;
    var last_end = -1;
    while p <= hi {
        if !rx_first(r, p, hi) { break; }
        let s = RX_M[0];
        let e = RX_M[1];
        if s == e && s == last_end {
            // Try again one character later.
            if s >= hi { break; }
            p = s + 1;
            continue;
        }
        for k in slots { let v = RX_M[k]; RX_ML.push(v); }
        n++;
        last_end = e;
        p = if s == e { e + 1 } else { e };
        if s == e && e >= hi { break; }
    }
    return mark, n;
}

// Sam's replacement text, appended to ED_S: & is the match, \1 to \9 are
// groups, \n is a newline. The replacement is ED_S[ro..ro+rn], the match is at
// RX_ML[mo..].
fn rx_expand(ro: i64, rn: i64, mo: i64, groups: i64) {
    var i = 0;
    while i < rn {
        let c = ED_S[ro + i];
        if c == '&' {
            for p in RX_ML[mo]..RX_ML[mo + 1] { let v = ED_CP[p]; ED_S.push(v); }
        } else if c == '\\' && i + 1 < rn {
            let n = ED_S[ro + i + 1];
            i++;
            if n >= '1' && n <= '9' {
                let d = n - '0';
                if d <= groups {
                    let s = RX_ML[mo + 2 * d];
                    let e = RX_ML[mo + 2 * d + 1];
                    if s >= 0 && e >= s { for p in s..e { let v = ED_CP[p]; ED_S.push(v); } }
                }
            } else if n == 'n' {
                ED_S.push('\n');
            } else if n == 't' {
                ED_S.push('\t');
            } else {
                ED_S.push(n);
            }
        } else {
            ED_S.push(c);
        }
        i++;
    }
}

// --- Find and Replace ------------------------------------------------------

// Puts the pattern in RX_P. Plain text escapes each pattern character.
fn ed_pattern(pattern: u8[:], plain: bool) {
    RX_P.clear();
    each_utf8(pattern) {
        if plain && (it == '.' || it == '[' || it == ']' || it == '*' || it == '+' || it == '?' || it == '|' ||
                     it == '(' || it == ')' || it == '^' || it == '$' || it == '\\') {
            RX_P.push('\\');
        }
        RX_P.push(it);
    };
}

fn edit_find(out: u8[>..]&, text: u8[:], pattern: u8[:], plain: bool, ignore_case: bool) {
    ed_reset();
    if pattern.len == 0 { out.append("{\"matches\":[]}"); return; }
    ed_load(text);
    ed_pattern(pattern, plain);
    let r = rx_get(ignore_case);
    if r < 0 { ed_error_json(out); return; }
    let mark, n = rx_all(r, 0, ED_CP.len);
    let slots = 2 * (RXS[r].groups + 1);
    out.append("{\"matches\":[");
    for i in n {
        if i > 0 { out.push(','); }
        let o = mark + i * slots;
        format(out, "[", ED_BO[RX_ML[o]], ",", ED_BO[RX_ML[o + 1]], "]");
    }
    out.append("]}");
}

fn edit_replace(out: u8[>..]&, text: u8[:], pattern: u8[:], plain: bool, ignore_case: bool,
                replacement: u8[:], sel_s: i64, sel_e: i64, all: bool) {
    ed_reset();
    if pattern.len == 0 { out.append("{\"count\":0}"); return; }
    ed_load(text);
    ed_pattern(pattern, plain);
    let r = rx_get(ignore_case);
    if r < 0 { ed_error_json(out); return; }
    let groups = RXS[r].groups;
    let slots = 2 * (groups + 1);
    let ro = ED_S.len;
    each_utf8(replacement) { ED_S.push(it); };
    let rn = ED_S.len - ro;
    let mark, n = rx_all(r, 0, ED_CP.len);
    var result: u8[>..] = [];
    var cursor = 0;
    var count = 0;
    var caret = 0;
    for i in n {
        let o = mark + i * slots;
        let s = ED_BO[RX_ML[o]];
        let e = ED_BO[RX_ML[o + 1]];
        if !all && (s != sel_s || e != sel_e) { continue; }
        result.append(text[cursor..s]);
        if plain {
            result.append(replacement);
        } else {
            let eo = ED_S.len;
            rx_expand(ro, rn, o, groups);
            ed_put_s(result, eo, ED_S.len - eo);
            ED_S.resize(eo);
        }
        caret = result.len;
        cursor = e;
        count++;
        if !all { break; }
    }
    if count == 0 { out.append("{\"count\":0}"); return; }
    result.append(text[cursor..]);
    format(out, "{\"count\":", count, ",\"text\":");
    json_str(out, result);
    if !all { format(out, ",\"selection\":[", caret, ",", caret, "]"); }
    out.push('}');
}

// --- sam ---------------------------------------------------------------
//
// Addresses select text:
//
//     #n       the empty position after n characters
//     n        line n
//     /re/     the next match after dot; ?re? the match before dot
//     $  .     the end of the file; dot (the selection)
//     a1,a2    from the start of a1 to the end of a2; "," alone is the whole file
//     a1;a2    the same, but a2 starts at a1
//     a+b a-b  b after or before a; "+" alone is the next line
//
// Commands act on dot:
//
//     x/re/ cmd    run cmd on each match in dot ("x cmd" loops over lines)
//     y/re/ cmd    run cmd on each part between the matches
//     g/re/ cmd    run cmd if dot has a match; v/re/ cmd if it has none
//     s/re/text/   replace the first match; s/re/text/g replaces all
//     c/text/  a/text/  i/text/   change, append, insert
//     d            delete
//     m addr  t addr   move or copy dot to after addr
//     p  =         show the text, or the line numbers
//     { cmds }     several commands, one on each line, on the same dot
//
// Each command runs on the text as it was at the start of the command. Its
// changes are made at the end, together. Commands on separate lines run one
// after the other.

let A_LINE = 1;
let A_CHAR = 2;
let A_DOT = 3;
let A_END = 4;
let A_FWD = 5;
let A_BACK = 6;
let A_PLUS = 7;
let A_MINUS = 8;
let A_CHAIN = 9;
let A_COMMA = 10;
let A_SEMI = 11;

let C_SELECT = 1;
let C_X = 2;
let C_Y = 3;
let C_G = 4;
let C_V = 5;
let C_S = 6;
let C_CHANGE = 7;
let C_APPEND = 8;
let C_INSERT = 9;
let C_DELETE = 10;
let C_MOVE = 11;
let C_COPY = 12;
let C_PRINT = 13;
let C_LINES = 14;
let C_BLOCK = 15;

// An address. LINE, CHAR: n. FWD, BACK: the pattern ED_S[so..so+sn].
// CHAIN: the parts first, next, ... COMMA, SEMI: l and r (-1 when missing).
struct SmA { k: i64, n: i64, so: i64, sn: i64, l: i64, r: i64, first: i64, next: i64, last: i64 }
// A command. ro/rn: the pattern (ro = -1 for x without a pattern).
// to/tn: the text or the replacement. inner: the command of x, y, g, v.
// target: the address of m and t. first/last: the commands of a block.
struct SmC { k: i64, addr: i64, ro: i64, rn: i64, to: i64, tn: i64, n: i64, glob: bool,
             inner: i64, target: i64, first: i64, next: i64, last: i64 }
// A change: the range s..e of the text becomes ED_S[o..o+n].
struct SmE { s: i64, e: i64, o: i64, n: i64, idx: i64 }

var SM_A: SmA[>..] = [];
var SM_C: SmC[>..] = [];
var SM_P: i64[>..] = [];     // the command text
var SM_I = 0;
var SM_TOP: i64[>..] = [];   // the commands of the program
var SM_E: SmE[>..] = [];
var SM_PB: u8[>..] = [];     // printed text
var SM_PS: i64[>..] = [];    // printed lines: offset, length in SM_PB
var SM_IC = false;
var SM_NEW: i64[>..] = [];
var SM_ORIG: i64[>..] = [];

fn sm_peek() -> i64 { if SM_I < SM_P.len { SM_P[SM_I] } else { -1 } }

fn sm_is_ws(c: i64) -> bool {
    (c >= 0x09 && c <= 0x0D) || c == ' ' || c == 0x85 || c == 0xA0 || c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F || c == 0x205F || c == 0x3000
}
fn sm_is_digit(c: i64) -> bool { c >= '0' && c <= '9' }
// Letters: ASCII letters, and other characters outside the punctuation blocks.
fn sm_is_letter(c: i64) -> bool {
    if c < 0x80 { return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'); }
    if c < 0xC0 || c == 0xD7 || c == 0xF7 { return false; }
    if c >= 0x2000 && c <= 0x2BFF { return false; }
    if c >= 0x3000 && c <= 0x303F { return false; }
    return !sm_is_ws(c);
}

fn sm_blanks() { while SM_I < SM_P.len && (SM_P[SM_I] == ' ' || SM_P[SM_I] == '\t') { SM_I++; } }
fn sm_space() { while SM_I < SM_P.len && sm_is_ws(SM_P[SM_I]) { SM_I++; } }

fn sm_number() -> i64, bool {
    if !sm_is_digit(sm_peek()) { return 0, false; }
    var n = 0;
    while sm_is_digit(sm_peek()) { n = n * 10 + (sm_peek() - '0'); SM_I++; }
    return n, true;
}

// Text up to the next delimiter, appended to ED_S. "\d" is the delimiter
// itself. A missing last delimiter is allowed, as in sam.
fn sm_delim(d: i64, keep: bool) -> i64, i64 {
    let o = ED_S.len;
    while true {
        let c = sm_peek();
        if c < 0 { break; }
        SM_I++;
        if c == d { break; }
        if c == '\n' { SM_I--; break; }
        if c == '\\' && sm_peek() >= 0 {
            let n = sm_peek();
            SM_I++;
            if n == d { ED_S.push(d); }
            else if keep { ED_S.push('\\'); ED_S.push(n); }
            else { ED_S.push(rx_esc(n)); }
            continue;
        }
        ED_S.push(c);
    }
    return o, ED_S.len - o;
}

fn sm_addr_node(k: i64) -> i64 {
    SM_A.push(SmA { k: k, n: 0, so: 0, sn: 0, l: -1, r: -1, first: -1, next: -1, last: -1 });
    return SM_A.len - 1;
}

fn sm_chain_add(ch: i64, p: i64) {
    if SM_A[ch].first < 0 { SM_A[ch].first = p; } else { SM_A[SM_A[ch].last].next = p; }
    SM_A[ch].last = p;
}

fn sm_simple() -> i64 {
    var ch = -1;
    while true {
        sm_blanks();
        let c = sm_peek();
        if c < 0 { break; }
        var k = 0;
        var n = 0;
        var so = 0;
        var sn = 0;
        if c == '#' {
            SM_I++;
            k = A_CHAR;
            let v, ok = sm_number();
            n = if ok { v } else { 1 };
        } else if sm_is_digit(c) {
            k = A_LINE;
            let v, ok = sm_number();
            n = v;
        } else if c == '/' {
            SM_I++;
            k = A_FWD;
            let o, l = sm_delim('/', true);
            so = o;
            sn = l;
        } else if c == '?' {
            SM_I++;
            k = A_BACK;
            let o, l = sm_delim('?', true);
            so = o;
            sn = l;
        } else if c == '.' { SM_I++; k = A_DOT; }
        else if c == '$' { SM_I++; k = A_END; }
        else if c == '+' { SM_I++; k = A_PLUS; }
        else if c == '-' { SM_I++; k = A_MINUS; }
        else { break; }
        if ch < 0 {
            ch = sm_addr_node(A_CHAIN);
        } else {
            let lk = SM_A[SM_A[ch].last].k;
            if lk == A_PLUS || lk == A_MINUS || k == A_PLUS || k == A_MINUS {
            } else if k == A_LINE || k == A_CHAR || k == A_FWD || k == A_BACK {
                // "a/re/" means "a+/re/".
                sm_chain_add(ch, sm_addr_node(A_PLUS));
            } else {
                ed_fail("Two addresses are next to each other. Put + or - between them.");
                return -1;
            }
        }
        let p = sm_addr_node(k);
        SM_A[p].n = n;
        SM_A[p].so = so;
        SM_A[p].sn = sn;
        sm_chain_add(ch, p);
    }
    return ch;
}

recursive fn sm_compound() -> i64 {
    let left = sm_simple();
    if ED_ERR.len > 0 { return -1; }
    sm_blanks();
    let c = sm_peek();
    if c != ',' && c != ';' { return left; }
    SM_I++;
    let right = sm_compound();
    if ED_ERR.len > 0 { return -1; }
    let a = sm_addr_node(if c == ',' { A_COMMA } else { A_SEMI });
    SM_A[a].l = left;
    SM_A[a].r = right;
    return a;
}

fn sm_cmd_node(k: i64, addr: i64) -> i64 {
    SM_C.push(SmC { k: k, addr: addr, ro: -1, rn: 0, to: 0, tn: 0, n: 1, glob: false,
                    inner: -1, target: -1, first: -1, next: -1, last: -1 });
    return SM_C.len - 1;
}

fn sm_bad_delim(d: i64) -> bool { d < 0 || sm_is_letter(d) || sm_is_digit(d) || sm_is_ws(d) }

recursive fn sm_command() -> i64 {
    sm_blanks();
    let addr = sm_compound();
    if ED_ERR.len > 0 { return -1; }
    sm_blanks();
    let c = sm_peek();
    if c < 0 || c == '\n' || c == '}' { return sm_cmd_node(C_SELECT, addr); }
    SM_I++;
    if c == 'x' || c == 'y' || c == 'g' || c == 'v' {
        var ro = -1;
        var rn = 0;
        let d = sm_peek();
        if sm_bad_delim(d) || d == '{' {
            if c != 'x' { ed_fail_c("Add a pattern after ", c, ", for example ", c, "/word/.", -1, ""); return -1; }
        } else {
            SM_I++;
            let o, l = sm_delim(d, true);
            ro = o;
            rn = l;
        }
        sm_blanks();
        if sm_peek() < 0 || sm_peek() == '\n' {
            ed_fail_c("Add a command after ", c, "/…/, for example p or d.", -1, "", -1, "");
            return -1;
        }
        let inner = sm_command();
        if ED_ERR.len > 0 { return -1; }
        let k = if c == 'x' { C_X } else if c == 'y' { C_Y } else if c == 'g' { C_G } else { C_V };
        let n = sm_cmd_node(k, addr);
        SM_C[n].ro = ro;
        SM_C[n].rn = rn;
        SM_C[n].inner = inner;
        return n;
    }
    if c == 's' {
        let v, ok = sm_number();
        let d = sm_peek();
        if sm_bad_delim(d) { ed_fail("Add a pattern and the new text after s, for example s/old/new/."); return -1; }
        SM_I++;
        let ro, rn = sm_delim(d, true);
        let to, tn = sm_delim(d, true);
        var glob = false;
        if sm_peek() == 'g' { glob = true; SM_I++; }
        let n = sm_cmd_node(C_S, addr);
        SM_C[n].ro = ro;
        SM_C[n].rn = rn;
        SM_C[n].to = to;
        SM_C[n].tn = tn;
        SM_C[n].n = if ok { v } else { 1 };
        SM_C[n].glob = glob;
        return n;
    }
    if c == 'c' || c == 'a' || c == 'i' {
        sm_blanks();
        let d = sm_peek();
        if sm_bad_delim(d) { ed_fail_c("Add the text after ", c, ", for example ", c, "/new text/.", -1, ""); return -1; }
        SM_I++;
        let to, tn = sm_delim(d, false);
        let n = sm_cmd_node(if c == 'c' { C_CHANGE } else if c == 'a' { C_APPEND } else { C_INSERT }, addr);
        SM_C[n].to = to;
        SM_C[n].tn = tn;
        return n;
    }
    if c == 'd' { return sm_cmd_node(C_DELETE, addr); }
    if c == 'p' { return sm_cmd_node(C_PRINT, addr); }
    if c == '=' { return sm_cmd_node(C_LINES, addr); }
    if c == 'm' || c == 't' {
        sm_blanks();
        let target = sm_compound();
        if ED_ERR.len > 0 { return -1; }
        if target < 0 { ed_fail_c("Add an address after ", c, ", for example ", c, "$.", -1, ""); return -1; }
        let n = sm_cmd_node(if c == 'm' { C_MOVE } else { C_COPY }, addr);
        SM_C[n].target = target;
        return n;
    }
    if c == '{' {
        let n = sm_cmd_node(C_BLOCK, addr);
        while true {
            sm_space();
            let x = sm_peek();
            if x < 0 { ed_fail("This { has no }."); return -1; }
            if x == '}' { SM_I++; break; }
            let child = sm_command();
            if ED_ERR.len > 0 { return -1; }
            if SM_C[n].first < 0 { SM_C[n].first = child; } else { SM_C[SM_C[n].last].next = child; }
            SM_C[n].last = child;
        }
        return n;
    }
    ed_fail_c("Marklove does not know the command ", c, ". Use x, y, g, v, s, c, a, i, d, m, t, p, or =.", -1, "", -1, "");
    return -1;
}

fn sm_program() {
    while true {
        sm_space();
        if SM_I >= SM_P.len { break; }
        let at = SM_I;
        let c = sm_command();
        if ED_ERR.len > 0 { return; }
        if SM_I == at {
            // A "}" with no "{". The Swift parser does not stop here.
            ed_fail_c("Marklove does not know the command ", SM_P[at], ". Use x, y, g, v, s, c, a, i, d, m, t, p, or =.", -1, "", -1, "");
            return;
        }
        SM_TOP.push(c);
    }
}

// --- sam addresses (after sam's address.c) ------------------------------

fn sm_line(l: i64, a0: i64, a1: i64, sign: i64) -> i64, i64 {
    let n = ED_CP.len;
    if sign >= 0 {
        var p = 0;
        var start = 0;
        if l == 0 {
            if sign == 0 || a1 == 0 { return 0, 0; }
            start = a1;
            p = a1 - 1;
        } else {
            var count = 0;
            if sign == 0 || a1 == 0 {
                p = 0;
                count = 1;
            } else {
                p = a1 - 1;
                count = if ED_CP[p] == '\n' { 1 } else { 0 };
                p++;
            }
            while count < l {
                if p >= n { ed_fail_n("Line ", l, " is past the end of the file."); return 0, 0; }
                if ED_CP[p] == '\n' { count++; }
                p++;
            }
            start = p;
        }
        while p < n {
            let c = ED_CP[p];
            p++;
            if c == '\n' { break; }
        }
        return start, max(start, p);
    }
    var p = a0;
    var end = 0;
    if l == 0 {
        end = a0;
    } else {
        var count = 0;
        while true {
            if p == 0 {
                count++;
                if count != l { ed_fail("The address is before the start of the file."); return 0, 0; }
            } else if ED_CP[p - 1] != '\n' {
                p--;
            } else {
                count++;
                if count != l { p--; }
            }
            if count >= l { break; }
        }
        end = p;
        if p > 0 { p--; }
    }
    while p > 0 && ED_CP[p - 1] != '\n' { p--; }
    return p, max(p, end);
}

fn sm_char(l: i64, a0: i64, a1: i64, sign: i64) -> i64, i64 {
    var p1 = a0;
    var p2 = a1;
    if sign == 0 { p1 = l; p2 = l; }
    else if sign < 0 { p1 -= l; p2 = p1; }
    else { p2 += l; p1 = p2; }
    if p1 < 0 || p2 > ED_CP.len { ed_fail_n("Character #", l, " is outside the file."); return 0, 0; }
    return p1, p2;
}

// Compiles the pattern ED_S[o..o+n].
fn sm_regex(o: i64, n: i64) -> i64 {
    RX_P.clear();
    for i in n { let v = ED_S[o + i]; RX_P.push(v); }
    return rx_get(SM_IC);
}

fn sm_search(so: i64, sn: i64, p: i64, forward: bool) -> i64, i64 {
    let re = sm_regex(so, sn);
    if re < 0 { return 0, 0; }
    let count = ED_CP.len;
    if forward {
        if rx_first(re, p, -1) || rx_first(re, 0, -1) {
            let s = RX_M[0];
            let e = RX_M[1];
            if s == e && s == p {
                let start = if p + 1 > count { 0 } else { p + 1 };
                if rx_first(re, start, -1) || rx_first(re, 0, -1) { return RX_M[0], RX_M[1]; }
            }
            return s, e;
        }
    } else {
        let mark, n = rx_all(re, 0, count);
        let slots = 2 * (RXS[re].groups + 1);
        var hit = -1;
        for i in n {
            let s = RX_ML[mark + i * slots];
            let e = RX_ML[mark + i * slots + 1];
            if e <= p && !(s == e && e == p) { hit = i; }
        }
        if hit < 0 && n > 0 { hit = n - 1; }
        if hit >= 0 {
            let s = RX_ML[mark + hit * slots];
            let e = RX_ML[mark + hit * slots + 1];
            RX_ML.resize(mark);
            return s, e;
        }
        RX_ML.resize(mark);
    }
    ed_fail_s("No match for ", so, sn, ".");
    return 0, 0;
}

recursive fn sm_addr(ai: i64, d0: i64, d1: i64, b0: i64, b1: i64, sign: i64) -> i64, i64 {
    let a = SM_A[ai];
    let count = ED_CP.len;
    if a.k == A_COMMA || a.k == A_SEMI {
        var l0 = 0;
        var l1 = 0;
        if a.l >= 0 {
            let x0, x1 = sm_addr(a.l, d0, d1, b0, b1, 0);
            l0 = x0;
            l1 = x1;
        }
        if ED_ERR.len > 0 { return 0, 0; }
        var r1 = count;
        if a.r >= 0 {
            if a.k == A_SEMI {
                let y0, y1 = sm_addr(a.r, l0, l1, l0, l1, 0);
                r1 = y1;
            } else {
                let y0, y1 = sm_addr(a.r, d0, d1, b0, b1, 0);
                r1 = y1;
            }
        }
        if ED_ERR.len > 0 { return 0, 0; }
        if r1 < l0 { ed_fail("The second address is before the first one."); return 0, 0; }
        return l0, r1;
    }
    var x0 = b0;
    var x1 = b1;
    var sg = sign;
    var p = a.first;
    while p >= 0 && ED_ERR.len == 0 {
        let part = SM_A[p];
        let k = part.k;
        if k == A_PLUS || k == A_MINUS {
            sg = if k == A_PLUS { 1 } else { -1 };
            let nx = part.next;
            if nx < 0 || SM_A[nx].k == A_PLUS || SM_A[nx].k == A_MINUS {
                let y0, y1 = sm_line(1, x0, x1, sg);
                x0 = y0;
                x1 = y1;
            }
            p = nx;
            continue;
        }
        if k == A_LINE {
            let y0, y1 = sm_line(part.n, x0, x1, sg);
            x0 = y0;
            x1 = y1;
        } else if k == A_CHAR {
            let y0, y1 = sm_char(part.n, x0, x1, sg);
            x0 = y0;
            x1 = y1;
        } else if k == A_DOT {
            x0 = d0;
            x1 = d1;
        } else if k == A_END {
            x0 = count;
            x1 = count;
        } else if k == A_FWD {
            let y0, y1 = sm_search(part.so, part.sn, if sg >= 0 { x1 } else { x0 }, sg >= 0);
            x0 = y0;
            x1 = y1;
        } else if k == A_BACK {
            // As in sam: ? turns the direction around.
            var back = -sg;
            if back == 0 { back = -1; }
            let y0, y1 = sm_search(part.so, part.sn, if back >= 0 { x1 } else { x0 }, back >= 0);
            x0 = y0;
            x1 = y1;
        }
        sg = 0;
        p = part.next;
    }
    return x0, x1;
}

fn sm_resolve(ai: i64, d0: i64, d1: i64) -> i64, i64 {
    if ai < 0 { return d0, d1; }
    let x0, x1 = sm_addr(ai, d0, d1, d0, d1, 0);
    return x0, x1;
}

// --- sam commands ----------------------------------------------------------

fn sm_edit(s: i64, e: i64, o: i64, n: i64) { SM_E.push(SmE { s: s, e: e, o: o, n: n, idx: SM_E.len }); }

fn sm_print_start() -> i64 { SM_PB.len }
fn sm_print_end(o: i64) { SM_PS.push(o); SM_PS.push(SM_PB.len - o); }

recursive fn sm_run(ci: i64, dot0: i64, dot1: i64) -> i64, i64 {
    let c = SM_C[ci];
    let k = c.k;
    let d0, d1 = sm_resolve(c.addr, dot0, dot1);
    if ED_ERR.len > 0 { return 0, 0; }
    if k == C_SELECT { return d0, d1; }
    if k == C_X || k == C_Y {
        var re = -1;
        if c.ro < 0 {
            // With no pattern, x loops over lines. The last line counts also without a newline.
            RX_P.clear();
            RX_P.push('.');
            RX_P.push('*');
            RX_P.push('\\');
            RX_P.push('n');
            RX_P.push('?');
            re = rx_get(SM_IC);
        } else {
            re = sm_regex(c.ro, c.rn);
        }
        if re < 0 { return 0, 0; }
        let slots = 2 * (RXS[re].groups + 1);
        let mark, n = rx_all(re, d0, d1);
        var l0 = d0;
        var l1 = d1;
        var p = d0;
        for i in n {
            let s = RX_ML[mark + i * slots];
            let e = RX_ML[mark + i * slots + 1];
            if k == C_X {
                let y0, y1 = sm_run(c.inner, s, e);
                l0 = y0;
                l1 = y1;
            } else {
                let y0, y1 = sm_run(c.inner, p, s);
                l0 = y0;
                l1 = y1;
                p = e;
            }
            if ED_ERR.len > 0 { return 0, 0; }
        }
        RX_ML.resize(mark);
        if k == C_Y {
            let y0, y1 = sm_run(c.inner, p, max(p, d1));
            l0 = y0;
            l1 = y1;
        }
        return l0, l1;
    }
    if k == C_G || k == C_V {
        let re = sm_regex(c.ro, c.rn);
        if re < 0 { return 0, 0; }
        let found = rx_first(re, d0, d1);
        if found == (k == C_G) {
            let y0, y1 = sm_run(c.inner, d0, d1);
            return y0, y1;
        }
        return d0, d1;
    }
    if k == C_S {
        let re = sm_regex(c.ro, c.rn);
        if re < 0 { return 0, 0; }
        let groups = RXS[re].groups;
        let slots = 2 * (groups + 1);
        let mark, n = rx_all(re, d0, d1);
        let nth = max(1, c.n);
        var chosen = 0;
        for i in n {
            if (c.glob && i >= nth - 1) || (!c.glob && i == nth - 1) {
                let mo = mark + i * slots;
                let o = ED_S.len;
                rx_expand(c.to, c.tn, mo, groups);
                sm_edit(RX_ML[mo], RX_ML[mo + 1], o, ED_S.len - o);
                chosen++;
            }
        }
        RX_ML.resize(mark);
        if chosen == 0 { ed_fail_s("No match for ", c.ro, c.rn, " in the selection."); return 0, 0; }
        return d0, d1;
    }
    if k == C_CHANGE { sm_edit(d0, d1, c.to, c.tn); return d0, d1; }
    if k == C_APPEND { sm_edit(d1, d1, c.to, c.tn); return d0, d1; }
    if k == C_INSERT { sm_edit(d0, d0, c.to, c.tn); return d0, d1; }
    if k == C_DELETE { sm_edit(d0, d1, 0, 0); return d0, d1; }
    if k == C_MOVE || k == C_COPY {
        let t0, t1 = sm_resolve(c.target, d0, d1);
        if ED_ERR.len > 0 { return 0, 0; }
        if k == C_MOVE && t1 > d0 && t1 < d1 { ed_fail("The text cannot move into itself."); return 0, 0; }
        let o = ED_S.len;
        for i in d0..d1 { let v = ED_CP[i]; ED_S.push(v); }
        sm_edit(t1, t1, o, d1 - d0);
        if k == C_MOVE { sm_edit(d0, d1, 0, 0); }
        return d0, d1;
    }
    if k == C_PRINT {
        let o = sm_print_start();
        ed_put_text(SM_PB, d0, d1);
        sm_print_end(o);
        return d0, d1;
    }
    if k == C_LINES {
        var first = 1;
        for i in d0 { if ED_CP[i] == '\n' { first++; } }
        var last = first;
        for i in d0..d1 { if ED_CP[i] == '\n' { last++; } }
        if d1 > d0 && ED_CP[d1 - 1] == '\n' { last--; }
        let o = sm_print_start();
        if first == last { format(SM_PB, "line ", first); } else { format(SM_PB, "lines ", first, " to ", last); }
        format(SM_PB, "; characters #", d0, ",#", d1);
        sm_print_end(o);
        return d0, d1;
    }
    // C_BLOCK
    var ch = c.first;
    while ch >= 0 {
        let y0, y1 = sm_run(ch, d0, d1);
        if ED_ERR.len > 0 { return 0, 0; }
        ch = SM_C[ch].next;
    }
    return d0, d1;
}

// Runs one command on ED_CP with the selection s0..s1. Makes the changes in
// ED_CP. Returns the new selection and the number of changes.
fn sm_run_one(ci: i64, s0: i64, s1: i64) -> i64, i64, i64 {
    SM_E.clear();
    let d0, d1 = sm_run(ci, s0, s1);
    if ED_ERR.len > 0 { return 0, 0, 0; }
    // Changes in file order. Two changes may not overlap.
    sort(SM_E) { a, b => a.s < b.s || (a.s == b.s && a.idx < b.idx) };
    for i in 1..SM_E.len {
        if SM_E[i].s < SM_E[i - 1].e { ed_fail("Two changes overlap. Make the changes in separate commands."); return 0, 0, 0; }
    }
    if SM_E.len == 0 { return d0, d1, 0; }
    SM_NEW.clear();
    var p = 0;
    var new_start = -1;
    var new_end = 0;
    for i in SM_E.len {
        let e = SM_E[i];
        for j in p..e.s { let v = ED_CP[j]; SM_NEW.push(v); }
        if new_start < 0 { new_start = SM_NEW.len; }
        for j in e.n { let v = ED_S[e.o + j]; SM_NEW.push(v); }
        new_end = SM_NEW.len;
        p = max(p, e.e);
    }
    for j in p..ED_CP.len { let v = ED_CP[j]; SM_NEW.push(v); }
    ED_CP.clear();
    for j in SM_NEW.len { let v = SM_NEW[j]; ED_CP.push(v); }
    return new_start, new_end, SM_E.len;
}

fn edit_sam(out: u8[>..]&, command: u8[:], text: u8[:], sel_s: i64, sel_e: i64, ignore_case: bool) {
    ed_reset();
    SM_IC = ignore_case;
    ed_load(text);
    let s0 = ed_index(sel_s);
    let s1 = max(s0, ed_index(sel_e));
    each_utf8(command) { SM_P.push(it); };
    SM_I = 0;
    sm_program();
    if ED_ERR.len == 0 && SM_TOP.len == 0 { ed_fail("Type a command, for example ,x/old/c/new/."); }
    if ED_ERR.len > 0 { ed_error_json(out); return; }
    SM_ORIG.clear();
    for j in ED_CP.len { let v = ED_CP[j]; SM_ORIG.push(v); }
    var a = s0;
    var b = s1;
    var changes = 0;
    var all_select = true;
    for t in SM_TOP.len {
        let ci = SM_TOP[t];
        if SM_C[ci].k != C_SELECT { all_select = false; }
        let x0, x1, n = sm_run_one(ci, a, b);
        if ED_ERR.len > 0 { ed_error_json(out); return; }
        a = x0;
        b = x1;
        changes += n;
    }
    var changed = ED_CP.len != SM_ORIG.len;
    if !changed { for j in ED_CP.len { if ED_CP[j] != SM_ORIG[j] { changed = true; break; } } }
    // The new text and the byte offsets of the selection.
    var t: u8[>..] = [];
    var ba = 0;
    var bb = 0;
    var sel_u16 = 0;
    for j in ED_CP.len {
        if j == a { ba = t.len; }
        if j == b { bb = t.len; }
        if j >= a && j < b { sel_u16 += if ED_CP[j] >= 0x10000 { 2 } else { 1 }; }
        push_utf8(t, ED_CP[j]);
    }
    if a >= ED_CP.len { ba = t.len; }
    if b >= ED_CP.len { bb = t.len; }
    out.append("{\"text\":");
    if changed { json_str(out, t); } else { out.append("null"); }
    format(out, ",\"selection\":[", ba, ",", bb, "],\"printed\":[");
    var i = 0;
    while i < SM_PS.len {
        if i > 0 { out.push(','); }
        json_str(out, SM_PB[SM_PS[i]..SM_PS[i] + SM_PS[i + 1]]);
        i += 2;
    }
    out.append("],\"summary\":");
    var sum: u8[>..] = [];
    let printed = SM_PS.len / 2;
    if changes > 0 {
        format(sum, changes, if changes == 1 { " change." } else { " changes." });
    } else if printed > 0 {
        format(sum, "Results: ", printed, ".");
    } else if all_select {
        format(sum, "Selected characters: ", sel_u16, ".");
    } else if !changed && s0 == s1 && !has_prefix(trim_sp(command), ",") {
        sum.append("No changes. Dot is empty. Put , before the command to use the whole file.");
    } else {
        sum.append("No changes.");
    }
    json_str(out, sum);
    out.push('}');
}

// --- line differences (the Myers algorithm) -------------------------------

// The lines of the old text (a) and the new text (b): byte ranges.
var LD_A: u8[>..] = [];
var LD_B: u8[>..] = [];
var LD_AS: i64[>..] = [];
var LD_AE: i64[>..] = [];
var LD_BS: i64[>..] = [];
var LD_BE: i64[>..] = [];
// Integer codes of the changed middle part, for the Myers algorithm.
var LD_CA: i64[>..] = [];
var LD_CB: i64[>..] = [];
// Equal pairs from ld_myers, in order.
var LD_PX: i64[>..] = [];
var LD_PY: i64[>..] = [];
// The Myers trace: for each d, v[k] for k in -(d+1)..d+1.
var LD_TR: i64[>..] = [];
var LD_TO: i64[>..] = [];
var LD_V: i64[>..] = [];
// The changes: old range, new range.
var LD_CH: i64[>..] = [];

fn ld_split(t: u8[:], s: i64[>..]&, e: i64[>..]&) {
    s.clear();
    e.clear();
    var p = 0;
    for c, i in t {
        if c == '\n' { s.push(p); e.push(i); p = i + 1; }
    }
    s.push(p);
    e.push(t.len);
}

fn ld_a(i: i64) -> u8[:] { LD_A[LD_AS[i]..LD_AE[i]] }
fn ld_b(i: i64) -> u8[:] { LD_B[LD_BS[i]..LD_BE[i]] }

// A line of the joined list: a lines first, then b lines.
fn ld_line(i: i64, na: i64, pre: i64) -> u8[:] {
    if i < na { return ld_a(pre + i); }
    return ld_b(pre + i - na);
}

// The equal pairs of a shortest edit script of LD_CA and LD_CB into LD_PX and
// LD_PY, or false when the texts are too different for a fast answer.
fn ld_myers(max_cost: i64) -> bool {
    let n = LD_CA.len;
    let m = LD_CB.len;
    let mx = n + m;
    let limit = min(mx, max_cost);
    let offset = mx + 1;
    LD_V.clear();
    for i in 2 * mx + 3 { LD_V.push(0); }
    LD_TR.clear();
    LD_TO.clear();
    var found = false;
    var d = 0;
    while d <= limit && !found {
        LD_TO.push(LD_TR.len);
        for k in -(d + 1)..d + 2 { let v = LD_V[offset + k]; LD_TR.push(v); }
        var k = -d;
        while k <= d {
            var x = 0;
            if k == -d || (k != d && LD_V[offset + k - 1] < LD_V[offset + k + 1]) {
                x = LD_V[offset + k + 1];
            } else {
                x = LD_V[offset + k - 1] + 1;
            }
            var y = x - k;
            while x < n && y < m && LD_CA[x] == LD_CB[y] { x++; y++; }
            LD_V[offset + k] = x;
            if x >= n && y >= m { found = true; break; }
            k += 2;
        }
        d++;
    }
    if !found { return false; }
    // Walk back through the trace to find the equal pairs.
    LD_PX.clear();
    LD_PY.clear();
    var x = n;
    var y = m;
    var dd = LD_TO.len - 1;
    while dd >= 0 {
        let base = LD_TO[dd] + dd + 1;   // the index of k = 0
        let k = x - y;
        var prev_k = 0;
        if k == -dd || (k != dd && LD_TR[base + k - 1] < LD_TR[base + k + 1]) { prev_k = k + 1; } else { prev_k = k - 1; }
        let prev_x = LD_TR[base + prev_k];
        let prev_y = prev_x - prev_k;
        while x > prev_x && y > prev_y {
            x--;
            y--;
            LD_PX.push(x);
            LD_PY.push(y);
        }
        if dd > 0 { x = prev_x; y = prev_y; }
        dd--;
    }
    reverse(LD_PX);
    reverse(LD_PY);
    return true;
}

// The changed regions into LD_CH: old start, old end, new start, new end.
fn ld_changes() {
    LD_CH.clear();
    let na = LD_AS.len;
    let nb = LD_BS.len;
    var prefix = 0;
    while prefix < na && prefix < nb && ld_a(prefix) == ld_b(prefix) { prefix++; }
    var suffix = 0;
    while suffix < na - prefix && suffix < nb - prefix && ld_a(na - 1 - suffix) == ld_b(nb - 1 - suffix) { suffix++; }
    let ca = na - prefix - suffix;
    let cb = nb - prefix - suffix;
    if ca == 0 && cb == 0 { return; }
    if ca == 0 || cb == 0 {
        LD_CH.push(prefix); LD_CH.push(prefix + ca); LD_CH.push(prefix); LD_CH.push(prefix + cb);
        return;
    }
    // Integer codes compare faster than strings.
    var idx: i64[>..] = [];
    for i in ca + cb { idx.push(i); }
    sort(idx) { p, q => compare(ld_line(p, ca, prefix), ld_line(q, ca, prefix)) < 0 };
    var codes: i64[>..] = [];
    for i in ca + cb { codes.push(0); }
    var code = 0;
    for i in idx.len {
        if i > 0 && ld_line(idx[i], ca, prefix) != ld_line(idx[i - 1], ca, prefix) { code++; }
        codes[idx[i]] = code;
    }
    LD_CA.clear();
    LD_CB.clear();
    for i in ca { LD_CA.push(codes[i]); }
    for i in cb { LD_CB.push(codes[ca + i]); }
    if !ld_myers(20000) {
        LD_CH.push(prefix); LD_CH.push(prefix + ca); LD_CH.push(prefix); LD_CH.push(prefix + cb);
        return;
    }
    var i = 0;
    var j = 0;
    for t in LD_PX.len + 1 {
        let mi = if t < LD_PX.len { LD_PX[t] } else { ca };
        let mj = if t < LD_PX.len { LD_PY[t] } else { cb };
        if mi > i || mj > j {
            LD_CH.push(prefix + i); LD_CH.push(prefix + mi); LD_CH.push(prefix + j); LD_CH.push(prefix + mj);
        }
        i = mi + 1;
        j = mj + 1;
    }
}

fn ld_line_json(out: u8[>..]&, first: bool, op: u8[:], t: u8[:], o: i64, n: i64) {
    if !first { out.push(','); }
    format(out, "{\"op\":\"", op, "\",\"text\":");
    json_str(out, t);
    if o > 0 { format(out, ",\"old\":", o); }
    if n > 0 { format(out, ",\"new\":", n); }
    out.push('}');
}

fn edit_diff(out: u8[>..]&, old: u8[:], new: u8[:]) {
    LD_A.clear();
    LD_A.append(old);
    LD_B.clear();
    LD_B.append(new);
    ld_split(LD_A, LD_AS, LD_AE);
    ld_split(LD_B, LD_BS, LD_BE);
    ld_changes();
    out.push('[');
    var first = true;
    var i = 0;
    var j = 0;
    var c = 0;
    while c <= LD_CH.len {
        let o0 = if c < LD_CH.len { LD_CH[c] } else { LD_AS.len };
        while i < o0 {
            ld_line_json(out, first, "same", ld_a(i), i + 1, j + 1);
            first = false;
            i++;
            j++;
        }
        if c == LD_CH.len { break; }
        for k in LD_CH[c]..LD_CH[c + 1] { ld_line_json(out, first, "remove", ld_a(k), k + 1, 0); first = false; }
        for k in LD_CH[c + 2]..LD_CH[c + 3] { ld_line_json(out, first, "add", ld_b(k), 0, k + 1); first = false; }
        i = LD_CH[c + 1];
        j = LD_CH[c + 3];
        c += 4;
    }
    out.push(']');
}

// --- commit messages -------------------------------------------------------
//
// Commit messages that say what changed in the presentation: slides and
// sections added, edited, renamed, moved, or removed, and front matter.
//
//     Add slide “Wave speed”, edit 2 slides
//
//     - Add slide “Wave speed”
//     - Edit slide “The heat equation”
//     - Edit slide “Summary”

let CV_ADD = 0;
let CV_EDIT = 1;
let CV_REMOVE = 2;
let CV_RENAME = 3;
let CV_MOVE = 4;
let CV_CHANGE = 5;

let CN_TITLE = 0;     // title slide
let CN_SECTION = 1;
let CN_SLIDE = 2;
let CN_FRONT = 3;     // front matter
let CN_TEXT = 4;

// A slide or a section: its kind, title and body text in CM_S.
struct CmPart { kind: i64, to: i64, tn: i64, bo: i64, bn: i64 }
struct CmKV { ko: i64, kn: i64, vo: i64, vn: i64 }
struct CmItem { verb: i64, noun: i64, to: i64, tn: i64 }

var CM_S: u8[>..] = [];
var CM_PA: CmPart[>..] = [];
var CM_PB: CmPart[>..] = [];
var CM_MA: CmKV[>..] = [];
var CM_MB: CmKV[>..] = [];
var CM_IT: CmItem[>..] = [];

fn cm_text(o: i64, n: i64) -> u8[:] { CM_S[o..o + n] }
fn cm_title(p: CmPart) -> u8[:] { CM_S[p.to..p.to + p.tn] }
fn cm_body(p: CmPart) -> u8[:] { CM_S[p.bo..p.bo + p.bn] }

fn cm_verb(v: i64) -> const u8[:] {
    if v == CV_ADD { return "Add"; }
    if v == CV_EDIT { return "Edit"; }
    if v == CV_REMOVE { return "Remove"; }
    if v == CV_RENAME { return "Rename"; }
    if v == CV_MOVE { return "Move"; }
    return "Change";
}

fn cm_noun(n: i64) -> const u8[:] {
    if n == CN_TITLE { return "title slide"; }
    if n == CN_SECTION { return "section"; }
    if n == CN_SLIDE { return "slide"; }
    if n == CN_FRONT { return "front matter"; }
    return "text";
}

fn cm_kind_noun(k: i64) -> i64 {
    if k == F_TITLE { return CN_TITLE; }
    if k == F_SECTION { return CN_SECTION; }
    return CN_SLIDE;
}

// Parses one version and copies its parts and its front matter.
fn cm_read(text: u8[:], parts: CmPart[>..]&, kv: CmKV[>..]&) {
    reset();
    SRC.clear();
    SRC.append(text);
    parse_source();
    parts.clear();
    kv.clear();
    for f in FR {
        let to = CM_S.len;
        if f.kind == F_TITLE { CM_S.append("Title slide"); } else { CM_S.append(sp_text(f.title)); }
        let tn = CM_S.len - to;
        // The body: the source of the blocks, without blank lines.
        var body: u8[>..] = [];
        let src = SRC[f.hs1..max(f.hs1, f.s1)];
        var p = 0;
        while p <= src.len {
            var e = index_of_byte(src, '\n', p);
            if e < 0 { e = src.len; }
            let line = src[p..e];
            if trim_all(line).len > 0 {
                if body.len > 0 { body.push('\n'); }
                var l = line;
                if l.len > 0 && l[l.len - 1] == '\r' { l = l[..l.len - 1]; }
                body.append(l);
            }
            p = e + 1;
        }
        let bo = CM_S.len;
        CM_S.append(trim_all(body));
        parts.push(CmPart { kind: f.kind, to: to, tn: tn, bo: bo, bn: CM_S.len - bo });
    }
    // The front matter: the last value of each key.
    var i = META.len - 1;
    while i >= 0 {
        let k = sp_text(META[i].k);
        var seen = false;
        for x in kv { if cm_text(x.ko, x.kn) == k { seen = true; } }
        if !seen {
            let ko = CM_S.len;
            CM_S.append(k);
            let vo = CM_S.len;
            CM_S.append(sp_text(META[i].v));
            kv.push(CmKV { ko: ko, kn: vo - ko, vo: vo, vn: CM_S.len - vo });
        }
        i--;
    }
}

fn cm_find(kv: CmKV[:], key: u8[:]) -> i64 {
    for x, i in kv { if cm_text(x.ko, x.kn) == key { return i; } }
    return -1;
}

// “text”, with at most 48 characters.
fn cm_quoted(out: u8[>..]&, s: u8[:]) {
    out.append("“");
    if char_count(s) > 48 {
        var n = 0;
        var i = 0;
        while i < s.len {
            if (s[i] & 0xC0) != 0x80 { n++; if n > 47 { break; } }
            out.push(s[i]);
            i++;
        }
        out.append("…");
    } else {
        out.append(s);
    }
    out.append("”");
}

// "slide “Two”", or "the title slide".
fn cm_name(out: u8[>..]&, p: CmPart) {
    if p.kind == F_TITLE { out.append("the title slide"); return; }
    out.append(cm_noun(cm_kind_noun(p.kind)));
    out.push(' ');
    cm_quoted(out, cm_title(p));
}

fn cm_item(verb: i64, noun: i64, to: i64) { CM_IT.push(CmItem { verb: verb, noun: noun, to: to, tn: CM_S.len - to }); }

// The display name of a theme for a front matter value, as Theme.named.
fn cm_theme_name(out: u8[>..]&, value: u8[:]) {
    let ids: (const u8[:])[20] = ["selenized", "catppuccin", "catppuccin-frappe", "catppuccin-macchiato", "everforest",
        "gruvbox", "solarized", "github", "tokyo-night", "tokyo-night-storm", "rose-pine", "rose-pine-moon", "ayu",
        "ayu-mirage", "one", "dracula", "monokai", "night-owl", "nord", "matrix"];
    let names: (const u8[:])[20] = ["Selenized", "Catppuccin", "Catppuccin Frappé", "Catppuccin Macchiato", "Everforest",
        "Gruvbox", "Solarized", "GitHub", "Tokyo Night", "Tokyo Night Storm", "Rosé Pine", "Rosé Pine Moon", "Ayu",
        "Ayu Mirage", "One", "Dracula", "Monokai", "Night Owl", "Nord", "Matrix"];
    let alias: (const u8[:])[26] = ["catppuccin-latte", "catppuccin-mocha", "latte", "mocha", "tokyo-night-day",
        "tokyonight", "tokyonight-day", "tokyonight-night", "tokyonight-storm", "rose-pine-dawn", "rose-pine-main",
        "ayu-dark", "ayu-light", "one-dark", "one-light", "one-dark-pro", "atom-one", "one-half-dark", "one-half-light",
        "alucard", "dracula-light", "light-owl", "monokai-pro", "github-light", "github-dark", ""];
    let alias_id: i64[26] = [1, 1, 1, 1, 8, 8, 8, 8, 9, 10, 10, 12, 12, 14, 14, 14, 14, 14, 14, 15, 15, 17, 16, 7, 7, 0];
    // Lower case, with - for spaces and underscores.
    var v: u8[>..] = [];
    for c in trim_sp(value) {
        if c == ' ' || c == '_' { v.push('-'); } else { v.push(lower(c)); }
    }
    if v.len == 0 { out.append(names[0]); return; }
    for a, i in alias { if a.len > 0 && a == v { out.append(names[alias_id[i]]); return; } }
    for id, i in ids { if id == v { out.append(names[i]); return; } }
    for id, i in ids {
        if (has_suffix(v, "-light") && v[..v.len - 6] == id) || (has_suffix(v, "-dark") && v[..v.len - 5] == id) {
            out.append(names[i]);
            return;
        }
    }
    // A longer name that starts with a theme id, such as gruvbox-material.
    var best = -1;
    for id, i in ids { if has_prefix(v, id) && (best < 0 || id.len > ids[best].len) { best = i; } }
    out.append(names[if best < 0 { 0 } else { best }]);
}

// Slide and section changes between two versions of the Markdown, into CM_IT.
fn cm_changes(old: u8[:], new: u8[:]) {
    // Front matter.
    var keys: (const u8[:])[>..] = [];
    for x in CM_MA { keys.push(cm_text(x.ko, x.kn)); }
    for x in CM_MB { if cm_find(CM_MA, cm_text(x.ko, x.kn)) < 0 { keys.push(cm_text(x.ko, x.kn)); } }
    sort(keys) { a, b => compare(a, b) < 0 };
    var changed: (const u8[:])[>..] = [];
    for k in keys {
        let ia = cm_find(CM_MA, k);
        let ib = cm_find(CM_MB, k);
        if ia >= 0 && ib >= 0 && cm_text(CM_MA[ia].vo, CM_MA[ia].vn) == cm_text(CM_MB[ib].vo, CM_MB[ib].vn) { continue; }
        if k == "title" && ib >= 0 {
            let to = CM_S.len;
            CM_S.append("Change the title to ");
            var q: u8[>..] = [];
            cm_quoted(q, cm_text(CM_MB[ib].vo, CM_MB[ib].vn));
            CM_S.append(q);
            cm_item(CV_CHANGE, CN_FRONT, to);
        } else if k == "theme" && ib >= 0 {
            let to = CM_S.len;
            CM_S.append("Change the theme to ");
            var q: u8[>..] = [];
            cm_theme_name(q, cm_text(CM_MB[ib].vo, CM_MB[ib].vn));
            CM_S.append(q);
            cm_item(CV_CHANGE, CN_FRONT, to);
        } else {
            changed.push(k);
        }
    }
    if changed.len > 0 {
        var t: u8[>..] = [];
        t.append("Change ");
        for k, i in changed { if i > 0 { t.append(", "); } t.append(k); }
        t.append(" in the front matter");
        let to = CM_S.len;
        CM_S.append(t);
        cm_item(CV_CHANGE, CN_FRONT, to);
    }

    // Match by kind and title, in order.
    var unmatched_old: i64[>..] = [];
    for i in CM_PA.len { unmatched_old.push(i); }
    var pair_a: i64[>..] = [];
    var pair_b: i64[>..] = [];
    var unmatched_new: i64[>..] = [];
    for p, j in CM_PB {
        var hit = -1;
        for u, k in unmatched_old {
            if CM_PA[u].kind == p.kind && cm_title(CM_PA[u]) == cm_title(p) { hit = k; break; }
        }
        if hit >= 0 {
            pair_a.push(unmatched_old[hit]);
            pair_b.push(j);
            remove_at(unmatched_old, hit);
        } else {
            unmatched_new.push(j);
        }
    }
    // A new title with the same content is a rename.
    var ren_a: i64[>..] = [];
    var ren_b: i64[>..] = [];
    var added: i64[>..] = [];
    for j in unmatched_new {
        let p = CM_PB[j];
        var hit = -1;
        for u, k in unmatched_old {
            if CM_PA[u].kind == p.kind && p.bn > 0 && cm_body(CM_PA[u]) == cm_body(p) { hit = k; break; }
        }
        if hit >= 0 {
            ren_a.push(unmatched_old[hit]);
            ren_b.push(j);
            remove_at(unmatched_old, hit);
        } else {
            added.push(j);
        }
    }
    for j in added {
        let p = CM_PB[j];
        if p.kind == F_TITLE && p.bn == 0 { continue; }
        var t: u8[>..] = [];
        t.append("Add ");
        cm_name(t, p);
        let to = CM_S.len;
        CM_S.append(t);
        cm_item(CV_ADD, cm_kind_noun(p.kind), to);
    }
    for r in ren_a.len {
        let pa = CM_PA[ren_a[r]];
        let pb = CM_PB[ren_b[r]];
        var t: u8[>..] = [];
        t.append("Rename ");
        t.append(cm_noun(cm_kind_noun(pb.kind)));
        t.push(' ');
        cm_quoted(t, cm_title(pa));
        t.append(" to ");
        cm_quoted(t, cm_title(pb));
        let to = CM_S.len;
        CM_S.append(t);
        cm_item(CV_RENAME, cm_kind_noun(pb.kind), to);
    }
    for r in pair_a.len {
        let pa = CM_PA[pair_a[r]];
        let pb = CM_PB[pair_b[r]];
        if cm_body(pa) == cm_body(pb) { continue; }
        var t: u8[>..] = [];
        t.append("Edit ");
        cm_name(t, pb);
        let to = CM_S.len;
        CM_S.append(t);
        cm_item(CV_EDIT, cm_kind_noun(pb.kind), to);
    }
    // Moved: matched parts outside the longest increasing run.
    var order: i64[>..] = [];
    for r in pair_a.len { order.push(r); }
    sort(order) { x, y => pair_a[x] < pair_a[y] };
    var longest: i64[>..] = [];
    for r in order {
        let x = pair_b[r];
        var k = -1;
        for l, li in longest { if l >= x { k = li; break; } }
        if k >= 0 { longest[k] = x; } else { longest.push(x); }
    }
    let moved = order.len - longest.len;
    if moved > 0 {
        let to = CM_S.len;
        if moved == 1 { CM_S.append("Move 1 slide"); } else { format(CM_S, "Move ", moved, " slides"); }
        cm_item(CV_MOVE, CN_SLIDE, to);
    }
    for i in unmatched_old {
        let p = CM_PA[i];
        if p.kind == F_TITLE && p.bn == 0 { continue; }
        var t: u8[>..] = [];
        t.append("Remove ");
        cm_name(t, p);
        let to = CM_S.len;
        CM_S.append(t);
        cm_item(CV_REMOVE, cm_kind_noun(p.kind), to);
    }
    if CM_IT.len == 0 && old != new {
        let to = CM_S.len;
        CM_S.append("Edit text");
        cm_item(CV_EDIT, CN_TEXT, to);
    }
}

// For example: "Add 2 slides, edit 3 slides".
fn cm_summarize(out: u8[>..]&) {
    var keys: i64[>..] = [];
    var counts: i64[>..] = [];
    for it in CM_IT {
        let key = it.verb * 16 + it.noun;
        var k = -1;
        for x, i in keys { if x == key { k = i; } }
        if k < 0 { keys.push(key); counts.push(1); } else { counts[k] += 1; }
    }
    var subject: u8[>..] = [];
    var two = 0;
    for key, i in keys {
        if i > 0 { subject.append(", "); }
        let verb = cm_verb(key / 16);
        let noun = key % 16;
        if i == 0 { subject.append(verb); } else { for c in verb { subject.push(lower(c)); } }
        let n = counts[i];
        if noun == CN_TEXT {
            subject.append(" text");
        } else {
            format(subject, " ", n, " ", cm_noun(noun));
            if n != 1 && noun != CN_FRONT { subject.push('s'); }
        }
        if i == 1 { two = subject.len; }
    }
    if char_count(subject) > 72 {
        out.append(subject[..two]);
        out.append(", and more");
        return;
    }
    out.append(subject);
}

fn edit_commit_message(out: u8[>..]&, old: u8[:], new: u8[:]) {
    CM_S.clear();
    CM_IT.clear();
    cm_read(old, CM_PA, CM_MA);
    cm_read(new, CM_PB, CM_MB);
    cm_changes(old, new);
    if CM_IT.len == 1 {
        out.append(cm_text(CM_IT[0].to, CM_IT[0].tn));
    } else if CM_IT.len == 0 {
        out.append("Edit text");
    } else {
        cm_summarize(out);
    }
    if CM_IT.len > 1 {
        out.append("\n");
        for it, i in CM_IT {
            if i >= 30 { break; }
            out.append("\n- ");
            out.append(cm_text(it.to, it.tn));
        }
        if CM_IT.len > 30 { format(out, "\n- And ", CM_IT.len - 30, " more changes"); }
    }
}
