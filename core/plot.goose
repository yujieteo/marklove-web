// Function plots: the `::: plot` division, as the app's Expression,
// PlotSpec (Content/Plot.swift) and HTMLExporter.plot.
//
// Public functions:
//   plot_reset()
//       Sets the slider counter to 0. Call it once at the start of each
//       document, as the app makes a new HTMLExporter.
//   plot_html(out: u8[>..]&, body: u8[:], step_attr: u8[:], id_prefix: u8[:])
//       Appends the HTML of the plot whose division body is `body`, the same
//       bytes as HTMLExporter.plot. `step_attr` is ` data-step="n"` or empty.
//       The slider ids are `<id_prefix>slider-<n>`, with n counted over the
//       document from 1. An empty id_prefix gives the app's ids.
//   plot_errors(out: u8[>..]&, body: u8[:])
//       Appends the PlotSpec.parse errors, each one followed by "\n".
//
// The numbers go out as the app writes them: %.2f, %.2e and %.17g with
// exact decimal rounding (as printf), and the shortest round-trip form for
// a Swift `\(Double)`.

import base;
import std;
import math;

extern fn sinh(x: f64) -> f64;
extern fn cosh(x: f64) -> f64;
extern fn tanh(x: f64) -> f64;

let PK_NUM = 0;
let PK_VAR = 1;
let PK_PAR = 2;
let PK_NEG = 3;
let PK_BIN = 4;
let PK_CALL = 5;

// An expression node. BIN: op is the operator byte. CALL: op is the
// function number, a the first argument in PARG, b the argument count.
struct PNode { k: i64, op: i64, v: f64, a: i64, b: i64 }
// A token: text at o, n in PSRC. k is 0 for a word or a number, otherwise
// the operator byte (`**` is '^').
struct PTok { o: i64, n: i64, k: i64 }
struct PPar { no: i64, nn: i64, lo: f64, hi: f64, init: f64, lo_o: i64, lo_n: i64 }
struct PCur { o: i64, n: i64, root: i64 }
struct PLine { a: i64, b: i64 }

var PSRC: u8[>..] = [];
var PN: PNode[>..] = [];
var PARG: i64[>..] = [];
// Call arguments while the parser reads them.
var PSTK: i64[>..<] = [];
var PT: PTok[>..] = [];
var PI_AT = 0;
var PEXPR_O = 0;
var PEXPR_N = 0;
var PUSE_PARS = false;
var PFAIL = false;
var PMSG: u8[>..] = [];
var PLN: PLine[>..] = [];
var PPARS: PPar[>..] = [];
var PCURS: PCur[>..] = [];
var PERR: u8[>..] = [];
var PNERR = 0;
var PX0: f64 = 0.0;
var PX1: f64 = 1.0;
var PHASY = false;
var PY0: f64 = 0.0;
var PY1: f64 = 1.0;
var PXL_O = 0;
var PXL_N = 0;
var PYL_O = 0;
var PYL_N = 0;
var PCONTROLS = 0;
var PDIG: u8[>..] = [];

fn plot_reset() { PCONTROLS = 0; }

// ---- Characters, as Swift's Character properties for the usual scripts.

// The code point at PSRC[i] and its byte length.
fn pl_cp(i: i64) -> i64, i64 {
    let c = PSRC[i];
    if c < 0x80 { return c, 1; }
    let n = utf8_len(c);
    if i + n > PSRC.len { return c, 1; }
    var v: i64 = 0;
    if n == 2 { v = c & 0x1F; } else if n == 3 { v = c & 0x0F; } else { v = c & 0x07; }
    for k in 1..n { v = (v << 6) | (PSRC[i + k] & 0x3F); }
    return v, n;
}

fn pl_is_space(cp: i64) -> bool {
    cp == ' ' || cp == '\t' || cp == 0xA0 || cp == 0x1680 || (cp >= 0x2000 && cp <= 0x200A) ||
        cp == 0x202F || cp == 0x205F || cp == 0x3000
}

fn pl_is_ws(cp: i64) -> bool {
    pl_is_space(cp) || (cp >= 0x0A && cp <= 0x0D) || cp == 0x85 || cp == 0x2028 || cp == 0x2029
}

fn pl_is_number(cp: i64) -> bool {
    (cp >= '0' && cp <= '9') || cp == 0xB2 || cp == 0xB3 || cp == 0xB9 || (cp >= 0xBC && cp <= 0xBE) ||
        (cp >= 0x660 && cp <= 0x669) || (cp >= 0x6F0 && cp <= 0x6F9) || (cp >= 0x966 && cp <= 0x96F) ||
        cp == 0x2070 || (cp >= 0x2074 && cp <= 0x2079) || (cp >= 0x2080 && cp <= 0x2089) ||
        (cp >= 0x2150 && cp <= 0x2189) || (cp >= 0x2460 && cp <= 0x249B) || (cp >= 0xFF10 && cp <= 0xFF19)
}

fn pl_is_letter(cp: i64) -> bool {
    if cp < 0x80 { return (cp >= 'a' && cp <= 'z') || (cp >= 'A' && cp <= 'Z'); }
    if cp == 0xAA || cp == 0xB5 || cp == 0xBA { return true; }
    if cp >= 0xC0 && cp <= 0x2AF { return cp != 0xD7 && cp != 0xF7; }
    if cp >= 0x370 && cp <= 0x3FF {
        return cp != 0x375 && cp != 0x37E && cp != 0x384 && cp != 0x385 && cp != 0x387 && cp != 0x3F6;
    }
    if cp >= 0x400 && cp <= 0x52F { return cp < 0x482 || cp > 0x489; }
    if (cp >= 0x531 && cp <= 0x556) || (cp >= 0x561 && cp <= 0x587) { return true; }
    if (cp >= 0x5D0 && cp <= 0x5EA) || (cp >= 0x620 && cp <= 0x64A) { return true; }
    if cp >= 0x1E00 && cp <= 0x1FBC { return true; }
    if cp == 0x2102 || cp == 0x2107 || (cp >= 0x210A && cp <= 0x2113) || cp == 0x2115 ||
        (cp >= 0x2119 && cp <= 0x211D) || cp == 0x2124 || cp == 0x2126 || cp == 0x2128 ||
        (cp >= 0x212A && cp <= 0x212D) || (cp >= 0x212F && cp <= 0x2139) { return true; }
    if (cp >= 0x3041 && cp <= 0x3096) || (cp >= 0x30A1 && cp <= 0x30FA) { return true; }
    if (cp >= 0x4E00 && cp <= 0x9FFF) || (cp >= 0xAC00 && cp <= 0xD7A3) { return true; }
    return false;
}

