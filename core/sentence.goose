// Sentences and words, as the app's SentenceSplitter and the word chunks of
// TakahashiFormatter. "e.g.", "i.e.", "Fig. 2", "3.5", and initials stay
// inside one sentence. Inline math, code spans, and link destinations are
// protected: no boundary falls inside them, and each counts as one word.
//
// The functions work on the text in `STX` and give byte ranges into it.

import parse;

var STX: u8[>..] = [];
// Protected regions and sentence ranges, as byte ranges into STX.
var PROT: Line[>..] = [];
var SENT: Line[>..] = [];
// Words of `st_tokens`, as ranges into STX. A token that holds a protected
// region keeps it whole.
var WTOK: Line[>..] = [];

fn st_find(s: u8[:], needle: u8[:], from: i64) -> i64 {
    let k = index_of(s, needle, from);
    if k < 0 { return -1; }
    return k + needle.len;
}

fn protect_in(s: u8[:], prot: Line[>..]&) {
    prot.clear();
    var i = 0;
    while i < s.len {
        let c = s[i];
        let next = i + 1;
        if c == '\\' {
            if next < s.len && s[next] == '(' {
                let end = st_find(s, "\\)", next + 1);
                if end >= 0 { prot.push(Line { i, end }); i = end; continue; }
            }
            i = if next < s.len { next + utf8_len(s[next]) } else { next };
            continue;
        }
        if c == '$' {
            if next < s.len && s[next] == '$' {
                let end = st_find(s, "$$", next + 1);
                if end >= 0 { prot.push(Line { i, end }); i = end; continue; }
            }
            if next < s.len && !is_ws(s[next]) {
                let close = index_of_byte(s, '$', next);
                if close >= 0 { prot.push(Line { i, close + 1 }); i = close + 1; continue; }
            }
        }
        if c == '`' {
            var j = i;
            while j < s.len && s[j] == '`' { j++; }
            let end = st_find(s, s[i..j], j);
            if end >= 0 { prot.push(Line { i, end }); i = end; continue; }
            i = j;
            continue;
        }
        if c == ']' && next < s.len && s[next] == '(' {
            let close = index_of_byte(s, ')', next);
            if close >= 0 { prot.push(Line { i, close + 1 }); i = close + 1; continue; }
        }
        if c == '<' {
            let close = index_of_byte(s, '>', next);
            if close >= 0 && !contains_byte(s[next..close], ' ') {
                prot.push(Line { i, close + 1 });
                i = close + 1;
                continue;
            }
        }
        i = next;
    }
}

// The length of a closing quote, bracket, or emphasis mark at i, or 0.
fn st_closer(i: i64) -> i64 {
    let s = STX;
    let c = s[i];
    if c == '"' || c == '\'' || c == ')' || c == ']' || c == '*' || c == '_' { return 1; }
    if i + 2 < s.len && c == 0xE2 && s[i + 1] == 0x80 && (s[i + 2] == 0x9D || s[i + 2] == 0x99) { return 3; }
    return 0;
}

fn st_abbrev(w: u8[:]) -> bool {
    for a in ["e.g", "i.e", "etc", "vs", "cf", "fig", "eq", "dr", "mr", "mrs", "ms", "prof", "no", "approx", "al", "sec", "ch"] {
        if w == a { return true; }
    }
    return false;
}

