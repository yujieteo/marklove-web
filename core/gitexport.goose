// Git history export: writes a real `.git` folder into the ZIP builder of
// pack.goose. Ports the object-writing parts of Git/GitRepository.swift:
// writeObject, writeTree, commitIfChanged, setHead (reflog), initialize,
// writeConfig, writeIndex and Zlib.compress with stored blocks.
//
// Public functions (call in this sequence, oldest version first):
//
//   git_begin(name: u8[:], email: u8[:], mtime: i64)
//       Starts a new history with this author. mtime (unix seconds) goes
//       into the ZIP entries of the objects.
//   git_file(path: u8[:], data: u8[:]) -> bool
//       Adds one file to the next commit. The first git_file after a commit
//       starts a new file list. False for an unsafe or hidden path.
//   git_file_ref(path: u8[:], sha: u8[:], size: i64) -> bool
//       The same for a file whose blob object JavaScript writes itself: sha
//       is the 40-digit SHA-1 of "blob <size>\0" and the bytes. JavaScript
//       adds .git/objects/<2 digits>/<38 digits> once, with zip_add_ref.
//   git_commit(message: u8[:], unix_time: i64, tz_minutes: i64, out)
//       Commits the file list, with the previous commit as parent. Appends
//       the 40-digit commit SHA to out. When the tree is the same as the
//       parent's, no commit is made and out gets the parent's SHA, as
//       commitIfChanged.
//   git_finish(mtime: i64)
//       Adds the rest of `.git/` to the ZIP builder: the folders that Git
//       needs, HEAD, config, description, info/exclude, refs/heads/main, the
//       reflogs and the index of the last commit. The objects go into the
//       ZIP builder as they are made, so call zip_begin before git_begin. JS adds the
//       worktree files itself with zip_add; for a clean `git status` they are
//       the files of the last commit. mtime (unix seconds) goes into the ZIP
//       entries and the index.

import std;
import base;
import pack;

struct GxFile { po: i64, pn: i64, obj: i64, size: i64 }

var GX_NAME: u8[>..] = [];
var GX_EMAIL: u8[>..] = [];
// Objects: 20 raw SHA bytes each. The objects themselves are in the ZIP.
var GX_SHA: u8[>..] = [];
var GX_MTIME = 0;
// The file list of the current (or last) commit.
var GX_FP: u8[>..] = [];
var GX_FILES: GxFile[>..] = [];
var GX_NEW = false;
var GX_HEAD = -1;
var GX_HEAD_TREE = -1;
var GX_LOG: u8[>..] = [];

fn git_begin(name: u8[:], email: u8[:], mtime: i64) {
    GX_MTIME = mtime;
    GX_NAME.clear();
    GX_EMAIL.clear();
    for c in name {
        if c == '\n' { GX_NAME.push(' '); } else if c != '<' && c != '>' { GX_NAME.push(c); }
    }
    for c in email { if c != '<' && c != '>' && c != '\n' { GX_EMAIL.push(c); } }
    GX_SHA.clear();
    GX_FP.clear();
    GX_FILES.clear();
    GX_NEW = false;
    GX_HEAD = -1;
    GX_HEAD_TREE = -1;
    GX_LOG.clear();
}

fn gx_hex(out: u8[>..]&, b: u8[:]) {
    let digits = "0123456789abcdef";
    for c in b {
        out.push(digits[(c >> 4) as i64]);
        out.push(digits[(c & 0x0F) as i64]);
    }
}

fn gx_obj_hex(out: u8[>..]&, i: i64) {
    var b: u8[..20] = [];
    for k in 20 { b.push(GX_SHA[i * 20 + k]); }
    gx_hex(out, b);
}

fn gx_be32(out: u8[>..]&, v: i64) {
    out.push((v >> 24 & 0xFF) as u8);
    out.push((v >> 16 & 0xFF) as u8);
    out.push((v >> 8 & 0xFF) as u8);
    out.push((v & 0xFF) as u8);
}

