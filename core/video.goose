// Video and audio files: the timeline of the slide pages (VideoTimeline),
// the podcast cues (SubtitleWriter.sequentialCues), and the MP4 container.
// The browser encodes the frames and the sound (WebCodecs) and keeps the
// encoded bytes. This file writes the boxes of the container around them.

import layout;
import narr;

// --- the timeline ----------------------------------------------------------

// A page state on the timeline.
struct VSeg { page: i64, step: i64, start: f64, dur: f64 }
var SEGS: VSeg[>..] = [];

// Real sentence lengths in seconds, as "sentence\tseconds" lines.
var DURATIONS: u8[>..] = [];

fn sentence_seconds(s: u8[:]) -> f64 {
    var i = 0;
    while i < DURATIONS.len {
        var e = index_of_byte(DURATIONS, '\n', i);
        if e < 0 { e = DURATIONS.len; }
        let line = DURATIONS[i..e];
        let t = index_of_byte(line, '\t');
        if t >= 0 && line[..t] == s {
            let v, ok = parse_flt(line[t + 1..]);
            if ok { return v; }
        }
        i = e + 1;
    }
    return estimated_seconds(s);
}

// VideoTimeline.make: the output pages in order. The narration sentences of
// a frame are shared out across the steps of its pages.
fn page_timeline() {
    SEGS.clear();
    CUES.clear();
    var frames: i64[>..] = [];
    for p in OUT0..PAGES.len {
        let f = PAGES[p].frame;
        var seen = false;
        for g in frames { if g == f { seen = true; } }
        if !seen { frames.push(f); }
    }
    var t = 0.0;
    for f in frames {
        var total = 0;
        for p in OUT0..PAGES.len { if PAGES[p].frame == f { total += max(1, PAGES[p].steps); } }
        var sents: Span[>..] = [];
        if f >= 0 { for g in NSEG { if g.frame == f { for k in g.sent_lo..g.sent_hi { sents.push(NSENT[k]); } } } }
        var bucket: i64[>..] = [];
        for k in sents.len { bucket.push(max(0, min(total - 1, k * total / max(sents.len, 1)))); }
        var index = 0;
        for p in OUT0..PAGES.len {
            if PAGES[p].frame != f { continue; }
            for step in max(1, PAGES[p].steps) {
                var speech = 0.0;
                var any = false;
                for k in sents.len { if bucket[k] == index { any = true; speech += sentence_seconds(sp_text(sents[k])) + SENTENCE_GAP; } }
                let d = if any { max(MIN_STEP, speech + 0.6) } else { SILENT_STEP };
                var ct = t + 0.3;
                for k in sents.len {
                    if bucket[k] != index { continue; }
                    let sd = sentence_seconds(sp_text(sents[k]));
                    CUES.push(Cue { ct, ct + sd, sents[k] });
                    ct += sd + SENTENCE_GAP;
                }
                SEGS.push(VSeg { p, step, t, d });
                t += d;
                index++;
            }
        }
    }
}

// The podcast has no slides: the sentences follow each other.
fn sequential_cues() {
    CUES.clear();
    var t = 0.3;
    var last = -1;
    for g in NSEG {
        for k in g.sent_lo..g.sent_hi {
            if last >= 0 && last != g.frame { t += 0.9 - SENTENCE_GAP; }
            let d = sentence_seconds(sp_text(NSENT[k]));
            CUES.push(Cue { t, t + d, NSENT[k] });
            t += d + SENTENCE_GAP;
            last = g.frame;
        }
    }
}

fn timeline_json(out: u8[>..]&) {
    out.append("{\"voice\":");
    json_str(out, meta("voice"));
    out.append(",\"segments\":[");
    for s, i in SEGS {
        if i > 0 { out.push(','); }
        format(out, "{\"page\":", s.page - OUT0, ",\"step\":", s.step, ",\"start\":");
        fmt_fixed(out, s.start, 4);
        out.append(",\"duration\":");
        fmt_fixed(out, s.dur, 4);
        out.push('}');
    }
    out.append("],\"cues\":[");
    for c, i in CUES {
        if i > 0 { out.push(','); }
        out.append("{\"start\":");
        fmt_fixed(out, c.start, 4);
        out.append(",\"end\":");
        fmt_fixed(out, c.end, 4);
        out.append(",\"text\":");
        json_str(out, sp_text(c.text));
        out.push('}');
    }
    out.append("]}");
}

