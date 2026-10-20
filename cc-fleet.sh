#!/usr/bin/env bash
# cc-fleet.sh - a driving Claude session's side of batch driving: propose a batch of worktree
# units, let Adam approve it ONCE in Shepherd, then have Shepherd open each unit's tab.
#
#   cc-fleet.sh propose --file <batch.json> [--wait-max <seconds>]
#       batch.json = {"title": "...", "mergeWhenGreen": true|false,
#                     "units": [{"type": "feat|fix|ui|docs", "slug": "...", "task": "..."}]}   (1-8 units)
#       Optional per unit (2026-09-29): "blockedBy": ["<slug>", ...] -- the units it waits for
#       (its tab opens, and its merge is ready, only once they have merged; an unknown slug or a
#       circle is refused), "covers": ["<issue id>", ...] and "packet": "<packet id>".
#       Optional per batch (2026-09-29, the coverage index): "issues": [{"id", "title"}, ...] -- the
#       issue list it was built from -- and "triage": [{"id", "as": "dup|wontfix|later|covered-elsewhere",
#       "note"}, ...] for the issues it won't build. With an issue list, every covers and triage id
#       must be one of its issues, and a batch that leaves an issue neither covered nor triaged is
#       refused, printing the uncovered ids, so it never reaches Adam unapprovable.
#       Run it from inside the repo, in the BACKGROUND, and end the turn: Claude Code wakes the
#       session when Adam answers. Exit 0 BATCH APPROVED, 3 DENIED (+ note), 4 still waiting
#       (--wait-max), 5 withdrawn, 6 Shepherd isn't running, 2 refused (the reason is printed).
#       It prints one pre-flight line (2026-10-03): what the briefs ask for that Adam should look
#       at twice (force push, push to main, skipped tests, rm -rf, secrets, CI/deploy files, two
#       units citing one file, two hook-wiring units). Advisory: it never refuses a batch.
#   cc-fleet.sh preflight --file <batch.json> [--json]
#       That pre-flight for a batch file, without proposing it (--json: each unit's flag ids and
#       the batch's own flags). Needs no Shepherd.
#   cc-fleet.sh tab --batch <id> --unit <slug> [--wait-max 240]
#       Shepherd opens an empty Claude tab in the repo's window and answers with the new
#       session's name and the message to send it (SendMessage). Driver only; approved batches only.
#       Exit 7 = the unit waits for its blockedBy units to merge: nothing opened, ask again later.
#       A unit whose tab opened after an earlier `tab` had given up: run it again, it prints the
#       answer that one missed.
#   cc-fleet.sh status --batch <id>     Shepherd's view of the units, grouped by outcome (JSON)
#   cc-fleet.sh wait --batch <id> [--after N] [--wait-max S]
#       The units' events Shepherd relayed after #N (tab opened, asked a question, turn finished,
#       merge requested, gate red, checker fail, merged, blocked, session ended, and ended: gone
#       10 minutes with no merge or blocked result, so the batch can finish), one line each,
#       then how to wait for the next ones. Driver only. Run it in the BACKGROUND and end the
#       turn; it wakes the driver. Exit 0 events printed, 4 none within --wait-max, 5 the batch
#       stopped (after printing any left), 6 Shepherd isn't running, 2 refused.
#   cc-fleet.sh stop --batch <id>       ends the batch; its permissions go with it
#
# The approval lives in Shepherd (its own <id>.state.json), never in this file's word: a
# decision bound to the proposal's nonce, claimed with mv like the approval gate's.
set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

FLEET_DIR="${CC_FLEET_DIR:-$HOME/.claude/cc-fleet}"
SESSIONS_DIR="${CC_SESSIONS_DIR:-$HOME/.claude/sessions}"
POLL="${CC_FLEET_POLL:-1}"
PANEL_MAX_AGE="${CC_MERGE_PANEL_MAX_AGE:-30}"

refuse() { echo "❌ cc-fleet: $*"; exit 2; }
command -v jq >/dev/null 2>&1 || refuse "jq is required"
SID="${CLAUDE_CODE_SESSION_ID:-}"
# `alive` is exempt: it answers "is Shepherd up?", which is exactly what a caller that can't
# run the rest of these commands needs to know (2026-09-22). Everything else acts on a batch
# and is meaningless without a session to own it.
if [ "${1:-}" != "alive" ]; then
  [ -n "$SID" ] || refuse "not inside a Claude Code session (CLAUDE_CODE_SESSION_ID is unset)"
fi

shepherd_alive() {
  local hb now
  now="$(date +%s)"
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  [ -n "$hb" ] && [ $((now - hb)) -le "$PANEL_MAX_AGE" ]
}

batch_file() { # <id> -> path, refusing an id that could leave the dir
  case "$1" in ''|*[!A-Za-z0-9]*) refuse "bad batch id: $1" ;; esac
  printf '%s/%s.json' "$FLEET_DIR" "$1"
}

update_batch() { # <file> <jq filter> [jq args...]
  local f="$1" filter="$2"; shift 2
  local tmp="$f.tmp.$$"
  if jq "$@" "$filter" "$f" > "$tmp" 2>/dev/null; then mv "$tmp" "$f"; else rm -f "$tmp"; return 1; fi
}

# The brief pre-flight (2026-10-03, mining round 2 unit E3): what a batch's briefs ask for that
# Adam should look at twice -- force push, push to main, deleting or skipping tests, rm -rf,
# secrets, CI or deploy files; two units citing one file; more than one unit changing hook wiring.
# Negation-aware: "never git push" and "don't skip tests" aren't asks. Advisory only: it never
# refuses or holds a batch. A jq mirror of core.briefScan / core.batchBriefFlags (cc-core.lua):
# KEEP IN SYNC -- tests/fleet.test.sh runs `preflight --json` over tests/fixtures/brief-flags.tsv,
# the table tests/brief-flags.test.lua holds the Lua to. Prepend it to a filter that ends in
# bf_preflight (JSON) or bf_line (propose's one line); the input is the batch JSON.
BRIEF_PREFLIGHT_JQ='
def bf_isneg: IN("no", "not", "none", "without", "never", "zero", "nor", "cannot", "avoid", "avoids", "forbidden",
                 "prohibited", "dont") or endswith("n\u0027t");
def bf_isreset: IN("but", "then", "instead", "however", "except", "otherwise");
def bf_order: ["force-push", "push-main", "tests", "rm-rf", "secrets", "ci-deploy"];
def bf_label: {"force-push": "force push", "push-main": "push to main", "tests": "deletes or skips tests",
               "rm-rf": "rm -rf", "secrets": "touches secrets", "ci-deploy": "CI or deploy files"}[.];
