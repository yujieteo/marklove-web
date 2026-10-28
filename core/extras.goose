// Extras: equation lookup, math speech, the tour project, AI prompt text,
// and the listener package text. Ports of MathLocator, MathSpeech, Tour,
// DemoProject, PromptText and parts of ProjectPackage.
//
// Public functions:
//   math_at(out, text: u8[:], offset: i64)
//       The equation at a UTF-16 offset of `text`, as JSON
//       {"latex":"…","display":true|false,"start":n,"end":n} (UTF-16 offsets,
//       the range includes the dollar signs), or `null`.
//   math_speech(out, latex: u8[:])
//       The words for VoiceOver, as MathSpeech.spoken. The equation preview
//       in the app also removes commas and spaces at both ends.
//   tour_project(out)
//       The tour (demo) project as JSON {"name":"…","markdown":"…",
//       "assets":{"images/peafowl.png":"demo-peafowl.png"}}: each asset path in
//       the project maps to the bundled file that the page must supply.
//   revision_prompt(out)
//   listener_markdown(out)
//   public_assets(out)    JSON array of paths. The listener ZIP uses it.
//   private_assets(out)   JSON array of paths that only private notes use.
//                         The presenter ZIP uses public + private.
//       These use the parsed document (call `parse_source` first).
//   authoring_prompt(out, selected_draft: u8[:])
//       An empty draft (after a trim) adds no draft section.

import render;

// --- small helpers -------------------------------------------------------

// One code point of UTF-8 text at i: the value and the byte length.
fn ex_cp(s: u8[:], i: i64) -> i64, i64 {
    let c = s[i];
    let n = min(utf8_len(c), s.len - i);
    if n == 1 { return c, 1; }
    var v: i64 = (c as i64) & (if n == 2 { 0x1F } else if n == 3 { 0x0F } else { 0x07 });
    for k in 1..n { v = (v << 6) | ((s[i + k] as i64) & 0x3F); }
    return v, n;
}

// The byte index of a UTF-16 offset. An offset inside a character gives the
// next character.
fn ex_u16_to_byte(s: u8[:], u: i64) -> i64 {
    var n = 0;
    var i = 0;
    while i < s.len && n < u {
        let c = s[i];
        n += if (c & 0xF8) == 0xF0 { 2 } else { 1 };
        i += utf8_len(c);
    }
    return min(i, s.len);
}

// Words with one space between them, as `split(whereSeparator: isWhitespace)`.
fn ex_compact(out: u8[>..]&, s: u8[:]) {
    var first = true;
    var i = 0;
    while i < s.len {
        while i < s.len && (is_ws(s[i]) || s[i] == 0x0B || s[i] == 0x0C) { i++; }
        if i >= s.len { break; }
        if !first { out.push(' '); }
        first = false;
        while i < s.len && !(is_ws(s[i]) || s[i] == 0x0B || s[i] == 0x0C) { out.push(s[i]); i++; }
    }
}

// --- MathLocator ---------------------------------------------------------

fn ml_escaped(s: u8[:], i: i64) -> bool {
    var n = 0;
    var j = i - 1;
    while j >= 0 && s[j] == '\\' { n++; j--; }
    return n % 2 == 1;
}

// The end of the line that contains i, after its line break.
fn ml_line_end(s: u8[:], i: i64) -> i64 {
    var j = i;
    while j < s.len && s[j] != '\n' { j++; }
    return if j < s.len { j + 1 } else { j };
}

fn ml_line_start(s: u8[:], i: i64) -> i64 {
    var j = i;
    while j > 0 && s[j - 1] != '\n' { j--; }
    return j;
}

fn ml_found(out: u8[>..]&, text: u8[:], latex: u8[:], display: bool, a: i64, b: i64) {
    out.append("{\"latex\":");
    json_str(out, latex);
    out.append(if display { ",\"display\":true" } else { ",\"display\":false" });
    format(out, ",\"start\":", utf16_len(text[..a]), ",\"end\":", utf16_len(text[..b]), "}");
}

