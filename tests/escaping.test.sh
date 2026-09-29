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
# user-stories.md content is fully user-authored -> both the story TEXT and the ## area
# headings must be esc()'d before reaching the panel innerHTML (renderStories).
assert_eq "user-story text is esc()'d"           "yes" "$(has 'esc(blk.text')"
assert_eq "user-story area heading is esc()'d"   "yes" "$(has 'esc(g.area)')"
# commit stats (2026-09-25): commit subjects are anyone's text, and project names are relabels
assert_eq "commit subject is esc()'d"            "yes" "$(has 'esc(c.subject')"
assert_eq "commit project name is esc()'d"       "yes" "$(has 'esc(r.name')"
# pinned links (2026-09-29): a session wrote each chip's label and link (cc-pin.sh)
assert_eq "pin chip label is esc()'d"            "yes" "$(has 'esc(pn.label')"
assert_eq "pin chip link is esc()'d"             "yes" "$(has 'esc(pn.url)')"
# overlap radar (2026-09-29): its lines carry branch and file names, which anyone can pick
assert_eq "an Instances row's overlap line is esc()'d"      "yes" "$(has 'esc(im.overlap)')"
assert_eq "an idle worktree's overlap line is esc()'d"      "yes" "$(has 'esc(iw.overlap)')"
assert_eq "the project's merge order is esc()'d"            "yes" "$(has 'esc(p.mergeOrder)')"
# worktree leases (2026-09-29): the port and database path come from Shepherd's own registry,
# which is a file on disk all the same
assert_eq "a lease's port is esc()'d"                     "yes" "$(has 'esc(String(ls.port))')"
assert_eq "a lease's tooltip (its database path) is esc()'d" "yes" "$(has "title=\"'+esc(leaseTitle(ls))+'\"")"
# task packets (2026-09-29): a moved packet's line names cited paths, which anyone can type; it
# rides meta (esc()'d), and the packet form's result is set as text
assert_eq "a moved packet's line rides the esc()'d meta"   "yes" "$(has 'if(it.packetMoved){ meta = (meta ? meta + " · " : "") + "📦 " + it.packetMoved; }')"
assert_eq "the packet form's result is text, never HTML"   "yes" "$(has 'document.getElementById("pk-msg").textContent = ')"
# the decisions inbox (2026-09-29): a question, its default and its options were written by a
# session (cc-decide.sh), and the row names its session (a relabel) -- inboxRowsHtml's `r.`
assert_eq "an Inbox question is esc()'d"            "yes" "$(has 'esc(r.question)')"
assert_eq "an Inbox row's session name is esc()'d"  "yes" "$(has 'esc(r.session)')"
assert_eq "an Inbox row's project is esc()'d"       "yes" "$(has 'esc(r.project)')"
assert_eq "an Inbox question's default is esc()'d"  "yes" "$(has 'esc(r["default"])')"
assert_eq "an Inbox question's options are esc()'d" "yes" "$(has "inboxAct(event)\">' + esc(o) + '</button>'")"
# requirement ids (2026-09-29): a requirement's title and source are typed by hand, and the id is
# read back from ~/.claude/cc-reqs.json -- renderReqs' `rq.` never reaches HTML raw
assert_eq "a requirement's id is esc()'d"          "yes" "$(has 'esc(rq.id)')"
assert_eq "a requirement's title is esc()'d"       "yes" "$(has 'esc(rq.title)')"
assert_eq "a requirement's source is esc()'d"      "yes" "$(has 'esc(rq.source)')"
# cross-repo tickets (2026-09-29): a ticket's title, body, replies, closing note and every name on the
# board were written by sessions (cc-ticket.sh) -- ticketRowsHtml's `r.` fields; the card badge's
# tooltip carries the oldest title (tests/tickets-view.test.js runs the real renderer)
assert_eq "a ticket's title is esc()'d"          "yes" "$(has "<div class=\"ib-q\">' + esc(r.title)")"
assert_eq "a ticket's body is esc()'d"           "yes" "$(has "'<div class=\"tk-body\">' + esc(r.body)")"
assert_eq "a ticket's last reply is esc()'d"     "yes" "$(has "esc(r.last.by) + ': ' + esc(r.last.text)")"
assert_eq "a ticket's closing note is esc()'d"   "yes" "$(has "'<div class=\"tk-note\">Closing note: ' + esc(r.note)")"
assert_eq "the card's ticket tooltip is esc()'d" "yes" "$(has "'<span class=\"tk-b\" title=\"' + esc(tip)")"

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
# 2026-09-10 (project stacks): branch names, the stack name/key, chat titles and worktree
# paths are user-controlled too, and the Instances view builds its rows from `im.` (an
# instance) and `iw.` (an idle worktree) -- every one of those fields must be esc()'d.
# 2026-09-11 (ready to merge): a merge request's branch, summary, test claim and note are
# written by a session -- it.merge.* and an Instances row's `mg.` never reach HTML raw.
# 2026-09-11 (Shepherd answers): a held question and its answers were written by a session --
# it.askLine / it.askView and an Instances row's `ak.` never reach HTML raw either.
# 2026-09-29 (working-on label): the label, tool and skill come from a transcript --
# it.workingOn and workingOnHtml's `wk.` never reach HTML raw.
# 2026-09-29 (automation trace): a Trace row's session name, summary and reason come from a
# session or its queue -- traceRowHtml's `tr.` never reaches HTML raw.
# 2026-09-29 (pinned links): a pin's label and link were written by a session (cc-pin.sh) --
# it.pins and pinChipsHtml's `pn.` never reach HTML raw.
# 2026-09-29 (overlap radar): it.overlap carries branch and file names; so does p.mergeOrder.
# 2026-09-29 (worktree leases): it.lease and leaseBadge's `ls.` come from a file on disk.
# 2026-09-29 (requirement ids): renderReqs' `rq.` -- a requirement's id, title and source.
SINK_RE="'[[:space:]]*\+[[:space:]]*(it\.(group|label|name|cwd|projectKey|status|branch|stackName|stackKey|sessTitle|wtRoot|merge|askLine|askView|workingOn|pins|overlap|lease)\b|p\.mergeOrder\b|\b(im|iw|mg|ak|wk|pn|ls|rq|tr)\.[A-Za-z]+\b|\bg\b)"
raw_sinks="$(grep -nE "$SINK_RE" "$DASH" || true)"
assert_eq "no user field concatenated RAW into panel HTML (must be esc()'d)" "" "$raw_sinks"

