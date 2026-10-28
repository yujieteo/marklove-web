// Marklove article runtime: plots with sliders, chart readouts, and captions.
// It never runs code from the author's Markdown. Without it, the article
// still shows every plot and chart.
(function () {
  "use strict";
  // Safe expression parser for plots, the same grammar as the app.
  var FUNCS = { sin: Math.sin, cos: Math.cos, tan: Math.tan, exp: Math.exp, log: Math.log, ln: Math.log, sqrt: Math.sqrt,
    abs: Math.abs, atan: Math.atan, asin: Math.asin, acos: Math.acos, sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh,
    min: Math.min, max: Math.max, floor: Math.floor, ceil: Math.ceil };
  var CONSTS = { pi: Math.PI, e: Math.E };
  function compile(src, params) {
    var toks = String(src).match(/\d*\.?\d+(?:e[+-]?\d+)?|[A-Za-z_]\w*|\*\*|[-+*\/^(),]|\S/gi) || [];
    var i = 0;
    function peek() { return toks[i]; }
    function take() { return toks[i++]; }
    function expect(t) { if (take() !== t) throw new Error("expected " + t); }
    function sum() { var a = prod(); while (peek() === "+" || peek() === "-") { var op = take(), b = prod(), l = a; a = op === "+" ? (function (l, b) { return function (x, p) { return l(x, p) + b(x, p); }; })(l, b) : (function (l, b) { return function (x, p) { return l(x, p) - b(x, p); }; })(l, b); } return a; }
    function prod() {
      var a = unary();
      for (;;) {
        var t = peek();
        if (t === "*" || t === "/") { take(); var b = unary(), l = a; a = t === "*" ? (function (l, b) { return function (x, p) { return l(x, p) * b(x, p); }; })(l, b) : (function (l, b) { return function (x, p) { return l(x, p) / b(x, p); }; })(l, b); }
        else if (t !== undefined && (t === "(" || /^[A-Za-z_\d.]/.test(t))) { var b2 = unary(), l2 = a; a = (function (l, b) { return function (x, p) { return l(x, p) * b(x, p); }; })(l2, b2); }
        else return a;
      }
    }
    function unary() { if (peek() === "-") { take(); var a = unary(); return function (x, p) { return -a(x, p); }; } if (peek() === "+") { take(); return unary(); } return pow(); }
    function pow() { var a = atom(); if (peek() === "^" || peek() === "**") { take(); var b = unary(); return function (x, p) { return Math.pow(a(x, p), b(x, p)); }; } return a; }
    function atom() {
      var t = take();
      if (t === undefined) throw new Error("end");
      if (/^\d|^\./.test(t)) { var v = parseFloat(t); return function () { return v; }; }
      if (t === "(") { var a = sum(); expect(")"); return a; }
      var n = t.toLowerCase();
      if (n === "x") return function (x) { return x; };
      if (params.indexOf(t) >= 0) return function (x, p) { return p[t]; };
      if (Object.prototype.hasOwnProperty.call(CONSTS, n)) { var c = CONSTS[n]; return function () { return c; }; }
      if (Object.prototype.hasOwnProperty.call(FUNCS, n)) {
        expect("("); var args = [sum()]; while (peek() === ",") { take(); args.push(sum()); } expect(")");
        var f = FUNCS[n];
        return function (x, p) { return f.apply(null, args.map(function (g) { return g(x, p); })); };
      }
      throw new Error("unknown " + t);
    }
    var f = sum();
    if (i < toks.length) throw new Error("unexpected " + toks[i]);
    return f;
  }

  document.querySelectorAll(".plot[data-plot]").forEach(function (plot) {
    var spec;
    try { spec = JSON.parse(plot.getAttribute("data-plot")); } catch (e) { return; }
    var names = spec.params.map(function (p) { return p.name; });
    var curves = [];
    try { curves = spec.curves.map(function (c) { return compile(c, names); }); } catch (e) { return; }
    var paths = plot.querySelectorAll("path.curve");
    var values = {};
    spec.params.forEach(function (p) { values[p.name] = p.value; });
    var W = 1000, H = 520, L = 60, R = 20, T = 20, B = 40;
    function draw() {
      var x0 = spec.x[0], x1 = spec.x[1], y0 = spec.y[0], y1 = spec.y[1];
      curves.forEach(function (f, i) {
        var d = "", pen = false;
        for (var k = 0; k <= 240; k++) {
          var x = x0 + (x1 - x0) * k / 240, y = f(x, values);
          if (!isFinite(y)) { pen = false; continue; }
          y = Math.min(Math.max(y, y0 - (y1 - y0)), y1 + (y1 - y0));
          var sx = L + (x - x0) / (x1 - x0 || 1) * (W - L - R), sy = H - B - (y - y0) / (y1 - y0 || 1) * (H - T - B);
          d += (pen ? "L" : "M") + sx.toFixed(2) + " " + sy.toFixed(2);
          pen = true;
        }
        if (paths[i]) paths[i].setAttribute("d", d);
      });
    }
    plot.querySelectorAll("input[type=range]").forEach(function (input) {
      var out = plot.querySelector("output[for='" + input.id + "']");
      input.addEventListener("input", function () {
        values[input.name] = parseFloat(input.value);
        var text = input.getAttribute("data-label") + " = " + (+parseFloat(input.value).toPrecision(3));
        input.setAttribute("aria-valuetext", text);
        if (out) out.textContent = (+parseFloat(input.value).toPrecision(3)).toString();
        draw();
      });
    });
  });

  // Charts: show the value of a focused or hovered bar.
  document.querySelectorAll(".chart").forEach(function (chart) {
    var readout = chart.querySelector(".readout");
    chart.querySelectorAll(".bar-rect").forEach(function (bar) {
      function show() { if (readout) readout.textContent = bar.getAttribute("aria-label"); }
      bar.addEventListener("focus", show);
      bar.addEventListener("mouseenter", show);
    });
  });

  document.querySelectorAll(".fig[data-caption]").forEach(function (fig) {
    fig.addEventListener("click", function () { fig.classList.toggle("open"); fig.classList.remove("dismissed"); });
    fig.addEventListener("mouseleave", function () { fig.classList.remove("dismissed"); });
    fig.addEventListener("focusout", function () { fig.classList.remove("dismissed"); fig.classList.remove("open"); });
  });
})();