fn math_at(out: u8[>..]&, text: u8[:], offset: i64) {
    let length = text.len;
    if length == 0 { out.append("null"); return; }
    let loc = ex_u16_to_byte(text, max(0, offset));
    // Lines in code fences are not math.
    var fenced: Line[>..] = [];
    var tokens: i64[>..] = [];
    var in_fence = false;
    var fence_start = 0;
    var ls = 0;
    while ls < length {
        let le = ml_line_end(text, ls);
        let content = trim_sp(text[ls..le]);
        if has_prefix(content, "```") || has_prefix(content, "~~~") {
            if in_fence { fenced.push(Line { fence_start, le }); } else { fence_start = ls; }
            in_fence = !in_fence;
        } else if !in_fence {
            var i = ls;
            while i + 1 < le {
                if text[i] == '$' && text[i + 1] == '$' && !ml_escaped(text, i) { tokens.push(i); i += 2; }
                else { i++; }
            }
        }
        ls = le;
    }
    if in_fence { fenced.push(Line { fence_start, length }); }
    for f in fenced { if loc >= f.s && loc < f.e { out.append("null"); return; } }

    // Display math: pairs of "$$" in order.
    var k = 0;
    while k + 1 < tokens.len {
        let open = tokens[k];
        let close = tokens[k + 1];
        if loc >= open && loc <= close + 2 {
            let latex = trim_all(text[open + 2..close]);
            if latex.len == 0 { out.append("null"); return; }
            ml_found(out, text, latex, true, open, close + 2);
            return;
        }
        k += 2;
    }

    // Inline math: "$…$" on the line, outside code spans and display math.
    let at = min(loc, length - 1);
    let start = ml_line_start(text, at);
    let end = ml_line_end(text, at);
    var opens = -1;
    var in_code = false;
    var i = start;
    while i < end {
        let c = text[i];
        if c == '`' { in_code = !in_code; i++; continue; }
        if in_code || c != '$' || ml_escaped(text, i) { i++; continue; }
        if i + 1 < end && text[i + 1] == '$' { i += 2; continue; }
        if opens >= 0 {
            // A closing "$" follows a character that is not a space.
            let before = text[i - 1];
            if before != ' ' && before != '\t' && i > opens + 1 {
                if loc >= opens && loc <= i + 1 {
                    ml_found(out, text, text[opens + 1..i], false, opens, i + 1);
                    return;
                }
                opens = -1;
            }
        } else if i + 1 < end {
            // An opening "$" comes before a character that is not a space.
            let after = text[i + 1];
            if after != ' ' && after != '\t' && after != '\n' { opens = i; }
        }
        i++;
    }
    out.append("null");
}

// --- MathSpeech ----------------------------------------------------------
//
// The reader works on code points in MS_CP. Each function appends words to
// MS_W (spans of MS_T). A function that puts words before its arguments
// writes the result after them, then moves it down (ms_finish).

var MS_CP: i64[>..] = [];
var MS_I = 0;
var MS_T: u8[>..] = [];
var MS_W: Line[>..] = [];

fn ms_peek() -> i64 { if MS_I < MS_CP.len { MS_CP[MS_I] } else { -1 } }

fn ms_word(t: u8[:]) {
    let o = MS_T.len;
    MS_T.append(t);
    MS_W.push(Line { o, MS_T.len });
}

fn ms_word_cp(c: i64) {
    let o = MS_T.len;
    push_utf8(MS_T, c as u32);
    MS_W.push(Line { o, MS_T.len });
}

fn ms_copy(j: i64) { let w = MS_W[j]; MS_W.push(w); }
fn ms_copy_range(a: i64, b: i64) { for j in a..b { ms_copy(j); } }

fn ms_is(j: i64, t: u8[:]) -> bool { MS_T[MS_W[j].s..MS_W[j].e] == t }

// Moves the words from `mid` to the end down to `base`.
fn ms_finish(base: i64, mid: i64) {
    let n = MS_W.len - mid;
    for k in n { let w = MS_W[mid + k]; MS_W[base + k] = w; }
    MS_W.resize(base + n);
}

fn ms_skip_spaces() {
    while true {
        let c = ms_peek();
        if c == ' ' || c == '\n' || c == '\t' { MS_I++; } else { break; }
    }
}

fn ms_is_letter(c: i64) -> bool { c >= 0 && c < 128 && is_alpha(c as u8) }
fn ms_is_number(c: i64) -> bool {
    (c >= '0' && c <= '9') || c == 0xB2 || c == 0xB3 || c == 0xB9 || (c >= 0xBC && c <= 0xBE)
}

recursive fn ms_sequence(close: i64) {
    while true {
        ms_skip_spaces();
        let c = ms_peek();
        if c < 0 { break; }
        if close >= 0 && c == close { MS_I++; break; }
        if c == '}' { MS_I++; continue; }
        ms_item();
    }
}

recursive fn ms_argument() {
    ms_skip_spaces();
    let c = ms_peek();
    if c < 0 { return; }
    if c == '{' { MS_I++; ms_sequence('}'); return; }
    if c == '\\' { ms_item(); return; }
    MS_I++;
    ms_char_word(c);
}

// The raw text of a braced argument, for \text{...}.
fn ms_raw_argument() {
    let o = MS_T.len;
    ms_skip_spaces();
    if ms_peek() == '{' {
        MS_I++;
        var depth = 1;
        while MS_I < MS_CP.len {
            let c = MS_CP[MS_I];
            MS_I++;
            if c == '{' { depth++; }
            else if c == '}' { depth--; if depth == 0 { break; } }
            push_utf8(MS_T, c as u32);
        }
    }
    MS_W.push(Line { o, MS_T.len });
}

