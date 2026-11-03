
type Params = Record<string, number>;
type Curve = (x: number, p: Params) => number;
type PlotParam = { name: string; value: number };
type PlotSpec = { params: PlotParam[]; curves: string[]; x: [number, number]; y: [number, number] };

const FUNCS: Record<string, (...args: number[]) => number> = {
  sin: Math.sin, cos: Math.cos, tan: Math.tan, exp: Math.exp, log: Math.log, ln: Math.log, sqrt: Math.sqrt,
  abs: Math.abs, atan: Math.atan, asin: Math.asin, acos: Math.acos, sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh,
  min: Math.min, max: Math.max, floor: Math.floor, ceil: Math.ceil,
};
const CONSTS: Record<string, number> = { pi: Math.PI, e: Math.E };
const TOKEN_PATTERN = /\d*\.?\d+(?:e[+-]?\d+)?|[A-Za-z_]\w*|\*\*|[-+*/^(),]|\S/gi;
const CURVE_SAMPLES = 240;
const PLOT_W = 1000, PLOT_H = 520, PLOT_L = 60, PLOT_R = 20, PLOT_T = 20, PLOT_B = 40;

function compile(src: string, params: string[]): Curve {
  const toks = String(src).match(TOKEN_PATTERN) || [];
  let i = 0;
  const peek = (): string | undefined => toks[i];
  const take = (): string | undefined => toks[i++];
  function expect(t: string): void { if (take() !== t) throw new Error("expected " + t); }
  const binary = (l: Curve, r: Curve, op: (a: number, b: number) => number): Curve => (x, p) => op(l(x, p), r(x, p));
  function sum(): Curve {
    let a = prod();
    while (peek() === "+" || peek() === "-") {
      const op = take(), b = prod();
      a = op === "+" ? binary(a, b, (u, v) => u + v) : binary(a, b, (u, v) => u - v);
    }
    return a;
  }
  function prod(): Curve {
    let a = unary();
    for (;;) {
      const t = peek();
      if (t === "*" || t === "/") {
        take();
        const b = unary();
        a = t === "*" ? binary(a, b, (u, v) => u * v) : binary(a, b, (u, v) => u / v);
      } else if (t !== undefined && (t === "(" || /^[A-Za-z_\d.]/.test(t))) {
        a = binary(a, unary(), (u, v) => u * v);
      } else return a;
    }
  }
  function unary(): Curve {
    if (peek() === "-") { take(); const a = unary(); return (x, p) => -a(x, p); }
    if (peek() === "+") { take(); return unary(); }
    return pow();
  }
  function pow(): Curve {
    const a = atom();
    if (peek() === "^" || peek() === "**") { take(); const b = unary(); return binary(a, b, Math.pow); }
    return a;
  }
  function atom(): Curve {
    const t = take();
    if (t === undefined) throw new Error("end");
    if (/^\d|^\./.test(t)) { const v = parseFloat(t); return () => v; }
    if (t === "(") { const a = sum(); expect(")"); return a; }
    const n = t.toLowerCase();
    if (n === "x") return (x) => x;
    if (params.indexOf(t) >= 0) return (_x, p) => p[t] ?? NaN;
    const c = Object.prototype.hasOwnProperty.call(CONSTS, n) ? CONSTS[n] : undefined;
    if (c !== undefined) return () => c;
    const f = Object.prototype.hasOwnProperty.call(FUNCS, n) ? FUNCS[n] : undefined;
    if (f !== undefined) {
      expect("(");
      const args = [sum()];
      while (peek() === ",") { take(); args.push(sum()); }
      expect(")");
      return (x, p) => f(...args.map((g) => g(x, p)));
    }
    throw new Error("unknown " + t);
  }
  const f = sum();
  if (i < toks.length) throw new Error("unexpected " + toks[i]);
  return f;
}

function isPair(v: unknown): v is [number, number] {
  return Array.isArray(v) && v.length >= 2 && typeof v[0] === "number" && typeof v[1] === "number";
}

function parsePlotSpec(text: string | null): PlotSpec | null {
  let raw: unknown;
  try { raw = JSON.parse(text ?? ""); } catch { return null; }
  if (typeof raw !== "object" || raw === null) return null;
  const params: unknown = Reflect.get(raw, "params");
  const curves: unknown = Reflect.get(raw, "curves");
  const x: unknown = Reflect.get(raw, "x");
  const y: unknown = Reflect.get(raw, "y");
  if (!Array.isArray(params) || !Array.isArray(curves) || !isPair(x) || !isPair(y)) return null;
  const parsed: PlotParam[] = [];
  for (const p of params) {
    if (typeof p !== "object" || p === null) return null;
    const name: unknown = Reflect.get(p, "name");
    const value: unknown = Reflect.get(p, "value");
    if (typeof name !== "string" || typeof value !== "number") return null;
    parsed.push({ name, value });
  }
  const sources: string[] = [];
  for (const c of curves) {
    if (typeof c !== "string") return null;
    sources.push(c);
  }
  return { params: parsed, curves: sources, x: [x[0], x[1]], y: [y[0], y[1]] };
}

