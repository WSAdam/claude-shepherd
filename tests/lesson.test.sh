#!/usr/bin/env bash
# lesson.test.sh - ~/.claude/cc-lesson.sh, a one-line lesson for the repo's coach (2026-10-03, mining
# round 2 unit B4). A session that learned something the hard way files it from inside the repo; the
# record lands in ~/.claude/cc-lesson/<epoch>-<pid>.json (temp, then renamed), naming the repo by its
# git common dir, and Shepherd puts it in that repo's coach log as `learned` on its next tick
# (tests/coach.test.lua drives that half). Drives the REAL cc-lesson.sh over temp dirs and repos.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
TMP="$(cd "$TMP" && pwd -P)"
export CC_STATUS_DIR="$TMP/status"
export CC_LESSON_DIR="$TMP/cc-lesson"
mkdir -p "$CC_STATUS_DIR" "$TMP/plain"
L="$ROOT/cc-lesson.sh"
REPO="$TMP/repo"
git init -q "$REPO" && git -C "$REPO" config user.email t@example.com && git -C "$REPO" config user.name Tester \
  && git -C "$REPO" config commit.gpgsign false && git -C "$REPO" commit -q --allow-empty -m init && git -C "$REPO" branch -q -M main
# lesson <out> <dir> [session id] args... -> $TMP/<out>.out (stdout), .err (stderr), .rc
lesson() {
  local o="$1" dir="$2" sid="$3"; shift 3
  (cd "$dir" && if [ -n "$sid" ]; then export CLAUDE_CODE_SESSION_ID="$sid"; else unset CLAUDE_CODE_SESSION_ID; fi
   bash "$L" "$@" > "$TMP/$o.out" 2> "$TMP/$o.err"; echo $? > "$TMP/$o.rc")
}
recs() { ls "$CC_LESSON_DIR" 2>/dev/null | grep -E '^[0-9]+-[0-9]+\.json$'; }

# ---- the CLI's refusals ----
out="$(bash "$L" --help 2>&1)"; rc=$?
assert_eq "--help works anywhere" "0" "$rc"
case "$out" in *'cc-lesson.sh "'*) r=yes ;; *) r="no: $out" ;; esac
assert_eq "...and shows the usage" "yes" "$r"
lesson none "$REPO" ""
assert_eq "no lesson: refused (exit 2)" "2" "$(cat "$TMP/none.rc")"
lesson blank "$REPO" "" "   "
assert_eq "a blank lesson: refused" "2" "$(cat "$TMP/blank.rc")"
lesson long "$REPO" "" "$(printf 'x%.0s' $(seq 1 401))"
assert_eq "a lesson over 400 characters: refused" "2" "$(cat "$TMP/long.rc")"
lesson norepo "$TMP/plain" "" "never push from a unit"
assert_eq "outside a git repo: refused" "2" "$(cat "$TMP/norepo.rc")"
case "$(cat "$TMP/norepo.err")" in *repo*) r=yes ;; *) r="no: $(cat "$TMP/norepo.err")" ;; esac
assert_eq "...saying why" "yes" "$r"
assert_eq "...and nothing was filed" "" "$(recs)"

# ---- a lesson filed in the main checkout ----
lesson ok "$REPO" "s1" "run make lint" "before make test"
assert_eq "a lesson in a repo: exits 0" "0" "$(cat "$TMP/ok.rc")"
case "$(cat "$TMP/ok.out")" in *repo*) r=yes ;; *) r="no: $(cat "$TMP/ok.out")" ;; esac
assert_eq "...saying which repo it was filed for" "yes" "$r"
R1="$(recs | head -1)"
assert_eq "...recorded as <epoch>-<pid>.json" "yes" "$([ -n "$R1" ] && echo yes || echo no)"
F1="$CC_LESSON_DIR/$R1"
assert_json "...its id is its name" "$F1" '.id' "${R1%.json}"
assert_json "...the words, joined into one line" "$F1" '.text' "run make lint before make test"
assert_json "...the repo's git common dir, absolute" "$F1" '.commonDir' "$REPO/.git"
assert_json "...its checkout" "$F1" '.toplevel' "$REPO"
assert_json "...the branch" "$F1" '.branch' "main"
assert_json "...the session that filed it" "$F1" '.session_id' "s1"
assert_json "...when" "$F1" '.at | type' "number"
assert_json "...format version 1" "$F1" '.v' "1"
assert_eq "...no temp file left behind" "" "$(ls "$CC_LESSON_DIR" | grep -v -E '^[0-9]+-[0-9]+\.json$')"
assert_eq "...in a folder only Adam can read" "700" "$(stat -c '%a' "$CC_LESSON_DIR" 2>/dev/null || stat -f '%Lp' "$CC_LESSON_DIR")"

# ---- in a worktree: the repo is still the main checkout's ----
git -C "$REPO" worktree add -q -b feat/wt "$REPO/.claude/worktrees/wt" 2>/dev/null
rm -f "$CC_LESSON_DIR"/*.json
lesson wt "$REPO/.claude/worktrees/wt" "" "$(printf 'keep tests\n\tbeside the code')"
assert_eq "in a worktree: exits 0" "0" "$(cat "$TMP/wt.rc")"
F2="$CC_LESSON_DIR/$(recs | head -1)"
assert_json "...filed for the main checkout's repo" "$F2" '.commonDir' "$REPO/.git"
assert_json "...on the worktree's branch" "$F2" '.branch' "feat/wt"
assert_json "...line breaks and tabs folded into spaces" "$F2" '.text' "keep tests beside the code"
assert_json "...no session outside one" "$F2" '.session_id' "null"

finish
