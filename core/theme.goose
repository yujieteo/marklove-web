// Themes, as the app's Theme.swift and ThemeCatalog.swift, and the theme CSS
// of HTMLExporter.themeCSS (the presentation and the article pages).
//
// Public functions. `theme` and `accent` are front matter values; "" is absent.
//   theme_list(out)
//       JSON array, in picker order:
//       [{"id","name","credit","darkOnly":bool,"light":PALETTE,"dark":PALETTE}]
//       PALETTE = {"name","isDark","background","surface","border","dim","text",
//                  "strong","accent","red","green","yellow","blue","magenta",
//                  "cyan","orange","violet","series":[6 hex]}. Colors are "#RRGGBB".
//   theme_resolve(out, theme, accent)
//       JSON {"id","name","darkOnly":bool,"prefersDark":true|false|null}.
//       An export uses dark = (user choice) ?? prefersDark ?? false, and writes
//       data-theme="dark" on <html> for a dark-only theme.
//   theme_css(out, theme, accent)
//       The CSS text of HTMLExporter.themeCSS for the resolved theme with the accent.
//   theme_palette(out, theme, accent, dark: i64, more_contrast: i64)
//       PALETTE (above) for one appearance, plus "roles": {role: hex} with the
//       editor color of each highlight role (see highlight.goose).
//       more_contrast = 1 gives the Increase Contrast palette (7:1).
//   theme_typography(out)
//       JSON of Typography (font names per surface) and the editor text style.

import base;

struct TC { r: f64, g: f64, b: f64 }

struct TPal {
    name: const u8[:],
    is_dark: bool,
    bg: TC, surface: TC, border: TC, dim: TC, text: TC, strong: TC, accent: TC,
    red: TC, green: TC, yellow: TC, blue: TC, magenta: TC, cyan: TC, orange: TC, violet: TC,
}

struct Theme {
    id: const u8[:],
    name: const u8[:],
    credit: const u8[:],
    dark_only: bool,
    light: TPal,
    dark: TPal,
}

// The built-in themes, made on first use.
var TH: Theme[>..] = [];

// --- colors -------------------------------------------------------------

fn th_hexval(c: u8) -> i64 {
    if c >= '0' && c <= '9' { return c - '0'; }
    if c >= 'a' && c <= 'f' { return c - 'a' + 10; }
    if c >= 'A' && c <= 'F' { return c - 'A' + 10; }
    return -1;
}

// `#RRGGBB` or `RRGGBB`. Returns false for other text.
fn th_parse_hex(s0: u8[:]) -> TC, bool {
    var s = trim_sp(s0);
    if s.len > 0 && s[0] == '#' { s = s[1..]; }
    if s.len != 6 { return TC { 0.0, 0.0, 0.0 }, false; }
    var v: i64[..6] = [];
    for c in s {
        let d = th_hexval(c);
        if d < 0 { return TC { 0.0, 0.0, 0.0 }, false; }
        v.push(d);
    }
    return TC { (v[0] * 16 + v[1]) / 255.0, (v[2] * 16 + v[3]) / 255.0, (v[4] * 16 + v[5]) / 255.0 }, true;
}

fn th_c(s: u8[:]) -> TC {
    let c, ok = th_parse_hex(s);
    return c;
}

fn th_byte(x: f64) -> i64 { round(x * 255.0) as i64 }

fn th_hex(out: u8[>..]&, c: TC) {
    let D = "0123456789ABCDEF";
    out.push('#');
    for v in [th_byte(c.r), th_byte(c.g), th_byte(c.b)] {
        let x = min(255, max(0, v));
        out.push(D[x / 16]);
        out.push(D[x % 16]);
    }
}

fn th_lin(c: f64) -> f64 { if c <= 0.04045 { c / 12.92 } else { pow((c + 0.055) / 1.055, 2.4) } }
fn th_gamma(c: f64) -> f64 { if c <= 0.0031308 { 12.92 * c } else { 1.055 * pow(c, 1.0 / 2.4) - 0.055 } }

fn th_cbrt(x: f64) -> f64 {
    if x == 0.0 { return 0.0; }
    let a = abs(x);
    var y = pow(a, 1.0 / 3.0);
    y = y - (y * y * y - a) / (3.0 * y * y);
    return if x < 0.0 { -y } else { y };
}

fn th_lum(c: TC) -> f64 { 0.2126 * th_lin(c.r) + 0.7152 * th_lin(c.g) + 0.0722 * th_lin(c.b) }

fn th_contrast(a: TC, b: TC) -> f64 {
    let x = th_lum(a) + 0.05;
    let y = th_lum(b) + 0.05;
    return max(x, y) / min(x, y);
}