// --- MP4 ---------------------------------------------------------------------

// A track: the samples are in the media data in order. sizes and durs are
// 32-bit little-endian numbers, one for each sample.
struct Track { sizes: const u8[:], durs: const u8[:], keys: const u8[:], config: const u8[:], scale: i64 }

fn u32_le(b: u8[:], i: i64) -> i64 {
    (b[i * 4] as i64) | ((b[i * 4 + 1] as i64) << 8) | ((b[i * 4 + 2] as i64) << 16) | ((b[i * 4 + 3] as i64) << 24)
}

fn be(out: u8[>..]&, v: i64, n: i64) {
    var k = n - 1;
    while k >= 0 { out.push(((v >> (k * 8)) & 255) as u8); k--; }
}

// Opens a box; mp4_close writes its size.
fn mp4_open(out: u8[>..]&, kind: const u8[:]) -> i64 {
    let at = out.len;
    be(out, 0, 4);
    out.append(kind);
    return at;
}

fn mp4_close(out: u8[>..]&, at: i64) {
    let n = out.len - at;
    for k in 4 { out[at + k] = ((n >> ((3 - k) * 8)) & 255) as u8; }
}

fn full(out: u8[>..]&, kind: const u8[:], version: i64, flags: i64) -> i64 {
    let at = mp4_open(out, kind);
    be(out, version, 1);
    be(out, flags, 3);
    return at;
}

fn matrix(out: u8[>..]&) {
    for v in [0x10000, 0, 0, 0, 0x10000, 0, 0, 0, 0x40000000] { be(out, v, 4); }
}

fn samples(t: Track) -> i64 { t.sizes.len / 4 }

fn media_duration(t: Track) -> i64 {
    var d = 0;
    for i in samples(t) { d += u32_le(t.durs, i); }
    return d;
}

fn stbl(out: u8[>..]&, t: Track, offset: i64) {
    let n = samples(t);
    // Time to sample: runs of equal durations.
    var a = full(out, "stts", 0, 0);
    let count_at = out.len;
    be(out, 0, 4);
    var runs = 0;
    var i = 0;
    while i < n {
        let d = u32_le(t.durs, i);
        var j = i;
        while j < n && u32_le(t.durs, j) == d { j++; }
        be(out, j - i, 4);
        be(out, d, 4);
        runs++;
        i = j;
    }
    for k in 4 { out[count_at + k] = ((runs >> ((3 - k) * 8)) & 255) as u8; }
    mp4_close(out, a);
    // Sync samples, when not all samples are key frames.
    if t.keys.len == n {
        var all = true;
        for k in t.keys { if k == 0 { all = false; } }
        if !all {
            a = full(out, "stss", 0, 0);
            var keys = 0;
            for k in t.keys { if k != 0 { keys++; } }
            be(out, keys, 4);
            for k, s in t.keys { if k != 0 { be(out, s + 1, 4); } }
            mp4_close(out, a);
        }
    }
    // One chunk with all the samples.
    a = full(out, "stsc", 0, 0);
    be(out, 1, 4);
    be(out, 1, 4);
    be(out, n, 4);
    be(out, 1, 4);
    mp4_close(out, a);
    a = full(out, "stsz", 0, 0);
    be(out, 0, 4);
    be(out, n, 4);
    for s in n { be(out, u32_le(t.sizes, s), 4); }
    mp4_close(out, a);
    if offset > 0xFFFFFFFF {
        a = full(out, "co64", 0, 0);
        be(out, 1, 4);
        be(out, offset, 8);
    } else {
        a = full(out, "stco", 0, 0);
        be(out, 1, 4);
        be(out, offset, 4);
    }
    mp4_close(out, a);
}

