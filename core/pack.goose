// Project packages: CRC-32, a ZIP writer with stored entries, a ZIP reader
// with raw DEFLATE inflate, the project ZIP import rules, and SHA-1.
// Ports Package/Zip.swift, the import part of Package/ProjectPackage.swift
// and Git/SHA1.swift.
//
// Public functions:
//
//   zip_begin()
//       Starts a new archive in the global builder.
//   zip_add(name: u8[:], data: u8[:], mtime: i64) -> i64
//       Adds one stored file. mtime is unix seconds; the DOS time is UTC.
//       Returns 0 = added, 1 = invalid name, 2 = duplicate name, 3 = too large.
//   zip_add_dir(name: u8[:], mtime: i64) -> i64
//       Adds an empty folder entry ("name/"). Same codes as zip_add.
//   zip_add_ref(name: u8[:], size: i64, crc: i64, mtime: i64) -> i64
//       Adds one stored file whose bytes stay outside (in JavaScript): the
//       caller writes them right after the bytes that zip_take gives next.
//       Same codes as zip_add.
//   zip_take(out)
//       Appends the archive bytes so far to out and removes them from the
//       builder, so that a large archive goes out in parts.
//   zip_finish(out)
//       Appends the rest of the archive to out and clears the builder.
//   zip_crc32_update(crc: i64, data: u8[:]) -> i64
//       Continues a CRC-32 (start with 0) over one more part of a file.
//
//   pack_import(zip: u8[:], out)
//       Reads a project ZIP. Appends JSON to out:
//         {"markdownName":"talk.md","markdown":"...",
//          "assets":[{"path":"images/a.png","method":8,"offset":123,
//                     "csize":100,"usize":120,"crc":4567}, ...],
//          "warnings":["...", ...]}
//       or {"error":"..."}. The asset bytes stay in the ZIP: JavaScript
//       reads csize bytes at offset, inflates them for method 8 and checks
//       usize and crc. The .git folder is not imported.
//
//   inflate(data: u8[:], limit: i64, out) -> bool
//       Raw DEFLATE (RFC 1951). Appends at most limit bytes. On false,
//       PK_ERR has the message.
//   zip_crc32(data: u8[:]) -> i64
//   sha1_hex(data: u8[:], out)      40 lower-case hex digits.
//   sha1(data: u8[:], out)          the 20 digest bytes.
//
// Not ported: isListener (it needs the front matter; parse.goose has it).

import std;
import base;

var PK_ERR: u8[>..] = [];

fn pk_fail(m: const u8[:]) -> bool {
    PK_ERR.clear();
    PK_ERR.append(m);
    return false;
}

fn pk_u16(d: u8[:], i: i64) -> i64 { let a: i64 = d[i]; let b: i64 = d[i + 1]; return a | (b << 8); }
fn pk_u32(d: u8[:], i: i64) -> i64 { pk_u16(d, i) | (pk_u16(d, i + 2) << 16) }

fn pk_le16(out: u8[>..]&, v: i64) {
    out.push((v & 0xFF) as u8);
    out.push((v >> 8 & 0xFF) as u8);
}

fn pk_le32(out: u8[>..]&, v: i64) {
    pk_le16(out, v & 0xFFFF);
    pk_le16(out, v >> 16 & 0xFFFF);
}

// MARK: CRC-32 (IEEE)

var CRC_T: u32[256] = [0; 256];
var CRC_READY = false;

fn zip_crc32(data: u8[:]) -> i64 { zip_crc32_update(0, data) }

fn zip_crc32_update(prev: i64, data: u8[:]) -> i64 {
    if !CRC_READY {
        for i in 256 {
            var c = i as u32;
            for k in 8 {
                if (c & 1) != 0 { c = 0xEDB88320 ^ (c >> 1); } else { c = c >> 1; }
            }
            CRC_T[i] = c;
        }
        CRC_READY = true;
    }
    var crc: u32 = (prev as u32) ^ 0xFFFFFFFF;
    for b in data { crc = CRC_T[((crc ^ b) & 0xFF) as i64] ^ (crc >> 8); }
    return crc ^ 0xFFFFFFFF;
}

// MARK: ZIP writer