fn st_ranges() {
    SENT.clear();
    let s = STX;
    var start = 0;
    var i = 0;
    var p = 0;
    while i < s.len {
        while p < PROT.len && PROT[p].e <= i { p++; }
        if p < PROT.len && PROT[p].s <= i && i < PROT[p].e { i = PROT[p].e; continue; }
        let c = s[i];
        if !(c == '.' || c == '!' || c == '?') { i++; continue; }
        var j = i + 1;
        while j < s.len && (s[j] == '.' || s[j] == '!' || s[j] == '?') { j++; }
        while j < s.len {
            let n = st_closer(j);
            if n == 0 { break; }
            j += n;
        }
        if j >= s.len { break; }
        if !is_ws(s[j]) { i = j; continue; }
        // The last word before the mark, without opening marks, in lower case.
        var we = i;
        while we > start && is_ws(s[we - 1]) { we--; }
        var ws = we;
        while ws > start && !is_ws(s[ws - 1]) { ws--; }
        while ws < we && contains_byte("(\"'*_[", s[ws]) { ws++; }
        while we > ws && contains_byte("(\"'*_[", s[we - 1]) { we--; }
        var bare: u8[..32] = [];
        for b in s[ws..we] { if bare.len < 32 { bare.push(lower(b)); } }
        let bare_chars = char_count(s[ws..we]);
        let is_abbr = c == '.' && (st_abbrev(bare) || (bare_chars == 1 && is_alpha(bare[0])));
        var k = j;
        while k < s.len && is_ws(s[k]) { k++; }
        let next_lower = k < s.len && s[k] >= 'a' && s[k] <= 'z';
        let next_digit = k < s.len && is_digit(s[k]);
        if is_abbr || next_digit || (c == '.' && next_lower && bare_chars <= 3) {
            i = j;
            continue;
        }
        SENT.push(Line { start, j });
        start = k;
        i = k;
    }
    if start < s.len && trim_all(s[start..]).len > 0 { SENT.push(Line { start, s.len }); }
}

// Splits Markdown source text into sentence ranges (into STX).
fn split_markdown(t: u8[:]) {
    STX.clear();
    STX.append(t);
    protect_in(STX, PROT);
    st_ranges();
}

// Collapses white space to single spaces, into out.
fn collapse_ws(out: u8[>..]&, t: u8[:]) {
    var i = 0;
    var first = true;
    while i < t.len {
        while i < t.len && is_ws(t[i]) { i++; }
        if i >= t.len { break; }
        if !first { out.push(' '); }
        first = false;
        while i < t.len && !is_ws(t[i]) { out.push(t[i]); i++; }
    }
}

// Splits plain text into trimmed sentences: ranges into STX, which holds
// the text with white space collapsed.
fn split_plain(t: u8[:]) {
    STX.clear();
    collapse_ws(STX, t);
    PROT.clear();
    st_ranges();
    var k = 0;
    for r in SENT {
        let a = trim_sp(STX[r.s..r.e]);
        if a.len == 0 { continue; }
        // The offset of the trimmed text in STX.
        var o = r.s;
        while o < r.e && (STX[o] == ' ' || STX[o] == '\t') { o++; }
        SENT[k] = Line { o, o + a.len };
        k++;
    }
    SENT.resize(k);
}

fn has_word_char(t: u8[:]) -> bool {
    // As Swift's isLetter || isNumber.
    var i = 0;
    while i < t.len {
        let cp, n = uni_decode(t, i);
        if uni_alnum(cp) { return true; }
        i += n;
    }
    return false;
}

// Counts words in Markdown text. Inline math and code count as one word each.
var WPROT: Line[>..] = [];

fn word_count(t: u8[:]) -> i64 {
    protect_in(t, WPROT);
    var n = 0;
    var i = 0;
    var p = 0;
    var wa = -1;
    while i <= t.len {
        let at_prot = i < t.len && p < WPROT.len && WPROT[p].s == i;
        if i == t.len || at_prot || is_ws(t[i]) {
            if wa >= 0 && has_word_char(t[wa..i]) { n++; }
            wa = -1;
            if i == t.len { break; }
            if at_prot {
                // A protected region is " W ": one word on its own.
                n++;
                i = WPROT[p].e;
                p++;
                continue;
            }
        } else if wa < 0 {
            wa = i;
        }
        i++;
    }
    return n;
}

let WORDS_PER_MINUTE = 130.0;

fn space_words(t: u8[:]) -> i64 {
    var n = 0;
    var inw = false;
    for c in t {
        if is_ws(c) { inw = false; } else if !inw { inw = true; n++; }
    }
    return n;
}

// Estimated speaking time for a sentence when there is no audio.
fn estimated_seconds(t: u8[:]) -> f64 { max(0.8, (space_words(t) as f64) * 60.0 / WORDS_PER_MINUTE) }

// Splits STX at white space outside protected regions, into WTOK.
fn st_tokens() {
    WTOK.clear();
    protect_in(STX, PROT);
    var i = 0;
    var p = 0;
    var cur = -1;
    let s = STX;
    while i < s.len {
        while p < PROT.len && PROT[p].e <= i { p++; }
        if p < PROT.len && PROT[p].s == i {
            if cur < 0 { cur = i; }
            i = PROT[p].e;
            continue;
        }
        if is_ws(s[i]) {
            if cur >= 0 { WTOK.push(Line { cur, i }); cur = -1; }
        } else if cur < 0 {
            cur = i;
        }
        i++;
    }
    if cur >= 0 { WTOK.push(Line { cur, s.len }); }
}

