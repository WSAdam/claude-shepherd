#!/usr/bin/env node
// scrub.js - cut a fixture out of a REAL Claude Code transcript for tests/transcript-replay.test.lua
// and tests/scenario-replay.test.lua. Run by hand; it never runs inside the suite (it needs a
// private transcript, and the suite needs nothing but the committed fixtures).
//
//   node tests/fixtures/transcripts/scrub.js --src ~/.claude/projects/<p>/<id>.jsonl \
//        --out tests/fixtures/transcripts/<name>.jsonl (--head BYTES | --tail BYTES) \
//        [--end-at OFFSET | --end-after WHAT [--then TYPE]] [--tear BYTES]
//
// The window and the scrub are cc-scrub.js's (the repo root; its header documents every flag and
// every rule): 2026-09-29 it moved there so Shepherd's "Capture as scenario" runs the same rules
// from ~/.claude. This file adds the one thing a fixture for a public repo needs on top:
// check-scrubbed.js proves the output holds no word outside vocabulary.txt, and nothing is
// written when one survives.
"use strict";
const fs = require("fs");
const path = require("path");
const { cutWindow, parseArgs, USAGE } = require(path.join(__dirname, "..", "..", "..", "cc-scrub.js"));
const { checkText } = require("./check-scrubbed.js");

function main(argv) {
  const opt = parseArgs(argv);
  if (!opt.src || !opt.out || (!opt.head && !opt.tail)) {
    console.error("usage: scrub.js " + USAGE);
    process.exit(2);
  }
  console.log("🚀 scrubbing a window of " + path.basename(opt.src));
  const cut = cutWindow(opt);
  const vocabulary = fs.readFileSync(path.join(__dirname, "vocabulary.txt"), "utf8");
  const strangers = checkText(cut.out.toString("utf8"), vocabulary);
  if (strangers.length) {
    console.error("❌ not written: " + strangers.length + " word(s) outside vocabulary.txt survived the scrub: " +
      strangers.slice(0, 80).join(" "));
    console.error("   If they are Claude Code's own (a new record key or type), add them to vocabulary.txt by hand.");
    process.exit(1);
  }
  fs.writeFileSync(opt.out, cut.out);
  console.log("✅ " + opt.out + ": " + cut.out.length + " bytes, " + cut.lines + " lines, bytes " + cut.from + "-" + cut.to + " of " + cut.total);
}

if (require.main === module) {
  try { main(process.argv); } catch (e) { console.error("❌ " + e.message); process.exit(1); }
}