// attr is the external attributes: the Unix mode << 16, and 0x10 for a folder.
struct ZwEnt { no: i64, nn: i64, crc: i64, size: i64, off: i64, time: i64, date: i64, attr: i64 }

var ZW_DATA: u8[>..] = [];
// The archive bytes before ZW_DATA: taken by zip_take, or outside.
var ZW_BASE = 0;
var ZW_NAMES: u8[>..] = [];
var ZW_ENTS: ZwEnt[>..] = [];

fn zip_begin() {
    ZW_BASE = 0;
    ZW_DATA.clear();
    ZW_NAMES.clear();
    ZW_ENTS.clear();
}

// A safe relative entry name, as ZipWriter.cleanName. False for absolute
// paths, ":" and ".." segments.
fn zip_clean_name(name: u8[:], out: u8[>..]&) -> bool {
    let start = out.len;
    if name.len > 0 && (name[0] == '/' || name[0] == '\\') { return false; }
    if contains_byte(name, ':') { return false; }
    var a = 0;
    while a <= name.len {
        var b = a;
        while b < name.len && name[b] != '/' && name[b] != '\\' { b++; }
        let n = b - a;
        if n == 2 && name[a] == '.' && name[a + 1] == '.' { out.resize(start); return false; }
        if n > 0 && !(n == 1 && name[a] == '.') {
            if out.len > start { out.push('/'); }
            for i in a..b { out.push(name[i]); }
        }
        a = b + 1;
    }
    return out.len > start;
}

// DOS time and date of a unix time, in UTC.
fn zip_dos_time(t: i64) -> i64, i64 {
    let days = div_euclid(t, 86400);
    let secs = t - days * 86400;
    // Civil date from days (H. Hinnant).
    let z = days + 719468;
    let era = div_euclid(z, 146097);
    let doe = z - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    var month = mp + 3;
    if mp >= 10 { month = mp - 9; }
    var year = yoe + era * 400;
    if month <= 2 { year++; }
    year = max(1980, year);
    let time = ((secs / 3600) << 11) | ((secs / 60 % 60) << 5) | (secs % 60 / 2);
    let date = ((year - 1980) << 9) | (month << 5) | day;
    return time & 0xFFFF, date & 0xFFFF;
}

fn zip_add(name: u8[:], data: u8[:], mtime: i64) -> i64 {
    let r = zip_header(name, data.len, zip_crc32(data), mtime);
    if r == 0 { ZW_DATA.append(data); }
    return r;
}

fn zip_add_ref(name: u8[:], size: i64, crc: i64, mtime: i64) -> i64 {
    let r = zip_header(name, size, crc, mtime);
    if r == 0 { ZW_BASE += size; }
    return r;
}

fn zip_take(out: u8[>..]&) {
    out.append(ZW_DATA);
    ZW_BASE += ZW_DATA.len;
    ZW_DATA.clear();
}

// The local header of a stored file, and its central directory entry.
fn zip_header(name: u8[:], size: i64, crc: i64, mtime: i64) -> i64 {
    var clean: u8[>..] = [];
    if !zip_clean_name(name, clean) { return 1; }
    for e in ZW_ENTS {
        if ZW_NAMES[e.no..e.no + e.nn] == clean { return 2; }
    }
    if size >= 0xFFFFFFFF || ZW_BASE + ZW_DATA.len + size >= 0xFFFFFFFF - 1000000 { return 3; }
    let no = ZW_NAMES.len;
    ZW_NAMES.append(clean);
    let time, date = zip_dos_time(mtime);
    let off = ZW_BASE + ZW_DATA.len;
    pk_le32(ZW_DATA, 0x04034B50);
    pk_le16(ZW_DATA, 20);        // version needed
    pk_le16(ZW_DATA, 0x0800);    // UTF-8 names
    pk_le16(ZW_DATA, 0);         // stored
    pk_le16(ZW_DATA, time);
    pk_le16(ZW_DATA, date);
    pk_le32(ZW_DATA, crc);
    pk_le32(ZW_DATA, size);
    pk_le32(ZW_DATA, size);
    pk_le16(ZW_DATA, clean.len);
    pk_le16(ZW_DATA, 0);
    ZW_DATA.append(clean);
    ZW_ENTS.push(ZwEnt { no: no, nn: clean.len, crc: crc, size: size, off: off, time: time, date: date, attr: 0x81A40000 });
    return 0;
}