// Trims spaces (CharacterSet.whitespaces) from PSRC[a..b].
fn pl_trim(a: i64, b: i64) -> i64, i64 {
    var s = a;
    var e = b;
    while s < e {
        let cp, n = pl_cp(s);
        if !pl_is_space(cp) { break; }
        s += n;
    }
    while e > s {
        var k = e - 1;
        while k > s && (PSRC[k] & 0xC0) == 0x80 { k--; }
        let cp, n = pl_cp(k);
        if !pl_is_space(cp) { break; }
        e = k;
    }
    return s, e;
}

fn pl_lower_prefix(a: i64, b: i64, p: u8[:]) -> bool {
    if b - a < p.len { return false; }
    for i in p.len { if lower(PSRC[a + i]) != p[i] { return false; } }
    return true;
}

fn pl_src_eq(o: i64, n: i64, o2: i64, n2: i64) -> bool {
    if n != n2 { return false; }
    for i in n { if PSRC[o + i] != PSRC[o2 + i] { return false; } }
    return true;
}

fn pl_src_lower_is(o: i64, n: i64, s: u8[:]) -> bool {
    if n != s.len { return false; }
    for i in n { if lower(PSRC[o + i]) != s[i] { return false; } }
    return true;
}

fn pl_msg_src(o: i64, n: i64) { for i in o..o + n { PMSG.push(PSRC[i]); } }
fn pl_err_src(o: i64, n: i64) { for i in o..o + n { PERR.push(PSRC[i]); } }

// ---- Expressions

fn pl_fail2(a: u8[:], o: i64, n: i64, b: u8[:]) {
    if PFAIL { return; }
    PFAIL = true;
    PMSG.clear();
    PMSG.append(a);
    pl_msg_src(o, n);
    PMSG.append(b);
    pl_msg_src(PEXPR_O, PEXPR_N);
}

fn pl_fail(a: u8[:]) {
    if PFAIL { return; }
    PFAIL = true;
    PMSG.clear();
    PMSG.append(a);
    pl_msg_src(PEXPR_O, PEXPR_N);
}

// The token text as an error message shows it.
fn pl_fail_tok(a: u8[:], t: PTok, b: u8[:]) {
    if t.k == 0 { pl_fail2(a, t.o, t.n, b); return; }
    if PFAIL { return; }
    PFAIL = true;
    PMSG.clear();
    PMSG.append(a);
    PMSG.push(t.k as! u8);
    PMSG.append(b);
    pl_msg_src(PEXPR_O, PEXPR_N);
}

fn pl_node(k: i64, op: i64, v: f64, a: i64, b: i64) -> i64 {
    PN.push(PNode { k: k, op: op, v: v, a: a, b: b });
    return PN.len - 1;
}

fn pl_tokenize(a: i64, b: i64) -> bool {
    PT.clear();
    var i = a;
    while i < b {
        let cp, n = pl_cp(i);
        if pl_is_ws(cp) { i += n; continue; }
        var dot_num = false;
        if cp == '.' && i + 1 < b {
            let c2, n2 = pl_cp(i + 1);
            dot_num = pl_is_number(c2);
        }
        if pl_is_number(cp) || dot_num {
            var j = i;
            while j < b {
                let c, m = pl_cp(j);
                if !(pl_is_number(c) || c == '.') { break; }
                j += m;
            }
            if j < b && (PSRC[j] == 'e' || PSRC[j] == 'E') {
                var k = j + 1;
                if k < b && (PSRC[k] == '+' || PSRC[k] == '-') { k++; }
                if k < b {
                    let c, m = pl_cp(k);
                    if pl_is_number(c) {
                        while k < b {
                            let c3, m3 = pl_cp(k);
                            if !pl_is_number(c3) { break; }
                            k += m3;
                        }
                        j = k;
                    }
                }
            }
            PT.push(PTok { o: i, n: j - i, k: 0 });
            i = j;
            continue;
        }
        if pl_is_letter(cp) || cp == '_' {
            var j = i;
            while j < b {
                let c, m = pl_cp(j);
                if !(pl_is_letter(c) || pl_is_number(c) || c == '_') { break; }
                j += m;
            }
            PT.push(PTok { o: i, n: j - i, k: 0 });
            i = j;
            continue;
        }
        if cp == '*' && i + 1 < b && PSRC[i + 1] == '*' { PT.push(PTok { o: i, n: 2, k: '^' }); i += 2; continue; }
        if cp == '+' || cp == '-' || cp == '*' || cp == '/' || cp == '^' || cp == '(' || cp == ')' || cp == ',' {
            PT.push(PTok { o: i, n: 1, k: cp });
            i += 1;
            continue;
        }
        pl_fail2("Unexpected character \"", i, n, "\" in ");
        return false;
    }
    return true;
}

fn pl_peek(k: i64) -> bool { PI_AT < PT.len && PT[PI_AT].k == k }

