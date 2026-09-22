// card-layout.browser.test.js - BEHAVIORAL fixture: replays the SHIPPED panel HTML in a real
// (headless Chromium) browser with a SPARSE card beside a DENSE one in the same grid row, and
// measures the cards theme's geometry.
//
// 2026-09-17: from a screenshot of the cards theme -- (a) a sparse card (title, status row,
// context bar) stretched to its row-neighbour's height and its rows spread apart with big dead
// gaps (the .tile grid shared the surplus height among its implicit auto rows); (b) the branch
// chip wrapped onto a second line indented under the status text, so the status row and the chip
// had a different left edge than the title (.label had no nowrap and .stk-br capped at 9em, and
// .label started in grid column 2 while .name/.meta spanned both); (c) a quiet "Ready for you"
// card was dimmed as if stale (.tile.stale applied to every card older than 90s).
//
// Geometry, not screenshots. The two items are built here rather than in capture-panel.lua's
// status-file fixture because branch / stackAlso / bg_active are decorated by the Lua refresh
// from git + the subagent scan, which a temp-dir fixture cannot produce -- the panel's own
// window.ccUpdate is the real entry point either way.
//
// 2026-09-17 (measured and fixed 2026-09-22): the same DENSE item under the CONTRAST layout
// theme -- risk / PR / agents are loose grid items there, because .badges is display:contents
// and the contrast tile is an `auto 1fr` grid, so whichever badge lands in the 1fr column is
// blockified and stretched right across the card (pill 195px on a 276px card, ratio 0.70).
// Every layout theme is now measured by the one pack() helper against the one threshold.
//
// Needs Playwright (the isolate runner's copy, or CC_PLAYWRIGHT=<module path>); without it
// this prints an explicit skip, like `make lint` does for a missing luacheck.
// Usage: node tests/card-layout.browser.test.js

const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) console.log("ok   - " + name);
  else { failed++; console.log("FAIL - " + name); }
}
function finish() {
  console.log("-- card-layout.browser.test.js: " + run + " run, " + failed + " failed --");
  process.exit(failed ? 1 : 0);
}

function loadPlaywright() {
  const tries = [process.env.CC_PLAYWRIGHT,
    path.join(os.homedir(), ".isolate-runner", "node_modules", "playwright"), "playwright"].filter(Boolean);
  for (const t of tries) { try { return require(t); } catch (e) { /* next */ } }
  return null;
}
const pw = loadPlaywright();
if (!pw) {
  console.log("skip - real-browser card-layout check: Playwright not installed (set CC_PLAYWRIGHT or install the isolate runner)");
  process.exit(0);
}

// ---- capture the real panel (stubbed-hs load of claude-dashboard.lua) --------
const out = fs.mkdtempSync(path.join(os.tmpdir(), "cc-panel-"));
const home = fs.mkdtempSync(path.join(os.tmpdir(), "cc-home-"));
try {
  execFileSync("lua", [path.join(ROOT, "tests/support/capture-panel.lua"), ROOT, out],
    { env: Object.assign({}, process.env, { HOME: home }), stdio: ["ignore", "pipe", "inherit"] });
} catch (e) {
  check("captured the shipped panel html under a stubbed hs", false);
  finish();
}
const update = fs.readFileSync(path.join(out, "update.js"), "utf8");

// Two cards in ONE grid row, as the screenshot had them: a sparse stale "done" card beside a
// dense one carrying a long branch chip, the background-agents badge and an "also" line.
const now = Math.floor(Date.now() / 1000);
const SPARSE = {
  key: "sparse", session_id: "sparse", name: "quiet-repo", status: "done",
  since: now - 420, updated: now - 420, stale: true, editor: "vscode",
  context_frac: 0.31, context_tokens: 62000,
};
const DENSE = {
  key: "dense", session_id: "dense", name: "busy-repo", status: "working",
  since: now - 95, updated: now, editor: "vscode",
  branch: "feat/a-really-long-branch-name-that-cannot-fit",
  isMainWt: false, stackSize: 2, stackKey: "dense-stack", stackRank: 1,
  stackAlso: [{ b: "done", n: 1 }],
  sessTitle: "reworking the fleet grid's project cards",
  bg_active: true, bg_count: 3,
  risk: "high", riskScore: 74, riskSignals: ["deny", "error"],
  context_frac: 0.68, context_tokens: 136000,
};