// Adds an empty folder entry; the name gets a "/" at the end. A folder that
// is already there is not added again. Returns the same codes as zip_add.
fn zip_add_dir(name: u8[:], mtime: i64) -> i64 {
    var clean: u8[>..] = [];
    if !zip_clean_name(name, clean) { return 1; }
    clean.push('/');
    for e in ZW_ENTS {
        if ZW_NAMES[e.no..e.no + e.nn] == clean { return 0; }
    }
    if ZW_BASE + ZW_DATA.len >= 0xFFFFFFFF - 1000000 { return 3; }
    let no = ZW_NAMES.len;
    ZW_NAMES.append(clean);
    let time, date = zip_dos_time(mtime);
    let off = ZW_BASE + ZW_DATA.len;
    pk_le32(ZW_DATA, 0x04034B50);
    pk_le16(ZW_DATA, 20);
    pk_le16(ZW_DATA, 0x0800);
    pk_le16(ZW_DATA, 0);
    pk_le16(ZW_DATA, time);
    pk_le16(ZW_DATA, date);
    pk_le32(ZW_DATA, 0);
    pk_le32(ZW_DATA, 0);
    pk_le32(ZW_DATA, 0);
    pk_le16(ZW_DATA, clean.len);
    pk_le16(ZW_DATA, 0);
    ZW_DATA.append(clean);
    ZW_ENTS.push(ZwEnt { no: no, nn: clean.len, crc: 0, size: 0, off: off, time: time, date: date, attr: 0x41ED0010 });
    return 0;
}

fn zip_finish(out: u8[>..]&) {
    let central_start = ZW_BASE + ZW_DATA.len;
    for e in ZW_ENTS {
        pk_le32(ZW_DATA, 0x02014B50);
        pk_le16(ZW_DATA, 0x031E);    // made by: Unix, 3.0
        pk_le16(ZW_DATA, 20);
        pk_le16(ZW_DATA, 0x0800);
        pk_le16(ZW_DATA, 0);
        pk_le16(ZW_DATA, e.time);
        pk_le16(ZW_DATA, e.date);
        pk_le32(ZW_DATA, e.crc);
        pk_le32(ZW_DATA, e.size);
        pk_le32(ZW_DATA, e.size);
        pk_le16(ZW_DATA, e.nn);
        pk_le16(ZW_DATA, 0);
        pk_le16(ZW_DATA, 0);
        pk_le16(ZW_DATA, 0);
        pk_le16(ZW_DATA, 0);          // internal attributes
        pk_le32(ZW_DATA, e.attr);     // external attributes
        pk_le32(ZW_DATA, e.off);
        for i in e.no..e.no + e.nn { ZW_DATA.push(ZW_NAMES[i]); }
    }
    let central_size = ZW_BASE + ZW_DATA.len - central_start;
    pk_le32(ZW_DATA, 0x06054B50);
    pk_le16(ZW_DATA, 0);
    pk_le16(ZW_DATA, 0);
    pk_le16(ZW_DATA, ZW_ENTS.len);
    pk_le16(ZW_DATA, ZW_ENTS.len);
    pk_le32(ZW_DATA, central_size);
    pk_le32(ZW_DATA, central_start);
    pk_le16(ZW_DATA, 0);
    for b in ZW_DATA { out.push(b); }
    zip_begin();
}

// MARK: Inflate (RFC 1951)

struct PkBits { pos: i64, buf: u64, cnt: i64, bad: bool }
struct PkHuff { counts: i64[16], syms: i64[320] }

fn pk_bits(r: PkBits&, d: u8[:], n: i64) -> i64 {
    if n == 0 { return 0; }
    while r.cnt < n {
        if r.pos >= d.len { r.bad = true; return 0; }
        r.buf |= (d[r.pos] as u64) << r.cnt;
        r.pos++;
        r.cnt += 8;
    }
    let mask: u64 = (1 << n) - 1;
    let v = (r.buf & mask) as i64;
    r.buf >>= n;
    r.cnt -= n;
    return v;
}

