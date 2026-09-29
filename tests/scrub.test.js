// scrub.test.js - the transcript scrubber (cc-scrub.js) and the fixture cutter that wraps it.
//
// 2026-09-29: the scrubber became the one both tests/fixtures/transcripts/scrub.js (by hand, into
// the public repo) and Shepherd's "Capture as scenario" (a live card, into ~/.claude/cc-scenarios/)
// run, so it moved to the repo root and ships with the hooks. It now keeps three things the
// detectors read that it used to mask: an assistant record's attributionSkill, the words a denied
// tool result is recognised by, and `git commit` in a Bash command (a turn that committed reads
// "done"). Each is checked here against a readable transcript built on the spot; nothing here
// reads ~/.claude.
//
// Usage: node tests/scrub.test.js
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { execFileSync, spawnSync } = require("child_process");

const ROOT = path.join(__dirname, "..");
const SCRUB = path.join(ROOT, "cc-scrub.js");
const FIXTURE_CUTTER = path.join(ROOT, "tests/fixtures/transcripts/scrub.js");

let run = 0, failed = 0;
function check(name, cond) {
  run++;
  if (cond) { console.log("ok   - " + name); }
  else { failed++; console.log("FAIL - " + name); }
}
function eq(name, got, want) { check(name + "  (got=" + JSON.stringify(got) + " want=" + JSON.stringify(want) + ")", got === want); }