// Swift's Double(String) on a token: a decimal number, or inf, infinity,
// nan and snan in any case.
fn pl_number(t: PTok) -> f64, bool {
    let c = PSRC[t.o];
    if is_digit(c) || c == '.' {
        var dots = 0;
        var i = 0;
        while i < t.n {
            let d = PSRC[t.o + i];
            if d == 'e' || d == 'E' { break; }
            if d == '.' { dots++; } else if !is_digit(d) { return 0.0, false; }
            i++;
        }
        if dots > 1 { return 0.0, false; }
        for k in i..t.n { if PSRC[t.o + k] >= 0x80 { return 0.0, false; } }
        let v, ok = pl_parse_num(PSRC[t.o..t.o + t.n]);
        return v, ok;
    }
    if pl_src_lower_is(t.o, t.n, "inf") || pl_src_lower_is(t.o, t.n, "infinity") { return 1.0 / 0.0, true; }
    if pl_src_lower_is(t.o, t.n, "nan") || pl_src_lower_is(t.o, t.n, "snan") { return 0.0 / 0.0, true; }
    return 0.0, false;
}

fn pl_param_index(t: PTok) -> i64 {
    if !PUSE_PARS { return -1; }
    for p, i in PPARS { if pl_src_eq(p.no, p.nn, t.o, t.n) { return i; } }
    return -1;
}

fn pl_func_index(t: PTok) -> i64 {
    let names: (const u8[:])[18] = ["sin", "cos", "tan", "exp", "log", "ln", "sqrt", "abs", "atan", "asin",
        "acos", "sinh", "cosh", "tanh", "min", "max", "floor", "ceil"];
    for s, i in names { if pl_src_lower_is(t.o, t.n, s) { return i; } }
    return -1;
}

recursive fn pl_sum() -> i64 {
    var a = pl_prod();
    if a < 0 { return -1; }
    while pl_peek('+') || pl_peek('-') {
        let op = PT[PI_AT].k;
        PI_AT++;
        let b = pl_prod();
        if b < 0 { return -1; }
        a = pl_node(PK_BIN, op, 0.0, a, b);
    }
    return a;
}

recursive fn pl_prod() -> i64 {
    var a = pl_unary();
    if a < 0 { return -1; }
    while PI_AT < PT.len {
        let k = PT[PI_AT].k;
        if k == '*' || k == '/' {
            PI_AT++;
            let b = pl_unary();
            if b < 0 { return -1; }
            a = pl_node(PK_BIN, k, 0.0, a, b);
        } else if k == '(' || k == 0 {
            let b = pl_unary();
            if b < 0 { return -1; }
            a = pl_node(PK_BIN, '*', 0.0, a, b);
        } else {
            break;
        }
    }
    return a;
}

recursive fn pl_unary() -> i64 {
    if pl_peek('-') {
        PI_AT++;
        let a = pl_unary();
        if a < 0 { return -1; }
        return pl_node(PK_NEG, 0, 0.0, a, 0);
    }
    if pl_peek('+') { PI_AT++; return pl_unary(); }
    return pl_pow();
}

recursive fn pl_pow() -> i64 {
    let a = pl_atom();
    if a < 0 { return -1; }
    if pl_peek('^') {
        PI_AT++;
        let b = pl_unary();
        if b < 0 { return -1; }
        return pl_node(PK_BIN, '^', 0.0, a, b);
    }
    return a;
}

recursive fn pl_atom() -> i64 {
    if PI_AT >= PT.len { PI_AT++; pl_fail("Unexpected end of "); return -1; }
    let t = PT[PI_AT];
    PI_AT++;
    if t.k == 0 {
        let v, ok = pl_number(t);
        if ok { return pl_node(PK_NUM, 0, v, 0, 0); }
    }
    if t.k == '(' {
        let a = pl_sum();
        if a < 0 { return -1; }
        let close = pl_peek(')');
        PI_AT++;
        if !close { pl_fail("Expected ) in "); return -1; }
        return a;
    }
    if t.k == 0 {
        if pl_src_lower_is(t.o, t.n, "x") { return pl_node(PK_VAR, 0, 0.0, 0, 0); }
        let pi = pl_param_index(t);
        if pi >= 0 { return pl_node(PK_PAR, 0, 0.0, pi, 0); }
        if pl_src_lower_is(t.o, t.n, "pi") { return pl_node(PK_NUM, 0, PI, 0, 0); }
        if pl_src_lower_is(t.o, t.n, "e") { return pl_node(PK_NUM, 0, 2.718281828459045, 0, 0); }
        let f = pl_func_index(t);
        if f >= 0 {
            let open = pl_peek('(');
            PI_AT++;
            if !open { pl_fail2("Expected ( after ", t.o, t.n, " in "); return -1; }
            // The arguments wait on PSTK, above those of outer calls.
            let base = PSTK.len;
            let a0 = pl_sum();
            if a0 < 0 { return -1; }
            PSTK.push(a0);
            while pl_peek(',') {
                PI_AT++;
                let a1 = pl_sum();
                if a1 < 0 { return -1; }
                PSTK.push(a1);
            }
            let close = pl_peek(')');
            PI_AT++;
            if !close { pl_fail("Expected ) in "); return -1; }
            let start = PARG.len;
            let count = PSTK.len - base;
            for k in base..PSTK.len { PARG.push(PSTK[k]); }
            PSTK.resize(base);
            // log and ln are one function.
            let id = if f == 5 { 4 } else { f };
            return pl_node(PK_CALL, id, 0.0, start, count);
        }
    }
    pl_fail_tok("Unknown name \"", t, "\" in ");
    return -1;
}

// Parses PSRC[a..b]. Returns the root node, or -1 with the message in PMSG.
fn pl_parse_expr(a: i64, b: i64, use_pars: bool) -> i64 {
    PFAIL = false;
    PEXPR_O = a;
    PEXPR_N = b - a;
    PUSE_PARS = use_pars;
    if !pl_tokenize(a, b) { return -1; }
    PI_AT = 0;
    PSTK.clear();
    let e = pl_sum();
    if e < 0 { return -1; }
    if PI_AT < PT.len {
        let t = PT[PI_AT];
        pl_fail_tok("Unexpected \"", t, "\" in ");
        return -1;
    }
    return e;
}