function elements<T extends Element>(root: ParentNode, selector: string, kind: abstract new (...args: never[]) => T): T[] {
  return [...root.querySelectorAll(selector)].filter((el): el is T => el instanceof kind);
}

function setupPlots(): void {
  for (const plot of elements(document, ".plot[data-plot]", Element)) {
    const spec = parsePlotSpec(plot.getAttribute("data-plot"));
    if (!spec) continue;
    const names = spec.params.map((p) => p.name);
    let curves: Curve[] = [];
    try { curves = spec.curves.map((c) => compile(c, names)); } catch { continue; }
    const paths = plot.querySelectorAll("path.curve");
    const values: Params = {};
    for (const p of spec.params) values[p.name] = p.value;
    const draw = (): void => {
      const [x0, x1] = spec.x, [y0, y1] = spec.y;
      curves.forEach((f, i) => {
        let d = "", pen = false;
        for (let k = 0; k <= CURVE_SAMPLES; k++) {
          const x = x0 + (x1 - x0) * k / CURVE_SAMPLES;
          let y = f(x, values);
          if (!isFinite(y)) { pen = false; continue; }
          y = Math.min(Math.max(y, y0 - (y1 - y0)), y1 + (y1 - y0));
          const sx = PLOT_L + (x - x0) / (x1 - x0 || 1) * (PLOT_W - PLOT_L - PLOT_R);
          const sy = PLOT_H - PLOT_B - (y - y0) / (y1 - y0 || 1) * (PLOT_H - PLOT_T - PLOT_B);
          d += (pen ? "L" : "M") + sx.toFixed(2) + " " + sy.toFixed(2);
          pen = true;
        }
        paths[i]?.setAttribute("d", d);
      });
    };
    for (const input of elements(plot, "input[type=range]", HTMLInputElement)) {
      const out = plot.querySelector("output[for='" + input.id + "']");
      input.addEventListener("input", () => {
        values[input.name] = parseFloat(input.value);
        const text = input.getAttribute("data-label") + " = " + (+parseFloat(input.value).toPrecision(3));
        input.setAttribute("aria-valuetext", text);
        if (out) out.textContent = (+parseFloat(input.value).toPrecision(3)).toString();
        draw();
      });
    }
  }
}

function setupCharts(): void {
  for (const chart of elements(document, ".chart", Element)) {
    const readout = chart.querySelector(".readout");
    for (const bar of elements(chart, ".bar-rect", Element)) {
      const show = (): void => { if (readout) readout.textContent = bar.getAttribute("aria-label"); };
      bar.addEventListener("focus", show);
      bar.addEventListener("mouseenter", show);
    }
  }
}

function setupCaptions(): void {
  for (const fig of elements(document, ".fig[data-caption]", Element)) {
    fig.addEventListener("click", () => { fig.classList.toggle("open"); fig.classList.remove("dismissed"); });
    fig.addEventListener("mouseleave", () => { fig.classList.remove("dismissed"); });
    fig.addEventListener("focusout", () => { fig.classList.remove("dismissed"); fig.classList.remove("open"); });
  }
}

function need<T extends Element>(id: string, kind: abstract new (...args: never[]) => T): T {
  const el = document.getElementById(id);
  if (!(el instanceof kind)) throw new Error("Missing element #" + id);
  return el;
}

const deck = need("deck", HTMLElement);
const slides = elements(deck, ".slide", HTMLElement);
const counter = need("counter", HTMLElement);
const live = document.getElementById("live");
const viewButton = need("view", HTMLElement);
const prevButton = need("prev", HTMLElement);
const nextButton = need("next", HTMLElement);
const READING_MEDIA = "(max-width: 640px) and (orientation: portrait)";
const SWIPE_DISTANCE = 60;
const STATEMENT_MIN = 3, STATEMENT_MAX = 14, STATEMENT_ROUNDS = 12;
let index = 0, step = 0;

function steps(slide: Element): number { return parseInt(slide.getAttribute("data-steps") || "1", 10); }