fn th_mix(a: TC, b: TC, t: f64) -> TC {
    TC { a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t }
}

fn th_oklab(c: TC) -> f64, f64, f64 {
    let r = th_lin(c.r);
    let g = th_lin(c.g);
    let b = th_lin(c.b);
    let l = th_cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b);
    let m = th_cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b);
    let s = th_cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b);
    return 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
           1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
           0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s;
}

fn th_clamp01(x: f64) -> f64 { min(1.0, max(0.0, x)) }
fn th_out(x: f64) -> f64 { th_clamp01(th_gamma(th_clamp01(x))) }

// A color from OKLab. Chroma falls until the color is inside sRGB.
fn th_from_oklab(l: f64, a0: f64, b0: f64) -> TC {
    var a = a0;
    var b = b0;
    for k in 60 {
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b;
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b;
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b;
        let L = l_ * l_ * l_;
        let M = m_ * m_ * m_;
        let S = s_ * s_ * s_;
        let r = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S;
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S;
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S;
        if r >= -0.0005 && r <= 1.0005 && g >= -0.0005 && g <= 1.0005 && bl >= -0.0005 && bl <= 1.0005 {
            return TC { th_out(r), th_out(g), th_out(bl) };
        }
        a *= 0.92;
        b *= 0.92;
    }
    let v = th_out(l * l * l);
    return TC { v, v, v };
}

fn th_worst(c: TC, bg: TC, surface: TC) -> f64 { min(th_contrast(c, bg), th_contrast(c, surface)) }

// The nearest color with the same hue that has at least `target` contrast
// with the background and the surface.
fn th_with_contrast(c: TC, target: f64, bg: TC, surface: TC) -> TC {
    if th_worst(c, bg, surface) >= target { return c; }
    let lighten = th_lum(bg) < 0.18;
    let L, A, B = th_oklab(c);
    var l = L;
    for k in 220 {
        l += if lighten { 0.004 } else { -0.004 };
        if l <= 0.0 || l >= 1.0 { break; }
        let x = th_from_oklab(l, A, B);
        if th_worst(x, bg, surface) >= target { return x; }
    }
    return if lighten { TC { 1.0, 1.0, 1.0 } } else { TC { 0.0, 0.0, 0.0 } };
}

// Every text role at `minimum` contrast or more. Hues stay the same.
fn th_accessible(p: TPal, minimum: f64) -> TPal {
    var q = p;
    let t = max(minimum, 4.5);
    q.text = th_with_contrast(p.text, t, p.bg, p.surface);
    q.strong = th_with_contrast(p.strong, t, p.bg, p.surface);
    q.dim = th_with_contrast(p.dim, minimum, p.bg, p.surface);
    q.accent = th_with_contrast(p.accent, minimum, p.bg, p.surface);
    q.red = th_with_contrast(p.red, minimum, p.bg, p.surface);
    q.green = th_with_contrast(p.green, minimum, p.bg, p.surface);
    q.yellow = th_with_contrast(p.yellow, minimum, p.bg, p.surface);
    q.blue = th_with_contrast(p.blue, minimum, p.bg, p.surface);
    q.magenta = th_with_contrast(p.magenta, minimum, p.bg, p.surface);
    q.cyan = th_with_contrast(p.cyan, minimum, p.bg, p.surface);
    q.orange = th_with_contrast(p.orange, minimum, p.bg, p.surface);
    q.violet = th_with_contrast(p.violet, minimum, p.bg, p.surface);
    return q;
}

// Increase Contrast: text at 7:1 or more, and stronger borders.
fn th_increased(p: TPal) -> TPal {
    var q = th_accessible(p, 7.0);
    q.border = th_mix(p.border, q.dim, 0.6);
    return q;
}

// --- the catalog --------------------------------------------------------

fn th_pal(name: const u8[:], dark: bool, bg: u8[:], surface: u8[:], border: u8[:], dim: u8[:],
          text: u8[:], strong: u8[:], accent: u8[:], red: u8[:], green: u8[:], yellow: u8[:],
          blue: u8[:], magenta: u8[:], cyan: u8[:], orange: u8[:], violet: u8[:]) -> TPal {
    TPal { name: name, is_dark: dark, bg: th_c(bg), surface: th_c(surface), border: th_c(border), dim: th_c(dim),
           text: th_c(text), strong: th_c(strong), accent: th_c(accent), red: th_c(red), green: th_c(green),
           yellow: th_c(yellow), blue: th_c(blue), magenta: th_c(magenta), cyan: th_c(cyan),
           orange: th_c(orange), violet: th_c(violet) }
}

