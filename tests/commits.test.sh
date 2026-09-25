#!/usr/bin/env bash
# commits.test.sh - ~/.claude/cc-commits.sh, the git side of the commit stats under the fleet
# block (2026-09-25). It finds every repo a Claude session worked in from the transcripts under
# ~/.claude/projects, then prints the user's OWN commits in each since an epoch, with their
# line counts. Whose commits count comes from each repo's git identity, never from Shepherd,
# so a coworker's install counts theirs. Side-effect-free: throwaway repos, a fake projects dir
# and a private global git config under a temp dir.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
S="$ROOT/cc-commits.sh"
NOW="$(date +%s)"
DAY=86400

# A private git identity: the real ~/.gitconfig must never decide whose commits these are.
export HOME="$TMP/home" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
git config --file "$GIT_CONFIG_GLOBAL" user.email me@example.invalid
git config --file "$GIT_CONFIG_GLOBAL" user.name Me

at() { printf '%s +0000' "$(( NOW - $1 ))"; }   # <seconds ago> -> a git date
commit_as() { # <dir> <email> <seconds ago> <subject> <file>
  printf '%s\n' "$4" >> "$1/$5"
  git -C "$1" add -A
  GIT_AUTHOR_DATE="$(at "$3")" GIT_COMMITTER_DATE="$(at "$3")" \
    git -C "$1" -c user.email="$2" -c user.name=x commit -qm "$4"
}

# alpha: mine, someone else's, an alias's, one too old, a worktree branch's, a stash, a note
ALPHA="$TMP/work/alpha"
git init -q -b main "$ALPHA"
printf '.claude/worktrees/\n' > "$ALPHA/.gitignore"
commit_as "$ALPHA" me@example.invalid $((40 * DAY)) "too old" old.txt
commit_as "$ALPHA" me@example.invalid $DAY "mine on main" mine.txt
commit_as "$ALPHA" other@example.invalid $DAY "theirs" theirs.txt
commit_as "$ALPHA" alias@example.invalid $DAY "alias commit" alias.txt
git -C "$ALPHA" worktree add -q "$ALPHA/.claude/worktrees/unit" -b feat/unit
commit_as "$ALPHA/.claude/worktrees/unit" me@example.invalid 3600 "mine on a worktree branch" unit.txt
printf 'dirty\n' >> "$ALPHA/mine.txt"
git -C "$ALPHA" stash push -q -m "stashed work"
git -C "$ALPHA" notes add -m "a note" HEAD

# beta: a repo-local identity overrides the global one; its transcript is from a removed worktree
BETA="$TMP/work/beta"
git init -q -b main "$BETA"
git -C "$BETA" config user.email beta-me@example.invalid
commit_as "$BETA" beta-me@example.invalid $DAY "beta mine" b.txt
commit_as "$BETA" me@example.invalid $DAY "global identity in beta" g.txt

# gamma: only an old transcript points here
GAMMA="$TMP/work/gamma"
git init -q -b main "$GAMMA"
commit_as "$GAMMA" me@example.invalid $DAY "gamma mine" c.txt

PROJ="$TMP/projects"
transcript() { # <name> <cwd>
  mkdir -p "$PROJ/$1"
  printf '{"type":"user","cwd":"%s","sessionId":"s"}\n{"type":"assistant"}\n' "$2" > "$PROJ/$1/s.jsonl"
}
transcript alpha "$ALPHA"
transcript alpha-unit "$ALPHA/.claude/worktrees/unit"
transcript beta-gone "$BETA/.claude/worktrees/gone"
transcript gamma "$GAMMA"
transcript nowhere "$TMP/work/not-a-repo"
perl -e '$t = time - 30 * 86400; utime($t, $t, $ARGV[0])' "$PROJ/gamma/s.jsonl"

OUT="$TMP/out"
bash "$S" --since $(( NOW - 14 * DAY )) --lookback-days 14 --email alias@example.invalid \
  --projects-dir "$PROJ" > "$OUT" 2> "$TMP/err"
assert_eq "exits 0" "0" "$?"