// The audio decoder configuration: an MPEG-4 ES descriptor.
fn esds(out: u8[>..]&, config: u8[:]) {
    let a = full(out, "esds", 0, 0);
    fn desc(tag: i64, n: i64) {
        be(out, tag, 1);
        // Four bytes of length, as many writers do.
        be(out, 0x80 | ((n >> 21) & 127), 1);
        be(out, 0x80 | ((n >> 14) & 127), 1);
        be(out, 0x80 | ((n >> 7) & 127), 1);
        be(out, n & 127, 1);
    }
    let dsi = 5 + config.len;
    let dcd = 13 + dsi;
    desc(3, 3 + 5 + dcd + 5 + 1);
    be(out, 1, 2);
    be(out, 0, 1);
    desc(4, dcd);
    be(out, 0x40, 1);
    be(out, 0x15, 1);
    be(out, 0, 3);
    be(out, 64000, 4);
    be(out, 64000, 4);
    desc(5, config.len);
    out.append(config);
    desc(6, 1);
    be(out, 2, 1);
    mp4_close(out, a);
}

// The Opus decoder configuration (dOps), from the OpusHead of the encoder.
fn dops(out: u8[>..]&, head: u8[:], channels: i64, rate: i64) {
    let a = mp4_open(out, "dOps");
    be(out, 0, 1);
    if head.len >= 19 && head[..8] == "OpusHead" {
        be(out, head[9] as i64, 1);
        be(out, (head[10] as i64) | ((head[11] as i64) << 8), 2);
        be(out, (head[12] as i64) | ((head[13] as i64) << 8) | ((head[14] as i64) << 16) | ((head[15] as i64) << 24), 4);
        be(out, (head[16] as i64) | ((head[17] as i64) << 8), 2);
        be(out, head[18] as i64, 1);
    } else {
        be(out, channels, 1);
        be(out, 312, 2);
        be(out, rate, 4);
        be(out, 0, 2);
        be(out, 0, 1);
    }
    mp4_close(out, a);
}

let A_NONE = 0;
let A_AAC = 1;
let A_OPUS = 2;

fn trak(out: u8[>..]&, id: i64, t: Track, video: bool, w: i64, h: i64, codec: i64, rate: i64, channels: i64, offset: i64) {
    let tr = mp4_open(out, "trak");
    let dur = media_duration(t);
    let movie_dur = dur * 1000 / max(t.scale, 1);
    var a = full(out, "tkhd", 0, 3);
    be(out, 0, 4);
    be(out, 0, 4);
    be(out, id, 4);
    be(out, 0, 4);
    be(out, movie_dur, 4);
    be(out, 0, 8);
    be(out, 0, 2);
    be(out, 0, 2);
    be(out, if video { 0 } else { 0x100 }, 2);
    be(out, 0, 2);
    matrix(out);
    be(out, if video { w << 16 } else { 0 }, 4);
    be(out, if video { h << 16 } else { 0 }, 4);
    mp4_close(out, a);
    let mdia = mp4_open(out, "mdia");
    a = full(out, "mdhd", 0, 0);
    be(out, 0, 4);
    be(out, 0, 4);
    be(out, t.scale, 4);
    be(out, dur, 4);
    be(out, 0x55C4, 2);
    be(out, 0, 2);
    mp4_close(out, a);
    a = full(out, "hdlr", 0, 0);
    be(out, 0, 4);
    out.append(if video { "vide" } else { "soun" });
    be(out, 0, 12);
    out.append(if video { "VideoHandler" } else { "SoundHandler" });
    be(out, 0, 1);
    mp4_close(out, a);
    let minf = mp4_open(out, "minf");
    if video {
        a = full(out, "vmhd", 0, 1);
        be(out, 0, 8);
    } else {
        a = full(out, "smhd", 0, 0);
        be(out, 0, 4);
    }
    mp4_close(out, a);
    let dinf = mp4_open(out, "dinf");
    a = full(out, "dref", 0, 0);
    be(out, 1, 4);
    let u = full(out, "url ", 0, 1);
    mp4_close(out, u);
    mp4_close(out, a);
    mp4_close(out, dinf);
    let st = mp4_open(out, "stbl");
    a = full(out, "stsd", 0, 0);
    be(out, 1, 4);
    if video {
        let e = mp4_open(out, "avc1");
        be(out, 0, 6);
        be(out, 1, 2);
        be(out, 0, 16);
        be(out, w, 2);
        be(out, h, 2);
        be(out, 0x00480000, 4);
        be(out, 0x00480000, 4);
        be(out, 0, 4);
        be(out, 1, 2);
        be(out, 0, 32);
        be(out, 0x18, 2);
        be(out, 0xFFFF, 2);
        let c = mp4_open(out, "avcC");
        out.append(t.config);
        mp4_close(out, c);
        mp4_close(out, e);
    } else {
        let e = mp4_open(out, if codec == A_OPUS { "Opus" } else { "mp4a" });
        be(out, 0, 6);
        be(out, 1, 2);
        be(out, 0, 8);
        be(out, channels, 2);
        be(out, 16, 2);
        be(out, 0, 4);
        be(out, min(rate, 65535) << 16, 4);
        if codec == A_OPUS { dops(out, t.config, channels, rate); } else { esds(out, t.config); }
        mp4_close(out, e);
    }
    mp4_close(out, a);
    stbl(out, t, offset);
    mp4_close(out, st);
    mp4_close(out, minf);
    mp4_close(out, mdia);
    mp4_close(out, tr);
}