// Adds a theme with light and dark palettes, made accessible (4.5:1).
fn th_add(id: const u8[:], name: const u8[:], credit: const u8[:], light: TPal, dark: TPal) {
    TH.push(Theme { id: id, name: name, credit: credit, dark_only: false,
                    light: th_accessible(light, 4.5), dark: th_accessible(dark, 4.5) });
}

// Adds a dark-only theme. Both appearances use the dark palette.
fn th_add_dark(id: const u8[:], name: const u8[:], credit: const u8[:], dark: TPal) {
    let d = th_accessible(dark, 4.5);
    TH.push(Theme { id: id, name: name, credit: credit, dark_only: true, light: d, dark: d });
}

fn th_init() {
    if TH.len > 0 { return; }
    th_add("selenized", "Selenized", "Selenized by Jan Warchoł",
        th_pal("Selenized Light", false, "#FBF3DB", "#ECE3CC", "#D5CDB6", "#909995", "#53676D", "#3A4D53", "#0072D4",
               "#D2212D", "#489100", "#AD8900", "#0072D4", "#CA4898", "#009C8F", "#C25D1E", "#8762C6"),
        th_pal("Selenized Dark", true, "#103C48", "#184956", "#2D5B69", "#72898F", "#ADBCBC", "#CAD8D9", "#4695F7",
               "#FA5750", "#75B938", "#DBB32D", "#4695F7", "#F275BE", "#41C7B9", "#ED8649", "#AF88EB"));
    let latte = th_pal("Catppuccin Latte", false, "#EFF1F5", "#E6E9EF", "#CCD0DA", "#6C6F85", "#4C4F69", "#4C4F69", "#8839EF",
        "#D20F39", "#40A02B", "#DF8E1D", "#1E66F5", "#EA76CB", "#179299", "#FE640B", "#7287FD");
    th_add("catppuccin", "Catppuccin", "Catppuccin Latte and Mocha", latte,
        th_pal("Catppuccin Mocha", true, "#1E1E2E", "#181825", "#45475A", "#A6ADC8", "#CDD6F4", "#CDD6F4", "#CBA6F7",
               "#F38BA8", "#A6E3A1", "#F9E2AF", "#89B4FA", "#F5C2E7", "#94E2D5", "#FAB387", "#B4BEFE"));
    th_add("catppuccin-frappe", "Catppuccin Frappé", "Catppuccin Latte and Frappé", latte,
        th_pal("Catppuccin Frappé", true, "#303446", "#292C3C", "#51576D", "#A5ADCE", "#C6D0F5", "#C6D0F5", "#CA9EE6",
               "#E78284", "#A6D189", "#E5C890", "#8CAAEE", "#F4B8E4", "#81C8BE", "#EF9F76", "#BABBF1"));
    th_add("catppuccin-macchiato", "Catppuccin Macchiato", "Catppuccin Latte and Macchiato", latte,
        th_pal("Catppuccin Macchiato", true, "#24273A", "#1E2030", "#494D64", "#A5ADCB", "#CAD3F5", "#CAD3F5", "#C6A0F6",
               "#ED8796", "#A6DA95", "#EED49F", "#8AADF4", "#F5BDE6", "#8BD5CA", "#F5A97F", "#B7BDF8"));
    th_add("everforest", "Everforest", "Everforest by sainnhe",
        th_pal("Everforest Light", false, "#FDF6E3", "#F4F0D9", "#E0DCC7", "#829181", "#5C6A72", "#4F5B62", "#93B259",
               "#F85552", "#8DA101", "#DFA000", "#3A94C5", "#DF69BA", "#35A77C", "#F57D26", "#DF69BA"),
        th_pal("Everforest Dark", true, "#2D353B", "#343F44", "#475258", "#9DA9A0", "#D3C6AA", "#E2D7BD", "#A7C080",
               "#E67E80", "#A7C080", "#DBBC7F", "#7FBBB3", "#D699B6", "#83C092", "#E69875", "#D699B6"));
    th_add("gruvbox", "Gruvbox", "Gruvbox by Pavel Pertsev",
        th_pal("Gruvbox Light", false, "#FBF1C7", "#EBDBB2", "#D5C4A1", "#7C6F64", "#3C3836", "#282828", "#B57614",
               "#9D0006", "#79740E", "#B57614", "#076678", "#8F3F71", "#427B58", "#AF3A03", "#8F3F71"),
        th_pal("Gruvbox Dark", true, "#282828", "#3C3836", "#504945", "#A89984", "#EBDBB2", "#FBF1C7", "#FABD2F",
               "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#FE8019", "#D3869B"));
    th_add("solarized", "Solarized", "Solarized by Ethan Schoonover",
        th_pal("Solarized Light", false, "#FDF6E3", "#EEE8D5", "#DDD6C1", "#93A1A1", "#657B83", "#586E75", "#268BD2",
               "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#CB4B16", "#6C71C4"),
        th_pal("Solarized Dark", true, "#002B36", "#073642", "#0B4452", "#586E75", "#839496", "#93A1A1", "#268BD2",
               "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#CB4B16", "#6C71C4"));
    th_add("github", "GitHub", "GitHub Primer colors",
        th_pal("GitHub Light", false, "#FFFFFF", "#F6F8FA", "#D0D7DE", "#59636E", "#1F2328", "#1F2328", "#0969DA",
               "#CF222E", "#1A7F37", "#9A6700", "#0969DA", "#BF3989", "#1B7C83", "#BC4C00", "#8250DF"),
        th_pal("GitHub Dark", true, "#0D1117", "#161B22", "#30363D", "#9198A1", "#E6EDF3", "#F0F6FC", "#4493F8",
               "#F85149", "#3FB950", "#D29922", "#4493F8", "#DB61A2", "#39C5CF", "#DB6D28", "#AB7DF8"));
    let day = th_pal("Tokyo Night Day", false, "#E1E2E7", "#D0D5E3", "#C4C8DA", "#6172B0", "#3760BF", "#2E4F9E", "#2E7DE9",
        "#F52A65", "#587539", "#8C6C3E", "#2E7DE9", "#9854F1", "#007197", "#B15C00", "#7847BD");
    th_add("tokyo-night", "Tokyo Night", "Tokyo Night by enkia", day,
        th_pal("Tokyo Night", true, "#1A1B26", "#16161E", "#292E42", "#737AA2", "#C0CAF5", "#C0CAF5", "#7AA2F7",
               "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#FF9E64", "#9D7CD8"));
    th_add("tokyo-night-storm", "Tokyo Night Storm", "Tokyo Night by enkia", day,
        th_pal("Tokyo Night Storm", true, "#24283B", "#1F2335", "#3B4261", "#737AA2", "#C0CAF5", "#C0CAF5", "#7AA2F7",
               "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#FF9E64", "#9D7CD8"));
    let dawn = th_pal("Rosé Pine Dawn", false, "#FAF4ED", "#F2E9E1", "#DFDAD9", "#797593", "#575279", "#464261", "#D7827E",
        "#B4637A", "#286983", "#EA9D34", "#286983", "#B4637A", "#56949F", "#EA9D34", "#907AA9");
    th_add("rose-pine", "Rosé Pine", "Rosé Pine", dawn,
        th_pal("Rosé Pine", true, "#191724", "#1F1D2E", "#403D52", "#908CAA", "#E0DEF4", "#E0DEF4", "#EBBCBA",
               "#EB6F92", "#31748F", "#F6C177", "#31748F", "#EB6F92", "#9CCFD8", "#F6C177", "#C4A7E7"));
    th_add("rose-pine-moon", "Rosé Pine Moon", "Rosé Pine", dawn,
        th_pal("Rosé Pine Moon", true, "#232136", "#2A273F", "#44415A", "#908CAA", "#E0DEF4", "#E0DEF4", "#EA9A97",
               "#EB6F92", "#3E8FB0", "#F6C177", "#3E8FB0", "#EB6F92", "#9CCFD8", "#F6C177", "#C4A7E7"));
    let ayu_light = th_pal("Ayu Light", false, "#FCFCFC", "#F3F4F5", "#E1E2E4", "#8A9199", "#5C6166", "#41464C", "#FFAA33",
        "#F07171", "#86B300", "#F2AE49", "#399EE6", "#A37ACC", "#4CBF99", "#FA8D3E", "#A37ACC");
    th_add("ayu", "Ayu", "Ayu by dempfi", ayu_light,
        th_pal("Ayu Dark", true, "#0D1017", "#131721", "#1E222A", "#6C7380", "#BFBDB6", "#E6E1CF", "#E6B450",
               "#F07178", "#AAD94C", "#FFB454", "#59C2FF", "#D2A6FF", "#95E6CB", "#FF8F40", "#D2A6FF"));
    th_add("ayu-mirage", "Ayu Mirage", "Ayu by dempfi", ayu_light,
        th_pal("Ayu Mirage", true, "#1F2430", "#242936", "#343B4C", "#707A8C", "#CCCAC2", "#E6E1CF", "#FFCC66",
               "#F28779", "#D5FF80", "#FFD173", "#73D0FF", "#DFBFFF", "#95E6CB", "#FFAD66", "#DFBFFF"));
    th_add("one", "One", "Atom One",
        th_pal("One Light", false, "#FAFAFA", "#F0F0F1", "#E5E5E6", "#A0A1A7", "#383A42", "#232324", "#4078F2",
               "#E45649", "#50A14F", "#C18401", "#4078F2", "#A626A4", "#0184BC", "#986801", "#A626A4"),
        th_pal("One Dark", true, "#282C34", "#21252B", "#3E4451", "#7F848E", "#ABB2BF", "#D7DAE0", "#61AFEF",
               "#E06C75", "#98C379", "#E5C07B", "#61AFEF", "#C678DD", "#56B6C2", "#D19A66", "#C678DD"));
    th_add("dracula", "Dracula", "Dracula and Alucard by Zeno Rocha",
        th_pal("Alucard", false, "#FFFBEB", "#F5F1DE", "#CFCFDE", "#6C664B", "#1F1F1F", "#1F1F1F", "#644AC9",
               "#CB3A2A", "#14710A", "#846E15", "#036A96", "#A3144D", "#036A96", "#A34D14", "#644AC9"),
        th_pal("Dracula", true, "#282A36", "#21222C", "#44475A", "#6272A4", "#F8F8F2", "#F8F8F2", "#BD93F9",
               "#FF5555", "#50FA7B", "#F1FA8C", "#8BE9FD", "#FF79C6", "#8BE9FD", "#FFB86C", "#BD93F9"));
    th_add_dark("monokai", "Monokai", "Monokai by Wimer Hazenberg",
        th_pal("Monokai", true, "#272822", "#3E3D32", "#49483E", "#75715E", "#F8F8F2", "#F8F8F2", "#66D9EF",
               "#F92672", "#A6E22E", "#E6DB74", "#66D9EF", "#AE81FF", "#66D9EF", "#FD971F", "#AE81FF"));
    th_add("night-owl", "Night Owl", "Night Owl and Light Owl by Sarah Drasner",
        th_pal("Light Owl", false, "#FBFBFB", "#F0F0F0", "#D9D9D9", "#90A7B2", "#403F53", "#403F53", "#4876D6",
               "#DE3D3B", "#08916A", "#DAAA01", "#4876D6", "#994CC3", "#0C969B", "#C96765", "#994CC3"),
        th_pal("Night Owl", true, "#011627", "#0B2942", "#1D3B53", "#637777", "#D6DEEB", "#FFFFFF", "#82AAFF",
               "#EF5350", "#ADDB67", "#ECC48D", "#82AAFF", "#C792EA", "#7FDBCA", "#F78C6C", "#C792EA"));
    th_add("nord", "Nord", "Nord by Arctic Ice Studio",
        th_pal("Nord Light", false, "#ECEFF4", "#E5E9F0", "#D8DEE9", "#6E7A91", "#3B4252", "#2E3440", "#5E81AC",
               "#BF616A", "#5E7D4A", "#9A7B2E", "#5E81AC", "#8E6A87", "#3E7D8C", "#B4643F", "#8E6A87"),
        th_pal("Nord", true, "#2E3440", "#3B4252", "#434C5E", "#8A93A6", "#D8DEE9", "#ECEFF4", "#88C0D0",
               "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#D08770", "#B48EAD"));
    th_add_dark("matrix", "Matrix", "Green on black",
        th_pal("Matrix", true, "#0D0208", "#04170A", "#003B00", "#008F11", "#00FF41", "#B6FFC6", "#00FF41",
               "#FF4B4B", "#00FF41", "#C6FF00", "#00E5A0", "#7CFFB2", "#00E5A0", "#9CFF00", "#7CFFB2"));
}