def bf_rx: {
  "force-push": ["force[\\s-]?push", "(?<![a-z0-9])push(?![a-z0-9])[^,;]*?--force",
                 "(?<![a-z0-9])push(?![a-z0-9])[^,;]*?\\s-f(?![a-z0-9-])", "(?<![a-z0-9])push(?![a-z0-9])[^,;]*?\\s\\+[a-z0-9_]"],
  "tests": ["\\.skip(?![a-z0-9])", "\\.only(?![a-z0-9])", "(?<![a-z0-9])xit\\(", "(?<![a-z0-9])xdescribe(?![a-z0-9])",
            "(?<![a-z0-9])xtest\\(", "@skip", "mark\\.skip", "#\\[ignore\\]"],
  "rm-rf": ["(?<![a-z0-9])rm\\s+-[a-z]*r[a-z]*f", "(?<![a-z0-9])rm\\s+-[a-z]*f[a-z]*r", "(?<![a-z0-9])rm\\s+-r\\s+-f",
            "(?<![a-z0-9])rm\\s+-f\\s+-r"],
  "secrets": ["(?<![.a-z0-9_])\\.env(?![a-z0-9])", "\\.pem(?![a-z0-9])", "\\.p12(?![a-z0-9])", "(?<![a-z0-9])id_rsa",
              "(?<![a-z0-9])id_ed25519", "(?<![a-z0-9])credentials?(?![a-z0-9])", "private[\\s_-]key",
              "service[\\s_-]account[a-z0-9_-]*\\.json"],
  "ci-deploy": ["\\.github/workflows", "\\.gitlab-ci", "(?<![a-z0-9])jenkinsfile", "\\.circleci", "\\.travis\\.yml",
                "(?<![a-z0-9])deploy[a-z0-9_-]*\\.sh(?![a-z0-9])", "(?<![a-z0-9])deploy[a-z0-9_-]*\\.ya?ml",
                "(?<![a-z0-9])fly\\.toml", "(?<![a-z0-9])netlify\\.toml", "(?<![a-z0-9])vercel\\.json",
                "(?<![a-z0-9])wrangler\\.toml", "(?<![a-z0-9])wrangler\\.jsonc?", "deploy\\s+scripts?", "github\\s+actions?", "(?<![a-z0-9])ci\\s+config",
                "(?<![a-z0-9])ci\\s+workflows?", "(?<![a-z0-9])ci\\s+pipelines?"]
};
def bf_fold($c): reduce .[] as $x ($c; if ($x.w | bf_isneg) then true elif ($x.w | bf_isreset) then false else . end);
def bf_isfile:
  IN("Makefile", "SHIPPED", "Dockerfile", "Jenkinsfile")
  or ([ capture("^(?<stem>.+)\\.(?<ext>[A-Za-z0-9]+)$") ][0] as $m
      | $m != null and ($m.stem | test("[A-Za-z]"))
        and ($m.ext | ascii_downcase | IN("lua", "sh", "bash", "zsh", "js", "mjs", "cjs", "ts", "tsx", "jsx", "json", "jsonl",
             "md", "yml", "yaml", "toml", "py", "rb", "go", "rs", "css", "scss", "html", "htm", "txt", "tsv", "csv", "sql",
             "env", "pem", "conf", "cfg", "ini", "xml", "plist", "swift", "kt", "java", "c", "h", "cc", "cpp", "hpp",
             "lock", "rune")));