fn in_words(w: u8[:], list: (const u8[:])[:]) -> bool {
    for x in list { if w == x { return true; } }
    return false;
}

let JOINING: (const u8[:])[] = ["and", "but", "or", "nor", "so", "yet", "because", "since", "although", "though", "while", "whereas",
    "which", "that", "who", "whom", "whose", "where", "when", "if", "unless", "until", "then", "than", "as"];
let DETERMINERS: (const u8[:])[] = ["the", "a", "an", "each", "every", "its", "their", "his", "her", "our", "your", "my", "this", "these",
    "those", "all", "some", "any", "no", "many", "most", "both", "either", "neither"];
let PREPOSITIONS: (const u8[:])[] = ["to", "for", "with", "without", "by", "from", "into", "through", "after", "before", "over", "under",
    "between", "during", "across", "along", "about", "against", "within", "on", "in", "at", "of"];

fn wtok(i: i64) -> u8[:] { STX[WTOK[i].s..WTOK[i].e] }

fn break_cost(i: i64) -> f64 {
    let w = wtok(i);
    let n = WTOK.len;
    if w.len > 0 && contains_byte(",;:", w[w.len - 1]) { return 0.0; }
    if w == "—" || w == "–" || has_suffix(w, "—") { return 0.0; }
    if i + 1 < n {
        let raw = wtok(i + 1);
        var a = 0;
        var b = raw.len;
        while a < b && is_ascii_punct(raw[a]) { a++; }
        while b > a && is_ascii_punct(raw[b - 1]) { b--; }
        var next: u8[..32] = [];
        for c in raw[a..b] { if next.len < 32 { next.push(lower(c)); } }
        if has_prefix(raw, "(") || raw == "—" || raw == "–" { return 1.0; }
        if in_words(next, JOINING) { return 2.0; }
        if in_words(next, DETERMINERS) { return 4.0; }
        if in_words(next, PREPOSITIONS) { return 5.0; }
    }
    return 14.0;
}

// Splits an overlong sentence (in STX) into parts that fit the profile.
// Appends the cut positions (word indexes into WTOK, each the end of a
// part) to cuts.
fn word_chunks(cuts: i64[>..]&, size: i64, max_chars: i64) {
    st_tokens();
    let n = WTOK.len;
    if n == 0 { return; }
    var wsum: i64[>..] = [0];
    var csum: i64[>..] = [0];
    for k in n {
        let w = wtok(k);
        wsum.push(wsum[k] + (if has_word_char(w) { 1 } else { 0 }));
        csum.push(csum[k] + char_count(w) + 1);
    }
    let total = wsum[n];
    let parts = max(1, max(ceil((total as f64) / (size as f64)) as i64, ceil((csum[n] as f64) / (max_chars as f64)) as i64));
    let target = min((size as f64) * 0.75, (total as f64) / (parts as f64));
    let INF = 1e300;
    var best: f64[>..] = [];
    var from: i64[>..] = [];
    for k in n + 1 { best.push(INF); from.push(-1); }
    best[0] = 0.0;
    for end in 1..n + 1 {
        var start = end - 1;
        while start >= 0 {
            let w = wsum[end] - wsum[start];
            let c = csum[end] - csum[start] - 1;
            if w > size || (c > max_chars && end - start > 1) { break; }
            if best[start] < INF {
                let d = (w as f64) - target;
                var cost = best[start] + d * d * 0.25 + 3.0;
                if end < n { cost += break_cost(end - 1); }
                if w <= 2 && total > 2 { cost += 30.0; }
                if cost < best[end] { best[end] = cost; from[end] = start; }
            }
            start--;
        }
    }
    let base = cuts.len;
    if best[n] >= INF {
        // A single word longer than the limit: one word for each part.
        for k in n { cuts.push(k + 1); }
        return;
    }
    var k = n;
    while k > 0 { cuts.push(k); k = from[k]; }
    reverse(cuts[base..]);
}