fn th_find(id: u8[:]) -> i64 {
    th_init();
    for t, i in TH { if t.id == id { return i; } }
    return -1;
}

// --- front matter -------------------------------------------------------

struct TAlias { name: const u8[:], id: const u8[:], dark: i64 }

// Front matter names of variants. dark: 1 dark, 0 light, -1 not given.
let TH_ALIASES: TAlias[] = [
    TAlias { "catppuccin-latte", "catppuccin", 0 }, TAlias { "catppuccin-mocha", "catppuccin", 1 },
    TAlias { "latte", "catppuccin", 0 }, TAlias { "mocha", "catppuccin", 1 },
    TAlias { "tokyo-night-day", "tokyo-night", 0 }, TAlias { "tokyonight", "tokyo-night", -1 },
    TAlias { "tokyonight-day", "tokyo-night", 0 }, TAlias { "tokyonight-night", "tokyo-night", 1 },
    TAlias { "tokyonight-storm", "tokyo-night-storm", 1 },
    TAlias { "rose-pine-dawn", "rose-pine", 0 }, TAlias { "rose-pine-main", "rose-pine", 1 },
    TAlias { "ayu-dark", "ayu", 1 }, TAlias { "ayu-light", "ayu", 0 },
    TAlias { "one-dark", "one", 1 }, TAlias { "one-light", "one", 0 }, TAlias { "one-dark-pro", "one", 1 },
    TAlias { "atom-one", "one", -1 }, TAlias { "one-half-dark", "one", 1 }, TAlias { "one-half-light", "one", 0 },
    TAlias { "alucard", "dracula", 0 }, TAlias { "dracula-light", "dracula", 0 },
    TAlias { "light-owl", "night-owl", 0 }, TAlias { "monokai-pro", "monokai", 1 },
    TAlias { "github-light", "github", 0 }, TAlias { "github-dark", "github", 1 },
];

