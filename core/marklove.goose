// The functions that JavaScript calls. Each one reads its inputs with
// ml_arg (see io.h) and returns its result as bytes, which stay valid until
// the next call.
//
// The document functions read the same arguments:
//   0 the Markdown source
//   1 the assets, as "path\tURL\n" lines
//   2 the font style sheet      3 the page style sheet
//   4 the page script           5 "dark", "light" or "" (the reader decides)
// The options are bits: O_TAKAHASHI, O_TOC, O_NARRATION, O_PUBLIC_NOTES.

import lint;
import theme;
import edit;
import gitexport;
import vim;
import extras;
import pagesvg;
import trace;
import video;

let O_TAKAHASHI = 1;
let O_TOC = 2;
let O_NARRATION = 4;
let O_PUBLIC_NOTES = 8;

var R: u8[>..] = [];

fn arg(i: i32) -> u8[>..] {
    var b: u8[>..] = [];
    ml_arg(i, b);
    return b;
}

fn has(opts: i32, bit: i64) -> bool { ((opts as i64) & bit) != 0 }

// Parses the source and reads the page parts.
fn document(opts: i32) {
    load();
    load_assets(arg(1));
    HAVE_ASSETS = true;
    PART_FONTS.clear();
    ml_arg(2, PART_FONTS);
    PART_STYLE.clear();
    ml_arg(3, PART_STYLE);
    PART_RUNTIME.clear();
    ml_arg(4, PART_RUNTIME);
    FIXED_THEME.clear();
    ml_arg(5, FIXED_THEME);
    PART_THEME.clear();
    var t: u8[>..] = [];
    t.append(meta("theme"));
    var a: u8[>..] = [];
    a.append(meta("accent"));
    theme_css(PART_THEME, t, a);
    INCLUDE_NARRATION = has(opts, O_NARRATION);
    INCLUDE_PUBLIC_NOTES = has(opts, O_PUBLIC_NOTES);
}

fn done() -> const u8[:] { return R; }

// --- documents ------------------------------------------------------------

let PAGE_SLIDES = 0;
let PAGE_ARTICLE = 1;

export fn ml_page(kind: i32, opts: i32) -> const u8[:] {
    document(opts);
    if kind == PAGE_ARTICLE { article_page(has(opts, O_TOC)); }
    else { interactive_page(has(opts, O_TAKAHASHI)); }
    R.clear();
    R.append(H);
    return done();
}

// Renders the deck, so that each slide knows its reveal steps.
fn slides(opts: i32) {
    build_deck(has(opts, O_TAKAHASHI));
    narration_script();
    H.clear();
    XHTML = false;
    ART = false;
    LINK_PREFIX.clear();
    r_slides();
}

let TEXT_ARTICLE_MD = 0;
let TEXT_REVISED_MD = 1;
let TEXT_NARRATION = 2;
let TEXT_TRANSCRIPT = 3;
let TEXT_VTT = 4;
let TEXT_SRT = 5;

export fn ml_text(kind: i32, opts: i32) -> const u8[:] {
    document(opts);
    R.clear();
    let k = kind as i64;
    if k == TEXT_ARTICLE_MD { article_markdown(R); }
    else if k == TEXT_REVISED_MD { build_deck(has(opts, O_TAKAHASHI)); revised_markdown(R); }
    else if k == TEXT_NARRATION { narration_script(); narration_text(R); }
    else if k == TEXT_TRANSCRIPT { narration_script(); transcript(R); }
    else if k == TEXT_VTT || k == TEXT_SRT {
        // The video pages and timing (see ml_layout).
        layout_doc(LAYOUT_VIDEO, opts, 0, 0);
        R.clear();
        cues_text(R, k == TEXT_SRT);
    }
    return done();
}

fn u16_of(b: i64) -> i64 { U16[min(max(b, 0), U16.len - 1)] as i64 }

// The slides for the speaker view and for the editor: each slide's id,
// source range (UTF-16), reveal steps, and speaker notes.
export fn ml_outline(opts: i32) -> const u8[:] {
    document(opts);
    slides(opts);
    R.clear();
    R.push('[');
    for s, i in SL {
        if i > 0 { R.push(','); }
        R.append("{\"id\":");
        var id: u8[>..] = [];
        slide_id(id, s);
        json_str(R, id);
        format(R, ",\"frame\":", s.frame, ",\"kind\":", s.kind, ",\"s0\":", u16_of(s.s0), ",\"s1\":", u16_of(s.s1), ",\"steps\":", s.steps, ",\"notes\":");
        var notes: u8[>..] = [];
        if s.n == 0 { notes_text(notes, s.frame, D_NOTES); }
        json_str(R, notes);
        R.push('}');
    }
    R.push(']');
    return done();
}

