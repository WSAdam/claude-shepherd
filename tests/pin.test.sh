#!/usr/bin/env bash
# pin.test.sh - ~/.claude/cc-pin.sh, a session's pinned links (2026-09-29, build program unit 31).
# A session pins up to 8 links -- a preview URL, a PR, a file in its worktree -- and Shepherd shows
# them as chips on its card. They belong to the WORKTREE (cc-pins/<encoded git root>.json), so they
# outlive /clear. Refused: a 9th pin, a scheme other than http(s)/file, a file outside the git root
# (a symlink included), and anything holding a shell metacharacter. Every case in
# tests/fixtures/pin-links.tsv is also run against core.pinCheck (tests/core.test.lua).
# Side-effect-free: a throwaway repo, and the pins dir under a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
export CC_PINS_DIR="$TMP/pins"
P="$ROOT/cc-pin.sh"
CASES="$ROOT/tests/fixtures/pin-links.tsv"

REPO="$TMP/repo"
git init -q -b main "$REPO"
mkdir -p "$REPO/docs" "$TMP/outside"
printf 'a\n' > "$REPO/a.md"; printf 'b\n' > "$REPO/docs/b.md"; printf 'x\n' > "$TMP/outside.md"
printf 'o\n' > "$TMP/outside/x.md"
ln -s "$TMP/outside" "$REPO/out"
ln -s "$TMP/outside.md" "$REPO/link.md"
git -C "$REPO" add a.md docs && git -C "$REPO" -c user.email=t@example.invalid -c user.name=t commit -qm init
# git names the root by its real path (macOS /var -> /private/var); so does Shepherd
GITROOT="$(git -C "$REPO" rev-parse --show-toplevel)"
PFILE="$CC_PINS_DIR/$(printf '%s' "$GITROOT" | LC_ALL=C sed 's/[^A-Za-z0-9]/-/g').json"

pin() { # <out-name> <dir> args... -> $TMP/<out>.out and $TMP/<out>.rc (run as a session in <dir>)
  local o="$1" d="$2"; shift 2
  (cd "$d" && CLAUDE_CODE_SESSION_ID=s1 bash "$P" "$@" > "$TMP/$o.out" 2>&1; echo $? > "$TMP/$o.rc")
}
count() { jq '.pins | length' "$PFILE" 2>/dev/null || echo 0; }

# ---- the shared table: the same verdicts as core.pinCheck ----
while IFS=$'\t' read -r want link; do
  case "$want" in ''|'#'*) continue ;; esac
  link="${link//\{ROOT\}/$GITROOT}"
  rm -rf "$CC_PINS_DIR"
  pin case "$REPO" add "$link"
  rc="$(cat "$TMP/case.rc")"
  if [ "$want" = refused ]; then
    got="$([ "$rc" = 2 ] && [ ! -e "$PFILE" ] && echo refused || echo "rc=$rc")"
  else
    got="$([ "$rc" = 0 ] && jq -r '.pins[0].kind' "$PFILE" 2>/dev/null || echo "rc=$rc")"
  fi
  assert_eq "pin-links.tsv: $want  $link" "$want" "$got"
done < "$CASES"
n="$(grep -c -v -E '^(#|$)' "$CASES")"
assert_eq "...and the table was read (30+ cases)" "yes" "$([ "$n" -ge 30 ] && echo yes || echo "only $n")"

# ---- add: stored under the worktree's own name, with its root ----
rm -rf "$CC_PINS_DIR"
pin add1 "$REPO" add https://github.com/org/repo/pull/12 --label "PR #12"
assert_eq "add: a link is pinned" "0" "$(cat "$TMP/add1.rc")"
assert_json "add: the file names its worktree" "$PFILE" '.root' "$GITROOT"
assert_json "add: the link" "$PFILE" '.pins[0].url' "https://github.com/org/repo/pull/12"
assert_json "add: its label" "$PFILE" '.pins[0].label' "PR #12"
assert_json "add: its kind" "$PFILE" '.pins[0].kind' "http"
assert_eq "add: says it's on the card, and how many of 8" "yes" \
  "$(grep -q '1 of 8' "$TMP/add1.out" && echo yes || echo no)"
pin add2 "$REPO/docs" add ../a.md
assert_eq "add: a plain path is resolved from the session's folder" "0" "$(cat "$TMP/add2.rc")"
assert_json "...and stored as a file:// link to its real path" "$PFILE" '.pins[1].url' "file://$GITROOT/a.md"
assert_json "...of kind file" "$PFILE" '.pins[1].kind' "file"
assert_json "...with no label unless one was given" "$PFILE" '.pins[1] | has("label")' "false"
pin add3 "$REPO" add https://github.com/org/repo/pull/12 --label "The PR"
assert_eq "add: the same link again is no second pin" "2" "$(count)"
assert_json "...it takes the new label" "$PFILE" '.pins[0].label' "The PR"
pin sub "$REPO/docs" add b.md
assert_eq "add: a session in a subfolder pins to the same worktree file" "3" "$(count)"

