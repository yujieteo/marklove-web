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
        slides(opts);
        var steps: i64[>..] = [];
        for f in FR { steps.push(0); }
        for s in SL { steps[s.frame] += s.steps; }
        timeline(steps);
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