// zlib with deflate stored blocks, as Zlib.compress and Zlib.stored.
fn gx_zlib(out: u8[>..]&, d: u8[:]) {
    out.push(0x78);
    out.push(0x01);
    var i = 0;
    while true {
        let n = min(65535, d.len - i);
        if i + n >= d.len { out.push(1); } else { out.push(0); }
        out.push((n & 0xFF) as u8);
        out.push((n >> 8) as u8);
        out.push((~n & 0xFF) as u8);
        out.push((~n >> 8 & 0xFF) as u8);
        for k in i..i + n { out.push(d[k]); }
        i += n;
        if i >= d.len { break; }
    }
    var a = 1;
    var b = 0;
    for c in d {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    gx_be32(out, (b << 16) | a);
}

// Stores an object and returns its index. Objects are stored once.
fn gx_write(kind: const u8[:], content: u8[:]) -> i64 {
    var raw: u8[>..] = [];
    format(raw, kind, " ", content.len);
    raw.push(0);
    raw.append(content);
    var dg: u8[>..] = [];
    sha1(raw, dg);
    let known = gx_find(dg);
    if known >= 0 { return known; }
    GX_SHA.append(dg);
    let i = GX_SHA.len / 20 - 1;
    var hex: u8[>..] = [];
    gx_obj_hex(hex, i);
    var name: u8[>..] = [];
    name.append(".git/objects/");
    name.append(hex[..2]);
    zip_add_dir(name, GX_MTIME);
    name.push('/');
    name.append(hex[2..]);
    var z: u8[>..] = [];
    gx_zlib(z, raw);
    zip_add(name, z, GX_MTIME);
    return i;
}

fn gx_find(dg: u8[:]) -> i64 {
    for i in GX_SHA.len / 20 {
        if GX_SHA[i * 20..i * 20 + 20] == dg { return i; }
    }
    return -1;
}

fn git_file(path: u8[:], data: u8[:]) -> bool { gx_file(path, data, "", data.len) }

fn git_file_ref(path: u8[:], sha: u8[:], size: i64) -> bool {
    if sha.len != 40 { return false; }
    for c in sha { if !is_digit(c) && !(c >= 'a' && c <= 'f') { return false; } }
    return gx_file(path, "", sha, size);
}

fn gx_nibble(c: u8) -> i64 { if is_digit(c) { (c - '0') as i64 } else { (c - 'a' + 10) as i64 } }

// One file of the next commit: its bytes, or the SHA of a blob that
// JavaScript writes.
fn gx_file(path: u8[:], data: u8[:], sha: u8[:], size: i64) -> bool {
    if GX_NEW {
        GX_FP.clear();
        GX_FILES.clear();
        GX_NEW = false;
    }
    var clean: u8[>..] = [];
    if !zip_clean_name(path, clean) { return false; }
    // Hidden files (and .git) are not in the worktree, as worktreeFiles.
    if clean[0] == '.' || index_of(clean, "/.") >= 0 { return false; }
    var obj = -1;
    if sha.len == 0 { obj = gx_write("blob", data); }
    else {
        var dg: u8[..20] = [];
        for k in 20 { dg.push((gx_nibble(sha[2 * k]) * 16 + gx_nibble(sha[2 * k + 1])) as u8); }
        obj = gx_find(dg);
        if obj < 0 {
            GX_SHA.append(dg);
            obj = GX_SHA.len / 20 - 1;
            var dir: u8[>..] = [];
            dir.append(".git/objects/");
            dir.append(sha[..2]);
            zip_add_dir(dir, GX_MTIME);
        }
    }
    for i in GX_FILES.len {
        let f = GX_FILES[i];
        if GX_FP[f.po..f.po + f.pn] == clean {
            GX_FILES[i].obj = obj;
            GX_FILES[i].size = size;
            return true;
        }
    }
    let po = GX_FP.len;
    GX_FP.append(clean);
    GX_FILES.push(GxFile { po: po, pn: clean.len, obj: obj, size: size });
    return true;
}

// The file indexes in byte order of their paths. This is also Git tree order,
// because a folder's paths all start with "name/".
fn gx_sorted() -> i64[>..] {
    var idx: i64[>..] = [];
    for i in GX_FILES.len { idx.push(i); }
    sort(idx) { a, b =>
        let fa = GX_FILES[a];
        let fb = GX_FILES[b];
        compare(GX_FP[fa.po..fa.po + fa.pn], GX_FP[fb.po..fb.po + fb.pn]) < 0
    };
    return idx;
}

// The child trees of the gx_tree calls that are running.
var GX_KIDS: i64[>..] = [];

// The byte offset of the first "/" in file f at or after off, or -1.
fn gx_slash(f: GxFile, off: i64) -> i64 {
    for k in off..f.pn { if GX_FP[f.po + k] == '/' { return k - off; } }
    return -1;
}

// The end of the group of files idx[i..b] in the folder whose name is the
// s bytes at `off` of file idx[i].
fn gx_group_end(idx: i64[:], i: i64, b: i64, off: i64, s: i64) -> i64 {
    let f = GX_FILES[idx[i]];
    var j = i + 1;
    while j < b {
        let g = GX_FILES[idx[j]];
        if g.pn - off <= s || GX_FP[g.po + off + s] != '/' { break; }
        for k in s { if GX_FP[g.po + off + k] != GX_FP[f.po + off + k] { return j; } }
        j++;
    }
    return j;
}

// Writes the tree for the sorted files idx[a..b], whose paths share the
// first `off` bytes. Returns the object index.
recursive fn gx_tree(idx: i64[:], a: i64, b: i64, off: i64) -> i64 {
    // First the child trees, with no growable local in scope.
    let kids = GX_KIDS.len;
    var i = a;
    while i < b {
        let s = gx_slash(GX_FILES[idx[i]], off);
        if s < 0 { i++; continue; }
        let j = gx_group_end(idx, i, b, off, s);
        let child = gx_tree(idx, i, j, off + s + 1);
        GX_KIDS.push(child);
        i = j;
    }
    return gx_tree_write(idx, a, b, off, kids);
}

fn gx_tree_write(idx: i64[:], a: i64, b: i64, off: i64, kids: i64) -> i64 {
    var content: u8[>..] = [];
    var kid = kids;
    var i = a;
    while i < b {
        let f = GX_FILES[idx[i]];
        let s = gx_slash(f, off);
        var obj = f.obj;
        var end = f.pn;
        var j = i + 1;
        if s < 0 {
            content.append("100644 ");
        } else {
            content.append("40000 ");
            end = off + s;
            j = gx_group_end(idx, i, b, off, s);
            obj = GX_KIDS[kid];
            kid++;
        }
        for k in off..end { content.push(GX_FP[f.po + k]); }
        content.push(0);
        for k in 20 { content.push(GX_SHA[obj * 20 + k]); }
        i = j;
    }
    GX_KIDS.resize(kids);
    return gx_write("tree", content);
}

fn gx_stamp(out: u8[>..]&, t: i64, tz: i64) {
    format(out, t, " ");
    if tz < 0 { out.push('-'); } else { out.push('+'); }
    let a = abs(tz);
    format_int(out, a / 60, 10, 2, '0');
    format_int(out, a % 60, 10, 2, '0');
}

fn git_commit(message: u8[:], unix_time: i64, tz_minutes: i64, out: u8[>..]&) {
    let idx = gx_sorted();
    let tree = gx_tree(idx, 0, idx.len, 0);
    GX_NEW = true;
    if GX_HEAD >= 0 && tree == GX_HEAD_TREE {
        gx_obj_hex(out, GX_HEAD);
        return;
    }
    var text: u8[>..] = [];
    text.append(trim_all(message));
    if text.len == 0 { text.append("Save"); }
    var stamp: u8[>..] = [];
    gx_stamp(stamp, unix_time, tz_minutes);
    var body: u8[>..] = [];
    body.append("tree ");
    gx_obj_hex(body, tree);
    body.push('\n');
    if GX_HEAD >= 0 {
        body.append("parent ");
        gx_obj_hex(body, GX_HEAD);
        body.push('\n');
    }
    var who: u8[>..] = [];
    who.append(GX_NAME);
    who.append(" <");
    who.append(GX_EMAIL);
    who.append("> ");
    who.append(stamp);
    body.append("author ");
    body.append(who);
    body.append("\ncommitter ");
    body.append(who);
    body.append("\n\n");
    body.append(text);
    body.push('\n');
    let sha = gx_write("commit", body);
    // The reflog line, as setHead.
    var line: u8[>..] = [];
    if GX_HEAD >= 0 { gx_obj_hex(line, GX_HEAD); } else { line.append("0000000000000000000000000000000000000000"); }
    line.push(' ');
    gx_obj_hex(line, sha);
    line.push(' ');
    line.append(who);
    if GX_HEAD >= 0 { line.append("\tcommit: "); } else { line.append("\tcommit (initial): "); }
    let nl = index_of_byte(text, '\n');
    if nl >= 0 { line.append(text[..nl]); } else { line.append(text); }
    line.push('\n');
    GX_LOG.append(line);
    GX_HEAD = sha;
    GX_HEAD_TREE = tree;
    gx_obj_hex(out, sha);
}

// The index (version 2) of the current file list, as writeIndex.
fn gx_index(out: u8[>..]&, mtime: i64) {
    let idx = gx_sorted();
    out.append("DIRC");
    gx_be32(out, 2);
    gx_be32(out, idx.len);
    let secs = max(0, mtime);
    for i in idx {
        let f = GX_FILES[i];
        let start = out.len;
        gx_be32(out, secs); gx_be32(out, 0);    // ctime
        gx_be32(out, secs); gx_be32(out, 0);    // mtime
        gx_be32(out, 0); gx_be32(out, 0);       // dev, ino
        gx_be32(out, 0x81A4);                   // mode 0100644
        gx_be32(out, 0); gx_be32(out, 0);       // uid, gid
        gx_be32(out, f.size);
        for k in 20 { out.push(GX_SHA[f.obj * 20 + k]); }
        let n = min(f.pn, 0xFFF);
        out.push((n >> 8) as u8);
        out.push((n & 0xFF) as u8);
        for k in f.po..f.po + f.pn { out.push(GX_FP[k]); }
        // One to eight NUL bytes, to a multiple of eight.
        let npad = 8 - (out.len - start) % 8;
        for k in npad { out.push(0); }
    }
    var dg: u8[>..] = [];
    sha1(out, dg);
    out.append(dg);
}

fn gx_put(name: const u8[:], data: u8[:], mtime: i64) {
    var n: u8[>..] = [];
    n.append(".git/");
    n.append(name);
    zip_add(n, data, mtime);
}

fn gx_dir(name: const u8[:], mtime: i64) {
    var n: u8[>..] = [];
    n.append(".git");
    n.append(name);
    zip_add_dir(n, mtime);
}

fn git_finish(mtime: i64) {
    // The folders of initialize(), with their parents.
    gx_dir("", mtime);
    gx_dir("/objects", mtime);
    gx_dir("/objects/info", mtime);
    gx_dir("/objects/pack", mtime);
    gx_dir("/refs", mtime);
    gx_dir("/refs/heads", mtime);
    gx_dir("/refs/tags", mtime);
    gx_dir("/info", mtime);
    gx_dir("/logs", mtime);
    gx_dir("/logs/refs", mtime);
    gx_dir("/logs/refs/heads", mtime);
    gx_put("HEAD", "ref: refs/heads/main\n", mtime);
    gx_put("config", "[core]\n\trepositoryformatversion = 0\n\tfilemode = false\n\tbare = false\n\tlogallrefupdates = true\n\ttrustctime = false\n\tcheckStat = minimal\n\tignorecase = true\n\tprecomposeunicode = true\n", mtime);
    gx_put("description", "Unnamed repository; edit this file 'description' to name the repository.\n", mtime);
    gx_put("info/exclude", "# Files that Git does not track. Marklove writes this list.\n.DS_Store\n*.tmp\n", mtime);
    if GX_HEAD >= 0 {
        var ref: u8[>..] = [];
        gx_obj_hex(ref, GX_HEAD);
        ref.push('\n');
        gx_put("refs/heads/main", ref, mtime);
        var log: u8[>..] = [];
        log.append(GX_LOG);
        gx_put("logs/HEAD", log, mtime);
        gx_put("logs/refs/heads/main", log, mtime);
        var index: u8[>..] = [];
        gx_index(index, mtime);
        gx_put("index", index, mtime);
    }
}