recursive fn ms_item() {
    let c = ms_peek();
    if c < 0 { return; }
    if c == '{' { MS_I++; ms_sequence('}'); return; }
    if c == '^' {
        MS_I++;
        let base = MS_W.len;
        ms_argument();
        ms_power(base);
        return;
    }
    if c == '_' { MS_I++; ms_word("sub"); ms_argument(); return; }
    if c == '\\' { ms_command_words(); return; }
    if ms_is_number(c) {
        let o = MS_T.len;
        var last_num = false;
        while MS_I < MS_CP.len {
            let d = MS_CP[MS_I];
            let ok = ms_is_number(d) ||
                (d == '.' && last_num && MS_I + 1 < MS_CP.len && ms_is_number(MS_CP[MS_I + 1]));
            if !ok { break; }
            push_utf8(MS_T, d as u32);
            last_num = ms_is_number(d);
            MS_I++;
        }
        MS_W.push(Line { o, MS_T.len });
        return;
    }
    MS_I++;
    ms_char_word(c);
}

// The words base.. are an exponent.
fn ms_power(base: i64) {
    let n = MS_W.len - base;
    if n == 1 && ms_is(base, "2") { MS_W.resize(base); ms_word("squared"); return; }
    if n == 1 && ms_is(base, "3") { MS_W.resize(base); ms_word("cubed"); return; }
    if n == 1 && ms_is(base, "prime") { return; }
    if n == 2 && ms_is(base, "prime") && ms_is(base + 1, "prime") { MS_W.resize(base); ms_word("double prime"); return; }
    let mid = MS_W.len;
    ms_word("to the power");
    ms_copy_range(base, mid);
    if n != 1 { ms_word(","); }
    ms_finish(base, mid);
}

fn ms_char_word(c: i64) {
    if c == '=' { ms_word("equals"); }
    else if c == '+' { ms_word("plus"); }
    else if c == '-' || c == 0x2212 { ms_word("minus"); }
    else if c == '<' { ms_word("less than"); }
    else if c == '>' { ms_word("greater than"); }
    else if c == '/' { ms_word("over"); }
    else if c == '(' { ms_word("open paren"); }
    else if c == ')' { ms_word("close paren"); }
    else if c == '[' { ms_word("open bracket"); }
    else if c == ']' { ms_word("close bracket"); }
    else if c == '|' { ms_word("bar"); }
    else if c == '!' { ms_word("factorial"); }
    else if c == '\'' { ms_word("prime"); }
    else if c == ',' { ms_word(","); }
    else if c == '&' || c == '~' { ms_word(""); }
    else if c == 0xD7 || c == 0xB7 { ms_word("times"); }
    else {
        // A character and its combining marks.
        let o = MS_T.len;
        push_utf8(MS_T, c as u32);
        while MS_I < MS_CP.len && MS_CP[MS_I] >= 0x300 && MS_CP[MS_I] <= 0x36F {
            push_utf8(MS_T, MS_CP[MS_I] as u32);
            MS_I++;
        }
        MS_W.push(Line { o, MS_T.len });
    }
}

// Limits after \sum, \int, \prod, or \lim, with the word that follows them.
recursive fn ms_limits(name: u8[:]) {
    let base = MS_W.len;
    var lo_a = 0;
    var lo_b = 0;
    var up_a = 0;
    var up_b = 0;
    for _ in 2 {
        ms_skip_spaces();
        if ms_peek() == '_' { MS_I++; lo_a = MS_W.len; ms_argument(); lo_b = MS_W.len; }
        else if ms_peek() == '^' { MS_I++; up_a = MS_W.len; ms_argument(); up_b = MS_W.len; }
    }
    let mid = MS_W.len;
    if name == "lim" {
        if lo_b == lo_a { ms_word("limit of"); }
        else {
            ms_word("limit as");
            for j in lo_a..lo_b { if ms_is(j, "to") { ms_word("approaches"); } else { ms_copy(j); } }
            ms_word("of");
        }
    } else {
        ms_word(name);
        if lo_b > lo_a { ms_word("from"); ms_copy_range(lo_a, lo_b); }
        if up_b > up_a { ms_word("to"); ms_copy_range(up_a, up_b); }
        if lo_b > lo_a || up_b > up_a { ms_word("of"); }
    }
    ms_finish(base, mid);
}