# R2-17: the tile status reaches innerHTML twice (class token + label). The class
# must use a sanitized token, and the label must be esc()'d -- a hostile bridged
# status string is also clamped in core.parseStatusList, but pin both JS sinks so
# neither can silently re-open. The token is `est` (effStatus: the background-aware
# status -- done/idle + live agents -> "working"), still regex-sanitized here; the
# label routes through esc(statusWords(it)) (statusWords returns a safe literal or the
# raw status, which this esc() wraps before it reaches innerHTML).
assert_eq "tile status class uses a sanitized token (not raw status)" "yes" \
  "$(has 'var stCls = /^[a-z]+$/.test(est) ? est : "idle";')"
assert_eq "tile status class concatenates stCls, not raw status" "yes" "$(has '"tile s-" + stCls')"
assert_eq "tile status label is esc()'d at the sink" "yes" "$(has 'var label = esc(statusWords(it));')"

# Positive control: prove the grep actually FIRES on a known-bad sink, so a broken regex
# can't make the absence-assert above pass vacuously (a no-op tripwire is worse than none).
tmp="$(mktemp)"; cp "$DASH" "$tmp"; printf '%s\n' "x.innerHTML='<b>'+it.group+'</b>';" >> "$tmp"
planted="$(grep -cE "$SINK_RE" "$tmp")"; rm -f "$tmp"
assert_eq "deny-list grep fires on a planted raw sink (no vacuous pass)" "1" "$planted"
tmp="$(mktemp)"; cp "$DASH" "$tmp"; printf '%s\n' "html += '<span>' + im.folder + '</span>';" >> "$tmp"
planted="$(grep -cE "$SINK_RE" "$tmp")"; rm -f "$tmp"
assert_eq "deny-list grep fires on a planted raw Instances-row sink" "1" "$planted"
tmp="$(mktemp)"; cp "$DASH" "$tmp"; printf '%s\n' "html += '<i>' + mg.line + '</i>';" >> "$tmp"
planted="$(grep -cE "$SINK_RE" "$tmp")"; rm -f "$tmp"
assert_eq "deny-list grep fires on a planted raw merge-request sink" "1" "$planted"
review="$(sed -n '/^    function renderMerge(it){/,/^    }$/p' "$DASH")"
[ -n "$review" ] && got=found || got=missing
assert_eq "the merge review renderer exists" "found" "$got"
case "$review" in *innerHTML*) got=innerHTML ;; *) got=textContent ;; esac
assert_eq "the merge review fills itself with textContent only (never innerHTML)" "textContent" "$got"
tmp="$(mktemp)"; cp "$DASH" "$tmp"; printf '%s\n' "html += '<b>' + ak.question + '</b>';" >> "$tmp"
planted="$(grep -cE "$SINK_RE" "$tmp")"; rm -f "$tmp"
assert_eq "deny-list grep fires on a planted raw held-question sink" "1" "$planted"
tmp="$(mktemp)"; cp "$DASH" "$tmp"; printf '%s\n' "h += '<span>' + pn.label + '</span>';" >> "$tmp"
planted="$(grep -cE "$SINK_RE" "$tmp")"; rm -f "$tmp"
assert_eq "deny-list grep fires on a planted raw pin-chip sink" "1" "$planted"
tmp="$(mktemp)"; cp "$DASH" "$tmp"; printf '%s\n' "h = '<span>:' + ls.port + '</span>';" >> "$tmp"
planted="$(grep -cE "$SINK_RE" "$tmp")"; rm -f "$tmp"
assert_eq "deny-list grep fires on a planted raw lease sink" "1" "$planted"
tmp="$(mktemp)"; cp "$DASH" "$tmp"; printf '%s\n' "h += '<b>' + rq.title + '</b>';" >> "$tmp"
planted="$(grep -cE "$SINK_RE" "$tmp")"; rm -f "$tmp"
assert_eq "deny-list grep fires on a planted raw requirement sink" "1" "$planted"