fn pk_huff(h: PkHuff&, lengths: i64[:]) {
    for i in 16 { h.counts[i] = 0; }
    for l in lengths { h.counts[l] += 1; }
    h.counts[0] = 0;
    var offs: i64[16] = [0; 16];
    for i in 1..16 { offs[i] = offs[i - 1] + h.counts[i - 1]; }
    for s in lengths.len {
        let l = lengths[s];
        if l != 0 { h.syms[offs[l]] = s; offs[l] += 1; }
    }
}

// A symbol, or -1 with PK_ERR set.
fn pk_decode(h: PkHuff&, r: PkBits&, d: u8[:]) -> i64 {
    var code = 0;
    var first = 0;
    var index = 0;
    for len in 1..16 {
        code |= pk_bits(r, d, 1);
        if r.bad { pk_fail("Unexpected end of data"); return -1; }
        let count = h.counts[len];
        if code - count < first { return h.syms[index + (code - first)]; }
        index += count;
        first += count;
        first <<= 1;
        code <<= 1;
    }
    pk_fail("Invalid Huffman code");
    return -1;
}

let PK_LBASE: i64[29] = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258];
let PK_LEXTRA: i64[29] = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0];
let PK_DBASE: i64[30] = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577];
let PK_DEXTRA: i64[30] = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13];
let PK_ORDER: i64[19] = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15];

fn pk_codes(r: PkBits&, d: u8[:], out: u8[>..]&, base: i64, lit: PkHuff&, dist: PkHuff&, limit: i64) -> bool {
    while true {
        let sym = pk_decode(lit, r, d);
        if sym < 0 { return false; }
        if sym < 256 {
            out.push(sym as u8);
        } else if sym == 256 {
            return true;
        } else {
            let li = sym - 257;
            if li >= 29 { return pk_fail("Bad length symbol"); }
            let len = PK_LBASE[li] + pk_bits(r, d, PK_LEXTRA[li]);
            let di = pk_decode(dist, r, d);
            if di < 0 { return false; }
            if di >= 30 { return pk_fail("Bad distance symbol"); }
            let dd = PK_DBASE[di] + pk_bits(r, d, PK_DEXTRA[di]);
            if r.bad { return pk_fail("Unexpected end of data"); }
            if dd > out.len - base { return pk_fail("Distance too far"); }
            let start = out.len - dd;
            for k in len { out.push(out[start + k]); }
            if out.len - base > limit { return pk_fail("Output too large"); }
        }
    }
    return true;
}

fn inflate(d: u8[:], limit: i64, out: u8[>..]&) -> bool {
    let base = out.len;
    var r = PkBits { pos: 0, buf: 0, cnt: 0, bad: false };
    var lit = default<PkHuff>();
    var dist = default<PkHuff>();
    var lens: i64[320] = [0; 320];
    var fin = 0;
    while fin == 0 {
        fin = pk_bits(r, d, 1);
        let kind = pk_bits(r, d, 2);
        if r.bad { return pk_fail("Unexpected end of data"); }
        if kind == 0 {
            r.buf = 0;
            r.cnt = 0;
            if r.pos + 4 > d.len { return pk_fail("Bad stored block"); }
            let len = pk_u16(d, r.pos);
            let nlen = pk_u16(d, r.pos + 2);
            if len != (~nlen & 0xFFFF) { return pk_fail("Bad stored length"); }
            r.pos += 4;
            if r.pos + len > d.len { return pk_fail("Stored block too short"); }
            for i in r.pos..r.pos + len { out.push(d[i]); }
            r.pos += len;
        } else if kind == 1 {
            for i in 288 {
                if i < 144 { lens[i] = 8; } else if i < 256 { lens[i] = 9; } else if i < 280 { lens[i] = 7; } else { lens[i] = 8; }
            }
            pk_huff(lit, lens[..288]);
            for i in 30 { lens[i] = 5; }
            pk_huff(dist, lens[..30]);
            if !pk_codes(r, d, out, base, lit, dist, limit) { return false; }
        } else if kind == 2 {
            let hlit = pk_bits(r, d, 5) + 257;
            let hdist = pk_bits(r, d, 5) + 1;
            let hclen = pk_bits(r, d, 4) + 4;
            var clen: i64[19] = [0; 19];
            for i in hclen { clen[PK_ORDER[i]] = pk_bits(r, d, 3); }
            if r.bad { return pk_fail("Unexpected end of data"); }
            var ch = default<PkHuff>();
            pk_huff(ch, clen[..]);
            let total = hlit + hdist;
            var n = 0;
            while n < total {
                let sym = pk_decode(ch, r, d);
                if sym < 0 { return false; }
                var v = 0;
                var rep = 1;
                if sym < 16 { v = sym; }
                else if sym == 16 {
                    if n == 0 { return pk_fail("Repeat with no length"); }
                    v = lens[n - 1];
                    rep = 3 + pk_bits(r, d, 2);
                }
                else if sym == 17 { rep = 3 + pk_bits(r, d, 3); }
                else { rep = 11 + pk_bits(r, d, 7); }
                if r.bad { return pk_fail("Unexpected end of data"); }
                if n + rep > total { return pk_fail("Too many lengths"); }
                for k in rep { lens[n + k] = v; }
                n += rep;
            }
            pk_huff(lit, lens[..hlit]);
            pk_huff(dist, lens[hlit..total]);
            if !pk_codes(r, d, out, base, lit, dist, limit) { return false; }
        } else {
            return pk_fail("Invalid block type");
        }
        if out.len - base > limit { return pk_fail("Output too large"); }
    }
    return true;
}

