// stray-scroll.test.js - BEHAVIORAL: the panel's page never stays scrolled past its content.
//
// 2026-09-30: the panel went dead -- every tile and button ignored clicks -- while Hammerspoon and
// the page's script were both fine. The live page reported scrollY 491 although its content fit
// the view (scrollHeight 863, clientHeight 863): it was DRAWN unscrolled but hit-tested 491px
// higher, so a click on a tile landed on empty space (elementFromPoint gave HTML). The webview
// keeps a stale offset when Shepherd resizes its window to fit the content; nothing put it back.
// window.scrollTo(0, 0) in the live page made it clickable again at once.
//
// Runs the REAL shipped clampStrayScroll sliced out of claude-dashboard.lua (the
// done-order.test.js pattern), against a stubbed window and document.
//
// Usage: node tests/stray-scroll.test.js [path/to/claude-dashboard.lua]

const fs = require("fs");
const path = require("path");
const DASH = process.argv[2] || path.join(__dirname, "..", "claude-dashboard.lua");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + JSON.stringify(got) + " want=" + JSON.stringify(want) + ")", got === want); }

const src = fs.readFileSync(DASH, "utf8");
function slice(startNeedle, endNeedle) {
  const i = src.indexOf(startNeedle);
  if (i < 0) return null;
  const j = src.indexOf(endNeedle, i);
  if (j < 0) return null;
  return src.slice(i, j + endNeedle.length);
}
const clampSrc = slice("    function clampStrayScroll(){", "\n    }\n");
check("the panel ships clampStrayScroll", clampSrc !== null);
if (!clampSrc) {
  console.log("\n-- stray-scroll.test.js: " + run + " run, " + failed + " failed --");
  process.exit(1);
}

// a page: how far it is scrolled, how tall its content is, how tall the view is
function page(scrollY, scrollHeight, innerHeight) {
  const calls = [];
  const win = { scrollY: scrollY, scrollX: 0, innerHeight: innerHeight,
    scrollTo: function (x, y) { calls.push([x, y]); win.scrollY = y; } };
  const doc = { scrollingElement: { scrollHeight: scrollHeight }, documentElement: { scrollHeight: scrollHeight } };
  const fn = new Function("window", "document", clampSrc + "\nreturn clampStrayScroll;")(win, doc);
  return { fn: fn, calls: calls, win: win };
}

// the live failure: content fits the view, the page says it is 491px down
let p = page(491, 863, 863);
eq("content that fits the view but reads scrolled 491px is put back to the top", p.fn(), true);
eq("...with one scrollTo(0, 0)", JSON.stringify(p.calls), JSON.stringify([[0, 0]]));
eq("...and a second look finds nothing to do", p.fn() === false && p.calls.length === 1, true);
// a page that really scrolls is left alone
p = page(300, 1400, 863);
eq("a page scrolled within its content is left where it is", p.fn() === false && p.calls.length === 0, true);
p = page(537, 1400, 863);
eq("...also at its very end", p.fn() === false && p.calls.length === 0, true);
// content shrank under a scrolled page: back to the furthest real position, not the top
p = page(900, 1400, 863);
eq("a page scrolled past its end is put at its end", p.fn() === true && JSON.stringify(p.calls) === JSON.stringify([[0, 537]]), true);
p = page(0, 863, 863);
eq("an unscrolled page is left alone", p.fn() === false && p.calls.length === 0, true);
p = page(0.4, 863, 863);
eq("a sub-pixel offset is not worth a jump", p.fn() === false && p.calls.length === 0, true);

// it has to run without anyone scrolling: on every tick's render, on a resize, and when the
// window comes back (the offset went stale while the screen was locked)
check("every tick's render checks it (ccUpdate)", /window\.ccUpdate = function\(items, providers, bundles\)\{[\s\S]{0,400}clampStrayScroll\(\);/.test(src));
check("a resize checks it", src.indexOf('window.addEventListener("resize", clampStrayScroll);') >= 0);
check("coming back into view checks it", src.indexOf('document.addEventListener("visibilitychange", clampStrayScroll);') >= 0);

console.log("\n-- stray-scroll.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