recursive fn pl_eval(i: i64, x: f64, vals: f64[:]) -> f64 {
    let n = PN[i];
    if n.k == PK_NUM { return n.v; }
    if n.k == PK_VAR { return x; }
    if n.k == PK_PAR { return vals[n.a]; }
    if n.k == PK_NEG { return -pl_eval(n.a, x, vals); }
    if n.k == PK_BIN {
        let l = pl_eval(n.a, x, vals);
        let r = pl_eval(n.b, x, vals);
        if n.op == '+' { return l + r; }
        if n.op == '-' { return l - r; }
        if n.op == '*' { return l * r; }
        if n.op == '/' { return l / r; }
        return pow(l, r);
    }
    let a = pl_eval(PARG[n.a], x, vals);
    let f = n.op;
    if f == 14 || f == 15 {
        var m = a;
        for k in 1..n.b {
            let v = pl_eval(PARG[n.a + k], x, vals);
            if f == 14 { if v < m { m = v; } } else { if v > m { m = v; } }
        }
        return m;
    }
    // Swift evaluates every argument.
    for k in 1..n.b { let v = pl_eval(PARG[n.a + k], x, vals); }
    if f == 0 { return sin(a); }
    if f == 1 { return cos(a); }
    if f == 2 { return tan(a); }
    if f == 3 { return exp(a); }
    if f == 4 { return log(a); }
    if f == 6 { return sqrt(a); }
    if f == 7 { return if pl_neg(a) { -a } else { a }; }
    if f == 8 { return atan(a); }
    if f == 9 { return asin(a); }
    if f == 10 { return acos(a); }
    if f == 11 { return sinh(a); }
    if f == 12 { return cosh(a); }
    if f == 13 { return tanh(a); }
    if f == 16 { return floor(a); }
    return ceil(a);
}

// PlotSpec.constant: a finite value of an expression without x or sliders.
fn pl_constant(a: i64, b: i64) -> f64, bool {
    let e = pl_parse_expr(a, b, false);
    if e < 0 { return 0.0, false; }
    let none: f64[1] = [0.0];
    let v = pl_eval(e, 0.0, none[..0]);
    if is_nan(v) || is_inf(v) { return 0.0, false; }
    return v, true;
}

// ---- PlotSpec.parse

fn pl_error(m: u8[:]) { PERR.append(m); PERR.push('\n'); PNERR++; }

// Splits PSRC[a..b] at commas as Swift's split(separator:maxSplits:) with
// empty parts left out. The parts go to po, pn, trimmed. Returns the count.
fn pl_split(a: i64, b: i64, max_splits: i64, po: i64[8]&, pn: i64[8]&) -> i64 {
    var count = 0;
    var start = a;
    var i = a;
    while i < b {
        if PSRC[i] == ',' {
            let did = i > start;
            if did {
                if count < 8 {
                    let s, e = pl_trim(start, i);
                    po[count] = s;
                    pn[count] = e - s;
                }
                count++;
            }
            i++;
            start = i;
            if did && count == max_splits { break; }
            continue;
        }
        i++;
    }
    if start < b {
        if count < 8 {
            let s, e = pl_trim(start, b);
            po[count] = s;
            pn[count] = e - s;
        }
        count++;
    }
    return count;
}

fn pl_name_ok(o: i64, n: i64) -> bool {
    if n == 0 { return false; }
    var i = o;
    var first = true;
    while i < o + n {
        let cp, m = pl_cp(i);
        if !(pl_is_letter(cp) || pl_is_number(cp) || cp == '_') { return false; }
        if first && !pl_is_letter(cp) { return false; }
        first = false;
        i += m;
    }
    return !pl_src_lower_is(o, n, "x");
}

fn pl_parse(body: u8[:]) {
    PSRC.clear();
    PSRC.append(body);
    PN.clear();
    PARG.clear();
    PLN.clear();
    PPARS.clear();
    PCURS.clear();
    PERR.clear();
    PNERR = 0;
    PX0 = 0.0;
    PX1 = 1.0;
    PHASY = false;
    PY0 = 0.0;
    PY1 = 1.0;
    PXL_O = 0;
    PXL_N = 0;
    PYL_O = 0;
    PYL_N = 0;
    var start = 0;
    for i in 0..PSRC.len + 1 {
        if i == PSRC.len || PSRC[i] == '\n' {
            let s, e = pl_trim(start, i);
            PLN.push(PLine { a: s, b: e });
            start = i + 1;
        }
    }
    // Parameters first, because curves can use them.
    for li in PLN.len {
        let ln = PLN[li];
        guard pl_lower_prefix(ln.a, ln.b, "slider:") || pl_lower_prefix(ln.a, ln.b, "param:");
        let colon = index_of_byte(PSRC[..ln.b], ':', ln.a);
        var po: i64[8] = [0; 8];
        var pn: i64[8] = [0; 8];
        let count = pl_split(colon + 1, ln.b, 4, po, pn);
        var ok = count >= 3;
        var lo = 0.0;
        var hi = 0.0;
        if ok {
            let v, k = pl_constant(po[1], po[1] + pn[1]);
            lo = v;
            ok = k;
        }
        if ok {
            let v, k = pl_constant(po[2], po[2] + pn[2]);
            hi = v;
            ok = k && lo < hi;
        }
        if ok { ok = pl_name_ok(po[0], pn[0]); }
        if !ok {
            pl_error("Write a slider as: name, minimum, maximum, start, label.");
            continue;
        }
        var st = lo;
        if count > 3 {
            let v, k = pl_constant(po[3], po[3] + pn[3]);
            if k { st = v; }
        }
        var lab_o = po[0];
        var lab_n = pn[0];
        if count > 4 { lab_o = po[4]; lab_n = pn[4]; }
        let m = if lo >= st { lo } else { st };
        let init = if hi < m { hi } else { m };
        PPARS.push(PPar { no: po[0], nn: pn[0], lo: lo, hi: hi, init: init, lo_o: lab_o, lo_n: lab_n });
    }
    for li in PLN.len {
        let ln = PLN[li];
        guard ln.b > ln.a;
        if pl_lower_prefix(ln.a, ln.b, "slider:") || pl_lower_prefix(ln.a, ln.b, "param:") { continue; }
        let c0 = PSRC[ln.a];
        // ^[xy]\s*:  and  ^y\s*=
        var j = ln.a + 1;
        while j < ln.b {
            let cp, m = pl_cp(j);
            if !pl_is_ws(cp) { break; }
            j += m;
        }
        let after = if j < ln.b { PSRC[j] } else { 0 };
        if (c0 == 'x' || c0 == 'y') && after == ':' {
            var po: i64[8] = [0; 8];
            var pn: i64[8] = [0; 8];
            let count = pl_split(j + 1, ln.b, -1, po, pn);
            var ok = count == 2;
            var a = 0.0;
            var b = 0.0;
            if ok {
                let v, k = pl_constant(po[0], po[0] + pn[0]);
                a = v;
                ok = k;
            }
            if ok {
                let v, k = pl_constant(po[1], po[1] + pn[1]);
                b = v;
                ok = k && a < b;
            }
            if !ok {
                if c0 == 'x' { pl_error("Write the x range as: minimum, maximum."); }
                else { pl_error("Write the y range as: minimum, maximum."); }
                continue;
            }
            if c0 == 'x' { PX0 = a; PX1 = b; } else { PHASY = true; PY0 = a; PY1 = b; }
        } else if pl_lower_prefix(ln.a, ln.b, "xlabel:") {
            let s, e = pl_trim(ln.a + 7, ln.b);
            PXL_O = s;
            PXL_N = e - s;
        } else if pl_lower_prefix(ln.a, ln.b, "ylabel:") {
            let s, e = pl_trim(ln.a + 7, ln.b);
            PYL_O = s;
            PYL_N = e - s;
        } else if c0 == 'y' && after == '=' {
            let s, e = pl_trim(j + 1, ln.b);
            let root = pl_parse_expr(s, e, true);
            if root < 0 {
                PERR.append(PMSG);
                PERR.push('\n');
                PNERR++;
            } else {
                PCURS.push(PCur { o: s, n: e - s, root: root });
            }
        } else {
            PERR.append("Marklove does not understand this plot line: ");
            pl_err_src(ln.a, ln.b - ln.a);
            PERR.push('\n');
            PNERR++;
        }
    }
    if PCURS.len == 0 && PNERR == 0 { pl_error("Add a curve, for example: y = x^2"); }
}