fn ms_greek(n: u8[:]) -> bool {
    for g in ["alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "vartheta", "iota", "kappa",
              "lambda", "mu", "nu", "xi", "pi", "varpi", "rho", "varrho", "sigma", "varsigma", "tau", "upsilon", "phi", "varphi",
              "chi", "psi", "omega"] {
        if n == g { return true; }
    }
    return false;
}

fn ms_in(n: u8[:], set: const u8[:][:]) -> bool {
    for g in set { if n == g { return true; } }
    return false;
}

// The word for a symbol command, or "" when it is not one.
fn ms_symbol(n: u8[:]) -> const u8[:] {
    let t = [
        "partial", "partial", "nabla", "nabla", "infty", "infinity", "pm", "plus or minus", "mp", "minus or plus",
        "times", "times", "cdot", "times", "div", "divided by", "ast", "times",
        "le", "less than or equal to", "leq", "less than or equal to", "ge", "greater than or equal to", "geq", "greater than or equal to",
        "ll", "much less than", "gg", "much greater than",
        "neq", "not equal to", "ne", "not equal to", "approx", "approximately equal to", "equiv", "is equivalent to",
        "propto", "is proportional to", "sim", "similar to", "simeq", "similar to",
        "to", "to", "rightarrow", "to", "leftarrow", "from", "mapsto", "maps to",
        "Rightarrow", "implies", "implies", "implies", "Leftrightarrow", "if and only if", "iff", "if and only if",
        "in", "in", "notin", "not in", "subset", "subset of", "subseteq", "subset of or equal to", "cup", "union", "cap", "intersection",
        "emptyset", "empty set", "forall", "for all", "exists", "there exists", "neg", "not", "land", "and", "lor", "or",
        "ldots", "dot dot dot", "cdots", "dot dot dot", "dots", "dot dot dot", "vdots", "dot dot dot",
        "sin", "sine", "cos", "cosine", "tan", "tangent", "sec", "secant", "csc", "cosecant", "cot", "cotangent",
        "arcsin", "arc sine", "arccos", "arc cosine", "arctan", "arc tangent",
        "sinh", "hyperbolic sine", "cosh", "hyperbolic cosine", "tanh", "hyperbolic tangent",
        "log", "log", "ln", "natural log", "exp", "exp", "det", "determinant", "max", "max", "min", "min", "gcd", "gcd",
        "deg", "degrees", "circ", "degrees", "prime", "prime", "hbar", "h bar", "ell", "ell", "Re", "real part", "Im", "imaginary part",
        "angle", "angle", "perp", "perpendicular to", "parallel", "parallel to", "degree", "degrees",
    ];
    var k = 0;
    while k + 1 < t.len {
        if t[k] == n { return t[k + 1]; }
        k += 2;
    }
    return "";
}

