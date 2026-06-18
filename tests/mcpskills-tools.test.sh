#!/usr/bin/env bash
# mcpskills-tools.test.sh - source-level wiring tripwire for the "CLI tools" section
# of the 🔌 MCPs & Skills viewer (the pure card-shaping is behaviorally tested in
# core.test.lua: cliToolCards / CLI_TOOLS). Like escaping.test.sh + worklist-ui.test.sh,
# the panel JS has no headless runtime here, so this asserts the WIRING end-to-end:
# the Lua status probe -> payload -> JS render. Fails if a leg is silently dropped.

. "$(dirname "$0")/lib.sh"

DASH="$ROOT/claude-dashboard.lua"
has() { grep -qF "$1" "$DASH" && echo yes || echo no; }

# ---- Lua: probe real tool paths and ship them in the viewer payload ----------------
# FX.cliToolStatus resolves each tool via the SAME resolveBin the app uses to actually
# run rg/fd, so the shown status matches what would really be used.
assert_eq "FX.cliToolStatus resolves via resolveBin" "yes" "$(has 'local p = resolveBin(t.bin)')"
assert_eq "status maps over the core CLI_TOOLS catalog" "yes" "$(has 'ipairs(core.CLI_TOOLS)')"
assert_eq "shapes status through pure core.cliToolCards" "yes" "$(has 'return core.cliToolCards(resolved)')"
# The viewer payload carries the tool list to the webview.
assert_eq "mcpSkillsPayload includes tools" "yes" "$(has 'tools = FX.cliToolStatus()')"

# ---- JS: render a "CLI tools" section from d.tools ----------------------------------
assert_eq "JS defines a mkToolRow renderer"   "yes" "$(has 'function mkToolRow(t){')"
assert_eq "ccMcpSkills reads d.tools"          "yes" "$(has 'var tools = Array.isArray(d.tools) ? d.tools : [];')"
assert_eq "renders a CLI tools section header" "yes" "$(has 'CLI tools <span class="mk-count">')"
assert_eq "each tool row goes through mkToolRow" "yes" "$(has 'tools.forEach(function(t){ html += mkToolRow(t); });')"
# Installed -> green chip + path; missing -> the POSIX fallback.
assert_eq "row shows installed vs missing status" "yes" "$(has 't.installed ? "installed" : "missing"')"
assert_eq "missing row shows its fallback tool"   "yes" "$(has 'falls back to')"

# ---- XSS: tool fields reach innerHTML via esc() (system-derived, but escaped) -------
assert_eq "tool name is esc()'d" "yes" "$(has 'esc(t.name||"?")')"
assert_eq "tool path is esc()'d" "yes" "$(has 'esc(t.path || "")')"

# Positive control: prove `has` distinguishes present/absent (no vacuous pass).
assert_eq "control: a token that cannot exist is absent" "no" "$(has 'mk-tool-token-does-not-exist-zzz')"

finish
