// Source checks, as the app's Linter. Source checks advise. They never stop
// an export. The result is JSON for the editor's issue list.

import render;

// Format sets (bit masks over the export formats below).
let FMT_NAMES: (const u8[:])[] = ["slidesPDF", "slidesPNG", "slidesSVG", "articlePDF", "articleHTML", "epub", "handoutPDF",
    "posterPDF", "interactiveHTML", "articleMarkdown", "revisedMarkdown", "video", "narratedVideo", "manimVideo", "podcast",
    "narrationScript", "transcript", "subtitles", "presenterZIP", "listenerZIP", "projectZIP", "promptText"];

fn fbit(name: u8[:]) -> i64 {
    for n, i in FMT_NAMES { if n == name { return 1 << i; } }
    return 0;
}

fn fset(names: (const u8[:])[:]) -> i64 {
    var m = 0;
    for n in names { m |= fbit(n); }
    return m;
}

fn f_all() -> i64 { (1 << FMT_NAMES.len) - 1 }
fn f_visual() -> i64 { fset(["slidesPDF", "articlePDF", "handoutPDF", "interactiveHTML", "video", "narratedVideo", "manimVideo"]) }
fn f_packages() -> i64 { fset(["presenterZIP", "listenerZIP"]) }
fn f_audio() -> i64 { fset(["narratedVideo", "podcast", "narrationScript", "transcript", "subtitles"]) }
fn f_takahashi() -> i64 { fset(["slidesPDF", "handoutPDF", "interactiveHTML", "video", "narratedVideo", "revisedMarkdown"]) }

struct Diag { code: const u8[:], info: bool, msg: Line, detail: Line, s0: i64, s1: i64, formats: i64, takahashi: bool }
var DG: Diag[>..] = [];
var DT: u8[>..] = [];
// True when JavaScript gave the project's asset list.
var HAVE_ASSETS = false;

fn dt(t: u8[:]) -> Line {
    let o = DT.len;
    DT.append(t);
    return Line { o, DT.len };
}

fn diag(code: const u8[:], info: bool, msg: u8[:], detail: u8[:], s0: i64, s1: i64, formats: i64) {
    DG.push(Diag { code, info, dt(msg), dt(detail), s0, s1, formats, false });
}

// --- math --------------------------------------------------------------

fn is_env_supported(env: u8[:]) -> bool {
    for x in MATH_ENVIRONMENTS { if x == env { return true; } }
    return false;
}

// Unsupported commands in LaTeX at source offset `base`.
fn check_math(latex: u8[:], s0: i64, s1: i64) {
    let src = SRC[s0..s1];
    let at = index_of(src, latex);
    let base = if at >= 0 { s0 + at } else { s0 };
    let fv = f_visual() | fbit("listenerZIP");
    var i = 0;
    let n = latex.len;
    while i < n {
        if latex[i] != '\\' { i++; continue; }
        let start = i;
        i++;
        if i >= n { break; }
        var name: u8[..48] = [];
        if is_alpha(latex[i]) {
            var j = i;
            while j < n && (is_alpha(latex[j]) || latex[j] == '*') { j++; }
            for c in latex[i..j] { if name.len < 48 { name.push(c); } }
            i = j;
        } else {
            let l = min(utf8_len(latex[i]), n - i);
            for c in latex[i..i + l] { name.push(c); }
            i += l;
        }
        if name == "begin" || name == "end" {
            var j = i;
            while j < n && latex[j] == ' ' { j++; }
            if j < n && latex[j] == '{' {
                var k = j + 1;
                while k < n && latex[k] != '}' { k++; }
                let env = latex[j + 1..min(k, n)];
                if !is_env_supported(env) {
                    let e = min(k + 1, n);
                    var d: u8[>..] = [];
                    format(d, "\\", name, "{", env, "} is not available. Exports show this equation as LaTeX text. The equation stays unchanged in your source.");
                    diag("unsupportedMath", false, "This math command is not supported.", d, base + start, base + e, fv);
                }
                i = min(k + 1, n);
            }
            continue;
        }
        if !math_command_supported(name) {
            var d: u8[>..] = [];
            format(d, "\\", name, " is not available. Exports show this equation as LaTeX text. The equation stays unchanged in your source.");
            diag("unsupportedMath", false, "This math command is not supported.", d, base + start, base + i, fv);
        }
    }
    // Braces.
    var depth = 0;
    var escaped = false;
    var opens: i64[>..] = [];
    var bad = -1;
    for c, k in latex {
        if escaped { escaped = false; continue; }
        if c == '\\' { escaped = true; continue; }
        if c == '{' { depth++; opens.push(k); }
        if c == '}' {
            depth--;
            if depth < 0 { bad = k; break; }
            opens.pop();
        }
    }
    if bad < 0 && opens.len > 0 { bad = opens[0]; }
    if bad >= 0 {
        diag("mathBraces", false, "Check the braces in this equation.", "Each { needs a matching }. Exports show this equation as LaTeX text.",
             base + bad, base + bad + 1, fv);
    }
}