# ---- the cap: 8 per worktree ----
for i in 4 5 6 7 8; do pin "cap$i" "$REPO" add "http://localhost:800$i/"; done
assert_eq "cap: 8 links pinned" "8" "$(count)"
pin cap9 "$REPO" add http://localhost:8009/
assert_eq "cap: a 9th is refused" "2" "$(cat "$TMP/cap9.rc")"
assert_eq "...leaving the 8" "8" "$(count)"
assert_eq "...and says how to make room" "yes" "$(grep -q 'rm' "$TMP/cap9.out" && echo yes || echo no)"
pin cap8again "$REPO" add http://localhost:8004/ --label "api"
assert_eq "cap: relabelling a pinned link still works at 8" "0" "$(cat "$TMP/cap8again.rc")"

# ---- list ----
pin ls "$REPO" list
assert_eq "list: runs" "0" "$(cat "$TMP/ls.rc")"
assert_eq "list: one numbered line per pin" "8" "$(grep -c -E '^ *[1-8]\. ' "$TMP/ls.out")"
assert_eq "list: shows the label and the link" "yes" \
  "$(grep -F 'The PR' "$TMP/ls.out" | grep -qF 'https://github.com/org/repo/pull/12' && echo yes || echo no)"

# ---- rm: by link, by path, by number ----
pin rm1 "$REPO" rm https://github.com/org/repo/pull/12
assert_eq "rm: by its link" "0" "$(cat "$TMP/rm1.rc")"
assert_eq "...one fewer" "7" "$(count)"
assert_json "...the others keep their order" "$PFILE" '.pins[0].url' "file://$GITROOT/a.md"
pin rm2 "$REPO" rm a.md
assert_eq "rm: by the path it was pinned from" "6" "$(count)"
pin rm3 "$REPO" rm 1
assert_eq "rm: by the number list shows" "5" "$(count)"
assert_json "...the first went" "$PFILE" '.pins[0].url' "http://localhost:8004/"
pin rm4 "$REPO" rm https://nowhere.example/
assert_eq "rm: a link that isn't pinned is refused" "2" "$(cat "$TMP/rm4.rc")"
pin rm5 "$REPO" rm 9
assert_eq "rm: a number past the list is refused" "2" "$(cat "$TMP/rm5.rc")"
for u in http://localhost:8004/ http://localhost:8005/ http://localhost:8006/ http://localhost:8007/ http://localhost:8008/; do
  pin rmall "$REPO" rm "$u"
done
assert_eq "rm: the last pin takes the file with it" "gone" "$([ -e "$PFILE" ] && echo there || echo gone)"
pin lsnone "$REPO" list
assert_eq "list: no pins still runs" "0" "$(cat "$TMP/lsnone.rc")"