// ---- Sampling and ranges

fn pl_init_values() -> f64[>..] {
    var v: f64[>..] = [];
    for p in PPARS { v.push(p.init); }
    return v;
}

fn pl_sample_x(k: i64, count: i64) -> f64 {
    PX0 + (PX1 - PX0) * k / count
}

// PlotSpec.resolvedYRange with the initial values.
fn pl_y_range() -> f64, f64 {
    if PHASY { return PY0, PY1; }
    var lo = 1.0 / 0.0;
    var hi = -1.0 / 0.0;
    let init = pl_init_values();
    for s in 2 * PPARS.len + 1 {
        var vals = copy(init);
        if s > 0 {
            let p = PPARS[(s - 1) / 2];
            vals[(s - 1) / 2] = if s % 2 == 1 { p.lo } else { p.hi };
        }
        for c in PCURS {
            for k in 0..121 {
                let y = pl_eval(c.root, pl_sample_x(k, 120), vals);
                if is_nan(y) || is_inf(y) { continue; }
                if y < lo { lo = y; }
                if y >= hi { hi = y; }
            }
        }
    }
    if is_inf(lo) || is_inf(hi) { return 0.0, 1.0; }
    if lo > 0.0 { lo = 0.0; }
    if hi < 0.0 { hi = 0.0; }
    let width = if hi - lo == 0.0 { 1.0 } else { hi - lo };
    let margin = width * 0.08;
    if hi > 0.0 { hi += margin; }
    if lo < 0.0 { lo -= margin; }
    return lo, hi;
}

// ---- Numbers, with exact decimal rounding

fn pl_bits(x: f64) -> u64 {
    let a: f64[1] = [x];
    let b = bytes_of(a);
    return b[0] | (b[1] as u64) << 8 | (b[2] as u64) << 16 | (b[3] as u64) << 24 |
        (b[4] as u64) << 32 | (b[5] as u64) << 40 | (b[6] as u64) << 48 | (b[7] as u64) << 56;
}

fn pl_neg(x: f64) -> bool { (pl_bits(x) >> 63) != 0 }

// The exact decimal digits of |v| (finite, not 0) into d, with no leading
// or trailing zeros. Returns the point p: |v| = 0.d * 10^p.
fn pl_exact(v: f64, d: u8[>..]&) -> i64 {
    let m, e = pl_split_bits(v);
    return pl_exact_me(m, e, d);
}

// |v| = m * 2^e, with m < 2^53.
fn pl_split_bits(v: f64) -> u64, i64 {
    let b = pl_bits(v);
    let be = ((b >> 52) & 0x7FF) as! i64;
    let frac = b & 0xFFFFFFFFFFFFF;
    if be == 0 { return frac, -1074; }
    return frac | 0x10000000000000, be - 1075;
}

// The exact decimal digits of m * 2^e (m > 0), as pl_exact.
fn pl_exact_me(m0: u64, e: i64, d: u8[>..]&) -> i64 {
    d.clear();
    var m = m0;
    var limbs: u64[>..] = [];
    while m > 0 { limbs.push(m % 1000000000); m = m / 1000000000; }
    var k = 0;
    if e >= 0 {
        var left = e;
        while left > 0 {
            let c = if left > 29 { 29 } else { left };
            let f: u64 = (1 as u64) << c;
            var carry: u64 = 0;
            for &l in limbs { let t = l * f + carry; l = t % 1000000000; carry = t / 1000000000; }
            while carry > 0 { limbs.push(carry % 1000000000); carry = carry / 1000000000; }
            left -= c;
        }
    } else {
        k = -e;
        var left = k;
        while left > 0 {
            let c = if left > 13 { 13 } else { left };
            var f: u64 = 1;
            for i in c { f = f * 5; }
            var carry: u64 = 0;
            for &l in limbs { let t = l * f + carry; l = t % 1000000000; carry = t / 1000000000; }
            while carry > 0 { limbs.push(carry % 1000000000); carry = carry / 1000000000; }
            left -= c;
        }
    }
    var top = limbs.len - 1;
    format_uint(d, limbs[top], 10, 0, ' ');
    while top > 0 {
        top--;
        format_uint(d, limbs[top], 10, 9, '0');
    }
    let point = d.len - k;
    var n = d.len;
    while n > 0 && d[n - 1] == '0' { n--; }
    d.resize(n);
    return point;
}