recursive fn ms_command_words() {
    // The command name, after the backslash.
    MS_I++;
    let o = MS_T.len;
    let c0 = ms_peek();
    if c0 >= 0 {
        if !ms_is_letter(c0) { push_utf8(MS_T, c0 as u32); MS_I++; }
        else { while ms_is_letter(ms_peek()) { MS_T.push(ms_peek() as u8); MS_I++; } }
    }
    let name_l = Line { o, MS_T.len };
    // A copy of the name, so that the arena can grow.
    var nm: u8[..64] = [];
    let long = name_l.e - name_l.s > 64;
    if !long { nm.append(MS_T[name_l.s..name_l.e]); }
    if long { MS_W.push(name_l); return; }

    if ms_in(nm, ["left", "right", "big", "Big", "bigg", "Bigg", "bigl", "bigr", "Bigl", "Bigr", "biggl", "biggr",
                  ",", ";", ":", "!", "quad", "qquad", " ", "limits", "nolimits"]) { return; }
    if nm == "\\" { ms_word(","); return; }
    if ms_greek(nm) {
        if has_prefix(nm, "var") { ms_word(nm[3..]); } else { ms_word(nm); }
        return;
    }
    if nm.len > 0 && nm[0] >= 'A' && nm[0] <= 'Z' {
        var low: u8[..64] = [];
        for c in nm { low.push(lower(c)); }
        if ms_greek(low) {
            let w = MS_T.len;
            MS_T.append("capital ");
            MS_T.append(low);
            MS_W.push(Line { w, MS_T.len });
            return;
        }
    }
    if nm == "frac" || nm == "dfrac" || nm == "tfrac" {
        let base = MS_W.len;
        ms_argument();
        let m = MS_W.len;
        ms_argument();
        let mid = MS_W.len;
        if m - base == 1 && mid - m == 1 {
            ms_copy(base); ms_word("over"); ms_copy(m);
        } else {
            ms_word("fraction,"); ms_copy_range(base, m); ms_word(", over,"); ms_copy_range(m, mid); ms_word(", end fraction,");
        }
        ms_finish(base, mid);
        return;
    }
    if nm == "sqrt" {
        ms_skip_spaces();
        let base = MS_W.len;
        if ms_peek() == '[' { MS_I++; ms_sequence(']'); }
        let m = MS_W.len;
        ms_argument();
        let mid = MS_W.len;
        if m == base { ms_word("square root of"); }
        else if m - base == 1 && ms_is(base, "3") { ms_word("cube root of"); }
        else { ms_word("root"); ms_copy_range(base, m); ms_word("of"); }
        ms_copy_range(m, mid);
        if mid - m > 1 { ms_word(","); }
        ms_finish(base, mid);
        return;
    }
    if nm == "sum" { ms_limits("sum"); return; }
    if nm == "prod" { ms_limits("product"); return; }
    if nm == "int" { ms_limits("integral"); return; }
    if nm == "iint" { ms_limits("double integral"); return; }
    if nm == "oint" { ms_limits("contour integral"); return; }
    if nm == "lim" { ms_limits("lim"); return; }
    if ms_in(nm, ["text", "textrm", "textit", "textbf", "mbox", "operatorname"]) { ms_raw_argument(); return; }
    if nm == "hat" { ms_argument(); ms_word("hat"); return; }
    if nm == "bar" || nm == "overline" { ms_argument(); ms_word("bar"); return; }
    if nm == "tilde" { ms_argument(); ms_word("tilde"); return; }
    if nm == "dot" { ms_argument(); ms_word("dot"); return; }
    if nm == "ddot" { ms_argument(); ms_word("double dot"); return; }
    if nm == "vec" { ms_word("vector"); ms_argument(); return; }
    if nm == "begin" || nm == "end" { ms_raw_argument(); MS_W.pop(); return; }
    if ms_in(nm, ["mathrm", "mathbf", "mathit", "mathsf", "mathtt", "mathcal", "mathbb", "mathfrak", "boldsymbol", "bm",
                  "displaystyle", "textstyle", "scriptstyle"]) { ms_argument(); return; }
    let s = ms_symbol(nm);
    if s.len > 0 { ms_word(s); return; }
    MS_W.push(name_l);
}

fn math_speech(out: u8[>..]&, latex: u8[:]) {
    MS_CP.clear();
    MS_T.clear();
    MS_W.clear();
    MS_I = 0;
    var i = 0;
    while i < latex.len {
        let c, n = ex_cp(latex, i);
        MS_CP.push(c);
        i += n;
    }
    ms_sequence(-1);
    // Join with spaces, replace " ," with ",", then remove extra spaces.
    var joined: u8[>..] = [];
    for w, k in MS_W {
        if k > 0 { joined.push(' '); }
        joined.append(MS_T[w.s..w.e]);
    }
    var fixed: u8[>..] = [];
    var j = 0;
    while j < joined.len {
        if joined[j] == ' ' && j + 1 < joined.len && joined[j + 1] == ',' { fixed.push(','); j += 2; continue; }
        fixed.push(joined[j]);
        j++;
    }
    var first = true;
    for part in split(fixed, ' ') {
        if part.len == 0 { continue; }
        if !first { out.push(' '); }
        first = false;
        out.append(part);
    }
}

// --- ProjectPackage ------------------------------------------------------

// ProjectPaths.normalize. Returns false for a path that is not a local
// relative path.
fn ex_normalize(out: u8[>..]&, path: u8[:]) -> bool {
    var p = trim_sp(path);
    var q = 0;
    while q < p.len && p[q] != '?' && p[q] != '#' { q++; }
    p = p[..q];
    // Percent decoding. Text with a bad escape stays as it is.
    var dec: u8[>..] = [];
    var bad = false;
    var i = 0;
    while i < p.len {
        if p[i] == '%' {
            if i + 2 < p.len {
                let h, ok = parse_int(p[i + 1..i + 3], 16);
                if ok { dec.push(h as u8); i += 3; continue; }
            }
            bad = true;
            break;
        }
        dec.push(p[i]);
        i++;
    }
    var t: u8[>..] = [];
    if bad { t.append(p); } else { t.append(dec); }
    var lowt: u8[>..] = [];
    for c in t { lowt.push(lower(c)); }
    if t.len == 0 || t[0] == '/' || t[0] == '\\' || t[0] == '~' || index_of(lowt, "://") >= 0 ||
       has_prefix(lowt, "data:") || has_prefix(lowt, "file:") { return false; }
    for k in t.len { if t[k] == '\\' { t[k] = '/'; } }
    // Components, with "." removed and ".." applied.
    var starts: i64[>..] = [];
    let base = out.len;
    var a = 0;
    while a <= t.len {
        var b = a;
        while b < t.len && t[b] != '/' { b++; }
        let comp = t[a..b];
        if comp.len == 0 || comp == "." {
        } else if comp == ".." {
            if starts.len == 0 { out.resize(base); return false; }
            out.resize(starts[starts.len - 1]);
            starts.pop();
            if out.len > base { out.pop(); }
        } else {
            if out.len > base { out.push('/'); }
            starts.push(out.len);
            out.append(comp);
        }
        a = b + 1;
    }
    if out.len == base { return false; }
    return true;
}