// MARK: ZIP reader

struct PkEnt { no: i64, nn: i64, method: i64, csize: i64, usize: i64, crc: i64, local: i64 }

var PK_ENTS: PkEnt[>..] = [];
var PK_NAMES: u8[>..] = [];

// The largest total size Marklove extracts, to protect against ZIP bombs.
let PK_MAX_TOTAL = 2000000000;

// The length of a valid UTF-8 sequence at s[i], or 0.
fn pk_utf8_at(s: u8[:], i: i64) -> i64 {
    let c = s[i];
    if c < 0x80 { return 1; }
    var n = 0;
    var lo: u8 = 0x80;
    var hi: u8 = 0xBF;
    if c >= 0xC2 && c <= 0xDF { n = 2; }
    else if c == 0xE0 { n = 3; lo = 0xA0; }
    else if c == 0xED { n = 3; hi = 0x9F; }
    else if c >= 0xE1 && c <= 0xEF { n = 3; }
    else if c == 0xF0 { n = 4; lo = 0x90; }
    else if c == 0xF4 { n = 4; hi = 0x8F; }
    else if c >= 0xF1 && c <= 0xF3 { n = 4; }
    else { return 0; }
    if i + n > s.len { return 0; }
    if s[i + 1] < lo || s[i + 1] > hi { return 0; }
    for k in 2..n { if s[i + k] < 0x80 || s[i + k] > 0xBF { return 0; } }
    return n;
}

fn pk_valid_utf8(s: u8[:]) -> bool {
    var i = 0;
    while i < s.len {
        let n = pk_utf8_at(s, i);
        if n == 0 { return false; }
        i += n;
    }
    return true;
}

// Reads the central directory into PK_ENTS. On false, PK_ERR has the error.
fn pk_read(d: u8[:]) -> bool {
    PK_ENTS.clear();
    PK_NAMES.clear();
    if d.len < 22 { return pk_fail("notAZip"); }
    var eocd = -1;
    let lowest = max(0, d.len - 22 - 65535);
    var i = d.len - 22;
    while i >= lowest {
        if pk_u32(d, i) == 0x06054B50 { eocd = i; break; }
        i--;
    }
    if eocd < 0 { return pk_fail("notAZip"); }
    let count = pk_u16(d, eocd + 10);
    var p = pk_u32(d, eocd + 16);
    var total = 0;
    for k in count {
        if p + 46 > d.len || pk_u32(d, p) != 0x02014B50 { return pk_fail("corrupt(\"central directory\")"); }
        if (pk_u16(d, p + 8) & 1) != 0 { return pk_fail("encrypted"); }
        let name_len = pk_u16(d, p + 28);
        let extra_len = pk_u16(d, p + 30);
        let comment_len = pk_u16(d, p + 32);
        if p + 46 + name_len > d.len { return pk_fail("corrupt(\"name\")"); }
        let usize = pk_u32(d, p + 24);
        total += usize;
        if total > PK_MAX_TOTAL { return pk_fail("tooLarge"); }
        // A name that is not UTF-8 gets U+FFFD for each bad byte.
        let no = PK_NAMES.len;
        var j = p + 46;
        while j < p + 46 + name_len {
            let n = pk_utf8_at(d[..p + 46 + name_len], j);
            if n == 0 { PK_NAMES.append("�"); j++; }
            else { for q in n { PK_NAMES.push(d[j + q]); } j += n; }
        }
        PK_ENTS.push(PkEnt { no: no, nn: PK_NAMES.len - no, method: pk_u16(d, p + 10),
                             csize: pk_u32(d, p + 20), usize: usize, crc: pk_u32(d, p + 16),
                             local: pk_u32(d, p + 42) });
        p += 46 + name_len + extra_len + comment_len;
    }
    return true;
}