A="$(cd "$ALPHA" && pwd -P)"; B="$(cd "$BETA" && pwd -P)"
repos() { grep '^@@repo' "$OUT" | cut -f2; }
assert_eq "lists each repo Claude worked in once, as its main checkout" "$(printf '%s\n%s' "$A" "$B" | sort)" "$(repos | sort)"
assert_eq "a transcript older than the lookback doesn't count its repo" "0" "$(repos | grep -c gamma)"
assert_eq "the global identity plus the --email alias" "me@example.invalid,alias@example.invalid" \
  "$(grep "^@@repo	$A	" "$OUT" | cut -f3)"
assert_eq "a repo-local user.email wins over the global one" "beta-me@example.invalid,alias@example.invalid" \
  "$(grep "^@@repo	$B	" "$OUT" | cut -f3)"

# Shepherd runs the script with /bin/bash -- bash 3.2 on macOS -- whatever bash is on PATH here.
if [ -x /bin/bash ]; then
  /bin/bash "$S" --since $(( NOW - 14 * DAY )) --lookback-days 14 --email alias@example.invalid \
    --projects-dir "$PROJ" > "$TMP/out.sysbash" 2> "$TMP/err.sysbash"
  assert_eq "/bin/bash prints exactly what bash on PATH does" "same" \
    "$(cmp -s "$OUT" "$TMP/out.sysbash" && echo same || echo "differs: $(head -c 300 "$TMP/err.sysbash")")"
fi

subjects() { # <root>: the subjects printed under that repo
  awk -v r="$1" -F '\t' '/^@@repo/ { on = ($2 == r); next } on && /^\001/ { print $4 }' "$OUT"
}
has() { subjects "$1" | grep -qxF "$2" && echo yes || echo no; }
assert_eq "my commit on main is listed" yes "$(has "$A" "mine on main")"
assert_eq "my commit on a worktree branch is listed" yes "$(has "$A" "mine on a worktree branch")"
assert_eq "the alias's commit is listed" yes "$(has "$A" "alias commit")"
assert_eq "someone else's commit is not" no "$(has "$A" "theirs")"
assert_eq "a commit before --since is not" no "$(has "$A" "too old")"
assert_eq "the stash's commits are not" "0" "$(subjects "$A" | grep -cE '^(WIP|index) on')"
assert_eq "the notes ref's commit is not" "0" "$(subjects "$A" | grep -c 'Notes added')"
assert_eq "beta lists its local identity's commit" yes "$(has "$B" "beta mine")"
assert_eq "beta skips the global identity it overrides" no "$(has "$B" "global identity in beta")"
assert_eq "a commit carries its numstat line" "1" "$(grep -c "^1	0	unit.txt$" "$OUT")"
assert_eq "a commit header carries sha, author epoch and email" "1" \
  "$(grep -c "^$(printf '\001')[0-9a-f]\{40\}	[0-9]*	me@example.invalid	mine on main$" "$OUT")"

# no identity anywhere: the header still names the repo, no log follows
rm -f "$GIT_CONFIG_GLOBAL"; git -C "$BETA" config --unset user.email
bash "$S" --since $(( NOW - 14 * DAY )) --projects-dir "$PROJ" > "$TMP/noid"
assert_eq "no identity: the repos are still listed" "2" "$(grep -c '^@@repo' "$TMP/noid")"
assert_eq "no identity: with no emails" "" "$(grep '^@@repo' "$TMP/noid" | cut -f3 | tr -d '\n')"
assert_eq "no identity: and no commits" "0" "$(grep -c "^$(printf '\001')" "$TMP/noid")"

bash "$S" --projects-dir "$PROJ" > /dev/null 2>&1
assert_eq "--since is required" "2" "$?"
bash "$S" --since $(( NOW - DAY )) --projects-dir "$TMP/missing" > "$TMP/none"
assert_eq "a missing projects dir lists nothing and succeeds" "0:0" "$?:$(wc -l < "$TMP/none" | tr -d ' ')"

# A fresh install copies Adam's config (defaults/cc-config.json): it must never name whose
# commits count, or every coworker's panel would count Adam's.
assert_eq "defaults/cc-config.json ships no author emails" "0" \
  "$(jq -r '(.commits.authorEmails // []) | length' "$ROOT/defaults/cc-config.json")"

finish