// The base letter of a Latin-1 letter with a diacritic (the second byte of
// a C3 sequence), or 0 when it has no decomposition.
fn th_fold_c3(b: u8) -> u8 {
    let x = b | 0x20;   // upper case C3 80..9E to lower case C3 A0..BE
    if x >= 0xA0 && x <= 0xA5 { return 'a'; }
    if x == 0xA7 { return 'c'; }
    if x >= 0xA8 && x <= 0xAB { return 'e'; }
    if x >= 0xAC && x <= 0xAF { return 'i'; }
    if x == 0xB1 { return 'n'; }
    if x >= 0xB2 && x <= 0xB6 { return 'o'; }
    if x >= 0xB9 && x <= 0xBC { return 'u'; }
    if x == 0xBD || b == 0xBF { return 'y'; }
    return 0;
}

// Lower case, with `-` for spaces and underscores, and no accents.
fn th_normalize(out: u8[>..]&, v: u8[:]) {
    let start = out.len;
    var i = 0;
    while i < v.len {
        let c = v[i];
        if c == 0xC3 && i + 1 < v.len {
            let f = th_fold_c3(v[i + 1]);
            if f != 0 { out.push(f); }
            else {
                out.push(c);
                let b = v[i + 1];
                out.push(if b >= 0x80 && b <= 0x9E && b != 0x97 { b + 0x20 } else { b });
            }
            i += 2;
        } else if (c == 0xCC || (c == 0xCD && i + 1 < v.len && v[i + 1] <= 0xAF)) && i + 1 < v.len {
            i += 2;   // a combining diacritic, U+0300 to U+036F
        } else if c == ' ' || c == '_' {
            out.push('-');
            i++;
        } else {
            out.push(lower(c));
            i++;
        }
    }
    // Trim the white space that is left (tabs).
    var a = start;
    while a < out.len && (out[a] == '\t') { a++; }
    var b = out.len;
    while b > a && out[b - 1] == '\t' { b--; }
    if a > start {
        for k in a..b { out[start + k - a] = out[k]; }
    }
    out.resize(start + b - a);
}