export fn ml_lint() -> const u8[:] {
    document(0);
    lint();
    R.clear();
    lint_json(R);
    return done();
}

// Starts an EPUB in the ZIP builder and returns the media paths to add
// under "OEBPS/media/", one on each line. Finish with ml_zip_finish.
export fn ml_epub(date: f64, opts: i32) -> const u8[:] {
    document(opts);
    zip_begin();
    epub_begin(date as i64);
    R.clear();
    R.append(LINKED);
    return done();
}

// --- packages and prompts -------------------------------------------------

let LIST_LISTENER_MD = 0;
let LIST_PUBLIC_ASSETS = 1;
let LIST_PRIVATE_ASSETS = 2;
let LIST_REVISION_PROMPT = 3;

export fn ml_listener(kind: i32) -> const u8[:] {
    document(0);
    R.clear();
    let k = kind as i64;
    if k == LIST_LISTENER_MD { listener_markdown(R); }
    else if k == LIST_PUBLIC_ASSETS { public_assets(R); }
    else if k == LIST_PRIVATE_ASSETS { private_assets(R); }
    else if k == LIST_REVISION_PROMPT { revision_prompt(R); }
    return done();
}

export fn ml_authoring_prompt() -> const u8[:] {
    R.clear();
    authoring_prompt(R, arg(0));
    return done();
}

export fn ml_tour() -> const u8[:] {
    R.clear();
    tour_project(R);
    return done();
}

// The equation at a UTF-16 offset of argument 0, as JSON or null.
export fn ml_math_at(offset: i32) -> const u8[:] {
    R.clear();
    math_at(R, arg(0), offset as i64);
    return done();
}

export fn ml_math_speech() -> const u8[:] {
    R.clear();
    math_speech(R, arg(0));
    return done();
}

// --- equations, themes, highlighting --------------------------------------

export fn ml_math(display: i32) -> const u8[:] {
    R.clear();
    math_html(R, arg(0), display != 0);
    return done();
}

export fn ml_math_check() -> const u8[:] {
    let m = math_check(arg(0));
    R.clear();
    R.append(m);
    return done();
}

export fn ml_theme_list() -> const u8[:] {
    R.clear();
    theme_list(R);
    return done();
}

export fn ml_theme_resolve() -> const u8[:] {
    R.clear();
    theme_resolve(R, arg(0), arg(1));
    return done();
}

export fn ml_theme_css() -> const u8[:] {
    R.clear();
    theme_css(R, arg(0), arg(1));
    return done();
}

export fn ml_theme_palette(dark: i32, more_contrast: i32) -> const u8[:] {
    R.clear();
    theme_palette(R, arg(0), arg(1), dark as i64, more_contrast as i64);
    return done();
}

export fn ml_typography() -> const u8[:] {
    R.clear();
    theme_typography(R);
    return done();
}

export fn ml_highlight_md() -> const u8[:] {
    R.clear();
    highlight_markdown(R, arg(0));
    return done();
}

// --- editing (offsets are UTF-8 bytes) ------------------------------------

// syntax: 0 Sam (Plan 9), 1 plain text, 2 Vim.
export fn ml_find(syntax: i32, ignore_case: i32) -> const u8[:] {
    R.clear();
    if syntax == 2 { vim_find(R, arg(0), arg(1), ignore_case != 0); }
    else { edit_find(R, arg(0), arg(1), syntax == 1, ignore_case != 0); }
    return done();
}

export fn ml_replace(syntax: i32, ignore_case: i32, sel_s: i32, sel_e: i32, all: i32) -> const u8[:] {
    R.clear();
    if syntax == 2 { vim_replace(R, arg(0), arg(1), ignore_case != 0, arg(2), sel_s as i64, sel_e as i64, all != 0); }
    else { edit_replace(R, arg(0), arg(1), syntax == 1, ignore_case != 0, arg(2), sel_s as i64, sel_e as i64, all != 0); }
    return done();
}

export fn ml_sam(sel_s: i32, sel_e: i32, ignore_case: i32) -> const u8[:] {
    R.clear();
    edit_sam(R, arg(0), arg(1), sel_s as i64, sel_e as i64, ignore_case != 0);
    return done();
}

export fn ml_diff() -> const u8[:] {
    R.clear();
    edit_diff(R, arg(0), arg(1));
    return done();
}

export fn ml_commit_message() -> const u8[:] {
    R.clear();
    edit_commit_message(R, arg(0), arg(1));
    return done();
}

// --- ZIP, packages and Git -----------------------------------------------