// --- images --------------------------------------------------------------

fn check_image(path: u8[:], desc: u8[:], decorative: bool, s0: i64, s1: i64) {
    let kind = media_kind(path);
    let noun = if kind == M_IMAGE { "image" } else if kind == M_VIDEO { "video" } else { "audio file" };
    let fmts = f_visual() | f_packages();
    if is_remote(path) {
        var m: u8[>..] = [];
        format(m, "This ", noun, " is on the internet. Add a local copy.");
        diag("remoteImage", false, m, "Marklove does not download files from the internet. Put a copy in the project folder, for example images/, and change the path. Exports show the description in a frame.", s0, s1, fmts);
    } else if HAVE_ASSETS && asset_index(path) < 0 {
        var m: u8[>..] = [];
        if kind == M_IMAGE { m.append("Cannot find the image. Check the file path."); }
        else { format(m, "Cannot find the ", noun, ". Check the file path."); }
        var d: u8[>..] = [];
        format(d, "Marklove looks for \"", path, "\" in the project folder. Exports show the description in a frame.");
        diag("missingImage", false, m, d, s0, s1, fmts);
    }
    if kind != M_AUDIO && trim_sp(desc).len == 0 && !decorative {
        var d: u8[>..] = [];
        format(d, "Write the description between the brackets: ![Description](", path, "). If the image is only decoration, put <!-- decorative --> on the line before it.");
        var m: u8[>..] = [];
        format(m, "Add ", if kind == M_IMAGE { "an image" } else { "a video" }, " description.");
        diag("missingDescription", false, m, d, s0, s1, f_visual());
    }
}

// --- blocks --------------------------------------------------------------

recursive fn walk(lo: i64, hi: i64) {
    var i = lo;
    while i < hi {
        let e = EV[i];
        let next = e.end;
        if e.close { i = next; continue; }
        let k = e.k;
        if k == K_MATH { check_math(sp_text(e.a), e.s0, e.s1); }
        else if k == K_LIST {
            var j = i + 1;
            while j < e.end - 1 {
                if EV[j].k == K_ITEM && !EV[j].close { walk(j + 1, EV[j].end - 1); }
                j = EV[j].end;
            }
        }
        else if k == K_QUOTE { walk(i + 1, e.end - 1); }
        else if k == K_RAW {
            diag("rawHTML", true, "Marklove shows HTML as text. It does not run it.", "Use Markdown for formatting. Exports show this HTML as plain text.", e.s0, e.s1, f_visual());
        }
        else if k == K_DIV {
            let d = e.n;
            if d == D_UNKNOWN {
                let name = sp_text(e.b);
                {
                var m: u8[>..] = [];
                format(m, "Marklove does not know the block name \"", name, "\".");
                diag("unknownBlock", true, m, "The content shows as normal text. Known names: block, theorem, example, alert, key, definition, columns, column, morph, plot, chart, notes, narration, public-notes, explain.",
                     e.s0, min(e.s1, e.s0 + 3 + name.len + 1), f_visual());
                }
                walk(i + 1, e.end - 1);
            } else if d == D_PLOT {
                var errs: u8[>..] = [];
                plot_errors(errs, sp_text(e.c));
                if errs.len > 0 {
                    while errs.len > 0 && errs[errs.len - 1] == '\n' { errs.pop(); }
                    diag("plotProblem", false, "Check this plot.", errs, e.s0, e.s1, f_visual() | fbit("listenerZIP"));
                }
            } else if d == D_CHART {
                if div_table(i) >= 0 {
                    chart_spec(i);
                    if CH_ERRORS.len > 0 {
                        var errs: u8[>..] = [];
                        errs.append(CH_ERRORS);
                        while errs.len > 0 && errs[errs.len - 1] == '\n' { errs.pop(); }
                        diag("chartProblem", false, "Check this chart table.", errs, e.s0, e.s1, f_visual() | fbit("listenerZIP"));
                    }
                } else {
                    diag("chartProblem", false, "Add a table to this chart.", "A chart uses a Markdown table. The first column holds the labels. The other columns hold numbers.", e.s0, e.s1, f_visual());
                }
                walk(i + 1, e.end - 1);
            } else if d == D_MORPH {
                var j = i + 1;
                while j < e.end - 1 {
                    let x = EV[j];
                    if x.k == K_MATH && !x.close { check_math(sp_text(x.a), x.s0, x.s1); } else { walk(j, x.end); }
                    j = x.end;
                }
            } else if d == D_NOTES || d == D_NARRATION || d == D_PUBLIC || d == D_EXPLAIN {
            } else {
                walk(i + 1, e.end - 1);
            }
        }
        i = next;
    }
}