// The theme index and the preferred appearance (1 dark, 0 light, -1 none).
fn th_resolve(value: u8[:]) -> i64, i64 {
    th_init();
    if value.len == 0 { return 0, -1; }
    var v: u8[>..] = [];
    th_normalize(v, value);
    for a in TH_ALIASES {
        if a.name == v {
            let t = th_find(a.id);
            return t, if TH[t].dark_only { 1 } else { a.dark };
        }
    }
    let t = th_find(v);
    if t >= 0 { return t, if TH[t].dark_only { 1 } else { -1 }; }
    if has_suffix(v, "-light") {
        let b = th_find(v[..v.len - 6]);
        if b >= 0 { return b, if TH[b].dark_only { 1 } else { 0 }; }
    }
    if has_suffix(v, "-dark") {
        let b = th_find(v[..v.len - 5]);
        if b >= 0 { return b, 1; }
    }
    // A longer name that starts with a theme id, such as `gruvbox-material`.
    var best = -1;
    for th, i in TH {
        if has_prefix(v, th.id) && (best < 0 || th.id.len > TH[best].id.len) { best = i; }
    }
    if best >= 0 {
        var dark = -1;
        if has_suffix(v, "-dark") { dark = 1; } else if has_suffix(v, "-light") { dark = 0; }
        return best, if TH[best].dark_only { 1 } else { dark };
    }
    return 0, -1;
}

// Theme.prefersDark: Nord without a variant asks for dark.
fn th_prefers_dark(value: u8[:]) -> i64 {
    let t, d = th_resolve(value);
    if value.len > 0 && TH[t].id == "nord" && d < 0 { return 1; }
    return d;
}