# 2026-09-19 (audit ledger): the deny-list above is per-FIELD, so it could only ever see the
# prefixes someone remembered to add -- it knew it./im./iw./mg./ak. and not `e.` (a ledger
# event), which is how the redact button came to put e.id straight into an onclick: a JS
# string literal inside an HTML attribute, two nested contexts, neither escaped.
# This rule is per-SINK instead, so a new field name can't walk past it: no event-handler
# attribute anywhere in the panel may interpolate a bare property. An identifier that a
# handler needs rides in a data- attribute and is read back with getAttribute, the way the
# tile buttons already do it (data-key, data-stack). Indices, esc()'d and tplQuote()'d values
# are fine and stay -- it is the bare `+ thing.field` inside on*="..." that is banned.
HANDLER_RE="on[a-z]+=\\\\?\"[^\"]*'[[:space:]]*\+[[:space:]]*[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_]"
raw_handlers="$(grep -nE "$HANDLER_RE" "$DASH" || true)"
assert_eq "no event handler interpolates a bare property (use a data- attribute)" "" "$raw_handlers"
tmp="$(mktemp)"; cp "$DASH" "$tmp"
printf '%s\n' "html += '<button onclick=\"zap(\\'' + ev.id + '\\')\">z</button>';" >> "$tmp"
planted="$(grep -cE "$HANDLER_RE" "$tmp")"; rm -f "$tmp"
assert_eq "handler grep fires on a planted interpolated id (no vacuous pass)" "1" "$planted"
ask="$(sed -n '/^    function renderAsk(it){/,/^    }$/p' "$DASH")"
[ -n "$ask" ] && got=found || got=missing
assert_eq "the answer form renderer exists" "found" "$got"
case "$ask" in *innerHTML*) got=innerHTML ;; *) got=textContent ;; esac
assert_eq "the answer form fills itself with textContent only (never innerHTML)" "textContent" "$got"
# 2026-09-18 (batch outcomes): the batch review shows slugs, results and summary lines a session wrote.
batchr="$(sed -n '/^    function renderBatch(it){/,/^    }$/p' "$DASH")"
[ -n "$batchr" ] && got=found || got=missing
assert_eq "the batch review renderer exists" "found" "$got"
case "$batchr" in *innerHTML*) got=innerHTML ;; *) got=textContent ;; esac
assert_eq "the batch review fills itself with textContent only (never innerHTML)" "textContent" "$got"
case "$batchr" in *db-summary*) got=yes ;; *) got=no ;; esac
assert_eq "...its outcome summary included" "yes" "$got"
assert_eq "an answer label reaches an Instances row through esc()" "yes" "$(has "'\">' + esc(lbl) + '</button>'")"
assert_eq "the stack name reaches the card through esc()" "yes" "$(has 'esc(it.stackName)')"
assert_eq "a branch reaches the card through esc()"       "yes" "$(has 'esc(it.branch)')"

finish
