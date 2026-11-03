(() => {
  // src/article.ts
  var FUNCS = {
    sin: Math.sin,
    cos: Math.cos,
    tan: Math.tan,
    exp: Math.exp,
    log: Math.log,
    ln: Math.log,
    sqrt: Math.sqrt,
    abs: Math.abs,
    atan: Math.atan,
    asin: Math.asin,
    acos: Math.acos,
    sinh: Math.sinh,
    cosh: Math.cosh,
    tanh: Math.tanh,
    min: Math.min,
    max: Math.max,
    floor: Math.floor,
    ceil: Math.ceil
  };
  var CONSTS = { pi: Math.PI, e: Math.E };
  var TOKEN_PATTERN = /\d*\.?\d+(?:e[+-]?\d+)?|[A-Za-z_]\w*|\*\*|[-+*/^(),]|\S/gi;
  var CURVE_SAMPLES = 240;
  var PLOT_W = 1000;
  var PLOT_H = 520;
  var PLOT_L = 60;
  var PLOT_R = 20;
  var PLOT_T = 20;
  var PLOT_B = 40;
  function compile(src, params) {
    const toks = String(src).match(TOKEN_PATTERN) || [];
    let i = 0;
    const peek = () => toks[i];
    const take = () => toks[i++];
    function expect(t) {
      if (take() !== t)
        throw new Error("expected " + t);
    }
    const binary = (l, r, op) => (x, p) => op(l(x, p), r(x, p));
    function sum() {
      let a = prod();
      while (peek() === "+" || peek() === "-") {
        const op = take(), b = prod();
        a = op === "+" ? binary(a, b, (u, v) => u + v) : binary(a, b, (u, v) => u - v);
      }
      return a;
    }
    function prod() {
      let a = unary();
      for (;; ) {
        const t = peek();
        if (t === "*" || t === "/") {
          take();
          const b = unary();
          a = t === "*" ? binary(a, b, (u, v) => u * v) : binary(a, b, (u, v) => u / v);
        } else if (t !== undefined && (t === "(" || /^[A-Za-z_\d.]/.test(t))) {
          a = binary(a, unary(), (u, v) => u * v);
        } else
          return a;
      }
    }
    function unary() {
      if (peek() === "-") {
        take();
        const a = unary();
        return (x, p) => -a(x, p);
      }
      if (peek() === "+") {
        take();
        return unary();
      }
      return pow();
    }
    function pow() {
      const a = atom();
      if (peek() === "^" || peek() === "**") {
        take();
        const b = unary();
        return binary(a, b, Math.pow);
      }
      return a;
    }
    function atom() {
      const t = take();
      if (t === undefined)
        throw new Error("end");
      if (/^\d|^\./.test(t)) {
        const v = parseFloat(t);
        return () => v;
      }
      if (t === "(") {
        const a = sum();
        expect(")");
        return a;
      }
      const n = t.toLowerCase();
      if (n === "x")
        return (x) => x;
      if (params.indexOf(t) >= 0)
        return (_x, p) => p[t] ?? NaN;
      const c = Object.prototype.hasOwnProperty.call(CONSTS, n) ? CONSTS[n] : undefined;
      if (c !== undefined)
        return () => c;
      const f = Object.prototype.hasOwnProperty.call(FUNCS, n) ? FUNCS[n] : undefined;
      if (f !== undefined) {
        expect("(");
        const args = [sum()];
        while (peek() === ",") {
          take();
          args.push(sum());
        }
        expect(")");
        return (x, p) => f(...args.map((g) => g(x, p)));
      }
      throw new Error("unknown " + t);
    }
    const f = sum();
    if (i < toks.length)
      throw new Error("unexpected " + toks[i]);
    return f;
  }
  function isPair(v) {
    return Array.isArray(v) && v.length >= 2 && typeof v[0] === "number" && typeof v[1] === "number";
  }
  function parsePlotSpec(text) {
    let raw;
    try {
      raw = JSON.parse(text ?? "");
    } catch {
      return null;
    }
    if (typeof raw !== "object" || raw === null)
      return null;
    const params = Reflect.get(raw, "params");
    const curves = Reflect.get(raw, "curves");
    const x = Reflect.get(raw, "x");
    const y = Reflect.get(raw, "y");
    if (!Array.isArray(params) || !Array.isArray(curves) || !isPair(x) || !isPair(y))
      return null;
    const parsed = [];
    for (const p of params) {
      if (typeof p !== "object" || p === null)
        return null;
      const name = Reflect.get(p, "name");
      const value = Reflect.get(p, "value");
      if (typeof name !== "string" || typeof value !== "number")
        return null;
      parsed.push({ name, value });
    }
    const sources = [];
    for (const c of curves) {
      if (typeof c !== "string")
        return null;
      sources.push(c);
    }
    return { params: parsed, curves: sources, x: [x[0], x[1]], y: [y[0], y[1]] };
  }
  function elements(root, selector, kind) {
    return [...root.querySelectorAll(selector)].filter((el) => el instanceof kind);
  }
  function setupPlots() {
    for (const plot of elements(document, ".plot[data-plot]", Element)) {
      const spec = parsePlotSpec(plot.getAttribute("data-plot"));
      if (!spec)
        continue;
      const names = spec.params.map((p) => p.name);
      let curves = [];
      try {
        curves = spec.curves.map((c) => compile(c, names));
      } catch {
        continue;
      }
      const paths = plot.querySelectorAll("path.curve");
      const values = {};
      for (const p of spec.params)
        values[p.name] = p.value;
      const draw = () => {
        const [x0, x1] = spec.x, [y0, y1] = spec.y;
        curves.forEach((f, i) => {
          let d = "", pen = false;
          for (let k = 0;k <= CURVE_SAMPLES; k++) {
            const x = x0 + (x1 - x0) * k / CURVE_SAMPLES;
            let y = f(x, values);
            if (!isFinite(y)) {
              pen = false;
              continue;
            }
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
          const text = input.getAttribute("data-label") + " = " + +parseFloat(input.value).toPrecision(3);
          input.setAttribute("aria-valuetext", text);
          if (out)
            out.textContent = (+parseFloat(input.value).toPrecision(3)).toString();
          draw();
        });
      }
    }
  }
  function setupCharts() {
    for (const chart of elements(document, ".chart", Element)) {
      const readout = chart.querySelector(".readout");
      for (const bar of elements(chart, ".bar-rect", Element)) {
        const show = () => {
          if (readout)
            readout.textContent = bar.getAttribute("aria-label");
        };
        bar.addEventListener("focus", show);
        bar.addEventListener("mouseenter", show);
      }
    }
  }
  function setupCaptions() {
    for (const fig of elements(document, ".fig[data-caption]", Element)) {
      fig.addEventListener("click", () => {
        fig.classList.toggle("open");
        fig.classList.remove("dismissed");
      });
      fig.addEventListener("mouseleave", () => {
        fig.classList.remove("dismissed");
      });
      fig.addEventListener("focusout", () => {
        fig.classList.remove("dismissed");
        fig.classList.remove("open");
      });
    }
  }
  setupPlots();
  setupCharts();
  setupCaptions();
})();