// m * 2^e as a double, by exact steps. The result must be a double.
fn pl_make(m: u64, e: i64) -> f64 {
    var v: f64 = m;
    var k = e;
    while k > 0 { v = v * 2.0; k--; }
    while k < 0 { v = v * 0.5; k++; }
    return v;
}

// -1, 0 or 1 as 0.a * 10^pa compares with 0.b * 10^pb (no zeros at the ends).
fn pl_dec_cmp(a: u8[:], pa: i64, b: u8[:], pb: i64) -> i64 {
    if pa != pb { return if pa < pb { -1 } else { 1 }; }
    let c = compare(a, b);
    return if c < 0 { -1 } else if c > 0 { 1 } else { 0 };
}

// A decimal number (digits, one point, an exponent) rounded correctly to
// the nearest double, as strtod and Swift's Double(String) do.
fn pl_parse_num(s: u8[:]) -> f64, bool {
    let g0, ok = parse_flt(s);
    if !ok { return 0.0, false; }
    // The digits and the point of the text.
    var dig: u8[>..] = [];
    var point = 0;
    var i = 0;
    var seen_point = false;
    while i < s.len && s[i] != 'e' && s[i] != 'E' {
        let c = s[i];
        if c == '.' { seen_point = true; }
        else if is_digit(c) {
            if dig.len == 0 && c == '0' { if seen_point { point--; } }
            else { dig.push(c); if !seen_point { point++; } }
        }
        i++;
    }
    if i < s.len {
        i++;
        var neg = false;
        if i < s.len && (s[i] == '+' || s[i] == '-') { neg = s[i] == '-'; i++; }
        var x = 0;
        while i < s.len && is_digit(s[i]) { if x < 100000 { x = x * 10 + (s[i] - '0'); } i++; }
        point += if neg { -x } else { x };
    }
    var n = dig.len;
    while n > 0 && dig[n - 1] == '0' { n--; }
    dig.resize(n);
    var g = g0;
    if dig.len == 0 || g == 0.0 || is_inf(g) { return g, true; }
    var mid: u8[>..] = [];
    for step in 4 {
        let m, e = pl_split_bits(g);
        // Above the midpoint with the next double: round up.
        let pu = pl_exact_me(2 * m + 1, e - 1, mid);
        let cu = pl_dec_cmp(dig, point, mid, pu);
        if cu > 0 || (cu == 0 && (m & 1) == 1) {
            g = if m + 1 == 0x20000000000000 { pl_make(0x10000000000000, e + 1) } else { pl_make(m + 1, e) };
            if is_inf(g) { return g, true; }
            continue;
        }
        // Below the midpoint with the previous double: round down.
        let edge = m == 0x10000000000000 && e > -1074;
        var pd = 0;
        if edge { pd = pl_exact_me(4 * m - 1, e - 2, mid); } else { pd = pl_exact_me(2 * m - 1, e - 1, mid); }
        let cd = pl_dec_cmp(dig, point, mid, pd);
        if cd < 0 || (cd == 0 && (m & 1) == 1) {
            g = if edge { pl_make(2 * m - 1, e - 1) } else { pl_make(m - 1, e) };
            continue;
        }
        break;
    }
    return g, true;
}

// Keeps the first n digits of d (0.d * 10^point), rounded half to even.
// Returns the new point. An empty d is zero.
fn pl_round(d: u8[>..]&, point: i64, n: i64) -> i64 {
    if n >= d.len { return point; }
    if n < 0 { d.clear(); return point; }
    let c = d[n];
    var up = c > '5';
    if c == '5' {
        var rest = false;
        for i in n + 1..d.len { if d[i] != '0' { rest = true; } }
        let odd = n > 0 && ((d[n - 1] - '0') & 1) == 1;
        up = rest || odd;
    }
    d.resize(n);
    var p = point;
    if up {
        var i = n - 1;
        while i >= 0 && d[i] == '9' { d[i] = '0'; i--; }
        if i >= 0 { d[i] = d[i] + 1; }
        else {
            d.clear();
            d.push('1');
            for j in n { d.push('0'); }
            d.resize(if n > 0 { n } else { 1 });
            p++;
        }
    }
    var len = d.len;
    while len > 0 && d[len - 1] == '0' { len--; }
    d.resize(len);
    return p;
}

fn pl_digit(d: u8[:], i: i64) -> u8 { if i >= 0 && i < d.len { d[i] } else { '0' } }

fn pl_exp(out: u8[>..]&, x: i64) {
    if x < 0 { out.push('-'); } else { out.push('+'); }
    let a = if x < 0 { -x } else { x };
    if a < 10 { out.push('0'); }
    format_int(out, a, 10, 0, ' ');
}

// printf %.<n>f
fn pl_fixed(out: u8[>..]&, v: f64, n: i64) {
    if is_nan(v) { out.append("nan"); return; }
    if pl_neg(v) { out.push('-'); }
    if is_inf(v) { out.append("inf"); return; }
    var p = 0;
    if v != 0.0 {
        p = pl_exact(v, PDIG);
        p = pl_round(PDIG, p, p + n);
    }
    if PDIG.len == 0 || v == 0.0 { PDIG.clear(); p = 0; }
    if p <= 0 { out.push('0'); } else { for i in p { out.push(pl_digit(PDIG, i)); } }
    if n > 0 {
        out.push('.');
        for i in n { out.push(pl_digit(PDIG, p + i)); }
    }
}