// Appends the normalized image paths of the anchors that are not in `skip`
// ("path\n" lines) or in `seen`, to `seen` and to the list.
fn ex_collect_images(seen: u8[>..]&, list: u8[>..]&) {
    for a in ANC {
        if a.kind != 2 { continue; }
        var p: u8[>..] = [];
        if !ex_normalize(p, sp_text(a.b)) { continue; }
        p.push('\n');
        var dup = false;
        var i = 0;
        while i < seen.len {
            let e = index_of_byte(seen, '\n', i);
            if seen[i..e + 1] == p { dup = true; break; }
            i = e + 1;
        }
        if dup { continue; }
        seen.append(p);
        list.append(p);
    }
}

fn ex_json_lines(out: u8[>..]&, list: u8[:]) {
    out.push('[');
    var i = 0;
    var first = true;
    while i < list.len {
        let e = index_of_byte(list, '\n', i);
        if !first { out.push(','); }
        first = false;
        json_str(out, list[i..e]);
        i = e + 1;
    }
    out.push(']');
}

// The kind of division that a frame keeps apart from its body: notes,
// narration, public notes, and explanations.
fn ex_is_extracted(k: i64) -> bool { k == D_NOTES || k == D_NARRATION || k == D_PUBLIC || k == D_EXPLAIN }

// The extracted divisions of one kind in events lo..hi. They are found in
// the body and in other divisions, at any depth, as the app's extractRaw.
// The result is pairs of event indexes in `found`.
fn ex_find_divs(found: i64[>..]&, lo: i64, hi: i64, kind: i64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        if e.close { i++; continue; }
        if e.k == K_DIV && ex_is_extracted(e.n) {
            if e.n == kind { found.push(i); }
            i = e.end;
        } else if e.k == K_DIV { i++; }
        else { i = e.end; }
    }
}

fn ex_all_notes(found: i64[>..]&) {
    for f in FR { ex_find_divs(found, f.lo, f.hi, D_NOTES); }
}

fn public_assets(out: u8[>..]&) {
    var seen: u8[>..] = [];
    var list: u8[>..] = [];
    ex_collect_images(seen, list);
    ex_json_lines(out, list);
}

fn private_assets(out: u8[>..]&) {
    var seen: u8[>..] = [];
    var pub: u8[>..] = [];
    ex_collect_images(seen, pub);
    // The raw text of each note, then a parse of each one.
    var notes: i64[>..] = [];
    ex_all_notes(notes);
    var raws: u8[>..] = [];
    var ends: i64[>..] = [];
    for d in notes { raws.append(sp_text(EV[d].c)); ends.push(raws.len); }
    var saved: u8[>..] = [];
    saved.append(SRC);
    var list: u8[>..] = [];
    var a = 0;
    for b in ends {
        reset();
        SRC.clear();
        SRC.append(raws[a..b]);
        parse_source();
        ex_collect_images(seen, list);
        a = b;
    }
    if ends.len > 0 {
        reset();
        SRC.clear();
        SRC.append(saved);
        parse_source();
    }
    ex_json_lines(out, list);
}

struct ExCut { s: i64, e: i64 }