const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "cc-scrub-test-"));
const RAW = path.join(TMP, "raw.jsonl");
const DENIAL = "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.";
const records = [
  { type: "user", origin: { kind: "human" }, timestamp: "2026-09-29T10:00:00.250Z", sessionId: "3f1e2d4c-1111-4222-8333-444455556666",
    message: { role: "user", content: [{ type: "text", text: "please rename the zebra module for Quokka Ltd" }] } },
  { type: "assistant", attributionSkill: "artifact-design", timestamp: "2026-09-29T10:00:05.000Z",
    message: { role: "assistant", model: "claude-opus-5-5", content: [
      { type: "tool_use", id: "toolu_01AbCdEf", name: "Bash", input: { command: "git commit -m \"zebra quokka rename\"", description: "Commit the zebra rename" } }] } },
  { type: "user", timestamp: "2026-09-29T10:00:06.000Z",
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_01AbCdEf", content: "[main 1a2b3c4] zebra quokka rename" }] } },
  { type: "assistant", attributionSkill: "rune:build", timestamp: "2026-09-29T10:00:08.000Z",
    message: { role: "assistant", model: "claude-opus-5-5", content: [
      { type: "tool_use", id: "toolu_02GhIjKl", name: "Edit", input: { file_path: "/Users/someone/zebra/auth.ts", old_string: "a", new_string: "b" } }] } },
  { type: "user", timestamp: "2026-09-29T10:00:09.000Z",
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_02GhIjKl", is_error: true, content: DENIAL }] } },
  { type: "user", timestamp: "2026-09-29T10:00:09.000Z",
    message: { role: "user", content: [{ type: "tool_result", tool_use_id: "toolu_02GhIjKl", content: "zebra was rejected by the linter" }] } },
  { type: "system", subtype: "stop_hook_summary", timestamp: "2026-09-29T10:00:10.000Z", hookCount: 1 },
];
const rawText = records.map((r) => JSON.stringify(r)).join("\n") + "\n";
fs.writeFileSync(RAW, rawText);

// ---- the scrubber, run the way Capture as scenario runs it -----------------------------------
const OUT = path.join(TMP, "w.jsonl");
const LABEL = path.join(TMP, "w.label.json");
const since = Math.floor(Date.parse("2026-09-29T10:00:10Z") / 1000);
const cap = spawnSync("node", [SCRUB, "--src", RAW, "--out", OUT, "--tail", "65536", "--label", LABEL,
  "--since", String(since), "--status", "done", "--said", JSON.stringify({ turn: "done", error: false })], { encoding: "utf8" });
eq("capture: the scrubber exits 0", cap.status, 0);
const out = fs.existsSync(OUT) ? fs.readFileSync(OUT, "utf8") : "";
const lines = out.split("\n").filter(Boolean).map((l) => JSON.parse(l));
eq("capture: the whole (small) transcript is the window", lines.length, records.length);
eq("capture: every line keeps its byte length", out.split("\n").map((l) => Buffer.byteLength(l)).join(","),
  rawText.split("\n").map((l) => Buffer.byteLength(l)).join(","));
check("capture: the prompt is masked", !/zebra|quokka|rename|please/i.test(out));
eq("capture: an assistant record's attributionSkill is kept", lines[1] && lines[1].attributionSkill, "artifact-design");
eq("capture: ...a plugin skill's too", lines[3] && lines[3].attributionSkill, "rune:build");
const cmd = lines[1] && lines[1].message.content[0].input.command;
check("capture: a Bash command keeps `git commit`, so a turn that committed reads done  (" + cmd + ")",
  typeof cmd === "string" && cmd.startsWith("git commit -x \""));
eq("capture: ...its message masked", cmd, "git commit -x \"xxxxx xxxxxx xxxxxx\"");
const desc = lines[1] && Object.values(lines[1].message.content[0].input)[1];   // its key, "description", is masked too
eq("capture: ...and the command's description masked whole", desc, "xxxxxx xxx xxxxx xxxxxx");
const denial = lines[4] && lines[4].message.content[0].content;
check("capture: a denied tool result keeps the words it is recognised by  (" + denial + ")",
  typeof denial === "string" && denial.includes("doesn't want to proceed") && denial.includes("rejected"));
check("capture: ...and masks every other word of it", typeof denial === "string" && !/file|edit|written|STOP|user/i.test(denial));
eq("capture: a result that isn't an error keeps none of them", lines[5] && lines[5].message.content[0].content,
  "xxxxx xxx xxxxxxxx xx xxx xxxxxx");
const input = lines[3] && lines[3].message.content[0].input;
check("capture: a tool input's file_path key is kept (the loop and file detectors read it)",
  out.includes('"input":{"file_path":"/xxxxx/xxxxxxx/xxxxx/xxxx.xx","xxx_xxxxxx":"x","xxx_xxxxxx":"x"}'));
eq("capture: ...its value masked to the same shape", input && input.file_path, "/xxxxx/xxxxxxx/xxxxx/xxxx.xx");
eq("capture: ids are renumbered (the session id took 1)", lines[1] && lines[1].message.content[0].id, "toolu_00000002");
eq("capture: timestamps are rebased to 2026-01-01", lines[0] && lines[0].timestamp, "2026-01-01T00:00:00.000Z");

const label = fs.existsSync(LABEL) ? JSON.parse(fs.readFileSync(LABEL, "utf8")) : {};
eq("label: names the window beside it", label.fixture, "w.jsonl");
eq("label: the tail it was cut for, read back the way the tick reads it", label.window, 65536);
eq("label: when the card last read done, on the window's rebased clock", label.since, "2026-01-01T00:00:10Z");
eq("label: how the card read", label.status, "done");
eq("label: what Shepherd's detectors said on the raw transcript", label.said && label.said.turn, "done");
eq("label: one blank verdict per detector, to fill in",
  Object.keys(label.expect || {}).join(",") + "|" + Object.values(label.expect || {}).map(String).join(","),
  "turn,resumed,awaiting,interrupted,error,looping|null,null,null,null,null,null");
eq("label: ...and a note", label.note, "");
check("label: carries no readable word of the session", !/zebra|quokka|someone|Users/i.test(JSON.stringify(label)));

// ---- shipped alone: ~/.claude holds cc-scrub.js with nothing beside it -------------------------
const ALONE = path.join(TMP, "alone");
fs.mkdirSync(ALONE);
fs.copyFileSync(SCRUB, path.join(ALONE, "cc-scrub.js"));
const alone = spawnSync("node", [path.join(ALONE, "cc-scrub.js"), "--src", RAW, "--out", path.join(ALONE, "a.jsonl"), "--tail", "65536"],
  { encoding: "utf8", cwd: ALONE });
eq("installed: cc-scrub.js runs on its own, as make install leaves it in ~/.claude", alone.status, 0);
eq("installed: ...writing the same window", fs.existsSync(path.join(ALONE, "a.jsonl")) && fs.readFileSync(path.join(ALONE, "a.jsonl"), "utf8"), out);

// ---- the fixture cutter: the same scrub, and it refuses a word vocabulary.txt doesn't know ----
const FX = path.join(TMP, "fx.jsonl");
const cut = spawnSync("node", [FIXTURE_CUTTER, "--src", RAW, "--out", FX, "--tail", "65536"], { encoding: "utf8" });
eq("fixture cutter: refuses a window with a word outside vocabulary.txt (a skill name here)", cut.status, 1);
check("fixture cutter: ...writes nothing", !fs.existsSync(FX));
check("fixture cutter: ...and names the stranger", /artifact|rune|build/.test(cut.stderr || ""));
const usage = spawnSync("node", [FIXTURE_CUTTER], { encoding: "utf8" });
check("fixture cutter: its usage line is the command the README shows",
  (usage.stderr || "").includes("--src <jsonl> --out <fixture> (--head N | --tail N)"));
const readme = fs.readFileSync(path.join(ROOT, "tests/fixtures/transcripts/README.md"), "utf8");
check("README: 'Regenerating' shows the cutter's real flags, not the old --bytes",
  readme.includes("node tests/fixtures/transcripts/scrub.js --src") && !readme.includes("[--bytes N]"));

try { execFileSync("rm", ["-r", TMP]); } catch (_) { /* a temp dir */ }
console.log("-- scrub.test.js: " + run + " run, " + failed + " failed --");
process.exit(failed === 0 ? 0 : 1);