fn sum_sizes(t: Track) -> i64 {
    var n = 0;
    for i in samples(t) { n += u32_le(t.sizes, i); }
    return n;
}

// The start of an MP4 file: ftyp, moov and the media data header. The
// video samples follow it, then the audio samples.
fn mp4_head(dst: u8[>..]&, v: Track, a: Track, w: i64, h: i64, codec: i64, rate: i64, channels: i64) {
    let has_video = samples(v) > 0;
    let has_audio = codec != A_NONE && samples(a) > 0;
    let data = sum_sizes(v) + sum_sizes(a);
    let large = data + 16 > 0xFFFFFFFF;
    // The moov box does not change size with the offsets, except for co64:
    // write it once to learn its size, then again.
    var out: u8[>..] = [];
    for pass in 2 {
        out.clear();
        let start = out.len;
        let f = mp4_open(out, "ftyp");
        out.append(if has_video { "isom" } else { "M4A " });
        be(out, 0x200, 4);
        out.append("isomiso2mp41");
        if has_video { out.append("avc1"); } else { out.append("M4A "); }
        mp4_close(out, f);
        let head = out.len - start;
        let moov_at = out.len;
        let m = mp4_open(out, "moov");
        let hd = full(out, "mvhd", 0, 0);
        be(out, 0, 4);
        be(out, 0, 4);
        be(out, 1000, 4);
        var dur = 0;
        if has_video { dur = max(dur, media_duration(v) * 1000 / max(v.scale, 1)); }
        if has_audio { dur = max(dur, media_duration(a) * 1000 / max(a.scale, 1)); }
        be(out, dur, 4);
        be(out, 0x10000, 4);
        be(out, 0x100, 2);
        be(out, 0, 10);
        matrix(out);
        be(out, 0, 24);
        be(out, 3, 4);
        mp4_close(out, hd);
        // The size of the moov box is known in the second pass.
        let moov_size = if pass == 0 { 0 } else { MOOV_SIZE };
        let data_at = head + moov_size + (if large { 16 } else { 8 });
        var id = 1;
        if has_video { trak(out, id, v, true, w, h, codec, rate, channels, data_at); id++; }
        if has_audio { trak(out, id, a, false, w, h, codec, rate, channels, data_at + sum_sizes(v)); }
        mp4_close(out, m);
        MOOV_SIZE = out.len - moov_at;
    }
    if large {
        be(out, 1, 4);
        out.append("mdat");
        be(out, data + 16, 8);
    } else {
        be(out, data + 8, 4);
        out.append("mdat");
    }
    dst.append(out);
}

var MOOV_SIZE = 0;