function render(announce: boolean): void {
  slides.forEach((s, i) => {
    const current = i === index;
    s.classList.toggle("current", current);
    if (!deck.classList.contains("reading")) s.setAttribute("aria-hidden", current ? "false" : "true");
    else s.removeAttribute("aria-hidden");
  });
  const slide = slides[index];
  if (!slide) return;
  elements(slide, "[data-step]", Element).forEach((el) => {
    const later = parseInt(el.getAttribute("data-step") ?? "", 10) > step;
    el.classList.toggle("later", later);
    if (!deck.classList.contains("reading")) el.setAttribute("aria-hidden", later ? "true" : "false");
    else el.removeAttribute("aria-hidden");
  });
  elements(slide, ".eqsteps", Element).forEach((group) => {
    const first = parseInt(group.getAttribute("data-first") ?? "", 10);
    const eqs = group.querySelectorAll(".eq");
    const k = Math.max(0, Math.min(eqs.length - 1, step - first));
    eqs.forEach((eq, j) => { eq.classList.toggle("shown", j === k); });
  });
  const total = steps(slide);
  counter.textContent = "Slide " + (index + 1) + " of " + slides.length + (total > 1 ? " · Step " + (step + 1) + " of " + total : "");
  if (announce && live) live.textContent = slide.getAttribute("aria-label") + (total > 1 ? ", step " + (step + 1) + " of " + total : "");
  fitStatements(slide);
  if (history.replaceState) history.replaceState(null, "", "#" + slide.id);
}

function go(delta: number): void {
  if (deck.classList.contains("reading")) return;
  const slide = slides[index];
  if (!slide) return;
  if (delta > 0) {
    if (step < steps(slide) - 1) step++;
    else if (index < slides.length - 1) { index++; step = 0; }
  } else {
    if (step > 0) step--;
    else if (index > 0) {
      index--;
      const previous = slides[index];
      step = (previous ? steps(previous) : 1) - 1;
    }
  }
  render(true);
}

function goTo(i: number): void { index = Math.max(0, Math.min(slides.length - 1, i)); step = 0; render(true); }

function setReading(on: boolean): void {
  deck.classList.toggle("reading", on);
  viewButton.setAttribute("aria-pressed", on ? "true" : "false");
  viewButton.textContent = on ? "Slides" : "Reading view";
  prevButton.hidden = on;
  nextButton.hidden = on;
  counter.hidden = on;
  render(false);
  slides[index]?.scrollIntoView(on ? { block: "start" } : undefined);
}

function fitStatements(slide: Element): void {
  if (deck.classList.contains("reading")) return;
  for (const el of elements(slide, ".statement", HTMLElement)) {
    const frame = el.parentElement;
    if (!frame) continue;
    let lo = STATEMENT_MIN, hi = STATEMENT_MAX, best = lo;
    for (let k = 0; k < STATEMENT_ROUNDS; k++) {
      const mid = (lo + hi) / 2;
      el.style.fontSize = mid + "cqh";
      if (el.scrollHeight <= frame.clientHeight * 0.9 && el.scrollWidth <= frame.clientWidth * 0.95) { best = mid; lo = mid; } else { hi = mid; }
    }
    el.style.fontSize = best + "cqh";
  }
}

prevButton.addEventListener("click", () => { go(-1); });
nextButton.addEventListener("click", () => { go(1); });
viewButton.addEventListener("click", () => { setReading(!deck.classList.contains("reading")); });

document.addEventListener("keydown", (e) => {
  if (e.target instanceof Element && (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA")) return;
  if (e.altKey || e.ctrlKey || e.metaKey) return;
  switch (e.key) {
    case "ArrowRight": case "PageDown": case " ": go(1); e.preventDefault(); break;
    case "ArrowLeft": case "PageUp": go(-1); e.preventDefault(); break;
    case "Home": goTo(0); e.preventDefault(); break;
    case "End": goTo(slides.length - 1); e.preventDefault(); break;
    case "Escape":
      document.querySelectorAll(".fig.open").forEach((f) => { f.classList.remove("open"); f.classList.add("dismissed"); });
      document.querySelectorAll(".fig:focus-within, .fig:hover").forEach((f) => { f.classList.add("dismissed"); });
      break;
  }
});

let touchX: number | null = null;
deck.addEventListener("touchstart", (e) => { touchX = e.touches[0]?.clientX ?? null; }, { passive: true });
deck.addEventListener("touchend", (e) => {
  const touch = e.changedTouches[0];
  if (touchX === null || !touch) return;
  const dx = touch.clientX - touchX;
  touchX = null;
  if (Math.abs(dx) > SWIPE_DISTANCE) go(dx < 0 ? 1 : -1);
});

setupCaptions();
setupPlots();
setupCharts();

const hash = location.hash.replace("#", "");
const start = slides.findIndex((s) => s.id === hash);
if (start >= 0) index = start;
if (window.matchMedia && window.matchMedia(READING_MEDIA).matches) setReading(true);
else render(false);
window.addEventListener("resize", () => { const s = slides[index]; if (s) fitStatements(s); });
