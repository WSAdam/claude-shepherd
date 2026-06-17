#!/usr/bin/env bash
# escaping.test.sh - XSS tripwire (R2-G). User-controlled group names and relabels flow
# into the panel webview via innerHTML; the ONLY defense is the JS esc() helper applied at
# each sink. This is a SOURCE-LEVEL tripwire, not a behavioral test -- the panel JS has no
# headless runtime in this Lua+bash suite. It fails if a known sink drops its esc() wrapper,
# or if esc() stops entity-encoding the HTML metacharacters. Reformatting a sink (e.g.
# `esc( it.group )`) can false-alarm; that's intentional -- re-verify the escape when you
# touch these lines. (A real behavioral test would need the headless-JS twin harness.)

. "$(dirname "$0")/lib.sh"

DASH="$ROOT/claude-dashboard.lua"
has() { grep -qF "$1" "$DASH" && echo yes || echo no; }

# 1. every user-controlled string reaches innerHTML through esc()
assert_eq "group filter chip label is esc()'d"  "yes" "$(has 'esc(g)')"
assert_eq "per-tile group tag is esc()'d"        "yes" "$(has 'esc(it.group)')"
assert_eq "tile display label/name is esc()'d"   "yes" "$(has 'esc(it.label')"
assert_eq "worklist item text is esc()'d"        "yes" "$(has 'esc(it.text')"

# 2. esc() itself still entity-encodes the HTML metacharacters (not gutted to a no-op)
assert_eq "esc() encodes &"  "yes" "$(has '.replace(/&/g,"&amp;")')"
assert_eq "esc() encodes <"  "yes" "$(has '.replace(/</g,"&lt;")')"
assert_eq "esc() encodes >"  "yes" "$(has '.replace(/>/g,"&gt;")')"
assert_eq 'esc() encodes "'  "yes" "$(has '.replace(/"/g,"&quot;")')"

# 3. Deny-list (the allow-list above can only name KNOWN sinks): no user-controlled STRING
# field may be concatenated RAW into a panel-JS HTML string. The idiom is '...'+EXPR+'...',
# so a safe sink reads '+esc(it.group)+' and an unsafe one '+it.group+' -- flag any '+ <field>
# not wrapped in esc(). The list is the user-controlled STRING fields ONLY; it is deliberately
# NOT auto-derived from every it.* because numeric fields (it.queue / it.since /
# it.context_tokens) are concatenated raw-but-safe into the meta string and would false-
# positive. Add a NEW user-controlled string field here when you render one.
# TODO(headless-js): replace this single-line source grep with the headless-JS twin harness
# -- it cannot see a sink whose field and its esc() are split across lines.
SINK_RE="'[[:space:]]*\+[[:space:]]*(it\.(group|label|name|cwd|projectKey)\b|\bg\b)"
raw_sinks="$(grep -nE "$SINK_RE" "$DASH" || true)"
assert_eq "no user field concatenated RAW into panel HTML (must be esc()'d)" "" "$raw_sinks"

# Positive control: prove the grep actually FIRES on a known-bad sink, so a broken regex
# can't make the absence-assert above pass vacuously (a no-op tripwire is worse than none).
tmp="$(mktemp)"; cp "$DASH" "$tmp"; printf '%s\n' "x.innerHTML='<b>'+it.group+'</b>';" >> "$tmp"
planted="$(grep -cE "$SINK_RE" "$tmp")"; rm -f "$tmp"
assert_eq "deny-list grep fires on a planted raw sink (no vacuous pass)" "1" "$planted"

finish