// The source ranges of decorative figures, for inline image checks.
fn in_decorative(s0: i64, s1: i64) -> bool {
    for e in EV { if e.k == K_FIG && !e.close && e.fl == 1 && e.s0 <= s0 && s1 <= e.s1 { return true; } }
    return false;
}

fn explanation_message(kind: i64, msg: u8[>..]&, detail: u8[>..]&) {
    let how = "Add a ::: explain block after it with the spoken words, or a ::: narration block for the whole slide.";
    if kind == NV_EQUATION { msg.append("Add a spoken explanation for this equation."); detail.append("Narration does not read equations aloud. "); }
    else if kind == NV_STEPS { msg.append("Add a spoken explanation for these equation steps."); detail.append("Narration does not read equations aloud. "); }
    else if kind == NV_IMAGE { msg.append("Add a spoken explanation for this image."); detail.append("Narration does not describe images. "); }
    else if kind == NV_VIDEO { msg.append("Add a spoken explanation for this video."); detail.append("Narration does not describe video. "); }
    else if kind == NV_TABLE { msg.append("Add a spoken explanation for this table."); detail.append("Narration does not read tables aloud. "); }
    else if kind == NV_PLOT { msg.append("Add a spoken explanation for this plot."); detail.append("Narration does not describe plots. "); }
    else if kind == NV_CHART { msg.append("Add a spoken explanation for this chart."); detail.append("Narration does not describe charts. "); }
    else { msg.append("Narration skips this paragraph because it has math."); detail.append("Narration does not read math aloud. "); }
    detail.append(how);
}

fn plural(w: u8[:]) -> const u8[:] {
    if w == "code" { return "code blocks"; }
    if w == "table" { return "tables"; }
    if w == "plot" { return "plots"; }
    if w == "chart" { return "charts"; }
    if w == "video" { return "video"; }
    return "audio";
}

