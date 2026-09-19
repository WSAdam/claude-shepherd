#!/usr/bin/env node
// scrub.js - cut a window out of a REAL Claude Code transcript and scrub every readable string
// out of it, for tests/transcript-replay.test.lua. Run by hand; it never runs inside the suite
// (it needs a private transcript, and the suite needs nothing but the committed fixtures).
//
//   node tests/fixtures/transcripts/scrub.js --src ~/.claude/projects/<p>/<id>.jsonl \
//        --out tests/fixtures/transcripts/<name>.jsonl (--head BYTES | --tail BYTES) \
//        [--end-at OFFSET | --end-after WHAT [--then TYPE]] [--tear BYTES]
//
//   --head N        the first N bytes, as FX.sessionFirstPrompt reads them (f:read(16384))
//   --tail N        the last N bytes plus a partial first line for FX.readTail to drop
//   --end-at O      treat the file as O bytes long: the transcript as it was at that moment
//   --end-after W   the same, O = the end of a record: `type[/subtype][:N]` (the Nth, default the
//                   last), `interrupt[:N]` (a turn that was stopped), `longest` (the biggest line)
//   --then T        ...and on to the end of the next `type[/subtype]` record after that
//   --tear B        with --tail: stop B bytes short of the end, inside the last record -- a read
//                   that raced the writer
//
// What survives: record shapes, key order, line order, torn lines and EVERY line's byte length
// (so a window cut at byte N tears the same record at the same place as the real file). What
// doesn't: every letter and digit of every string becomes x / 0 (a non-ASCII letter becomes a
// filler of the same UTF-8 length), ids are renumbered, timestamps are rebased to 2026-01-01 with
// their gaps kept, and any key this file doesn't know is masked too (file-history records key
// objects by file path). The few strings the parsers read -- record and block types, roles,
// models, built-in tool names, the interrupt marker, Claude Code's own <command-*>/<ide_*> tags,
// generic API-error words -- are kept by the lists below. check-scrubbed.js then proves the
// output holds no word outside vocabulary.txt, and this script refuses to write one that does.
"use strict";
const fs = require("fs");
const path = require("path");
const { checkText } = require("./check-scrubbed.js");

// ---- what is kept ------------------------------------------------------------------------------
const KNOWN_KEYS = new Set(`type subtype sessionId version content timestamp cwd parentUuid
  isSidechain uuid userType entrypoint gitBranch slug message role id model requestId stop_reason
  stop_sequence stop_details usage input_tokens output_tokens cache_creation_input_tokens
  cache_read_input_tokens cache_creation ephemeral_5m_input_tokens ephemeral_1h_input_tokens
  service_tier inference_geo server_tool_use web_search_requests web_fetch_requests iterations
  speed output_tokens_details thinking_tokens text name tool_use_id input toolUseResult is_error
  isMeta thinking signature aiTitle customTitle lastPrompt leafUuid level error formatted
  attachment toolUseID durationMs isApiErrorMessage isCompactSummary isVisibleInTranscriptOnly
  promptId sourceToolAssistantUUID caller apiBlockIndex agentId container context_management
  diagnostics effort perTurnEffort permissionMode operation mode messageId snapshot
  isSnapshotUpdate trackedFileBackups hookName hookEvent stdout stderr exitCode command hookCount
  hookInfos hookErrors preventedContinuation stopReason hasOutput retryInMs retryAttempt
  maxRetries rateLimits isNetworkDown connection isSSLError code cause status headers source
  media_type data summary`.split(/\s+/).filter(Boolean));

// Below these keys nothing is structural: tool inputs/results, attachments, snapshots.
const FREE_FORM = new Set(["input", "toolUseResult", "attachment", "snapshot", "data", "hookInfos", "diagnostics"]);

// A value under one of these keys is kept when it is a bare identifier (never inside FREE_FORM).
const IDENT_VALUE_KEYS = new Set(["type", "subtype", "role", "stop_reason", "level", "userType",
  "entrypoint", "service_tier", "permissionMode", "operation", "mode", "speed", "effort",
  "inference_geo", "hookEvent", "media_type"]);
const IDENT = /^[A-Za-z][A-Za-z0-9_\-\/]{0,40}$/;
const MODEL = /^(claude-[a-z0-9.\-]{1,40}|<synthetic>)$/;
const VERSION = /^\d+\.\d+\.\d+$/;

const BUILTIN_TOOLS = new Set(`Bash Read Edit Write Grep Glob Agent Task TodoWrite ExitPlanMode
  EnterPlanMode AskUserQuestion ToolSearch Skill WebFetch WebSearch NotebookEdit EnterWorktree
  ExitWorktree SendMessage Monitor TaskOutput TaskStop`.split(/\s+/).filter(Boolean));
const BUILTIN_SLASH = new Set(["/clear", "/compact", "/model", "/resume", "/config", "/cost", "/help", "/status"]);

