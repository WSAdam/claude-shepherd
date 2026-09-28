// check-links.js - every relative link and image in the given Markdown files resolves: the
// file exists inside <root>, and a #fragment names a heading (or an explicit id) in its target.
// External links (http:, https:, mailto:, any scheme) are left alone -- this is an offline check.
// Links inside fenced code blocks and `inline code` are not links, so they are skipped.
//   node tests/support/check-links.js <root> <file.md>...
// Prints one line per broken link (file:line: target -- why) and exits 1 if there are any.

const fs = require("fs");
const path = require("path");

const root = path.resolve(process.argv[2] || ".");
const files = process.argv.slice(3);

// Blank out fenced code blocks and (unless keepInline) inline code spans, keeping line numbers
// intact. Headings keep their inline code: GitHub's anchor for "## Upgrading after a `git pull`"
// is #upgrading-after-a-git-pull.
function stripCode(text, keepInline) {
  const out = [];
  let fence = null;
  for (const line of text.split("\n")) {
    const m = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (fence) {
      if (m && m[1][0] === fence[0] && m[1].length >= fence.length) fence = null;
      out.push("");
      continue;
    }
    if (m) { fence = m[1]; out.push(""); continue; }
    out.push(keepInline ? line : line.replace(/(`+)[\s\S]*?\1/g, ""));
  }
  return out;
}

// GitHub's heading anchors: lowercase, drop punctuation and emoji, spaces become hyphens,
// and a repeated heading gets -1, -2, ...
function slug(heading) {
  const text = heading
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")   // a link or image keeps its text
    .replace(/<[^>]+>/g, "")                        // inline html
    .replace(/`/g, "")
    .trim()
    .toLowerCase();
  return text.replace(/[^\p{L}\p{M}\p{N}\p{Pc} -]/gu, "").replace(/ /g, "-");
}

const anchorCache = new Map();
function anchorsOf(file) {
  if (anchorCache.has(file)) return anchorCache.get(file);
  const set = new Set();
  const seen = new Map();
  const raw = fs.readFileSync(file, "utf8");
  for (const line of stripCode(raw, true)) {
    const h = line.match(/^\s{0,3}#{1,6}\s+(.*?)\s*#*\s*$/);
    if (h) {
      const base = slug(h[1]);
      const n = seen.get(base) || 0;
      seen.set(base, n + 1);
      set.add(n === 0 ? base : base + "-" + n);
    }
  }
  // explicit anchors: <a id="x"> / <a name="x"> / id="x" on any tag
  for (const m of raw.matchAll(/\s(?:id|name)="([^"]+)"/g)) set.add(m[1]);
  anchorCache.set(file, set);
  return set;
}

let broken = 0;
function report(file, lineNo, target, why) {
  broken++;
  console.log(path.relative(root, file) + ":" + lineNo + ": " + target + " -- " + why);
}

for (const rel of files) {
  const file = path.resolve(root, rel);
  const lines = stripCode(fs.readFileSync(file, "utf8"));
  lines.forEach((line, i) => {
    const targets = [];
    for (const m of line.matchAll(/\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)/g)) targets.push(m[1]);
    for (const m of line.matchAll(/^\s{0,3}\[[^\]]+\]:\s*<?(\S+?)>?(?:\s+"[^"]*")?\s*$/g)) targets.push(m[1]);
    for (const m of line.matchAll(/<(?:img|a|source)\b[^>]*?\s(?:src|href|srcset)="([^"]+)"/g)) targets.push(m[1]);
    for (const target of targets) {
      if (/^[a-z][a-z0-9+.-]*:/i.test(target)) continue;   // http:, https:, mailto:, ...
      const hash = target.indexOf("#");
      const p = decodeURI(hash >= 0 ? target.slice(0, hash) : target);
      const frag = hash >= 0 ? decodeURIComponent(target.slice(hash + 1)) : "";
      let dest = file;
      if (p !== "") {
        if (p.startsWith("/")) { report(file, i + 1, target, "absolute path (use a relative link)"); continue; }
        dest = path.resolve(path.dirname(file), p);
        if (dest !== root && !dest.startsWith(root + path.sep)) { report(file, i + 1, target, "points outside the repo"); continue; }
        if (!fs.existsSync(dest)) { report(file, i + 1, target, "no such file"); continue; }
      }
      if (frag !== "" && /\.md$/i.test(dest) && fs.statSync(dest).isFile() && !anchorsOf(dest).has(frag)) {
        report(file, i + 1, target, "no heading #" + frag + " in " + path.relative(root, dest));
      }
    }
  });
}

if (broken) { console.log(broken + " broken link(s)"); process.exit(1); }
console.log("all links resolve in " + files.length + " file(s)");