export fn ml_zip_begin() { zip_begin(); }

export fn ml_zip_add(mtime: f64) -> i32 { zip_add(arg(0), arg(1), mtime as i64) as i32 }

// A file whose bytes stay in JavaScript. Returns the archive bytes to write
// before them, or nothing when the name is not valid or already there.
export fn ml_zip_add_ref(size: f64, crc: f64, mtime: f64) -> const u8[:] {
    R.clear();
    if zip_add_ref(arg(0), size as i64, crc as i64, mtime as i64) == 0 { zip_take(R); }
    return done();
}

export fn ml_zip_take() -> const u8[:] {
    R.clear();
    zip_take(R);
    return done();
}

export fn ml_zip_finish() -> const u8[:] {
    R.clear();
    zip_finish(R);
    return done();
}

export fn ml_crc32(prev: f64) -> f64 { zip_crc32_update(prev as i64, arg(0)) as f64 }

// Reads a project ZIP in place: argument 0 is not copied (see io.h).
export fn ml_pack_import(zip: const u8[:]) -> const u8[:] {
    R.clear();
    pack_import(zip, R);
    return done();
}

export fn ml_git_begin(mtime: f64) { git_begin(arg(0), arg(1), mtime as i64); }

export fn ml_git_file() -> i32 { if git_file(arg(0), arg(1)) { 1 } else { 0 } }

export fn ml_git_file_ref(size: f64) -> i32 { if git_file_ref(arg(0), arg(1), size as i64) { 1 } else { 0 } }

export fn ml_git_commit(time: f64, tz_minutes: i32) -> const u8[:] {
    R.clear();
    git_commit(arg(0), time as i64, tz_minutes as i64, R);
    return done();
}

export fn ml_git_finish(mtime: f64) { git_finish(mtime as i64); }

// --- Vim mode (offsets are UTF-8 bytes) -----------------------------------

export fn ml_vim_reset() { vim_reset(); }

export fn ml_vim_clipboard() { vim_clipboard(arg(0)); }

export fn ml_vim_key(sel_s: i32, sel_e: i32) -> const u8[:] {
    R.clear();
    vim_key(R, arg(0), sel_e as i64, sel_s as i64, sel_e as i64, arg(1));
    return done();
}

// --- pages: PDF, images and video ------------------------------------------
//
// The document arguments, and also:
//   6 the media sizes, as "path\twidth\theight" lines
//   7 the narration sentence lengths, as "sentence\tseconds" lines
// The pages stay in the core for ml_page_svg and the SVG export calls,
// until the next ml_layout. web/pages.js uses its own core for them.

let LAYOUT_SLIDES = 0;
let LAYOUT_VIDEO = 1;
let LAYOUT_ARTICLE = 2;
let LAYOUT_HANDOUT = 3;
let LAYOUT_POSTER = 4;

// a: 1 for Letter paper (article, handout), or the poster size.
// b: 1 for a landscape poster.
fn layout_doc(kind: i64, opts: i32, a: i64, b: i64) {
    document(opts);
    MEDIA.clear();
    ml_arg(6, MEDIA);
    DURATIONS.clear();
    ml_arg(7, DURATIONS);
    let tk = has(opts, O_TAKAHASHI);
    var dark = th_prefers_dark(meta("theme")) == 1;
    if FIXED_THEME == "dark" { dark = true; }
    if FIXED_THEME == "light" { dark = false; }
    set_palette(th_palette_of(th_theme(meta("theme"), meta("accent")), dark));
    GRAY = false;
    if kind == LAYOUT_SLIDES { layout_slides(tk, TY_SLIDES, true); }
    else if kind == LAYOUT_VIDEO {
        layout_slides(tk, TY_VIDEO, false);
        narration_script();
        page_timeline();
    }
    else if kind == LAYOUT_ARTICLE { layout_article(a == 1); }
    else if kind == LAYOUT_HANDOUT {
        // The handout is black and white on paper (Theme.paper).
        set_palette(th_pal("Black and white", false, "#FFFFFF", "#F2F2F2", "#BDBDBD", "#5C5C5C", "#000000", "#000000", "#000000",
            "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000"));
        GRAY = true;
        layout_handout(tk, a == 1);
    }
    else if kind == LAYOUT_POSTER { layout_poster(a, b == 1); }
}