// printf %.2e
fn pl_e2(out: u8[>..]&, v: f64) {
    if pl_neg(v) { out.push('-'); }
    if v == 0.0 { out.append("0.00e+00"); return; }
    var p = pl_exact(v, PDIG);
    p = pl_round(PDIG, p, 3);
    out.push(pl_digit(PDIG, 0));
    out.push('.');
    out.push(pl_digit(PDIG, 1));
    out.push(pl_digit(PDIG, 2));
    out.push('e');
    pl_exp(out, p - 1);
}

// The digits in PDIG at point p, as a %g or Swift layout writes them.
fn pl_layout(out: u8[>..]&, p: i64, exp_form: bool, swift: bool) {
    if exp_form {
        out.push(PDIG[0]);
        if PDIG.len > 1 { out.push('.'); out.append(PDIG[1..]); }
        out.push('e');
        pl_exp(out, p - 1);
        return;
    }
    if p <= 0 {
        out.append("0.");
        for i in -p { out.push('0'); }
        out.append(PDIG);
        return;
    }
    for i in p { out.push(pl_digit(PDIG, i)); }
    if PDIG.len > p { out.push('.'); out.append(PDIG[p..]); }
    else if swift { out.append(".0"); }
}

// printf %.17g, as JSONSerialization writes a Double.
fn pl_g17(out: u8[>..]&, v: f64) {
    if pl_neg(v) { out.push('-'); }
    if v == 0.0 { out.push('0'); return; }
    var p = pl_exact(v, PDIG);
    p = pl_round(PDIG, p, 17);
    let x = p - 1;
    pl_layout(out, p, x < -4 || x >= 17, false);
}

// Swift's `\(Double)`: the shortest digits that read back as v.
fn pl_desc(out: u8[>..]&, v: f64) {
    if is_nan(v) { out.append("nan"); return; }
    if pl_neg(v) { out.push('-'); }
    if is_inf(v) { out.append("inf"); return; }
    if v == 0.0 { out.append("0.0"); return; }
    let a = abs(v);
    var p = 0;
    for n in 1..18 {
        p = pl_exact(a, PDIG);
        p = pl_round(PDIG, p, n);
        var t: u8[>..] = [];
        t.append("0.");
        t.append(PDIG);
        t.push('e');
        format_int(t, p, 10, 0, ' ');
        let back, ok = pl_parse_num(t);
        if ok && back == a { break; }
    }
    pl_layout(out, p, p < -3 || a > 9007199254740992.0, true);
}

// PlotSpec.format: three significant digits, or an exponent.
fn pl_fmt(out: u8[>..]&, v: f64) {
    if v == 0.0 { out.push('0'); return; }
    if is_nan(v) { out.append("nan"); return; }
    if is_inf(v) { if v < 0.0 { out.append("-inf"); } else { out.append("inf"); } return; }
    let a = abs(v);
    if a >= 1e7 || a < 1e-3 { pl_e2(out, v); return; }
    if v == round(v) { format_int(out, v as! i64, 10, 0, ' '); return; }
    let d = max(0, 2 - (floor(log10(a)) as! i64));
    var s: u8[>..] = [];
    pl_fixed(s, v, d);
    if contains_byte(s, '.') {
        var n = s.len;
        while n > 0 && s[n - 1] == '0' { n--; }
        if n > 0 && s[n - 1] == '.' { n--; }
        s.resize(n);
    }
    out.append(s);
}

// ---- HTML

// HTMLExporter.escape: & < > and ".
fn pl_esc(out: u8[>..]&, s: u8[:]) {
    for c in s {
        if c == '&' { out.append("&amp;"); }
        else if c == '<' { out.append("&lt;"); }
        else if c == '>' { out.append("&gt;"); }
        else if c == '"' { out.append("&quot;"); }
        else { out.push(c); }
    }
}

fn pl_esc_src(out: u8[>..]&, o: i64, n: i64) { pl_esc(out, PSRC[o..o + n]); }

// A JSON string as JSONSerialization writes it.
fn pl_json_str(out: u8[>..]&, s: u8[:]) {
    let hex = "0123456789abcdef";
    out.push('"');
    for c in s {
        if c == '"' { out.append("\\\""); }
        else if c == '\\' { out.append("\\\\"); }
        else if c == '/' { out.append("\\/"); }
        else if c == '\n' { out.append("\\n"); }
        else if c == '\r' { out.append("\\r"); }
        else if c == '\t' { out.append("\\t"); }
        else if c == 0x08 { out.append("\\b"); }
        else if c == 0x0C { out.append("\\f"); }
        else if c < 0x20 { out.append("\\u00"); out.push(hex[c >> 4]); out.push(hex[c & 15]); }
        else { out.push(c); }
    }
    out.push('"');
}

fn pl_finite(v: f64) -> bool { !is_nan(v) && !is_inf(v) }

fn pl_json(out: u8[>..]&, y0: f64, y1: f64) {
    var ok = pl_finite(PX0) && pl_finite(PX1) && pl_finite(y0) && pl_finite(y1);
    for p in PPARS { if !pl_finite(p.init) { ok = false; } }
    if !ok { out.append("{}"); return; }
    out.append("{\"curves\":[");
    for c, i in PCURS {
        if i > 0 { out.push(','); }
        pl_json_str(out, PSRC[c.o..c.o + c.n]);
    }
    out.append("],\"params\":[");
    for p, i in PPARS {
        if i > 0 { out.push(','); }
        out.append("{\"name\":");
        pl_json_str(out, PSRC[p.no..p.no + p.nn]);
        out.append(",\"value\":");
        pl_g17(out, p.init);
        out.push('}');
    }
    out.append("],\"x\":[");
    pl_g17(out, PX0);
    out.push(',');
    pl_g17(out, PX1);
    out.append("],\"y\":[");
    pl_g17(out, y0);
    out.push(',');
    pl_g17(out, y1);
    out.append("]}");
}

fn pl_color(out: u8[>..]&, i: i64) {
    out.append("var(--s");
    format_int(out, i % 6 + 1, 10, 0, ' ');
    out.push(')');
}

