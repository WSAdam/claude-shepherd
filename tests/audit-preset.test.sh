#!/usr/bin/env bash
# audit-preset.test.sh - BEHAVIORAL: the find-only audit preset's own PreToolUse hook, run for real.
#
# 2026-09-29 (build program unit 38): Claude Code hands MCP servers its cwd as their root, so a
# playwright tool called with an explicit filename (browser_snapshot, browser_take_screenshot,
# browser_console_messages, browser_network_requests) writes that file into the audited repo, and
# no permission rule can see a tool's arguments. The preset's --settings carries a hook that denies
# any playwright call naming a file. This runs the exact command core.auditSpawnPlan ships, through
# `sh -c` as Claude Code runs a hook, against sample calls, and checks the settings and MCP config
# the panel writes are valid JSON. Side-effect-free: nothing is written outside a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT

# the plan for a sample project, as the panel encodes it (settings.json, mcp.json) + the hook command
lua - "$ROOT" "$TMP" <<'LUA'
local root, tmp = arg[1], arg[2]
local core = dofile(root .. "/cc-core.lua")
core.json = dofile(root .. "/tests/support/json.lua")
local plan = assert(core.auditSpawnPlan("/Users/u/Code/shop", "/Users/u", { roots = { "/Users/u/Code" } }))
local function put(name, s) local f = assert(io.open(tmp .. "/" .. name, "w")); f:write(s); f:close() end
put("settings.json", core.json.encode(plan.settings))
put("mcp.json", core.json.encode(plan.mcpConfig))
put("hook.sh", plan.settings.hooks.PreToolUse[1].hooks[1].command)
LUA

hook() { # <tool-input JSON> -> the hook's stdout (stdin is the whole PreToolUse payload)
  printf '{"session_id":"s1","hook_event_name":"PreToolUse","tool_name":"mcp__playwright__browser_snapshot","tool_input":%s}' "$1" \
    | sh -c "$(cat "$TMP/hook.sh")"
}

out="$(hook '{"filename":"src/app.ts"}')"
assert_eq "a playwright call naming a file is denied" "deny" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
assert_eq "...as a PreToolUse answer" "PreToolUse" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName' 2>/dev/null)"
assert_eq "...that tells the auditor to leave filename out" "yes" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'Leave filename out' && echo yes || echo no)"
out="$(hook '{"filename":""}')"
assert_eq "an empty filename is denied too (fail closed)" "deny" \
  "$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null)"
out="$(hook '{"depth":3}')"
assert_eq "a call with no filename passes silently (no decision, the rules decide)" "" "$out"
hook '{"url":"http://localhost:4102/"}' >/dev/null
assert_eq "...and the hook exits 0 (a non-zero exit would read as a hook error)" "0" "$?"

assert_eq "the settings the panel writes are valid JSON" "Bash" "$(jq -r '.permissions.deny[0]' "$TMP/settings.json" 2>/dev/null)"
assert_eq "...fencing the audited folder" "yes" \
  "$(jq -r '.permissions.deny[]' "$TMP/settings.json" | grep -qx 'Edit(//Users/u/Code/shop/\*\*)' && echo yes || echo no)"
assert_eq "...with the hook on every playwright tool" "mcp__playwright__.*" \
  "$(jq -r '.hooks.PreToolUse[0].matcher' "$TMP/settings.json" 2>/dev/null)"
assert_eq "the MCP config the panel writes runs playwright headless and isolated" "true" \
  "$(jq -r '.mcpServers.playwright.args | (index("--headless") != null) and (index("--isolated") != null)' "$TMP/mcp.json" 2>/dev/null)"

finish