// The pages: {pages: [{width, height, steps, title, text}], warnings,
// timeline (video only: segments and cues)}.
export fn ml_layout(kind: i32, opts: i32, a: i32, b: i32) -> const u8[:] {
    layout_doc(kind, opts, a, b);
    R.clear();
    R.append("{\"pages\":[");
    for p in OUT0..PAGES.len {
        let pg = PAGES[p];
        if p > OUT0 { R.push(','); }
        R.append("{\"width\":");
        fmt_fixed(R, pg.w, 2);
        R.append(",\"height\":");
        fmt_fixed(R, pg.h, 2);
        format(R, ",\"steps\":", max(1, pg.steps), ",\"title\":");
        json_str(R, tb(pg.title));
        R.append(",\"text\":");
        var t: u8[>..] = [];
        page_text(t, p);
        json_str(R, t);
        R.push('}');
    }
    R.append("],\"warnings\":");
    json_str(R, LWARN);
    if kind == LAYOUT_VIDEO {
        R.append(",\"timeline\":");
        timeline_json(R);
    }
    R.push('}');
    return done();
}

// A page state as SVG. layer: see LY_ALL in pagesvg.goose. A step of -1
// shows every step.
export fn ml_page_svg(page: i32, step: i32, layer: i32, progress: f64, scale: f64) -> const u8[:] {
    R.clear();
    let p = OUT0 + page;
    if p >= OUT0 && p < PAGES.len {
        page_svg(R, p, if step < 0 { STEP_ALL } else { step }, layer, progress, scale);
    }
    return done();
}

// A page for the SVG export, with "<!--ml-region N-->" marks. ml_regions
// gives the regions to draw (ml_region_svg) and to trace (ml_trace).
export fn ml_export_svg(page: i32) -> const u8[:] {
    R.clear();
    let p = OUT0 + page;
    if p >= OUT0 && p < PAGES.len { export_svg(R, p, page + 1); }
    return done();
}

export fn ml_regions() -> const u8[:] {
    R.clear();
    R.push('[');
    for r, i in REGIONS {
        if i > 0 { R.push(','); }
        R.append("{\"x\":"); fmt_fixed(R, r.x, 3);
        R.append(",\"y\":"); fmt_fixed(R, r.y, 3);
        R.append(",\"scale\":"); fmt_fixed(R, r.scale, 4);
        format(R, ",\"width\":", ceil(r.w * r.scale) as! i64, ",\"height\":", ceil(r.h * r.scale) as! i64, ",\"colors\":", r.colors);
        R.append(",\"minArea\":"); fmt_fixed(R, r.min_area, 2);
        R.append(",\"tolerance\":"); fmt_fixed(R, r.tol, 2);
        R.append(",\"label\":");
        var l: u8[>..] = [];
        region_label(l, i);
        json_str(R, l);
        R.push('}');
    }
    R.push(']');
    return done();
}

export fn ml_region_svg(i: i32) -> const u8[:] {
    R.clear();
    if i >= 0 && i < REGIONS.len { region_svg(R, i); }
    return done();
}

// Traces RGBA pixels in place (argument 0, see ml_trace_arg in io.h).
// Argument 1 is the label of the group.
export fn ml_trace(px: const u8[:], rank: u8[:], taken: u8[:], w: i32, h: i32, colors: i32, min_area: f64, tol: f64, x: f64, y: f64, scale: f64) -> const u8[:] {
    R.clear();
    trace(R, px, rank, taken, w, h, colors, min_area, tol, x, y, scale, arg(1));
    return done();
}

// A front matter value. Argument 6 is the key.
export fn ml_meta() -> const u8[:] {
    document(0);
    var key: u8[>..] = [];
    ml_arg(6, key);
    R.clear();
    R.append(meta(key));
    return done();
}

// The podcast cues, from the narration lengths (argument 7).
export fn ml_podcast(opts: i32) -> const u8[:] {
    document(opts);
    DURATIONS.clear();
    ml_arg(7, DURATIONS);
    narration_script();
    sequential_cues();
    SEGS.clear();
    R.clear();
    timeline_json(R);
    return done();
}

// The start of an MP4 file. Arguments: 0 1 2 the video sample sizes,
// durations and key flags, 3 the avcC record, 4 5 the audio sample sizes
// and durations, 6 the audio decoder configuration. Sizes and durations
// are 32-bit little-endian numbers.
export fn ml_mp4(width: i32, height: i32, vscale: i32, codec: i32, ascale: i32, rate: i32, channels: i32) -> const u8[:] {
    let vs = arg(0);
    let vd = arg(1);
    let vk = arg(2);
    let vc = arg(3);
    let as_ = arg(4);
    let ad = arg(5);
    let ac = arg(6);
    R.clear();
    mp4_head(R, Track { vs, vd, vk, vc, vscale }, Track { as_, ad, "", ac, ascale }, width, height, codec, rate, channels);
    return done();
}