fn th_pick_accent(p: TPal, value: u8[:]) -> TC, bool {
    var lv: u8[..16] = [];
    if value.len <= 16 { for c in value { lv.push(lower(c)); } }
    if lv == "red" { return p.red, true; }
    if lv == "green" { return p.green, true; }
    if lv == "yellow" { return p.yellow, true; }
    if lv == "blue" { return p.blue, true; }
    if lv == "magenta" { return p.magenta, true; }
    if lv == "cyan" { return p.cyan, true; }
    if lv == "orange" { return p.orange, true; }
    if lv == "violet" { return p.violet, true; }
    let c, ok = th_parse_hex(value);
    return c, ok;
}

// The resolved theme with the accent applied (Theme.withAccent).
fn th_theme(value: u8[:], accent: u8[:]) -> Theme {
    let i, d = th_resolve(value);
    var t = TH[i];
    if accent.len > 0 {
        let a, ok = th_pick_accent(t.light, accent);
        if ok { t.light.accent = a; }
        let b, ok2 = th_pick_accent(t.dark, accent);
        if ok2 { t.dark.accent = b; }
    }
    return t;
}

fn th_palette_of(t: Theme, dark: bool) -> TPal { if dark || t.dark_only { t.dark } else { t.light } }

// --- output -------------------------------------------------------------

fn th_bool(out: u8[>..]&, b: bool) { out.append(if b { "true" } else { "false" }); }

fn th_kv(out: u8[>..]&, key: u8[:], c: TC) {
    out.append(",\"");
    out.append(key);
    out.append("\":\"");
    th_hex(out, c);
    out.push('"');
}

fn th_palette_json(out: u8[>..]&, p: TPal, roles: bool) {
    out.append("{\"name\":");
    json_str(out, p.name);
    out.append(",\"isDark\":");
    th_bool(out, p.is_dark);
    th_kv(out, "background", p.bg); th_kv(out, "surface", p.surface); th_kv(out, "border", p.border);
    th_kv(out, "dim", p.dim); th_kv(out, "text", p.text); th_kv(out, "strong", p.strong);
    th_kv(out, "accent", p.accent); th_kv(out, "red", p.red); th_kv(out, "green", p.green);
    th_kv(out, "yellow", p.yellow); th_kv(out, "blue", p.blue); th_kv(out, "magenta", p.magenta);
    th_kv(out, "cyan", p.cyan); th_kv(out, "orange", p.orange); th_kv(out, "violet", p.violet);
    out.append(",\"series\":[");
    for c, i in [p.accent, p.orange, p.green, p.magenta, p.cyan, p.violet] {
        if i > 0 { out.push(','); }
        out.push('"'); th_hex(out, c); out.push('"');
    }
    out.push(']');
    if roles {
        // ThemePalette.highlight(role) in MarkloveRender/Platform.swift.
        out.append(",\"roles\":{\"text\":\"");
        th_hex(out, p.text);
        out.push('"');
        for r in ["headingMarker", "emphasisMarker", "listMarker", "quoteMarker", "fence", "tableBar", "escape",
                  "rule", "mathDelimiter", "imageMarker", "frontMatter", "comment", "codeComment"] { th_kv(out, r, p.dim); }
        th_kv(out, "heading", p.strong); th_kv(out, "strong", p.strong);
        th_kv(out, "emphasis", p.text); th_kv(out, "codeSpan", p.text); th_kv(out, "codeText", p.text);
        th_kv(out, "math", p.magenta); th_kv(out, "link", p.blue); th_kv(out, "url", p.cyan);
        th_kv(out, "directive", p.violet); th_kv(out, "pause", p.violet); th_kv(out, "narration", p.violet);
        th_kv(out, "notes", p.orange); th_kv(out, "keyword", p.green); th_kv(out, "string", p.cyan);
        th_kv(out, "number", p.magenta); th_kv(out, "type", p.yellow); th_kv(out, "function", p.blue);
        th_kv(out, "attribute", p.orange);
        out.push('}');
    }
    out.push('}');
}

fn theme_list(out: u8[>..]&) {
    th_init();
    out.push('[');
    for t, i in TH {
        if i > 0 { out.push(','); }
        out.append("{\"id\":"); json_str(out, t.id);
        out.append(",\"name\":"); json_str(out, t.name);
        out.append(",\"credit\":"); json_str(out, t.credit);
        out.append(",\"darkOnly\":"); th_bool(out, t.dark_only);
        out.append(",\"light\":"); th_palette_json(out, t.light, false);
        out.append(",\"dark\":"); th_palette_json(out, t.dark, false);
        out.push('}');
    }
    out.push(']');
}