fn pl_sx(x: f64) -> f64 {
    let w = if PX1 - PX0 >= 1e-12 { PX1 - PX0 } else { 1e-12 };
    60.0 + (x - PX0) / w * (1000.0 - 60.0 - 20.0)
}

fn pl_sy(y: f64, y0: f64, y1: f64) -> f64 {
    let h = if y1 - y0 >= 1e-12 { y1 - y0 } else { 1e-12 };
    520.0 - 40.0 - (y - y0) / h * (520.0 - 20.0 - 40.0)
}

// PlotSpec.accessibilityDescription
fn pl_description(out: u8[>..]&) {
    var t: u8[>..] = [];
    t.append("Plot of ");
    for c, i in PCURS {
        if i > 0 { t.append("; "); }
        t.append("y = ");
        t.append(PSRC[c.o..c.o + c.n]);
    }
    t.append(" for ");
    if PXL_N == 0 { t.push('x'); } else { t.append(PSRC[PXL_O..PXL_O + PXL_N]); }
    t.append(" from ");
    pl_fmt(t, PX0);
    t.append(" to ");
    pl_fmt(t, PX1);
    if PPARS.len > 0 {
        t.append(" with ");
        for p, i in PPARS {
            if i > 0 { t.append(", "); }
            t.append(PSRC[p.lo_o..p.lo_o + p.lo_n]);
            t.append(" = ");
            pl_fmt(t, p.init);
        }
    }
    t.push('.');
    pl_esc(out, t);
}

fn plot_errors(out: u8[>..]&, body: u8[:]) {
    pl_parse(body);
    out.append(PERR);
}

fn plot_html(out: u8[>..]&, body: u8[:], step_attr: u8[:], id_prefix: u8[:]) {
    pl_parse(body);
    let y0, y1 = pl_y_range();
    out.append("<div class=\"plot\" data-plot=\"");
    var js: u8[>..] = [];
    pl_json(js, y0, y1);
    pl_esc(out, js);
    out.push('"');
    out.append(step_attr);
    out.append("><p class=\"labels\"><span>");
    pl_esc_src(out, PYL_O, PYL_N);
    out.append("</span><span>");
    pl_fmt(out, y0);
    out.append(" to ");
    pl_fmt(out, y1);
    out.append("</span></p><svg viewBox=\"0 0 1000 520\" preserveAspectRatio=\"none\" role=\"img\" aria-label=\"");
    pl_description(out);
    out.append("\">");
    // Axes
    let zy0 = if y0 >= 0.0 { y0 } else { 0.0 };
    let zy = if y1 < zy0 { y1 } else { zy0 };
    let zx0 = if PX0 >= 0.0 { PX0 } else { 0.0 };
    let zx = if PX1 < zx0 { PX1 } else { zx0 };
    out.append("<path class=\"axis\" d=\"M60.00 ");
    pl_fixed(out, pl_sy(zy, y0, y1), 2);
    out.append("H980.00\"/><path class=\"axis\" d=\"M");
    pl_fixed(out, pl_sx(zx), 2);
    out.append(" 480.00V20.00\"/>");
    // Curves
    let init = pl_init_values();
    let span = y1 - y0;
    for c, i in PCURS {
        out.append("<path class=\"curve\" style=\"stroke:");
        pl_color(out, i);
        out.append("\" d=\"");
        var pen = false;
        for k in 0..241 {
            let x = pl_sample_x(k, 240);
            let y = pl_eval(c.root, x, init);
            if is_nan(y) || is_inf(y) { pen = false; continue; }
            let m = if y0 - span >= y { y0 - span } else { y };
            let cy = if y1 + span < m { y1 + span } else { m };
            out.push(if pen { 'L' } else { 'M' });
            pl_fixed(out, pl_sx(x), 2);
            out.push(' ');
            pl_fixed(out, pl_sy(cy, y0, y1), 2);
            pen = true;
        }
        out.append("\"/>");
    }
    out.append("</svg><p class=\"labels\"><span>");
    pl_fmt(out, PX0);
    out.append("</span><span>");
    pl_esc_src(out, PXL_O, PXL_N);
    out.append("</span><span>");
    pl_fmt(out, PX1);
    out.append("</span></p>");
    if PCURS.len > 1 {
        out.append("<p class=\"labels\">");
        for c, i in PCURS {
            if i > 0 { out.push(' '); }
            out.append("<span style=\"color:");
            pl_color(out, i);
            out.append("\">y = ");
            pl_esc_src(out, c.o, c.n);
            out.append("</span>");
        }
        out.append("</p>");
    }
    if PPARS.len > 0 {
        out.append("<div class=\"controls\">");
        for p in PPARS {
            PCONTROLS++;
            var id: u8[>..] = [];
            id.append(id_prefix);
            id.append("slider-");
            format_int(id, PCONTROLS, 10, 0, ' ');
            out.append("<label for=\"");
            out.append(id);
            out.append("\">");
            pl_esc_src(out, p.lo_o, p.lo_n);
            out.append("</label><input type=\"range\" id=\"");
            out.append(id);
            out.append("\" name=\"");
            pl_esc_src(out, p.no, p.nn);
            out.append("\" min=\"");
            pl_desc(out, p.lo);
            out.append("\" max=\"");
            pl_desc(out, p.hi);
            out.append("\" step=\"");
            pl_desc(out, (p.hi - p.lo) / 100.0);
            out.append("\" value=\"");
            pl_desc(out, p.init);
            out.append("\" data-label=\"");
            pl_esc_src(out, p.lo_o, p.lo_n);
            out.append("\" aria-valuetext=\"");
            pl_esc_src(out, p.lo_o, p.lo_n);
            out.append(" = ");
            pl_fmt(out, p.init);
            out.append("\"><output for=\"");
            out.append(id);
            out.append("\">");
            pl_fmt(out, p.init);
            out.append("</output>");
        }
        out.append("</div>");
    }
    out.append("</div>");
}