fn lint() {
    DG.clear();
    DT.clear();
    let all = f_all();
    for is in ISS {
        let s0 = is.s0;
        let s1 = is.s1;
        if is.kind == 1 {
            var d: u8[>..] = [];
            format(d, "The \"", sp_text(is.a), "\" block starts here and has no end. Marklove ends it at the next heading.");
            diag("unclosedDiv", false, "Add a closing ::: line.", d, s0, s1, all);
        } else if is.kind == 2 {
            diag("unclosedFence", false, "Add a closing code fence.", "The code block continues to the end of the file.", s0, s1, all);
        } else if is.kind == 3 {
            diag("unclosedMath", false, "Add the closing delimiter for this equation.", "The equation ends at the next blank line.", s0, s1, all);
        } else if is.kind == 4 {
            var m: u8[>..] = [];
            let art = is.scope == SC_ARTICLE;
            format(m, "Add <!-- /", if art { "article" } else { "slides" }, " --> after the ", if art { "article-only" } else { "slide-only" }, " text.");
            diag("unclosedScope", false, m, "Without the end marker, the scope continues to the end of the file.", s0, s1, all);
        } else if is.kind == 5 {
            var d: u8[>..] = [];
            format(d, "Add <!-- ", if is.scope == SC_ARTICLE { "article" } else { "slides" }, " --> before the text, or remove this line.");
            diag("strayScopeEnd", false, "This end marker has no start marker.", d, s0, s1, all);
        } else if is.kind == 6 {
            diag("nestedScope", false, "Close the first scope before you start a new one.", "Marklove ignores this start marker.", s0, s1, all);
        } else if is.kind == 7 {
            diag("unclosedComment", false, "Add --> to close this comment.", "The comment hides all text to the end of the file.", s0, s1, all);
        } else if is.kind == 8 {
            diag("unclosedFrontMatter", false, "Add a --- line after the front matter.", "Marklove reads the first lines as normal text.", s0, s1, all);
        }
    }
    if !has_meta("title") {
        diag("missingTitle", true, "Add a title to the front matter.", "Exports use the title for the file, the title slide, and the article. Example:\n---\ntitle: My lesson\n---", 0, 0, all);
    }
    for f in FR { walk(f.lo, f.hi); }
    for a in ANC {
        if a.kind == 2 {
            var desc: u8[>..] = [];
            desc.append(sp_text(a.a));
            var path: u8[>..] = [];
            path.append(sp_text(a.b));
            check_image(path, desc, in_decorative(a.s0, a.s1), a.s0, a.s1);
        } else if a.kind == 1 {
            var latex: u8[>..] = [];
            latex.append(sp_text(a.a));
            check_math(latex, a.s0, a.s1);
        }
    }
    // Narration.
    narration_script();
    for m in NMISS {
        var msg: u8[>..] = [];
        var detail: u8[>..] = [];
        explanation_message(m.kind, msg, detail);
        diag(if m.kind == NV_INLINE_MATH { "inlineMathNotSpoken" } else { "needsExplanation" }, false, msg, detail, m.s0, m.s1, f_audio() | fbit("manimVideo"));
    }
    for e in EV {
        if e.k == K_DIV && !e.close && (e.n == D_NARRATION || e.n == D_EXPLAIN) {
            let raw = sp_text(e.c);
            if contains_byte(raw, '$') || index_of(raw, "\\(") >= 0 {
                diag("mathInNarration", false, "Write math in words in spoken text.", "Narration reads text aloud. It does not read LaTeX. For example, write \"x squared\", not $x^2$.", e.s0, e.s1, f_audio());
            }
        }
    }
    // The Takahashi profile.
    takahashi_slides();
    var tw: TWarn[>..] = [];
    tw.append(TW);
    for w in tw {
        var m: u8[>..] = [];
        var d: u8[>..] = [];
        if w.kind == 1 {
            m.append("This sentence is too long for one Takahashi slide.");
            format(d, "It has ", w.n, " words. The limit is ", TK_MAX_WORDS, " words and ", TK_MAX_CHARS, " characters. Marklove continues the sentence on more slides and keeps every word. To fix it, make the sentence shorter.");
            diag("takahashiOverlong", false, m, d, w.s0, w.s1, f_takahashi());
        } else {
            format(m, "Takahashi phone slides do not support ", plural(w.a), ".");
            diag("takahashiOutOfProfile", false, m, "Marklove shows it on a standard slide. The phone profile shows one image, short text, or one equation on each slide.", w.s0, w.s1, f_takahashi());
        }
        DG[DG.len - 1].takahashi = true;
    }
    // A stable order: by position, then severity. No duplicates.
    var keep: Diag[>..] = [];
    for g in DG {
        var dup = false;
        for x in keep { if x.code == g.code && x.s0 == g.s0 && x.s1 == g.s1 { dup = true; break; } }
        if !dup { keep.push(g); }
    }
    stable_sort(keep) { a, b => a.s0 < b.s0 || (a.s0 == b.s0 && !a.info && b.info) };
    DG.clear();
    DG.append(keep);
}

fn u16_at(b: i64) -> i64 { U16[min(max(b, 0), U16.len - 1)] as i64 }

// The checks as JSON. Ranges are UTF-16 offsets for the editor.
fn lint_json(out: u8[>..]&) {
    out.push('[');
    for g, i in DG {
        if i > 0 { out.push(','); }
        out.append("{\"code\":");
        json_str(out, g.code);
        out.append(",\"severity\":");
        json_str(out, if g.info { "information" } else { "warning" });
        out.append(",\"message\":");
        json_str(out, DT[g.msg.s..g.msg.e]);
        out.append(",\"detail\":");
        json_str(out, DT[g.detail.s..g.detail.e]);
        format(out, ",\"start\":", u16_at(g.s0), ",\"end\":", u16_at(g.s1), ",\"formats\":[");
        var n = 0;
        for name, k in FMT_NAMES {
            if (g.formats & (1 << k)) == 0 { continue; }
            if n > 0 { out.push(','); }
            json_str(out, name);
            n++;
        }
        out.push(']');
        if g.takahashi { out.append(",\"style\":\"takahashi\""); }
        out.push('}');
    }
    out.push(']');
}