fn theme_resolve(out: u8[>..]&, theme: u8[:], accent: u8[:]) {
    let t = th_theme(theme, accent);
    let d = th_prefers_dark(theme);
    out.append("{\"id\":"); json_str(out, t.id);
    out.append(",\"name\":"); json_str(out, t.name);
    out.append(",\"darkOnly\":"); th_bool(out, t.dark_only);
    out.append(",\"prefersDark\":");
    out.append(if d < 0 { "null" } else if d == 1 { "true" } else { "false" });
    out.push('}');
}

fn theme_palette(out: u8[>..]&, theme: u8[:], accent: u8[:], dark: i64, more_contrast: i64) {
    let t = th_theme(theme, accent);
    let p = th_palette_of(t, dark != 0);
    th_palette_json(out, if more_contrast != 0 { th_increased(p) } else { p }, true);
}

// HTMLExporter.cssVariables.
fn th_vars(out: u8[>..]&, p: TPal) {
    fn v(name: u8[:], c: TC, last: bool) {
        out.append("--"); out.append(name); out.append(": "); th_hex(out, c);
        out.append(if last { ";" } else { "; " });
    }
    v("bg", p.bg, false); v("surface", p.surface, false); v("border", p.border, false); v("dim", p.dim, false);
    v("text", p.text, false); v("strong", p.strong, false); v("accent", p.accent, false);
    v("s1", p.accent, false); v("s2", p.orange, false); v("s3", p.green, false); v("s4", p.magenta, false);
    v("s5", p.cyan, false); v("s6", p.violet, false);
    v("kw", p.green, false); v("str", p.cyan, false); v("num", p.magenta, false); v("com", p.dim, false);
    v("type", p.yellow, false); v("fn", p.blue, true);
}

// HTMLExporter.themeCSS: the colors in light and dark, and for Increase Contrast.
fn theme_css(out: u8[>..]&, theme: u8[:], accent: u8[:]) {
    let t = th_theme(theme, accent);
    let light = th_palette_of(t, false);
    let dark = th_palette_of(t, true);
    let hc = th_increased(light);
    let hc_dark = th_increased(dark);
    out.append(":root { color-scheme: ");
    out.append(if t.dark_only { "dark" } else { "light dark" });
    out.append("; "); th_vars(out, light); out.append(" }\n");
    out.append("@media (prefers-color-scheme: dark) { :root:not([data-theme=\"light\"]) { "); th_vars(out, dark); out.append(" } }\n");
    out.append(":root[data-theme=\"dark\"] { color-scheme: dark; "); th_vars(out, dark); out.append(" }\n");
    out.append(":root[data-theme=\"light\"] { color-scheme: light; }\n");
    out.append("@media (prefers-contrast: more) {\n");
    out.append("  :root { "); th_vars(out, hc); out.append(" }\n");
    out.append("  @media (prefers-color-scheme: dark) { :root:not([data-theme=\"light\"]) { "); th_vars(out, hc_dark); out.append(" } }\n");
    out.append("  :root[data-theme=\"dark\"] { "); th_vars(out, hc_dark); out.append(" }\n");
    out.append("}");
}

// Typography (Theme.swift) and the editor text style (SourceStyle,
// EditorScreen, AppSettings in the app).
fn theme_typography(out: u8[>..]&) {
    let cp = "[\"CourierPrime-Regular\",\"Courier\"]";
    let cps = "[\"CourierPrimeSans-Regular\",\"CourierPrime-Regular\",\"Courier\"]";
    let pal = "[\"Palatino-Roman\",\"Palatino\",\"TeXGyrePagella-Regular\",\"BookAntiqua\"]";
    let bask = "[\"LibreBaskerville-Regular\",\"Baskerville\"]";
    fn face(name: u8[:], body: u8[:], code: u8[:], transcript: u8[:], last: bool) {
        out.push('"'); out.append(name); out.append("\":{\"body\":"); out.append(body);
        out.append(",\"heading\":"); out.append(body);
        out.append(",\"code\":"); out.append(code);
        out.append(",\"mathFont\":\"KpMath-Light\",\"transcript\":"); out.append(transcript);
        out.append(if last { "}" } else { "}," });
    }
    out.append("{\"typography\":{");
    face("editor", cp, cp, cp, false);
    face("article", pal, cps, pal, false);
    face("slides", bask, cps, bask, false);
    face("handout", cp, cp, cp, false);
    face("speakerReady", cp, cp, cp, false);
    face("video", pal, cps, cp, false);
    face("web", cp, cp, cp, true);
    out.append("},\"editor\":{\"font\":\"Courier Prime\",\"pointSize\":15,\"pointSizeIOS\":17,\"lineHeight\":1.4,");
    out.append("\"maxLineCharacters\":76,\"bold\":[\"heading\"],\"italic\":[\"comment\",\"codeComment\"]}}");
}