const INTERRUPTS = new Set(["[Request interrupted by user]", "[Request interrupted by user for tool use]"]);
const OWN_TAG = /(<\/?(?:ide_[a-z_]+|local-command-[a-z\-]+|command-[a-z\-]+|system-reminder)>)/;

// Words an API error may keep (core.classifyError reads them); every other word in it is masked.
const ERROR_WORDS = new Set(`api error connection overloaded timeout timed out request rate limit
  internal server econnreset econnrefused etimedout enotfound epipe socket hang up network fetch
  failed bad gateway service unavailable invalid exceeded retrying`.split(/\s+/).filter(Boolean));
const ERROR_CODES = new Set(["400", "401", "402", "403", "408", "413", "429", "500", "502", "503", "504", "529"]);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const API_ID = /^(msg|toolu|srvtoolu|req)_([A-Za-z0-9]+)$/;
const ISO = /^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?Z$/;
const REBASE_TO = Date.UTC(2026, 0, 1);

// ---- masking -----------------------------------------------------------------------------------
function maskChar(ch) {
  const cp = ch.codePointAt(0);
  if (cp < 128) {
    if ((ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z")) return "x";   // case is a shape too: drop it
    if (ch >= "0" && ch <= "9") return "0";
    return ch;
  }
  if (!/[\p{L}\p{N}\p{M}]/u.test(ch)) return ch;          // punctuation, symbols, emoji: no text in them
  return cp < 0x800 ? "é" : cp < 0x10000 ? "文" : "\u{1D431}";   // same UTF-8 length
}
function mask(s) { let out = ""; for (const ch of s) out += maskChar(ch); return out; }

function maskKeepingWords(s, words, codes) {
  return s.replace(/[A-Za-z]+|\d+|[^A-Za-z\d]+/g, (tok) =>
    (words.has(tok.toLowerCase()) || codes.has(tok)) ? tok : mask(tok));
}

function maskKeepingOwnTags(s) {
  const parts = s.split(OWN_TAG);
  let out = "";
  for (let i = 0; i < parts.length; i++) {
    if (i % 2 === 1) { out += parts[i]; continue; }
    const inName = i > 0 && parts[i - 1] === "<command-name>";
    out += (inName && BUILTIN_SLASH.has(parts[i].trim())) ? parts[i] : mask(parts[i]);
  }
  return out;
}

function makeState() { return { ids: new Map(), firstTs: null }; }

function renumber(st, kind, value, width, render) {
  const k = kind + ":" + value;
  if (!st.ids.has(k)) st.ids.set(k, st.ids.size + 1);
  return render(String(st.ids.get(k)).padStart(width, "0"));
}

function scrubString(s, key, ctx, st) {
  if (UUID.test(s)) return renumber(st, "uuid", s.toLowerCase(), 12, (n) => "00000000-0000-4000-8000-" + n);
  const id = API_ID.exec(s);
  if (id) return renumber(st, id[1], s, id[2].length, (n) => id[1] + "_" + n.slice(-id[2].length));
  const iso = ISO.exec(s);
  if (iso) {
    const t = Date.parse(iso[1] + "Z");
    if (st.firstTs === null) st.firstTs = t;
    return new Date(REBASE_TO + (t - st.firstTs)).toISOString().slice(0, 19) + (iso[2] ? iso[2].replace(/\d/g, "0") : "") + "Z";
  }
  if (!ctx.free) {
    if (IDENT_VALUE_KEYS.has(key) && IDENT.test(s)) return s;
    if (key === "model" && MODEL.test(s)) return s;
    if (key === "version" && VERSION.test(s)) return s;
    if (key === "name" && ctx.block === "tool_use" && BUILTIN_TOOLS.has(s)) return s;
    if (INTERRUPTS.has(s)) return s;
    if (ctx.apiError) return maskKeepingWords(s, ERROR_WORDS, ERROR_CODES);
    return maskKeepingOwnTags(s);
  }
  return mask(s);
}

// Serialised by hand, not through an object: two masked keys may collide, and both must survive
// or the line's byte length changes.
function ser(v, key, ctx, st) {
  if (typeof v === "string") return JSON.stringify(scrubString(v, key, ctx, st));
  if (v === null || typeof v !== "object") return JSON.stringify(v);
  if (Array.isArray(v)) return "[" + v.map((x) => ser(x, key, ctx, st)).join(",") + "]";
  const inner = { ...ctx, block: (!ctx.free && typeof v.type === "string") ? v.type : ctx.block };
  return "{" + Object.keys(v).map((k) => {
    const kk = KNOWN_KEYS.has(k) ? k : mask(k);
    return JSON.stringify(kk) + ":" + ser(v[k], k, { ...inner, free: ctx.free || FREE_FORM.has(k) }, st);
  }).join(",") + "}";
}

function scrubLine(line, st) {
  const rec = JSON.parse(line);
  const apiError = rec && (rec.subtype === "api_error" || rec.isApiErrorMessage === true);
  const out = ser(rec, "", { free: false, apiError, block: null }, st);
  if (Buffer.byteLength(out) !== Buffer.byteLength(line)) {
    throw new Error("a scrubbed line changed size (" + Buffer.byteLength(line) + " -> " + Buffer.byteLength(out) +
      " bytes); the window would tear somewhere else. Record type: " + String(rec && rec.type));
  }
  return out;
}

// ---- the window --------------------------------------------------------------------------------
function lineSpans(buf) {   // [start, end) of every line, end excluding the newline
  const spans = []; let pos = 0;
  while (pos < buf.length) {
    let nl = buf.indexOf(10, pos);
    if (nl < 0) nl = buf.length;
    spans.push([pos, nl]); pos = nl + 1;
  }
  return spans;
}

function isInterrupt(rec) {
  const c = rec.type === "user" && rec.message && rec.message.content;
  const first = typeof c === "string" ? c : (Array.isArray(c) && c.length === 1 && c[0] && c[0].text);
  return typeof first === "string" && first.startsWith("[Request interrupted by user");
}

// The byte just past a record: `type[/subtype][:N]` (the Nth, default the last), `interrupt[:N]`
// (a turn Adam stopped) or `longest` (the biggest line -- an oversized tool payload). Searching
// starts at `after`, so --then can name the next record of a kind.
function endAfter(buf, spans, spec, after) {
  const m = /^([^:]+)(?::(\d+))?$/.exec(spec);
  const want = m[1].split("/"), nth = m[2] ? Number(m[2]) : 0;
  const hits = [];
  let longest = [0, -1];
  for (const [a, b] of spans) {
    if (a < (after || 0)) continue;
    if (b - a > longest[0]) longest = [b - a, b + 1];
    if (want[0] === "longest") continue;
    const line = buf.toString("utf8", a, b);
    if (want[0] !== "interrupt" && !line.includes('"type":"' + want[0] + '"')) continue;
    let rec; try { rec = JSON.parse(line); } catch (_) { continue; }
    if (want[0] === "interrupt" ? isInterrupt(rec) : (rec.type === want[0] && (!want[1] || rec.subtype === want[1]))) hits.push(b + 1);
  }
  if (want[0] === "longest") return longest[1];
  if (!hits.length) throw new Error("no " + spec + " record in the source");
  return after ? hits[0] : nth ? hits[nth - 1] : hits[hits.length - 1];
}

function main(argv) {
  const opt = {};
  for (let i = 2; i < argv.length; i += 2) opt[argv[i].replace(/^--/, "")] = argv[i + 1];
  if (!opt.src || !opt.out || (!opt.head && !opt.tail)) {
    console.error("usage: scrub.js --src <jsonl> --out <fixture> (--head N | --tail N) [--end-at O | --end-after TYPE[/SUB][:N]] [--tear B]");
    process.exit(2);
  }
  console.log("🚀 scrubbing a window of " + path.basename(opt.src));
  const buf = fs.readFileSync(opt.src);
  const spans = lineSpans(buf);
  let end = buf.length;
  if (opt["end-at"]) end = Number(opt["end-at"]);
  if (opt["end-after"]) end = endAfter(buf, spans, opt["end-after"]);
  if (opt.then) end = endAfter(buf, spans, opt.then, end);
  end -= Number(opt.tear || 0);
  // 1KB of lead-in: FX.readTail seeks to size-N and drops the partial line it lands in.
  const from = opt.head ? 0 : Math.max(0, end - Number(opt.tail) - 1024);
  const to = opt.head ? Math.min(Number(opt.head), end) : end;

  const st = makeState();
  const pieces = [];
  for (const [a, b] of spans) {
    if (b < from || a >= to) continue;
    const scrubbed = Buffer.from(scrubLine(buf.toString("utf8", a, b), st) + "\n");
    pieces.push(scrubbed.subarray(Math.max(from, a) - a, Math.min(to, b + 1) - a));
  }
  const out = Buffer.concat(pieces);
  if (out.length !== to - from) throw new Error("window size drifted: " + out.length + " != " + (to - from));

  const vocabulary = fs.readFileSync(path.join(__dirname, "vocabulary.txt"), "utf8");
  const strangers = checkText(out.toString("utf8"), vocabulary);
  if (strangers.length) {
    console.error("❌ not written: " + strangers.length + " word(s) outside vocabulary.txt survived the scrub: " +
      strangers.slice(0, 80).join(" "));
    console.error("   If they are Claude Code's own (a new record key or type), add them to vocabulary.txt by hand.");
    process.exit(1);
  }
  fs.writeFileSync(opt.out, out);
  console.log("✅ " + opt.out + ": " + out.length + " bytes, " + pieces.length + " lines, bytes " + from + "-" + to + " of " + buf.length);
}

if (require.main === module) {
  try { main(process.argv); } catch (e) { console.error("❌ " + e.message); process.exit(1); }
}
module.exports = { mask, scrubLine, makeState };