(async () => {
  let browser;
  try { browser = await pw.chromium.launch({ headless: true }); }
  catch (e) {
    console.log("skip - real-browser card-layout check: Chromium could not launch (" + String(e.message).split("\n")[0] + ")");
    process.exit(0);
  }
  // Shepherd's default panel width: with --tile-min 170px the two cards land side by side in
  // the same grid row, which is what makes the sparse one stretch.
  const page = await browser.newPage({ viewport: { width: 580, height: 900 } });
  await page.addInitScript(() => {
    window.__sent = [];
    window.webkit = { messageHandlers: { cc: { postMessage: (m) => window.__sent.push(String(m)) } } };
  });
  await page.goto("file://" + path.join(out, "panel.html"));
  await page.evaluate((code) => { (0, eval)(code); }, update);
  await page.evaluate((items) => { window.ccUpdate(items); }, [SPARSE, DENSE]);

  const cardsTheme = await page.evaluate(() => document.body.className.indexOf("theme-cards") >= 0);
  check("the panel is rendering the cards theme", cardsTheme);

  // pack(k) measures one card. It is installed on the page (window.__pack) rather than being
  // local to one evaluate, so the SAME helper and the SAME thresholds measure every layout
  // theme: window.__packTheme(theme, items, keys) performs the shipped theme switch (the exact
  // class dance onThemeChange does), re-renders, and packs each key.
  await page.evaluate(() => {
    const r = (el) => { if (!el) return null; const b = el.getBoundingClientRect();
      return { x: b.x, y: b.y, w: b.width, h: b.height, right: b.right, bottom: b.bottom }; };
    const tile = (k) => document.querySelector('.tile[data-key="' + k + '"]');
    window.__pack = (k) => {
      const t = tile(k);
      if (!t) return null;
      // display:contents leaves the wrapper boxless, so the badges ROW is measured as the union
      // of the badges themselves -- the edge a reader actually sees, in every theme.
      const kids = Array.prototype.slice.call(t.querySelectorAll(".badges > *"))
        .map((el) => el.getBoundingClientRect()).filter((b) => b.width > 0 || b.height > 0);
      const row = kids.length ? { x: Math.min.apply(null, kids.map((b) => b.x)),
        y: Math.min.apply(null, kids.map((b) => b.y)),
        w: Math.max.apply(null, kids.map((b) => b.right)) - Math.min.apply(null, kids.map((b) => b.x)),
        h: Math.max.apply(null, kids.map((b) => b.bottom)) - Math.min.apply(null, kids.map((b) => b.y)) } : null;
      return {
        tile: r(t), name: r(t.querySelector(".name")), label: r(t.querySelector(".label")),
        meta: r(t.querySelector(".meta")), dot: r(t.querySelector(".dot")),
        srow: r(t.querySelector(".srow")),
        br: r(t.querySelector(".stk-br")), ctx: r(t.querySelector(".ctx-bar")),
        also: r(t.querySelector(".stk-also")), bg: r(t.querySelector(".bg-run")),
        badges: r(t.querySelector(".badges")), risk: r(t.querySelector(".risk")),
        badgeRow: row,
        badgesDisplay: (() => { const b = t.querySelector(".badges");
          return b ? getComputedStyle(b).display : null; })(),
        badgeCount: t.querySelectorAll(".badges").length,
        opacity: getComputedStyle(t).opacity, stale: t.classList.contains("stale"),
        labelLines: (() => { const l = t.querySelector(".label");
          if (!l) return 0;
          const cs = getComputedStyle(l);
          const lh = parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2;
          return Math.round(l.getBoundingClientRect().height / lh); })(),
      };
    };
    window.__packTheme = (theme, items, keys) => {
      document.body.className = document.body.className.replace(/(^|\s)theme-\S+/g, "").trim();
      document.body.classList.add("theme-" + theme);
      lastGridSig = null;
      window.ccUpdate(items);
      const o = {};
      for (const k of keys) o[k] = window.__pack(k);
      return o;
    };
  });
  const geo = await page.evaluate(() => ({ sparse: window.__pack("sparse"), dense: window.__pack("dense") }));

  check("both cards rendered", !!(geo.sparse && geo.dense));
  if (!geo.sparse || !geo.dense) { await browser.close(); finish(); }
  const s = geo.sparse, d = geo.dense;

  // --- (b) the status row is ONE line, with the branch chip ellipsised in place -----------
  check("the dense card's branch chip rendered", !!d.br);
  check("the dense card's status row occupies a single line  (lines=" + d.labelLines + ")", d.labelLines === 1);
  if (d.br) {
    check("the branch chip's right edge stays inside the tile  (chip=" + Math.round(d.br.right)
      + " tile=" + Math.round(d.tile.right) + ")", d.br.right <= d.tile.right);
    check("the branch chip sits on the status row, not under it  (chip.y=" + Math.round(d.br.y)
      + " label.y=" + Math.round(d.label.y) + ")", Math.abs(d.br.y - d.label.y) <= 6);
  }

  // --- title / status row / speech-bubble line share one left edge -------------------------
  // The STATUS ROW is what must line up with the title: the dot leads that row, so it is the
  // row's own left edge (.srow) that has to match, not the status text inside it.
  for (const [nm, c] of [["dense", d], ["sparse", s]]) {
    check("the " + nm + " card has a status row", !!c.srow);
    const edges = [c.name.x, c.srow.x].concat(c.meta ? [c.meta.x] : []).concat(c.also ? [c.also.x] : [])
      .concat(c.ctx ? [c.ctx.x] : []);
    const spread = Math.max.apply(null, edges) - Math.min.apply(null, edges);
    check("the " + nm + " card's title, status row, meta and bar share one left edge  (spread="
      + Math.round(spread) + "px)", spread <= 1.5);
    check("...and the dot is that row's leading element  (dot.x=" + Math.round(c.dot.x)
      + " srow.x=" + Math.round(c.srow.x) + ")", Math.abs(c.dot.x - c.srow.x) <= 1.5);
  }
  check("the dot sits ON the status line, vertically inside it  (dot.y=" + Math.round(d.dot.y)
    + " label.y=" + Math.round(d.label.y) + ")",
    d.dot.y >= d.label.y - 2 && d.dot.bottom <= d.label.bottom + 2);
  // The status text still clears the dot -- the row reads "dot age words chip", not overlapped.
  check("the status text starts right of the dot  (label.x=" + Math.round(d.label.x)
    + " dot.right=" + Math.round(d.dot.right) + ")", d.label.x >= d.dot.right);

  // The cards theme lifts the chip's 9em cap so the flex row sizes it; the grid-laid themes
  // keep the cap, which is what holds the chip inside its cell there.
  const caps = await page.evaluate(() => {
    const chip = document.querySelector('.tile[data-key="dense"] .stk-br');
    const cards = getComputedStyle(chip).maxWidth;
    document.body.className = document.body.className.replace(/(^|\s)theme-\S+/g, "").trim();
    document.body.classList.add("theme-contrast");
    const contrast = getComputedStyle(document.querySelector('.tile[data-key="dense"] .stk-br')).maxWidth;
    document.body.className = document.body.className.replace(/(^|\s)theme-\S+/g, "").trim();
    document.body.classList.add("theme-cards");
    return { cards: cards, contrast: contrast };
  });
  check("the cards theme lets the flex row size the branch chip  (max-width=" + caps.cards + ")",
    caps.cards === "none");
  check("the grid-laid themes still cap the chip  (contrast max-width=" + caps.contrast + ")",
    caps.contrast !== "none" && parseFloat(caps.contrast) > 0);

  // --- risk / PR / agents are ONE badges row, sized to their content ----------------------
  // 2026-09-17 unfixed-in-progress: as loose column children each badge took a full-width row
  // of its own, so the green agents pill stretched right across the card.
  check("the dense card has exactly one badges row  (got=" + d.badgeCount + ")", d.badgeCount === 1);
  check("the risk and agents badges sit on the SAME row  (risk.y=" + Math.round(d.risk.y)
    + " bg.y=" + Math.round(d.bg.y) + ")",
    !!(d.risk && d.bg) && Math.abs((d.risk.y + d.risk.h / 2) - (d.bg.y + d.bg.h / 2)) <= 3);
  check("the agents pill is as wide as its content, not the whole card  (pill="
    + Math.round(d.bg.w) + " card=" + Math.round(d.tile.w) + ")", d.bg.w < d.tile.w * 0.6);
  check("the badges row starts at the card's left edge  (badges.x=" + Math.round(d.badges.x)
    + " name.x=" + Math.round(d.name.x) + ")", Math.abs(d.badges.x - d.name.x) <= 1.5);
  check("a card with no risk, PR or agents emits no badges row  (got=" + s.badgeCount + ")",
    s.badgeCount === 0);

  // ---- the badges row keeps its shape in EVERY layout theme, not just cards ---------------
  // 2026-09-17: risk / PR / agents are loose grid items in theme-contrast, so whichever lands
  // in the 1fr column stretches across the card. `.badges` is display:contents (8657), which
  // dissolves the wrapper and makes each badge a direct child of the `auto 1fr` contrast tile
  // grid (8948-8951); the cards theme repairs that (8927-8929) and contrast had no such rule.
  // Measured in a real browser on the DENSE item above: pill 195px on a 276px card, ratio 0.70.
  // Same item, same thresholds, one loop -- so the two themes can never drift apart again.
  const themed = {};
  for (const theme of ["cards", "contrast"]) {
    themed[theme] = (await page.evaluate((a) => window.__packTheme(a.theme, a.items, ["dense"]),
      { theme, items: [SPARSE, DENSE] })).dense;
  }
  for (const theme of ["cards", "contrast"]) {
    const c = themed[theme];
    check("theme " + theme + ": the dense card rendered for the badge measurements", !!c);
    if (!c) continue;
    check("theme " + theme + ": the agents pill is as wide as its content, not the whole card  (pill="
      + Math.round(c.bg.w) + " card=" + Math.round(c.tile.w) + " ratio="
      + (c.bg.w / c.tile.w).toFixed(2) + ")", c.bg.w < c.tile.w * 0.6);
    check("theme " + theme + ": the badges start at the title's left edge  (badges.x="
      + Math.round(c.badgeRow.x) + " name.x=" + Math.round(c.name.x) + ")",
      Math.abs(c.badgeRow.x - c.name.x) <= 1.5);
    check("theme " + theme + ": risk and agents share ONE row  (risk.y=" + Math.round(c.risk.y)
      + " bg.y=" + Math.round(c.bg.y) + ")",
      !!(c.risk && c.bg) && Math.abs((c.risk.y + c.risk.h / 2) - (c.bg.y + c.bg.h / 2)) <= 3);
  }
  // The contrast tile's first grid column is the status dot's: a badge auto-placed into it
  // would widen the column away from the 18px the theme draws.
  check("theme contrast: the dot column is still 18px wide  (dot="
    + Math.round(themed.contrast.dot.w) + "x" + Math.round(themed.contrast.dot.h) + ")",
    Math.abs(themed.contrast.dot.w - 18) <= 0.5 && Math.abs(themed.contrast.dot.h - 18) <= 0.5);

  // The two single-row themes hide .label / .meta but NOT the badges, so the same loose-item
  // question applies there -- measured against the same threshold.
  for (const theme of ["bar", "dots"]) {
    const c = (await page.evaluate((a) => window.__packTheme(a.theme, a.items, ["dense"]),
      { theme, items: [SPARSE, DENSE] })).dense;
    check("theme " + theme + ": the dense card rendered for the badge measurements", !!c);
    if (!c) continue;
    check("theme " + theme + ": the agents pill is as wide as its content, not the whole card  (pill="
      + Math.round(c.bg.w) + " card=" + Math.round(c.tile.w) + " ratio="
      + (c.bg.w / c.tile.w).toFixed(2) + ")", c.bg.w < c.tile.w * 0.6);
    check("theme " + theme + ": the badges sit on the pill's one row, beside the title  (bg.y="
      + Math.round(c.bg.y) + " name.y=" + Math.round(c.name.y) + ")",
      Math.abs((c.bg.y + c.bg.h / 2) - (c.name.y + c.name.h / 2)) <= 3);
  }

  // --- (a) a stretched sparse card keeps its content packed at the top ---------------------
  check("the sparse card really is stretched to its neighbour's height  (sparse="
    + Math.round(s.tile.h) + " dense=" + Math.round(d.tile.h) + ")", s.tile.h >= d.tile.h - 1);
  const gap = s.label.y - (s.name.y + s.name.h);
  check("the sparse card's title-to-status gap stays tight when stretched  (gap="
    + Math.round(gap) + "px)", gap <= 8);
  check("both cards' context bars share a bottom edge  (sparse=" + Math.round(s.ctx.bottom)
    + " dense=" + Math.round(d.ctx.bottom) + ")", Math.abs(s.ctx.bottom - d.ctx.bottom) <= 1.5);

  // --- (c) a quiet "Ready for you" card is not dimmed --------------------------------------
  check("the stale 'Ready for you' card is at full strength  (opacity=" + s.opacity + ")",
    Number(s.opacity) === 1);

  // A genuinely idle stale card still dims -- and at .6, not .45.
  const idleOpacity = await page.evaluate((items) => {
    window.ccUpdate(items);
    const t = document.querySelector('.tile[data-key="cold"]');
    return t ? { opacity: getComputedStyle(t).opacity, stale: t.classList.contains("stale") } : null;
  }, [Object.assign({}, SPARSE, { key: "cold", session_id: "cold", name: "cold-repo", status: "idle" })]);
  check("a genuinely idle stale card is still marked stale", !!(idleOpacity && idleOpacity.stale));
  check("...and dims to .6, not .45  (opacity=" + (idleOpacity && idleOpacity.opacity) + ")",
    !!idleOpacity && Math.abs(Number(idleOpacity.opacity) - 0.6) < 0.01);

  // --- the OTHER themes are untouched by the two new grouping wrappers --------------------
  // .srow and .badges are display:contents outside the cards theme, so bar / dots / contrast
  // still place .dot, .label and the badges themselves. Pin that: a wrapper that ever stopped
  // being display:contents would swallow the dot these themes are built around.
  for (const theme of ["bar", "dots", "contrast"]) {
    const t = await page.evaluate((args) => {
      document.body.className = document.body.className.replace(/(^|\s)theme-\S+/g, "").trim();
      document.body.classList.add("theme-" + args.theme);
      lastGridSig = null;
      window.ccUpdate(args.items);
      const tile = document.querySelector('.tile[data-key="dense"]');
      if (!tile) return null;
      const dot = tile.querySelector(".dot"), name = tile.querySelector(".name");
      const srow = tile.querySelector(".srow"), badges = tile.querySelector(".badges");
      const bg = tile.querySelector(".bg-run");
      const rb = (el) => { const b = el.getBoundingClientRect(); return { x: b.x, y: b.y, w: b.width, h: b.height }; };
      return {
        srowContents: srow ? getComputedStyle(srow).display : null,
        badgesContents: badges ? getComputedStyle(badges).display : null,
        dot: dot ? rb(dot) : null, name: name ? rb(name) : null, bg: bg ? rb(bg) : null,
        dotParent: dot ? dot.parentElement.className : null,
      };
    }, { theme, items: [SPARSE, DENSE] });
    check("theme " + theme + ": the tile still rendered", !!t);
    if (!t) continue;
    check("theme " + theme + ": the status-row wrapper is display:contents  (got=" + t.srowContents + ")",
      t.srowContents === "contents");
    // REQUIREMENT CHANGE (2026-09-22): .srow stays display:contents in all three themes, but
    // the CONTRAST theme now lays the badges wrapper out itself -- exactly as the cards theme
    // does -- because dissolving it is what let a badge become a stretched grid item. bar and
    // dots still dissolve it: their tiles are flex rows, where loose badges lay out correctly.
    check("theme " + theme + ": the badges wrapper is " + (theme === "contrast" ? "laid out by the theme" : "display:contents")
      + "  (got=" + t.badgesContents + ")",
      theme === "contrast" ? t.badgesContents === "flex" : t.badgesContents === "contents");
    check("theme " + theme + ": the dot is still drawn  (" + (t.dot ? Math.round(t.dot.w) + "x" + Math.round(t.dot.h) : "none") + ")",
      !!t.dot && t.dot.w > 0 && t.dot.h > 0);
    check("theme " + theme + ": the background-agents badge is still drawn",
      !!t.bg && t.bg.w > 0 && t.bg.h > 0);
    if (theme === "bar" || theme === "dots") {
      check("theme " + theme + ": the dot leads the name on one row  (dot.x=" + Math.round(t.dot.x)
        + " name.x=" + Math.round(t.name.x) + ")",
        t.dot.x < t.name.x && Math.abs((t.dot.y + t.dot.h / 2) - (t.name.y + t.name.h / 2)) <= 3);
    } else {
      check("theme contrast: the dot keeps its own left column beside the name  (dot.x="
        + Math.round(t.dot.x) + " name.x=" + Math.round(t.name.x) + ")", t.dot.x < t.name.x);
    }
  }

  await browser.close();
  finish();
})().catch((e) => { console.log("FAIL - browser run crashed: " + e.message); process.exit(1); });