fn listener_markdown(out: u8[>..]&) {
    var cuts: ExCut[>..] = [];
    var notes: i64[>..] = [];
    ex_all_notes(notes);
    for d in notes { cuts.push(ExCut { EV[d].s0, EV[d].s1 }); }
    // Author comments: any HTML comment line that is not a Marklove marker.
    var in_fence = false;
    var fch: u8 = '`';
    var flen = 0;
    var comment_start = -1;
    for l in LN {
        let t0 = ln_text(l);
        if comment_start >= 0 {
            if index_of(t0, "-->") >= 0 { cuts.push(ExCut { comment_start, l.e }); comment_start = -1; }
            continue;
        }
        if in_fence {
            if is_fence_close(t0, fch, flen) { in_fence = false; }
            continue;
        }
        let f = fence(t0);
        if f.ok { in_fence = true; fch = f.ch; flen = f.len; continue; }
        let t = trim_sp(t0);
        if !has_prefix(t, "<!--") { continue; }
        var d: u8[..80] = [];
        var dv: u8[>..] = [];
        if directive(dv, t0) && dv.len <= 80 {
            d.append(dv);
            var marker = false;
            for m in ["article", "/article", "article-only", "/article-only", "slides", "/slides", "slides-only",
                      "/slides-only", "slide-only", "/slide-only", "end article", "end slides", "decorative"] {
                if d == m { marker = true; }
            }
            if marker { continue; }
        }
        if index_of(t, "-->") >= 0 { cuts.push(ExCut { l.s, l.e }); } else { comment_start = l.s; }
    }
    // Sort, extend each cut over its line break, and merge.
    for i in 1..cuts.len {
        var j = i;
        while j > 0 && (cuts[j - 1].s > cuts[j].s || (cuts[j - 1].s == cuts[j].s && cuts[j - 1].e > cuts[j].e)) {
            let x = cuts[j - 1];
            cuts[j - 1] = cuts[j];
            cuts[j] = x;
            j--;
        }
    }
    var merged: ExCut[>..] = [];
    for r in cuts {
        var e = r.e;
        if e < SRC.len && SRC[e] == '\n' { e++; }
        if merged.len > 0 && r.s <= merged[merged.len - 1].e {
            let m = merged.len - 1;
            merged[m].s = min(merged[m].s, r.s);
            merged[m].e = max(merged[m].e, e);
        } else {
            merged.push(ExCut { r.s, e });
        }
    }
    var text: u8[>..] = [];
    var cursor = 0;
    for r in merged {
        if r.s > cursor { text.append(SRC[cursor..r.s]); }
        cursor = max(cursor, r.e);
    }
    if cursor < SRC.len { text.append(SRC[cursor..]); }
    // "\n\n\n\n" becomes "\n\n\n" until no run of four is left.
    var t2: u8[>..] = [];
    var run = 0;
    for c in text {
        if c == '\n' { run++; if run > 3 { continue; } } else { run = 0; }
        t2.push(c);
    }
    // Mark the package as a listener presentation.
    let nl = index_of_byte(t2, '\n');
    if FRONT_S0 >= 0 && nl >= 0 {
        out.append(t2[..nl + 1]);
        out.append("marklove: listener\n");
        out.append(t2[nl + 1..]);
    } else {
        out.append("---\nmarklove: listener\n---\n\n");
        out.append(t2);
    }
}

// --- PromptText ----------------------------------------------------------

fn authoring_prompt(out: u8[>..]&, selected_draft: u8[:]) {
    out.append("Write a presentation as Marklove Markdown. ");
    pt_rules(out);
    out.append("My brief:\n[Write your brief here.]\n");
    let draft = trim_all(selected_draft);
    if draft.len > 0 {
        out.append("\nMy current draft:\n\n");
        out.append(draft);
        out.push('\n');
    }
}

fn revision_prompt(out: u8[>..]&) {
    var source: u8[>..] = [];
    listener_markdown(source);
    out.append("Revise the Marklove presentation at the end of this message. Keep its content, facts, and order. ");
    out.append("Change every sentence that breaks the rules in part A. Add interactive content where part C applies. ");
    pt_rules(out);
    out.append("The presentation:\n\n````markdown\n");
    out.append(source);
    if !has_suffix(source, "\n") { out.push('\n'); }
    out.append("````\n");
}

// --- Tour ----------------------------------------------------------------

fn tour_project(out: u8[>..]&) {
    out.append("{\"name\":\"Marklove Tour\",\"markdown\":");
    json_str(out, tour_markdown());
    out.append(",\"assets\":{\"images/peafowl.png\":\"demo-peafowl.png\"}}");
}

// --- long texts ----------------------------------------------------------
fn tour_markdown() -> const u8[:] {
    return """
    ---
    title: Your words, in every form
    subtitle: A short tour of Marklove
    author: Marklove
    ---

    Write once. Show it everywhere.

    ::: narration
    Welcome to Marklove. This short tour shows what one file can do.
    :::

    # Write once

    ## One file, every form

    This file is plain Markdown.

    . . .

    It becomes slides, an article, and a handout.

    . . .

    It also becomes a poster, a web page, and a video.

    ::: notes
    Only you see this note. It shows in Speaker Ready.
    :::

    ## A peafowl and a quill

    ![A blue peafowl. Its head is a quill tip. Its feather is a heart.](images/peafowl.png "The Marklove mark.")

    ::: explain
    The Marklove mark is a peafowl. Its head is the tip of a quill. Its feather is a heart.
    :::

    # Show the idea

    ## Math that looks like math

    ::: morph
    $$(a + b)^2$$
    $$(a + b)(a + b)$$
    $$a^2 + 2ab + b^2$$
    :::

    ::: explain
    Square a plus b, and you get three terms.
    :::

    ## Change it, see it

    ::: plot
    x: 0, 6.3
    y: -2, 2
    xlabel: time t
    ylabel: height
    slider: A, 0.2, 2, 1, Size A
    slider: k, 0.5, 4, 1, Speed k
    y = A * sin(k * x)
    :::

    ::: explain
    This is a wave. The two sliders change its size and its speed.
    :::

    ## Numbers become charts

    ::: chart bar
    | Material | Speed of sound (m/s) |
    | --- | ---: |
    | Air | 343 |
    | Water | 1480 |
    | Steel | 5960 |
    :::

    ::: explain
    Sound moves faster in water than in air. It is fastest in steel.
    :::

    # Share it

    ## Every version is kept

    Marklove saves a version each time you save.

    Each version tells what changed.

    Marklove reads [CommonMark](https://commonmark.org) Markdown.

    ## Try it now

    1. Select **Preview** to present.
    2. Change a slider on the wave.
    3. Select **Export** and choose a form.

    """;
}