fn pk_name(ei: i64, out: u8[>..]&) {
    let e = PK_ENTS[ei];
    for i in e.no..e.no + e.nn { out.push(PK_NAMES[i]); }
}

// Appends the bytes of entry ei. On false, out is as before and PK_ERR has
// the error.
fn pk_contents(d: u8[:], ei: i64, out: u8[>..]&) -> bool {
    let e = PK_ENTS[ei];
    let p = e.local;
    if p + 30 > d.len || pk_u32(d, p) != 0x04034B50 { return pk_fail("corrupt(\"local header\")"); }
    let start = p + 30 + pk_u16(d, p + 26) + pk_u16(d, p + 28);
    if start + e.csize > d.len { return pk_fail("corrupt(\"entry size\")"); }
    let base = out.len;
    if e.method == 0 {
        for i in start..start + e.csize { out.push(d[i]); }
    } else if e.method == 8 {
        if !inflate(d[start..start + e.csize], e.usize + 1, out) {
            var m: u8[>..] = [];
            m.append("InflateError(message: \"");
            m.append(PK_ERR);
            m.append("\")");
            PK_ERR.clear();
            PK_ERR.append(m);
            out.resize(base);
            return false;
        }
    } else {
        PK_ERR.clear();
        format(PK_ERR, "unsupportedMethod(", e.method, ")");
        return false;
    }
    var bad = 0;
    if out.len - base != e.usize { bad = 1; }
    else if zip_crc32(out[base..]) != e.crc { bad = 2; }
    if bad > 0 {
        out.resize(base);
        PK_ERR.clear();
        if bad == 1 { PK_ERR.append("corrupt(\"size of "); } else { PK_ERR.append("checksumMismatch(\""); }
        pk_name(ei, PK_ERR);
        PK_ERR.append("\")");
        return false;
    }
    return true;
}

// MARK: Project import

// Asset files of the last import: path and ZIP entry, by index.
struct PkFile { po: i64, pn: i64, ei: i64, data: i64 }

var PK_FS: PkFile[>..] = [];
var PK_FP: u8[>..] = [];

// The last path component and its extension (empty when none).
fn pk_last(s: u8[:]) -> u8[:] {
    var i = s.len;
    while i > 0 && s[i - 1] != '/' { i--; }
    return s[i..];
}

fn pk_ext(s: u8[:]) -> u8[:] {
    let c = pk_last(s);
    var i = c.len;
    while i > 0 && c[i - 1] != '.' { i--; }
    if i <= 1 { return c[c.len..]; }
    return c[i..];
}

fn pack_allowed_ext(e: u8[:]) -> bool {
    eq_nocase(e, "png") || eq_nocase(e, "jpg") || eq_nocase(e, "jpeg") || eq_nocase(e, "gif") ||
    eq_nocase(e, "webp") || eq_nocase(e, "heic") || eq_nocase(e, "svg") || eq_nocase(e, "pdf") ||
    eq_nocase(e, "mp4") || eq_nocase(e, "mov") || eq_nocase(e, "m4v") || eq_nocase(e, "webm") ||
    eq_nocase(e, "mp3") || eq_nocase(e, "m4a") || eq_nocase(e, "aac") || eq_nocase(e, "wav") ||
    eq_nocase(e, "caf")
}