# One sentence, starting in negation state $c: { flags, cites, state } (core.briefScan scanSentence)
def bf_sentence($c):
  . as $t | ascii_downcase as $s
  | [ $s | match("[a-z\u0027]+"; "g") | { o: .offset, w: .string } ] as $ws
  | ($ws | length) as $n
  | [ $s | match("[,;:()]"; "g") | .offset ] as $cl
  | [ $s | match("[,;]"; "g") | .offset ] as $cm
  | def neg($p):
      ([ $ws[] | select(.o < $p) ] | bf_fold($c))
      or ((first($cl[] | select(. >= $p)) // 1e9) as $end | any($ws[]; .o > $p and .o < $end and (.w | bf_isneg)));
    (bf_rx | with_entries(.value = [ .value[] as $r | $s | match($r; "g") | .offset ])) as $rx
  | [ range(0; $n) as $i | select($ws[$i].w | IN("push", "pushes", "pushed", "pushing"))
      | ([ range($i + 1; [$i + 5, $n] | min) | select($ws[.].w | IN("main", "master")) ][0]) as $k
      | select($k != null)
      | select((($ws[$k + 1].w // "") | sub("\u0027s$"; "")
                | IN("checkout", "worktree", "session", "chat", "conversation", "tab", "window", "thread")) | not)
      | select(all($cm[]; . <= $ws[$i].o or . >= $ws[$k].o))
      | $ws[$i].o ] as $pm
  | [ range(0; $n) as $j | select($ws[$j].w | IN("test", "tests", "fixture", "fixtures", "assertion", "assertions", "suite", "suites"))
      | ( (range([$j - 3, 0] | max; $j) as $i
           | if ($ws[$i].w | IN("delete", "deletes", "deleted", "deleting", "remove", "removes", "removed", "removing",
                                 "skip", "skips", "skipped", "skipping", "disable", "disables", "disabled", "disabling",
                                 "loosen", "loosens", "loosened", "loosening", "weaken", "weakens", "weakened", "weakening"))
             then $ws[$i].o
             elif $ws[$i].w == "out" and $i > 0 and ($ws[$i - 1].w | IN("comment", "comments", "commented")) then $ws[$i - 1].o
             else empty end),
          (range($j + 1; [$j + 3, $n] | min) as $i
           | select($ws[$i].w | IN("deleted", "removed", "skipped", "disabled", "loosened", "weakened")) | $ws[$j].o) ) ] as $tw
  | ($rx + { "push-main": $pm, tests: ($rx.tests + $tw) }) as $hits
  | { flags: [ bf_order[] as $id | select(any($hits[$id][]; neg(.) | not)) | $id ],
      cites: [ $t | match("[A-Za-z0-9._/~$*-]+"; "g") | select(neg(.offset) | not) | .string
               | select(contains("*") | not) | sub("\\.+$"; "") | sub("^\\./"; "")
               | select(test("^[~/$]") | not)
               | ((split("/") | last) // "") as $b
               | select($b | bf_isfile)
               | select($b | ascii_downcase | IN("node.js", "next.js", "vue.js", "nuxt.js", "d3.js", "chart.js", "three.js") | not)
               | { base: ($b | ascii_downcase), path: .,
                   sent: ($t | ascii_downcase | gsub("\\s+"; " ") | ltrimstr(" ") | rtrimstr(" ")) } ],
      state: ($ws | bf_fold($c)) };
# One brief: { flags (in bf_order), cites }. A list line under a negated "Never:" starts negated.
def bf_scan:
  gsub("\u2019"; "\u0027") | gsub("\r"; "") | split("\n")
  | reduce .[] as $line ({ carry: false, flags: [], cites: [] };
      ($line | test("^\\s*([-*+\u2022]|[0-9]+[.)])\\s")) as $list
      | if ($line | test("\\S") | not) then .carry = false
        else (if $list then .carry else false end) as $start
          | reduce ($line | splits("(?<=[.!?])\\s+")) as $t (.last = $start;
              ($t | bf_sentence($start)) as $r | .flags += $r.flags | .cites += $r.cites | .last = $r.state)
          | if $list then . else .carry = (.last and ($line | sub("[\\s*_]+$"; "") | endswith(":"))) end
        end)
  | .flags as $f | { flags: [ bf_order[] | select(. as $i | any($f[]; . == $i)) ], cites };
def bf_shared: IN("todo.md", "changelog.md", "readme.md", "claude.md", "decisions.md", "run.sh", "vocabulary.txt");
def bf_hook: IN("settings-hooks.json", "install.sh", "uninstall.sh");
# The batch: { units: [{slug, flags}], batch: [{id: same-file, file, units} | {id: hook-wiring, units}] }
# 2026-10-04: a sentence every brief in the batch says word for word is boilerplate (the merge
# steps name cc-merge.sh in each), so the files it names belong to no unit -- the same rule as
# core.batchBriefFlags.
def bf_preflight:
  [ (.units // [])[] | { slug: ((.slug // "?") | tostring), scan: ((.task // "") | tostring | bf_scan) } ] as $u0
  | ($u0 | length) as $n
  | ([ $u0[] | [ .scan.cites[].sent ] | unique[] ] | group_by(.)
     | map(select($n >= 2 and length == $n) | .[0])) as $boiler
  | [ $u0[] | .scan.cites |= map(.sent as $x | select(any($boiler[]; . == $x) | not)) ] as $u
  | { units: [ $u0[] | { slug, flags: .scan.flags } ],
      batch: ( ([ $u | to_entries[] | .key as $ix | .value.slug as $s | .value.scan.cites[]
                  | select(.base | (bf_shared or bf_hook) | not) | . + { ix: $ix, slug: $s } ]
                | group_by(.base)
                | map(select((map(.ix) | unique | length) >= 2)
                      | { id: "same-file", file: (sort_by([-(.path | length), .path]) | .[0].path),
                          units: (sort_by(.ix) | reduce .[].slug as $x ([]; if any(.[]; . == $x) then . else . + [$x] end)) }))
             + ([ $u[] | select(any(.scan.cites[]; .base | bf_hook)) | .slug ] as $h
                | if ($h | length) >= 2 then [ { id: "hook-wiring", units: $h } ] else [] end) ) };
# propose'"'"'s one line
def bf_line:
  bf_preflight as $p
  | ([ $p.units[] | select(.flags | length > 0) | "\(.slug): \([ .flags[] | bf_label ] | join(", "))" ]
     + [ $p.batch[] | if .id == "same-file" then "\(.file) is cited by \(.units | join(", "))"
                      else "\(.units | length) units change hook wiring (\(.units | join(", "))) -- a batch takes at most one" end ]) as $parts
  | if ($parts | length) == 0 then "🔍 Pre-flight: no risky phrasing in the briefs."
    else "🔍 Pre-flight (advisory; Adam sees it in the review): " + ($parts | join("; ")) + "." end;
'

# Wait for <decision> bound to <nonce>; claim with mv, put a stranger's answer back. Prints
# the claimed JSON on stdout. Returns 0 claimed, 4 wait-max ran out, 5 <watched> gone.
wait_answer() { # <decision file> <nonce> <watched file> <wait-max>
  local dec="$1" nonce="$2" watched="$3" waitmax="$4" start claim
  start="$(date +%s)"
  while :; do
    [ -f "$watched" ] || return 5
    if [ -f "$dec" ]; then
      claim="$dec.claim.$$"
      if mv "$dec" "$claim" 2>/dev/null; then
        if [ "$(jq -r '.nonce // empty' "$claim" 2>/dev/null)" = "$nonce" ]; then
          cat "$claim"; rm -f "$claim" "$dec".parked.*
          return 0
        fi
        if ln "$claim" "$dec" 2>/dev/null; then rm -f "$claim"; else mv "$claim" "$dec.parked.$$" 2>/dev/null; fi
      fi
    fi
    if [ "$waitmax" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$waitmax" ]; then return 4; fi
    sleep "$POLL"
  done
}

# Wait for Adam's answer to proposal <id> and act on it: what `propose` does once the batch is
# written, and all `propose --resume` does (2026-10-02: a late answer to a proposal whose waiting
# propose is gone -- killed at a background limit -- was never collected, and its batch read
# "proposed" for good).
collect_answer() { # <id> <batch file> <nonce> <wait-max> <main checkout>
  local id="$1" bf="$2" nonce="$3" waitmax="$4" main="$5"
  local ans rc
  ans="$(wait_answer "$FLEET_DIR/$id.decision" "$nonce" "$bf" "$waitmax")"; rc=$?
  if [ "$rc" -eq 5 ]; then echo "↩︎ The proposal was withdrawn."; exit 5; fi
  if [ "$rc" -eq 4 ]; then echo "⏳ Still waiting for Adam after ${waitmax}s -- batch $id stays proposed. Collect his answer later with: ~/.claude/cc-fleet.sh propose --resume $id"; exit 4; fi
  local verdict grant note
  verdict="$(printf '%s' "$ans" | jq -r '.verdict // empty')"
  grant="$(printf '%s' "$ans" | jq -r '.grantMerge == true')"
  note="$(printf '%s' "$ans" | jq -r '.note // empty' | head -c 500)"
  if [ "$verdict" != "approve" ]; then
    update_batch "$bf" '.phase = "denied" | .note = $n' --arg n "$note"
    echo "DENIED: ${note:-(no note)}"
    echo "Adam didn't approve batch $id. Nothing was opened."
    exit 3
  fi
  update_batch "$bf" '.phase = "approved" | .approvedAt = $t' --argjson t "$(date +%s)"
  echo "BATCH APPROVED -- $(jq -r .title "$bf"): $(jq -r '.units | length' "$bf") units in $main."
  if [ "$grant" = "true" ]; then
    echo "Merges are delegated: Shepherd merges each unit once its own git check finds it ready (one per repo at a time). A risky change, or one with no gate pass, still waits for Adam's click (grant grading)."
  else
    echo "Merges are NOT delegated: each unit stops at 'ready to merge' for Adam's click."
  fi
  echo "For each unit, open its tab, then SendMessage the printed session the printed message (notify_when_idle: true):"
  jq -r --arg id "$id" '.units[] | "  ~/.claude/cc-fleet.sh tab --batch \($id) --unit \(.slug)"
    + (if ((.blockedBy // []) | length) > 0 then "   (waits for \(.blockedBy | join(", ")) to merge first)" else "" end)' "$bf"
  if jq -e '.units | any((.blockedBy // []) | length > 0)' "$bf" >/dev/null 2>&1; then
    echo "A unit that waits isn't opened until its blockers have merged: its tab command exits 7 until then -- open the others first."
  fi
  echo "Follow them with ~/.claude/cc-fleet.sh wait --batch $id in the background; it wakes you with each unit's events."
  echo "After each wake, run it again with the --after it prints (never poll ListAgents)."
  echo "When every unit has merged or blocked: ~/.claude/cc-fleet.sh stop --batch $id, then summarise for Adam."
  exit 0
}

cmd_propose() {
  local file="" waitmax=0 resume=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file="${2:-}"; shift 2 ;;
      --wait-max) waitmax="${2:-}"; shift 2 ;;
      --resume) resume="${2:-}"; shift 2 ;;
      *) refuse "unknown option: $1" ;;
    esac
  done
  case "$waitmax" in ''|*[!0-9]*) refuse "--wait-max takes whole seconds" ;; esac
  if [ -n "$resume" ]; then
    local rbf; rbf="$(batch_file "$resume")"
    [ -f "$rbf" ] || refuse "no batch $resume"
    [ "$(jq -r .driver.session_id "$rbf")" = "$SID" ] || refuse "only the session that proposed batch $resume can collect Adam's answer"
    [ "$(jq -r '.phase // empty' "$rbf")" = "proposed" ] \
      || refuse "batch $resume isn't waiting for an answer (it's $(jq -r '.phase // "unknown"' "$rbf"))"
    echo "⏳ Waiting for Adam's answer to batch $resume..."
    collect_answer "$resume" "$rbf" "$(jq -r .nonce "$rbf")" "$waitmax" "$(jq -r '.repo // empty' "$rbf")"
  fi
  [ -f "$file" ] || refuse "--file must name the batch JSON"
  local problems
  problems="$(jq -r '
    def slugok: type == "string" and test("^[a-z0-9][a-z0-9._-]{0,39}$") and (test("\\.\\.") | not)
                and (test("\\.$") | not) and (test("\\.lock$") | not);
    # 2026-09-29: the optional unit fields (core.parseBatch checks the same)
    def coverok: type == "string" and test("^[A-Za-z0-9#][A-Za-z0-9._:#/-]{0,59}$");
    def packetok: type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$");
    # 2026-09-29 (unit 25): the optional issue list and triage (core.parseBatchIssues checks the same)
    def issueok: type == "object" and (.id | coverok) and (.title | type) == "string"
                 and (.title | length) >= 1 and (.title | length) <= 200;
    def triageok: type == "object" and (.id | coverok) and (.as | IN("dup", "wontfix", "later", "covered-elsewhere"))
                  and (.note | type) == "string" and (.note | length) >= 1 and (.note | length) <= 300;
    # The blockers that go in a circle, peeled like core.batchOrderProblem: units whose blockers
    # are all gone, then units nothing left waits for; what remains is the circle.
    def circle:
      { left: . }
      | until(.stop or (.left | length) == 0;
          .left as $l
          | [ $l | to_entries[]
              | select((.value | all(. as $b | $l | has($b) | not))
                       or (.key as $k | [ $l[][] ] | any(. == $k) | not))
              | .key ] as $peel
          | if ($peel | length) == 0 then .stop = true else .left = ($l | delpaths([ $peel[] | [.] ])) end)
      | .left | keys;
    if type != "object" then "not a JSON object" else
      [ (if (.title | type) != "string" or (.title | length) < 1 or (.title | length) > 120 then "title must be 1-120 characters" else empty end),
        (if has("mergeWhenGreen") and (.mergeWhenGreen | type) != "boolean" then "mergeWhenGreen must be true or false" else empty end),
        (if (.units | type) != "array" or (.units | length) < 1 or (.units | length) > 8 then "units must be a list of 1-8 units" else empty end),
        ((.units // []) | if type == "array" then .[] else empty end
          | (if (.type | IN("feat", "fix", "ui", "docs")) | not then "unit \(.slug // "?"): type must be feat, fix, ui or docs" else empty end),
            (if (.slug | slugok) | not then "unit \(.slug // "?"): slug must be lower-case letters, digits, . _ - (max 40)" else empty end),
            (if (.task | type) != "string" or (.task | length) < 1 or (.task | length) > 4000 then "unit \(.slug // "?"): task must be 1-4000 characters" else empty end),
            (if has("blockedBy") and ((.blockedBy | type) != "array" or (.blockedBy | length) > 8 or (.blockedBy | all(slugok) | not))
             then "unit \(.slug // "?"): blockedBy must be a list of up to 8 unit slugs" else empty end),
            (if has("covers") and ((.covers | type) != "array" or (.covers | length) > 50 or (.covers | all(coverok) | not))
             then "unit \(.slug // "?"): covers must be a list of up to 50 issue ids (letters, digits and # . _ : / -)" else empty end),
            (if has("packet") and (.packet | packetok | not)
             then "unit \(.slug // "?"): packet must be a packet id (letters, digits and . _ -, at most 40)" else empty end)),
        (if ((.units // []) | type) == "array" and ((.units | map(.slug) | unique | length) != (.units | length)) then "slugs must be unique" else empty end),
        # 2026-09-29 (unit 25): the issue list and triage are well formed, and every covers and
        # triage id names one of the issues (with no issue list, covers are free-form)
        (if has("issues") and ((.issues | type) != "array" or (.issues | length) < 1 or (.issues | length) > 200 or (.issues | all(issueok) | not))
         then "issues must be a list of 1-200 {\"id\", \"title\"} (an id: letters, digits and # . _ : / -; a title of 1-200 characters)" else empty end),
        (if (.issues | type) == "array" and (.issues | all(issueok)) and (([ .issues[].id ] | unique | length) != (.issues | length))
         then "issue ids must be unique" else empty end),
        (if has("triage") and ((.triage | type) != "array" or (.triage | length) > 200 or (.triage | all(triageok) | not))
         then "triage must be a list of up to 200 {\"id\", \"as\": dup|wontfix|later|covered-elsewhere, \"note\"} (a note is required, up to 300 characters)" else empty end),
        (if (.triage | type) == "array" and (.triage | all(triageok)) and (([ .triage[].id ] | unique | length) != (.triage | length))
         then "an issue is triaged twice" else empty end),
        ([ .issues // [] | if type == "array" then .[] else empty end | objects | .id ] as $ids
         | (if (.issues | type) == "array" then
              (.units // [] | if type == "array" then .[] else empty end | . as $u
               | (if (.covers | type) == "array" then .covers[] else empty end)
               | select(. as $c | $ids | any(. == $c) | not)
               | "unit \($u.slug) covers '"'"'\(.)'"'"', which isn'"'"'t one of the batch'"'"'s issues")
            else empty end),
           (.triage // [] | if type == "array" then .[] else empty end | objects | .id
            | select(. as $c | $ids | any(. == $c) | not)
            | "triage names '"'"'\(.)'"'"', which isn'"'"'t one of the batch'"'"'s issues")),
        # 2026-09-29: blockedBy names units of THIS batch, never itself, and never goes in a circle
        (if ((.units // []) | type) == "array" then
           (.units | map(.slug)) as $known
           | ( (.units[] | . as $u | (if (.blockedBy | type) == "array" then .blockedBy[] else empty end)
                | if . == $u.slug then "unit \($u.slug) can'"'"'t wait for itself"
                  elif (. as $b | $known | any(. == $b)) | not then "unit \($u.slug) waits for '"'"'\(.)'"'"', which isn'"'"'t one of the batch'"'"'s units"
                  else empty end),
               ( ([ .units[] | { key: (.slug | tostring), value: (if (.blockedBy | type) == "array" then [ .blockedBy[] | strings ] else [] end) } ]
                  | from_entries | circle) as $left
                 | if ($left | length) > 0
                   then "blockedBy goes in a circle: \([ .units[].slug | select(. as $s | $left | any(. == $s)) ] | join(", ")) -- none of them could ever start"
                   else empty end ) )
         else empty end)
      ] | .[] end' "$file" 2>&1)" || problems="the batch file isn't valid JSON"
  [ -z "$problems" ] || { echo "❌ cc-fleet: the batch was refused:"; printf '  %s\n' "$problems"; exit 2; }

  # 2026-09-29 (unit 25): every issue covered by a unit or triaged -- or Adam can't approve the
  # batch (core.batchApproveProblem), so it never reaches him. The ids and titles, one per line.
  local uncovered
  uncovered="$(jq -r '
    if (.issues | type) == "array" then
      ([ .units[] | (.covers // [])[] ] + [ (.triage // [])[] | .id ]) as $done
      | .issues[] | select(.id as $i | $done | any(. == $i) | not)
      | "  \(.id)  \(.title | gsub("[[:cntrl:]]+"; " "))"
    else empty end' "$file")"
  if [ -n "$uncovered" ]; then
    local nun; nun="$(printf '%s\n' "$uncovered" | grep -c .)"
    [ "$nun" = "1" ] && nun="1 issue" || nun="$nun issues"
    echo "❌ cc-fleet: the batch leaves $nun uncovered -- Adam can't approve it until every issue is covered by a unit or triaged:"
    printf '%s\n' "$uncovered"
    echo "Add each to a unit's \"covers\", or triage it in the batch's \"triage\": [{\"id\": \"<id>\", \"as\": \"dup|wontfix|later|covered-elsewhere\", \"note\": \"<why>\"}]."
    echo "Nothing was proposed: fix the file and propose again."
    exit 2
  fi

  local common main
  common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || refuse "run it from inside the repo the units belong to"
  case "$common" in */.git) main="${common%/.git}" ;; *) refuse "the repo has no main checkout (a bare repo?)" ;; esac
  local taken=""
  while IFS=$'\t' read -r type slug; do
    git --git-dir="$common" show-ref --verify --quiet "refs/heads/$type/$slug" && taken="$taken $type/$slug"
    git --git-dir="$common" show-ref --verify --quiet "refs/heads/worktree-$slug" && taken="$taken worktree-$slug"
    [ -e "$main/.claude/worktrees/$slug" ] && taken="$taken .claude/worktrees/$slug"
  done < <(jq -r '.units[] | [.type, .slug] | @tsv' "$file")
  [ -z "$taken" ] || refuse "already exists:$taken"
  shepherd_alive || { echo "⚠️ Shepherd isn't running, so Adam can't approve a batch there. Ask him in chat, and run the units by hand."; exit 6; }

  prune_batches
  mkdir -p "$FLEET_DIR" && chmod 700 "$FLEET_DIR" 2>/dev/null
  local now id nonce dname bf tmp
  now="$(date +%s)"; id="b${now}${RANDOM}"; nonce="$$.$now.$RANDOM"
  dname="$(jq -r '.name // empty' "$SESSIONS_DIR/${CLAUDE_PID:-none}.json" 2>/dev/null)"
  bf="$(batch_file "$id")"; tmp="$bf.tmp.$$"
  jq --arg id "$id" --arg nonce "$nonce" --arg sid "$SID" --arg pid "${CLAUDE_PID:-}" --arg dname "$dname" \
     --arg repo "$main" --arg common "$common" --argjson at "$now" '
    { v: 1, id: $id, nonce: $nonce, driver: { session_id: $sid, pid: $pid, name: $dname },
      repo: $repo, commonDir: $common, title: .title, mergeWhenGreen: (.mergeWhenGreen // false),
      units: [ .units[] | { type, slug, task, branch: (.type + "/" + .slug) }
               + (if has("blockedBy") then { blockedBy: (.blockedBy | reduce .[] as $b ([]; if index([$b]) then . else . + [$b] end)) } else {} end)
               + (if has("covers") then { covers } else {} end)
               + (if has("packet") then { packet } else {} end) ], at: $at, phase: "proposed" }
    # 2026-09-29 (unit 25): the issue list and triage, when the batch has them
    + (if has("issues") then { issues: [ .issues[] | { id, title } ] } else {} end)
    + (if has("triage") then { triage: [ .triage[] | { id, as, note } ] } else {} end)' \
     "$file" > "$tmp" && mv "$tmp" "$bf" || refuse "couldn't write the proposal in $FLEET_DIR"
  echo "⏳ Proposed batch $id ($(jq -r '.units | length' "$bf") units) to Adam in Shepherd. Waiting for his answer..."
  # 2026-09-29 (unit 25): what accounts for its issue list (core.batchCoverageLine's counts)
  jq -r 'if (.issues | type) == "array" then
      ([ .units[] | (.covers // [])[] ]) as $cv | ([ (.triage // [])[] | .id ]) as $tr
      | [ .issues[].id | . as $i | if ($cv | any(. == $i)) then "c" elif ($tr | any(. == $i)) then "t" else "u" end ] as $k
      | ([ $k[] | select(. == "c") ] | length) as $c | ([ $k[] | select(. == "t") ] | length) as $t
      | "📋 Coverage: \(.issues | length) issue\(if (.issues | length) == 1 then "" else "s" end): "
        + ([ (if $c > 0 then "\($c) covered by \(if $c == 1 then "a unit" else "units" end)" else empty end),
             (if $t > 0 then "\($t) triaged" else empty end) ] | join(", ")) + "."
    else empty end' "$bf"
  # 2026-10-03 (mining round 2, E3): the brief pre-flight, one line (core.batchPreflightView's twin).
  # Advisory: a jq failure here prints nothing and the proposal goes on.
  jq -r "$BRIEF_PREFLIGHT_JQ bf_line" "$bf" 2>/dev/null

  collect_answer "$id" "$bf" "$nonce" "$waitmax" "$main"
}

# What a tab answer says to the driver: the session's name, a warning if Shepherd sent one, and
# the message to send.
print_tab_answer() { # <slug> <answer json>
  local slug="$1" ans="$2" warn
  echo "✅ Unit $slug's tab is open. Its session: $(printf '%s' "$ans" | jq -r .name)"
  # 2026-09-30: the unit's window runs a tab bridge older than 0.6.0 (core.fleetBridgeWarning)
  warn="$(printf '%s' "$ans" | jq -r '.warn // empty' | tr -d '[:cntrl:]')"
  [ -z "$warn" ] || echo "⚠️ $warn"
  echo "Send it this message with SendMessage (to: \"$(printf '%s' "$ans" | jq -r .name)\", notify_when_idle: true):"
  echo "-----"
  printf '%s\n' "$ans" | jq -r .message
  echo "-----"
}

# How long `tab` waits for Shepherd by default. Shepherd itself gives a tab up to 225s
# (core.fleetTabMaxSeconds: 135s to open, 90s for its session). 2026-09-30: this was 120, so the
# driver was told "didn't open the tab" while Shepherd went on to open it, and the retry was
# refused as "already has its tab". tests/fleet.test.sh holds it above Shepherd's own limit.
TAB_WAIT_MAX=240

cmd_tab() {
  local id="" slug="" waitmax="$TAB_WAIT_MAX"
  while [ $# -gt 0 ]; do
    case "$1" in
      --batch) id="${2:-}"; shift 2 ;;
      --unit) slug="${2:-}"; shift 2 ;;
      --wait-max) waitmax="${2:-}"; shift 2 ;;
      *) refuse "unknown option: $1" ;;
    esac
  done
  case "$waitmax" in ''|*[!0-9]*) refuse "--wait-max takes whole seconds" ;; esac
  local bf; bf="$(batch_file "$id")"
  [ -f "$bf" ] || refuse "no batch $id"
  [ "$(jq -r .driver.session_id "$bf")" = "$SID" ] || refuse "only the session that proposed batch $id can open its tabs"
  [ "$(jq -r .phase "$bf")" = "approved" ] || refuse "batch $id isn't approved (it's $(jq -r .phase "$bf"))"
  [ -e "$FLEET_DIR/$id.stop" ] && refuse "batch $id was stopped"
  jq -e --arg s "$slug" '.units | any(.slug == $s)' "$bf" >/dev/null || refuse "batch $id has no unit '$slug'"
  if jq -e --arg s "$slug" '.units[$s].session != null' "$FLEET_DIR/$id.state.json" >/dev/null 2>&1; then
    # 2026-09-30: the tab may have opened after an earlier `tab` gave up waiting. Shepherd's answer
    # is still there, unread: when it is for the very session Shepherd recorded as this unit's,
    # it is printed now instead of refusing the driver the message it never got.
    local late="$FLEET_DIR/$id.tab-$slug.answer" have
    have="$(jq -r --arg s "$slug" '.units[$s].session.id // empty' "$FLEET_DIR/$id.state.json" 2>/dev/null)"
    if [ -n "$have" ] && [ "$(jq -r '(.ok == true) and ((.message | type) == "string")' "$late" 2>/dev/null)" = "true" ] \
       && [ "$(jq -r '.sessionId // empty' "$late" 2>/dev/null)" = "$have" ]; then
      local ans; ans="$(cat "$late")"
      rm -f "$late"
      echo "↩︎ Unit $slug's tab opened after an earlier wait gave up; this is the answer it missed."
      print_tab_answer "$slug" "$ans"
      exit 0
    fi
    refuse "unit $slug already has its tab ($(jq -r --arg s "$slug" '.units[$s].session.name' "$FLEET_DIR/$id.state.json"))"
  fi
  shepherd_alive || { echo "⚠️ Shepherd isn't running, so it can't open the tab."; exit 6; }
  local req="$FLEET_DIR/$id.tab-$slug.json" nonce tmp
  nonce="$$.$(date +%s).$RANDOM"; tmp="$req.tmp.$$"
  jq -n --arg b "$id" --arg s "$slug" --arg sid "$SID" --arg n "$nonce" --argjson at "$(date +%s)" \
    '{v: 1, batch: $b, slug: $s, session_id: $sid, nonce: $n, at: $at}' > "$tmp" && mv "$tmp" "$req" || refuse "couldn't write the tab request"
  echo "⏳ Asked Shepherd to open unit $slug's tab..."
  local ans rc
  ans="$(wait_answer "$FLEET_DIR/$id.tab-$slug.answer" "$nonce" "$req" "$waitmax")"; rc=$?
  rm -f "$req"
  [ "$rc" -eq 0 ] || refuse "Shepherd didn't open the tab within ${waitmax}s -- it may still be opening it: run the same command again in a minute (it prints the answer if the tab did open)"
  # 2026-09-29: blockedBy -- a unit whose blockers haven't all merged waits (exit 7), apart from a refusal
  if [ "$(printf '%s' "$ans" | jq -r '.ok != true and ((.waits // []) | length) > 0')" = "true" ]; then
    echo "⏸ cc-fleet: unit $slug $(printf '%s' "$ans" | jq -r '.reason // "waits for its blockers to merge first"') -- nothing was opened."
    echo "Ask again once they have merged (~/.claude/cc-fleet.sh status --batch $id shows each unit's outcome)."
    exit 7
  fi
  if [ "$(printf '%s' "$ans" | jq -r '.ok == true')" != "true" ]; then
    refuse "Shepherd couldn't open unit $slug's tab: $(printf '%s' "$ans" | jq -r '.reason // "no reason given"')"
  fi
  print_tab_answer "$slug" "$ans"
  exit 0
}

cmd_status() {
  local id=""
  while [ $# -gt 0 ]; do case "$1" in --batch) id="${2:-}"; shift 2 ;; *) refuse "unknown option: $1" ;; esac; done
  local bf; bf="$(batch_file "$id")"
  [ -f "$bf" ] || refuse "no batch $id"
  # Grouped by outcome, the way core.batchOutcomes groups them (merged-dirty counts as merged; a
  # session Shepherd settled as ended, with no result = ended; a session and no result = working;
  # no session = unopened). Shepherd's state file is the source; a missing or torn one reads as
  # empty, so every unit is unopened.
  local state
  state="$(jq -c 'if type == "object" then . else {} end' "$FLEET_DIR/$id.state.json" 2>/dev/null)" || state=""
  [ -n "$state" ] || state='{}'
  jq -n --slurpfile b "$bf" --argjson s "$state" '
    def outcome($us):
      if ($us.result == "merged" or $us.result == "merged-dirty") then "merged"
      elif $us.result == "blocked" then "blocked"
      # 2026-10-15: gone for core.BATCH_UNIT_END_GRACE with no result (core.unitSettle stamps endedAt)
      elif (($us.session | type) == "object") and (($us.endedAt | type) == "number") then "ended"
      elif (($us.session | type) == "object") then "working"
      else "unopened" end;
    ($s.units | if type == "object" then . else {} end) as $su
    # 2026-09-29: blockedBy, the way core.batchUnitOutcomeIn reads it -- a unit with no tab behind
    # a blocked one (directly or down a chain) is blocked too, so the batch can finish; one
    # behind a unit that has not merged yet waits. 2026-10-15: an ended unit never merges either.
    | ($b[0].units | map({ key: .slug, value: (.blockedBy // []) }) | from_entries) as $g
    | def raw($x): outcome(($su[$x] | if type == "object" then . else {} end));
      def via($x; $seen):
        if ($seen | any(. == $x)) then null
        else (first(($g[$x] // [])[] as $bl | raw($bl) as $o
                    | if ($o == "blocked" or $o == "ended") then $bl elif $o != "merged" then (via($bl; $seen + [$x]) // empty) else empty end)
              // null) end;
    [ $b[0].units[] | . as $u | ($su[$u.slug] | if type == "object" then . else {} end) as $us
        | outcome($us) as $o
        | (if $o == "unopened" then via($u.slug; []) else null end) as $v
        | [ ($u.blockedBy // [])[] | select(raw(.) != "merged") ] as $w
        | { slug: $u.slug, branch: $u.branch, outcome: (if $v then "blocked" else $o end),
            result: ($us.result // null), session: ($us.session.name? // null),
            note: (if $o == "ended" then "ended: its session is gone, with no merge or blocked result"
                   elif $o == "working" and (($us.goneAt | type) == "number") then "its session is gone: it settles as ended unless it comes back"
                   elif $o != "unopened" then null
                   elif $v then "blocked by \(if raw($v) == "ended" then "an ended" else "a blocked" end) unit (\($v))"
                   elif ($w | length) > 0 then "waits for \($w | join(", "))" else null end) } ] as $units
    | ([ "merged", "blocked", "ended", "working", "unopened" ]
       | map(. as $k | { key: $k, value: [ $units[] | select(.outcome == $k) | .slug ] }) | from_entries) as $o
    | { batch: $b[0].id, title: $b[0].title, phase: $b[0].phase, repo: $b[0].repo,
        grant: ($s.grant // null), counts: ($o | map_values(length)), outcomes: $o, units: $units }'
  exit 0
}

# The relayed events after #<after> as lines, oldest first; sets RELAY_LAST to the last number.
# Returns 1 when there are none. A torn last line (Shepherd mid-write) isn't an event yet.
RELAY_LAST=""
relay_events() { # <events file> <after>
  [ -f "$1" ] || return 1
  local rows
  rows="$(jq -R -n -c --argjson n "$2" '
    [ inputs | fromjson? | select(type == "object" and (.seq | type) == "number" and .seq > $n) ] | sort_by(.seq)' "$1" 2>/dev/null)" || return 1
  [ "$(printf '%s' "$rows" | jq 'length' 2>/dev/null)" -gt 0 ] 2>/dev/null || return 1
  printf '%s' "$rows" | jq -r '.[] | "#\(.seq) \(.unit) \(.event): \((.text // "") | gsub("[\\r\\n]"; " "))"'
  RELAY_LAST="$(printf '%s' "$rows" | jq '.[-1].seq')"
  return 0
}

batch_stopped() { # <id> <batch file>
  [ -e "$FLEET_DIR/$1.stop" ] || [ ! -f "$2" ] || [ "$(jq -r '.phase // empty' "$2" 2>/dev/null)" = "stopped" ]
}

# 2026-09-29 (build program unit 23): the driver used to stitch idle notices, unit messages and
# status polls together to learn what a unit had done. Shepherd now relays each unit's events,
# numbered, into <id>.events.jsonl (FX.relayFleet); this prints the ones after --after and exits,
# so a driver running it in the background is woken by exactly the news.
cmd_wait() {
  local id="" after=0 waitmax=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --batch) id="${2:-}"; shift 2 ;;
      --after) after="${2:-}"; shift 2 ;;
      --wait-max) waitmax="${2:-}"; shift 2 ;;
      *) refuse "unknown option: $1" ;;
    esac
  done
  case "$after" in ''|*[!0-9]*) refuse "--after takes the number of the last event you saw" ;; esac
  case "$waitmax" in ''|*[!0-9]*) refuse "--wait-max takes whole seconds" ;; esac
  local bf; bf="$(batch_file "$id")"
  [ -f "$bf" ] || refuse "no batch $id"
  [ "$(jq -r .driver.session_id "$bf")" = "$SID" ] || refuse "only the session that proposed batch $id can wait on its units"
  local ev="$FLEET_DIR/$id.events.jsonl" start
  start="$(date +%s)"
  while :; do
    if relay_events "$ev" "$after"; then
      echo "Next: ~/.claude/cc-fleet.sh wait --batch $id --after $RELAY_LAST   (in the background again)"
      exit 0
    fi
    if batch_stopped "$id" "$bf"; then
      # Shepherd writes a batch's last events before it stops it; read once more for a race
      if relay_events "$ev" "$after"; then
        echo "Next: ~/.claude/cc-fleet.sh wait --batch $id --after $RELAY_LAST   (in the background again)"
        exit 0
      fi
      echo "⏹ Batch $id has stopped: no more events will come after #$after."
      echo "Summarise it for Adam (~/.claude/cc-fleet.sh status --batch $id groups the units by outcome)."
      exit 5
    fi
    shepherd_alive || { echo "⚠️ Shepherd isn't running, so nothing relays the units' events (see ~/.claude/cc-fleet.sh alive)."; exit 6; }
    if [ "$waitmax" -gt 0 ] && [ $(( $(date +%s) - start )) -ge "$waitmax" ]; then
      echo "⏳ No new events from batch $id in ${waitmax}s (still after #$after)."
      exit 4
    fi
    sleep "$POLL"
  done
}

# A batch stopped over a week ago goes, every file of it, its relayed events included (2026-09-29):
# nothing ever removed a batch's files. Shepherd prunes the same batches in its tick
# (FX.removeBatch); this covers a driver proposing the next one. -mtime +6 = 7+ whole days old.
prune_batches() {
  local stop
  [ -d "$FLEET_DIR" ] || return 0
  find "$FLEET_DIR" -maxdepth 1 -type f -name 'b*.stop' -mtime +6 2>/dev/null | while IFS= read -r stop; do
    CC_FLEET_DIR="$FLEET_DIR" cc_fleet_remove_batch "$(basename "$stop" .stop)"
  done
}

cmd_stop() {
  local id=""
  while [ $# -gt 0 ]; do case "$1" in --batch) id="${2:-}"; shift 2 ;; *) refuse "unknown option: $1" ;; esac; done
  local bf; bf="$(batch_file "$id")"
  [ -f "$bf" ] || refuse "no batch $id"
  [ "$(jq -r .driver.session_id "$bf")" = "$SID" ] || refuse "only the session that proposed batch $id can stop it here (Adam can stop it in Shepherd)"
  : > "$FLEET_DIR/$id.stop"
  update_batch "$bf" '.phase = "stopped" | .stoppedAt = $t' --argjson t "$(date +%s)"
  echo "✅ Batch $id stopped: no more tabs, and no merges on its grant."
  exit 0
}

# Is Shepherd up? The one honest answer, because there is nothing else to look at.
# 2026-09-22: a session checked with `pgrep -fl -i shepherd`, found nothing and told Adam
# "Shepherd isn't running" -- while he was looking at that very question on its card. There
# is NO process called Shepherd: it is Lua (claude-dashboard.lua) running inside
# Hammerspoon, and ~/Applications/Shepherd.app is only a launcher. The panel's heartbeat is
# the signal every other command here already uses; this just says it out loud, so a session
# never has to invent a test. Deliberately usable with no Claude session id: a session that
# can't run the rest still needs to find out why.
cmd_alive() {
  local hb now age
  now="$(date +%s)"
  hb="$(tr -dc '0-9' < "$(cc_heartbeat_file)" 2>/dev/null)"
  if [ -n "$hb" ] && [ "$((now - hb))" -le "$PANEL_MAX_AGE" ]; then
    echo "✅ Shepherd is running (panel heartbeat $((now - hb))s old, inside Hammerspoon)."
    exit 0
  fi
  if [ -z "$hb" ]; then
    echo "⚠️ Shepherd isn't running: it has written no panel heartbeat (it may never have started here)."
  else
    age="$((now - hb))"
    echo "⚠️ Shepherd isn't running: its panel heartbeat is ${age}s old (stale past ${PANEL_MAX_AGE}s)."
  fi
  echo "   Shepherd is Lua inside Hammerspoon -- there is no process called Shepherd, so pgrep"
  echo "   proves nothing. Adam starts it from Shepherd.app, or Hammerspoon -> Reload Config."
  exit 6
}

# What a batch file's briefs ask for that Adam should look at twice -- the line propose prints, or
# with --json each unit's flag ids and the batch's own flags. Proposes nothing; needs no Shepherd.
cmd_preflight() {
  local file="" json=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --file) file="${2:-}"; shift 2 ;;
      --json) json=1; shift ;;
      *) refuse "unknown option: $1" ;;
    esac
  done
  [ -f "$file" ] || refuse "--file must name the batch JSON"
  jq -e '(.units | type) == "array"' "$file" >/dev/null 2>&1 || refuse "the batch file has no units list"
  if [ -n "$json" ]; then jq -c "$BRIEF_PREFLIGHT_JQ bf_preflight" "$file"
  else jq -r "$BRIEF_PREFLIGHT_JQ bf_line" "$file"; fi
}

case "${1:-}" in
  propose) shift; cmd_propose "$@" ;;
  preflight) shift; cmd_preflight "$@" ;;
  tab)     shift; cmd_tab "$@" ;;
  status)  shift; cmd_status "$@" ;;
  wait)    shift; cmd_wait "$@" ;;
  stop)    shift; cmd_stop "$@" ;;
  alive)   shift; cmd_alive "$@" ;;
  *) echo "usage: cc-fleet.sh propose --file <batch.json> | propose --resume <id> | preflight --file <batch.json> [--json] | tab --batch <id> --unit <slug> | status --batch <id> | wait --batch <id> [--after N] [--wait-max S] | stop --batch <id> | alive"
     exit 2 ;;
esac