// PromptText.rules for the standard Takahashi profile (12 words, 90 characters).
fn pt_rules(out: u8[>..]&) {
    out.append("""
        Marklove makes slides, Takahashi slides (one large sentence on each slide), an article, a handout, an interactive web page, and videos from this one file. Follow every rule below.

        A. SENTENCES (each sentence becomes one Takahashi slide)
        1. Each sentence has 12 words or fewer and 90 characters or fewer, spaces included. Math counts as one word.
        2. Each sentence holds one idea. If a sentence needs "and", "but", "which", or a comma to join two ideas, write two sentences.
        3. End each sentence with a period, a question mark, or an exclamation mark. Do not use semicolons.
        4. Write complete sentences. Do not cut a sentence over two lines, two bullets, or two slides.
        5. Use the active voice and common words. Put the main word near the start.
        6. A paragraph has three sentences or fewer. A bullet is one short sentence.
        7. A slide title has six words or fewer.
        Before you answer, count the words in each sentence. Split every sentence that is too long.

        B. STRUCTURE
        1. Start with front matter:
           ---
           title: The title
           subtitle: An optional subtitle
           author: The author
           ---
        2. Write "# Section" for a section and "## Slide title" for each slide. Put one idea on each slide.
        3. Write ordinary Markdown: paragraphs, lists, **bold**, *italic*, `code`, [links](https://example.com), and tables.
        4. Put ". . ." on its own line to show the next part on the next click. Use it to build an argument step by step.
        5. Put text for the article only between <!-- article --> and <!-- /article --> on separate lines. Use <!-- slides --> and <!-- /slides --> for text on slides only. Longer explanations go in the article.

        C. INTERACTIVE CONTENT (use it wherever the content has numbers, change, or a derivation)
        1. A relation between quantities: add a plot with a slider, so the reader can change a value and see the effect.
           ::: plot
           x: 0, 6.28
           y: -2, 2
           xlabel: time t (s)
           ylabel: displacement y (m)
           slider: A, 0.5, 2, 1, Amplitude A
           slider: w, 0.5, 3, 1, Frequency w
           y = A*sin(w*x)
           :::
           A plot can use numbers, x, slider names, pi, e, + - * / ^, and sin, cos, tan, asin, acos, atan, sinh, cosh, tanh, exp, log, sqrt, abs, floor, ceil, min, and max. Do not use other functions.
        2. A comparison of numbers: add a bar chart. The first column holds the labels. Each other column holds one series of numbers. Give the unit in the header.
           ::: chart bar
           | Material | Speed of sound (m/s) |
           | --- | ---: |
           | Air | 343 |
           | Water | 1480 |
           :::
        3. A derivation: show the equations one step at a time.
           ::: morph
           $$a = b + c$$
           $$a - c = b$$
           :::
        4. A main result: give it its own slide, with one display equation or one sentence.
        5. Use only real data. If you do not know a value, write [value] and say so in a note.

        D. MATH, IMAGES, AND SPOKEN TEXT
        1. Write math in LaTeX: $x^2$ in a sentence, and $$ ... $$ on separate lines for display math. Use one equation in each $$ block. Do not use \begin{...} environments.
        2. Write images as ![Description of the image](images/file.png "Optional caption"). Always write a description that tells what the image shows and why it matters.
        3. After each equation, plot, chart, or image, add an explanation in words. Narration reads it aloud, and screen readers use it.
           ::: explain
           The curve keeps its shape and gets smaller as time passes.
           :::
        4. Put private speaker notes in "::: notes" ... ":::". Put notes for the audience and the handout in "::: public-notes" ... ":::".
        5. Put spoken text for a whole slide in "::: narration" ... ":::". Write math in words in spoken text, for example "x squared".
        6. Do not use color alone to give meaning. Do not add HTML or scripts.

        Return only the Markdown, in one code block.


        """);
}