# ---- refusals ----
rc=0; (cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$P" list > "$TMP/nosid.out" 2>&1) || rc=$?
assert_eq "no CLAUDE_CODE_SESSION_ID: refused" "2" "$rc"
rc=0; (cd "$REPO" && env -u CLAUDE_CODE_SESSION_ID bash "$P" add https://x.example/ > "$TMP/nosid2.out" 2>&1) || rc=$?
assert_eq "...add too, writing nothing" "2 gone" "$rc $([ -e "$PFILE" ] && echo there || echo gone)"
mkdir -p "$TMP/plain"
pin norepo "$TMP/plain" add https://x.example/
assert_eq "outside a git repo: refused (pins belong to a worktree)" "2" "$(cat "$TMP/norepo.rc")"
pin nofile "$REPO" add docs/missing.md
assert_eq "a file that isn't there: refused" "2" "$(cat "$TMP/nofile.rc")"
pin outside "$REPO" add ../outside.md
assert_eq "a path outside the git root: refused" "2" "$(cat "$TMP/outside.rc")"
pin symdir "$REPO" add out/x.md
assert_eq "a file reached through a symlinked folder that leads outside: refused" "2" "$(cat "$TMP/symdir.rc")"
pin symfile "$REPO" add link.md
assert_eq "a symlink to a file outside: refused" "2" "$(cat "$TMP/symfile.rc")"
pin longurl "$REPO" add "https://x.example/$(printf 'a%.0s' $(seq 1 2001))"
assert_eq "a link over 2000 characters: refused" "2" "$(cat "$TMP/longurl.rc")"
pin longlabel "$REPO" add https://x.example/ --label "$(printf 'l%.0s' $(seq 1 81))"
assert_eq "a label over 80 characters: refused" "2" "$(cat "$TMP/longlabel.rc")"
pin ctllabel "$REPO" add https://x.example/ --label $'two\nlines'
assert_eq "a label with a control character: refused" "2" "$(cat "$TMP/ctllabel.rc")"
pin nolink "$REPO" add
assert_eq "add with no link: refused" "2" "$(cat "$TMP/nolink.rc")"
pin badcmd "$REPO" frob
assert_eq "an unknown command: refused" "2" "$(cat "$TMP/badcmd.rc")"
assert_eq "...none of the refusals wrote a pin" "gone" "$([ -e "$PFILE" ] && echo there || echo gone)"
pin meta "$REPO" add 'https://x.example/$(touch '"$TMP"'/pwned)'
assert_eq "a link carrying a command substitution is refused, and never run" "2 no" \
  "$(cat "$TMP/meta.rc") $([ -e "$TMP/pwned" ] && echo yes || echo no)"

# ---- a query with more than one parameter (2026-09-30) ----
# 2026-09-30: & was refused everywhere as a shell metacharacter, so no link with two query
# parameters (a filtered PR list, a preview with ?a=1&b=2) could be pinned -- though a link is only
# ever opened by argv, never through a shell. In an http(s) link & is URL syntax; a file's path
# still can't hold one, and the other metacharacters are refused as before.
pin amp "$REPO" add 'https://github.com/org/repo/pulls?q=is%3Aopen&sort=updated&page=2' --label "Open PRs"
assert_eq "a link with a multi-parameter query is pinned" "0" "$(cat "$TMP/amp.rc")"
assert_json "...whole, every parameter kept" "$PFILE" '.pins[0].url' 'https://github.com/org/repo/pulls?q=is%3Aopen&sort=updated&page=2'
pin amprm "$REPO" rm 'https://github.com/org/repo/pulls?q=is%3Aopen&sort=updated&page=2'
assert_eq "...and unpinned by the same link" "0 gone" "$(cat "$TMP/amprm.rc") $([ -e "$PFILE" ] && echo there || echo gone)"
printf 'x\n' > "$REPO/a&b.md"
pin ampfile "$REPO" add 'a&b.md'
assert_eq "a file whose name holds an & is still refused" "2 gone" "$(cat "$TMP/ampfile.rc") $([ -e "$PFILE" ] && echo there || echo gone)"
pin ampmeta "$REPO" add 'https://x.example/?a=1&b=$(touch '"$TMP"'/pwned2)'
assert_eq "a multi-parameter link carrying a command substitution is still refused, and never run" "2 no" \
  "$(cat "$TMP/ampmeta.rc") $([ -e "$TMP/pwned2" ] && echo yes || echo no)"
rm -f "$REPO/a&b.md"

# Another worktree whose root encodes to the same name (/a/b-c vs /a/b/c): its file is left alone.
rm -rf "$CC_PINS_DIR"; mkdir -p "$CC_PINS_DIR"
jq -n --arg r "/some/other-root" '{v:1, root:$r, pins:[{url:"https://keep.example/", kind:"http", at:1}]}' > "$PFILE"
pin clash "$REPO" add https://x.example/
assert_eq "a name another worktree's pins already use: refused" "2" "$(cat "$TMP/clash.rc")"
assert_json "...and that worktree keeps its pins" "$PFILE" '.pins[0].url' "https://keep.example/"

# ---- cc_remove: pins are per worktree, so SessionEnd drops only the pins of a worktree that's gone ----
rm -rf "$CC_PINS_DIR"; mkdir -p "$CC_PINS_DIR" "$TMP/gone-wt"
jq -n --arg r "$GITROOT" '{v:1, root:$r, pins:[{url:"https://live.example/", kind:"http", at:1}]}' > "$CC_PINS_DIR/live.json"
jq -n --arg r "$TMP/gone-wt" '{v:1, root:$r, pins:[{url:"https://gone.example/", kind:"http", at:1}]}' > "$CC_PINS_DIR/gone.json"
printf '{"v":' > "$CC_PINS_DIR/gone.json.tmp.4242"
printf 'not json' > "$CC_PINS_DIR/torn.json"
rmdir "$TMP/gone-wt"
(export CC_STATUS_DIR="$TMP/status"; mkdir -p "$CC_STATUS_DIR"; . "$ROOT/cc-lib.sh"; cc_remove somekey) >/dev/null 2>&1
assert_eq "cc_remove: keeps the pins of a worktree that's still there (they outlive /clear)" "there" \
  "$([ -e "$CC_PINS_DIR/live.json" ] && echo there || echo gone)"
assert_eq "cc_remove: drops the pins of a worktree that's gone" "gone" \
  "$([ -e "$CC_PINS_DIR/gone.json" ] && echo there || echo gone)"
assert_eq "...and their torn writes" "gone" "$([ -e "$CC_PINS_DIR/gone.json.tmp.4242" ] && echo there || echo gone)"
assert_eq "...and a pins file that names no worktree" "gone" "$([ -e "$CC_PINS_DIR/torn.json" ] && echo there || echo gone)"

finish
