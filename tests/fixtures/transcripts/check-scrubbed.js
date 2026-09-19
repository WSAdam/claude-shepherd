#!/usr/bin/env node
// check-scrubbed.js - prove a transcript fixture holds nothing readable. The repo is public and
// the fixtures are cut from real sessions, so every word in one must be either a mask (runs of
// x, the three non-ASCII fillers) or listed in vocabulary.txt -- Claude Code's own record keys,
// types and tags, short enough to read through by eye. A raw transcript dropped in here fails on
// its first sentence.
//
//   node check-scrubbed.js <fixture.jsonl>...     exit 1 and name the strangers
//   node check-scrubbed.js --list <fixture>...    print every non-mask word (to review a new one)
"use strict";
const fs = require("fs");
const path = require("path");

const FILLERS = new Set(["é", "文", "\u{1D431}"]);

// Every word in `text` that is neither a mask nor in the vocabulary, deduplicated, in order.
function checkText(text, vocabularyText) {
  const allowed = new Set(vocabularyText.split(/\s+/).filter(Boolean));
  const seen = new Set(), strangers = [];
  const note = (w) => { if (!seen.has(w)) { seen.add(w); strangers.push(w); } };
  // JSON escapes are not words: the n of \n would otherwise glue itself to the mask after it
  const body = text.replace(/\\(?:u[0-9a-fA-F]{4}|.)/g, " ");
  for (const word of body.match(/[A-Za-z]+/g) || []) {
    if (/^x+$/.test(word) || allowed.has(word)) continue;
    note(word);
  }
  for (const ch of body) {
    if (ch.codePointAt(0) >= 128 && /[\p{L}\p{N}\p{M}]/u.test(ch) && !FILLERS.has(ch)) note(ch);
  }
  return strangers;
}

if (require.main === module) {
  const args = process.argv.slice(2);
  const list = args[0] === "--list";
  const files = list ? args.slice(1) : args;
  const vocabulary = list ? "" : fs.readFileSync(path.join(__dirname, "vocabulary.txt"), "utf8");
  let bad = 0;
  for (const f of files) {
    const strangers = checkText(fs.readFileSync(f, "utf8"), vocabulary);
    if (list) { strangers.forEach((w) => console.log(w)); continue; }
    if (strangers.length) {
      bad = 1;
      console.log("❌ " + f + ": " + strangers.length + " readable word(s), e.g. " + strangers.slice(0, 8).join(" "));
    } else {
      console.log("✅ " + f + ": nothing readable");
    }
  }
  process.exit(bad);
}
module.exports = { checkText };