fn pk_usable(ei: i64) -> bool {
    var name: u8[>..] = [];
    pk_name(ei, name);
    if has_suffix(name, "/") || has_prefix(name, "__MACOSX/") { return false; }
    let last = pk_last(name);
    return !(last.len > 0 && last[0] == '.');
}

fn pk_is_md(ei: i64) -> bool {
    var name: u8[>..] = [];
    pk_name(ei, name);
    let e = pk_ext(name);
    return eq_nocase(e, "md") || eq_nocase(e, "markdown");
}

fn pk_find(path: u8[:]) -> i64 {
    for i in PK_FS.len {
        let f = PK_FS[i];
        if PK_FP[f.po..f.po + f.pn] == path { return i; }
    }
    return -1;
}

// Finds the bytes of entry ei for asset `path`, as `assets[path] = data`.
// Returns false (with PK_ERR) when the entry cannot be read.
fn pk_locate(z: u8[:], ei: i64, path: u8[:]) -> bool {
    let e = PK_ENTS[ei];
    let p = e.local;
    if p + 30 > z.len || pk_u32(z, p) != 0x04034B50 { return pk_fail("corrupt(\"local header\")"); }
    let start = p + 30 + pk_u16(z, p + 26) + pk_u16(z, p + 28);
    if start + e.csize > z.len { return pk_fail("corrupt(\"entry size\")"); }
    if e.method != 0 && e.method != 8 {
        PK_ERR.clear();
        format(PK_ERR, "unsupportedMethod(", e.method, ")");
        return false;
    }
    let old = pk_find(path);
    if old >= 0 {
        PK_FS[old].ei = ei;
        PK_FS[old].data = start;
    } else {
        let po = PK_FP.len;
        PK_FP.append(path);
        PK_FS.push(PkFile { po: po, pn: path.len, ei: ei, data: start });
    }
    return true;
}

fn pk_error_json(out: u8[>..]&, m: u8[:]) {
    out.append("{\"error\":");
    json_str(out, m);
    out.push('}');
}

fn pk_zip_error(out: u8[>..]&) {
    var m: u8[>..] = [];
    m.append("Marklove cannot open the ZIP file: ");
    m.append(PK_ERR);
    pk_error_json(out, m);
}

fn pack_import(z: u8[:], out: u8[>..]&) {
    PK_FS.clear();
    PK_FP.clear();
    if !pk_read(z) { pk_zip_error(out); return; }
    var md = -1;
    var md_count = 0;
    for i in PK_ENTS.len {
        if pk_usable(i) && pk_is_md(i) { if md < 0 { md = i; } md_count++; }
    }
    if md < 0 {
        pk_error_json(out, "The ZIP file has no Markdown file. Add one .md file and try again.");
        return;
    }
    if md_count > 1 {
        var m: u8[>..] = [];
        m.append("The ZIP file has more than one Markdown file: ");
        var first = true;
        for i in PK_ENTS.len {
            if pk_usable(i) && pk_is_md(i) {
                if !first { m.append(", "); }
                first = false;
                pk_name(i, m);
            }
        }
        m.append(". A project has one .md file.");
        pk_error_json(out, m);
        return;
    }
    let me = PK_ENTS[md];
    if me.usize > MAX_TEXT || (me.method == 0 && me.csize > MAX_TEXT) {
        pk_error_json(out, "The Markdown file is larger than 512 KB. Split it into more projects.");
        return;
    }
    var text: u8[>..] = [];
    if !pk_contents(z, md, text) { pk_zip_error(out); return; }
    if !pk_valid_utf8(text) {
        pk_error_json(out, "Marklove cannot read the Markdown file. Save it as UTF-8 text.");
        return;
    }
    // Asset paths are relative to the folder of the Markdown file.
    var md_name: u8[>..] = [];
    pk_name(md, md_name);
    var folder: u8[>..] = [];
    var cut = md_name.len;
    while cut > 0 && md_name[cut - 1] != '/' { cut--; }
    if cut == 1 { folder.push('/'); }
    else if cut > 1 { folder.append(md_name[..cut - 1]); }
    var warnings: u8[>..] = [];
    for i in PK_ENTS.len {
        if i == md || !pk_usable(i) { continue; }
        var name: u8[>..] = [];
        pk_name(i, name);
        var w: u8[>..] = [];
        var rel_start = 0;
        if folder.len > 0 {
            if !(has_prefix(name, folder) && name.len > folder.len && name[folder.len] == '/') {
                w.append("Skipped "); w.append(name); w.append(": it is outside the project folder.");
            }
            rel_start = folder.len + 1;
        }
        var clean: u8[>..] = [];
        if w.len == 0 && !zip_clean_name(name[rel_start..], clean) {
            w.append("Skipped "); w.append(name); w.append(": the path is not safe.");
        }
        if w.len == 0 && has_prefix(clean, ".git/") {
            continue;
        }
        if w.len == 0 && !pack_allowed_ext(pk_ext(clean)) {
            w.append("Skipped "); w.append(name); w.append(": Marklove imports images, audio, and video only.");
        }
        if w.len == 0 && !pk_locate(z, i, clean) {
            w.append("Skipped "); w.append(name); w.append(": "); w.append(PK_ERR);
        }
        if w.len > 0 {
            if warnings.len > 0 { warnings.push(','); }
            json_str(warnings, w);
        }
    }
    out.append("{\"markdownName\":");
    json_str(out, pk_last(md_name));
    out.append(",\"markdown\":");
    json_str(out, text);
    out.append(",\"assets\":[");
    var first = true;
    for i in PK_FS.len {
        let f = PK_FS[i];
        let e = PK_ENTS[f.ei];
        if !first { out.push(','); }
        first = false;
        var path: u8[>..] = [];
        for k in f.po..f.po + f.pn { path.push(PK_FP[k]); }
        out.append("{\"path\":");
        json_str(out, path);
        format(out, ",\"method\":", e.method, ",\"offset\":", f.data, ",\"csize\":", e.csize, ",\"usize\":", e.usize, ",\"crc\":", e.crc, "}");
    }
    out.append("],\"warnings\":[");
    out.append(warnings);
    out.append("]}");
}

