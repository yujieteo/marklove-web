// Marklove presentation runtime. It runs only Marklove's own interactions:
// navigation, reveals, equation steps, plots with sliders, charts, and captions.
// It never runs code from the author's Markdown.
(function () {
  "use strict";
  var deck = document.getElementById("deck");
  var slides = Array.prototype.slice.call(deck.querySelectorAll(".slide"));
  var counter = document.getElementById("counter");
  var live = document.getElementById("live");
  var viewButton = document.getElementById("view");
  var index = 0, step = 0;

  function steps(slide) { return parseInt(slide.getAttribute("data-steps") || "1", 10); }

  function render(announce) {
    slides.forEach(function (s, i) {
      var current = i === index;
      s.classList.toggle("current", current);
      if (!deck.classList.contains("reading")) s.setAttribute("aria-hidden", current ? "false" : "true");
      else s.removeAttribute("aria-hidden");
    });
    var slide = slides[index];
    if (!slide) return;
    slide.querySelectorAll("[data-step]").forEach(function (el) {
      var later = parseInt(el.getAttribute("data-step"), 10) > step;
      el.classList.toggle("later", later);
      if (!deck.classList.contains("reading")) el.setAttribute("aria-hidden", later ? "true" : "false");
      else el.removeAttribute("aria-hidden");
    });
    slide.querySelectorAll(".eqsteps").forEach(function (group) {
      var first = parseInt(group.getAttribute("data-first"), 10);
      var eqs = group.querySelectorAll(".eq");
      var k = Math.max(0, Math.min(eqs.length - 1, step - first));
      eqs.forEach(function (eq, j) { eq.classList.toggle("shown", j === k); });
    });
    var total = steps(slide);
    counter.textContent = "Slide " + (index + 1) + " of " + slides.length + (total > 1 ? " · Step " + (step + 1) + " of " + total : "");
    if (announce && live) live.textContent = slide.getAttribute("aria-label") + (total > 1 ? ", step " + (step + 1) + " of " + total : "");
    fitStatements(slide);
    if (history.replaceState) history.replaceState(null, "", "#" + slide.id);
  }

  function go(delta) {
    if (deck.classList.contains("reading")) return;
    var slide = slides[index];
    if (delta > 0) {
      if (step < steps(slide) - 1) step++;
      else if (index < slides.length - 1) { index++; step = 0; }
    } else {
      if (step > 0) step--;
      else if (index > 0) { index--; step = steps(slides[index]) - 1; }
    }
    render(true);
  }

  function goTo(i) { index = Math.max(0, Math.min(slides.length - 1, i)); step = 0; render(true); }

  document.getElementById("prev").addEventListener("click", function () { go(-1); });
  document.getElementById("next").addEventListener("click", function () { go(1); });
  viewButton.addEventListener("click", function () { setReading(!deck.classList.contains("reading")); });

  function setReading(on) {
    deck.classList.toggle("reading", on);
    viewButton.setAttribute("aria-pressed", on ? "true" : "false");
    viewButton.textContent = on ? "Slides" : "Reading view";
    document.getElementById("prev").hidden = on;
    document.getElementById("next").hidden = on;
    counter.hidden = on;
    render(false);
    if (on && slides[index]) slides[index].scrollIntoView({ block: "start" });
  }

  document.addEventListener("keydown", function (e) {
    if (e.target && (e.target.tagName === "INPUT" || e.target.tagName === "TEXTAREA")) return;
    if (e.altKey || e.ctrlKey || e.metaKey) return;
    switch (e.key) {
      case "ArrowRight": case "PageDown": case " ": go(1); e.preventDefault(); break;
      case "ArrowLeft": case "PageUp": go(-1); e.preventDefault(); break;
      case "Home": goTo(0); e.preventDefault(); break;
      case "End": goTo(slides.length - 1); e.preventDefault(); break;
      case "Escape":
        document.querySelectorAll(".fig.open").forEach(function (f) { f.classList.remove("open"); f.classList.add("dismissed"); });
        document.querySelectorAll(".fig:focus-within, .fig:hover").forEach(function (f) { f.classList.add("dismissed"); });
        break;
    }
  });

  // Swipe on touch screens, with buttons as the accessible alternative.
  var touchX = null;
  deck.addEventListener("touchstart", function (e) { touchX = e.touches[0].clientX; }, { passive: true });
  deck.addEventListener("touchend", function (e) {
    if (touchX === null) return;
    var dx = e.changedTouches[0].clientX - touchX;
    touchX = null;
    if (Math.abs(dx) > 60) go(dx < 0 ? 1 : -1);
  });

  // Captions: hover, focus, tap, and Escape to dismiss.
  document.querySelectorAll(".fig[data-caption]").forEach(function (fig) {
    fig.addEventListener("click", function () { fig.classList.toggle("open"); fig.classList.remove("dismissed"); });
    fig.addEventListener("mouseleave", function () { fig.classList.remove("dismissed"); });
    fig.addEventListener("focusout", function () { fig.classList.remove("dismissed"); fig.classList.remove("open"); });
  });

  // Takahashi statements: largest size that fits, with a readable minimum.
  function fitStatements(slide) {
    if (deck.classList.contains("reading")) return;
    slide.querySelectorAll(".statement").forEach(function (el) {
      var frame = el.parentElement;
      var lo = 3, hi = 14, best = lo;
      for (var k = 0; k < 12; k++) {
        var mid = (lo + hi) / 2;
        el.style.fontSize = mid + "cqh";
        if (el.scrollHeight <= frame.clientHeight * 0.9 && el.scrollWidth <= frame.clientWidth * 0.95) { best = mid; lo = mid; } else { hi = mid; }
      }
      el.style.fontSize = best + "cqh";
    });
  }

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

  // Start at the slide in the address, or open the reading view on a narrow portrait screen.
  var hash = location.hash.replace("#", "");
  var start = slides.findIndex(function (s) { return s.id === hash; });
  if (start >= 0) index = start;
  if (window.matchMedia && window.matchMedia("(max-width: 640px) and (orientation: portrait)").matches) setReading(true);
  else render(false);
  window.addEventListener("resize", function () { if (slides[index]) fitStatements(slides[index]); });
})();