// MARK: SHA-1

fn sha1(data: u8[:], out: u8[>..]&) {
    var h: u32[5] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0];
    var m: u8[>..] = [];
    m.append(data);
    let bits = (data.len as u64) * 8;
    m.push(0x80);
    while m.len % 64 != 56 { m.push(0); }
    for i in 8 { m.push(((bits >> ((7 - i) * 8)) & 0xFF) as u8); }
    var w: u32[80] = [0; 80];
    var chunk = 0;
    while chunk < m.len {
        for i in 16 {
            let j = chunk + i * 4;
            w[i] = ((m[j] as u32) << 24) | ((m[j + 1] as u32) << 16) | ((m[j + 2] as u32) << 8) | m[j + 3];
        }
        for i in 16..80 {
            let x = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16];
            w[i] = (x << 1) | (x >> 31);
        }
        var a = h[0];
        var b = h[1];
        var c = h[2];
        var d = h[3];
        var e = h[4];
        for i in 80 {
            var f: u32 = 0;
            var k: u32 = 0;
            if i < 20 { f = (b & c) | (~b & d); k = 0x5A827999; }
            else if i < 40 { f = b ^ c ^ d; k = 0x6ED9EBA1; }
            else if i < 60 { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
            else { f = b ^ c ^ d; k = 0xCA62C1D6; }
            let t = ((a << 5) | (a >> 27)) + f + e + k + w[i];
            e = d;
            d = c;
            c = (b << 30) | (b >> 2);
            b = a;
            a = t;
        }
        h[0] += a;
        h[1] += b;
        h[2] += c;
        h[3] += d;
        h[4] += e;
        chunk += 64;
    }
    for i in 5 {
        out.push((h[i] >> 24) as u8);
        out.push((h[i] >> 16 & 0xFF) as u8);
        out.push((h[i] >> 8 & 0xFF) as u8);
        out.push((h[i] & 0xFF) as u8);
    }
}

fn sha1_hex(data: u8[:], out: u8[>..]&) {
    var dg: u8[>..] = [];
    sha1(data, dg);
    let digits = "0123456789abcdef";
    for b in dg {
        out.push(digits[(b >> 4) as i64]);
        out.push(digits[(b & 0x0F) as i64]);
    }
}
