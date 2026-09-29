#!/usr/bin/env bash
# readme.test.sh - the README stays a front page that can't drift from the app it describes.
# Side-effect-free: reads the checkout, writes only to a temp dir.
#
# 2026-09-28: the README had grown to 1,733 lines and carried stale claims (a policy-bundle
# editor "planned" that already shipped, a gate that "falls back to the native prompt" when
# Claude Code's own permission mode may show none). It is now a short front page with the
# detail in docs/. These checks keep it that way:
#   - every relative link and image in README.md and docs/ resolves (file + #heading),
#   - every in-app feature (core.FEATURES, the single source) is in the README's feature tour
#     with a link to its reference page,
#   - every top-level docs/ page is reachable from the README,
#   - the README stays short.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT
CHECK="$ROOT/tests/support/check-links.js"

# md_files <root>: the Markdown a clone ships -- tracked plus new-but-not-ignored files (a
# worktree's pages before their first commit), never gitignored local notes (the main checkout
# keeps docs/orchestrator-next.md and docs/hardware-verification.md, untracked on purpose).
# Outside a git repo (a ZIP download), every .md file under docs/. A file deleted in the working
# tree but still in the index isn't shipped any more, so only files that exist are listed.
md_files() { # <root>
  local list f
  if git -C "$1" rev-parse --git-dir >/dev/null 2>&1; then
    list="$(cd "$1" && git ls-files --cached --others --exclude-standard -- README.md 'docs/*.md' | sort -u)"
  else
    list="$(cd "$1" && { echo README.md; find docs -name '*.md' 2>/dev/null; } | sort -u)"
  fi
  while IFS= read -r f; do [ -n "$f" ] && [ -f "$1/$f" ] && printf '%s\n' "$f"; done <<< "$list"
}
MD_EXISTING="$(md_files "$ROOT")"$'\n'

# The listing leaves a gitignored local note out, and still picks up a page not yet committed.
LR="$TMP/listing"
git init -q "$LR"
cp "$ROOT/.gitignore" "$LR/.gitignore"
mkdir -p "$LR/docs/sub"
printf '# r\n' > "$LR/README.md"; printf '# a\n' > "$LR/docs/a.md"; printf '# s\n' > "$LR/docs/sub/s.md"
git -C "$LR" add -A
printf '# new\n' > "$LR/docs/new.md"
printf '# local\n' > "$LR/docs/orchestrator-next.md"
got="$(md_files "$LR" | tr '\n' ' ')"
assert_eq "the checked pages are the ones a clone ships (a gitignored local note is left out)" \
  "README.md docs/a.md docs/new.md docs/sub/s.md " "$got"

# ---- links ------------------------------------------------------------------
# shellcheck disable=SC2086
out="$(cd "$ROOT" && printf '%s' "$MD_EXISTING" | tr '\n' '\0' | xargs -0 node "$CHECK" "$ROOT" 2>&1)"
if [ $? -eq 0 ]; then got=resolve; else got="broken:"$'\n'"$out"; fi
assert_eq "every relative link and image in README.md and docs/ resolves" "resolve" "$got"

n="$(printf '%s' "$MD_EXISTING" | grep -c 'docs/')"
if [ "$n" -ge 8 ]; then got=yes; else got="only $n"; fi
assert_eq "...and the check actually read the docs/ pages" "yes" "$got"

# The checker goes red on the real thing: a missing file, a missing heading, a path out of the repo.
mkdir -p "$TMP/site/docs"
printf '# Guide\n\n## Set it up\n\n## Upgrading after a `git pull`\n' > "$TMP/site/docs/guide.md"
printf '%s\n' '[ok](docs/guide.md#set-it-up)' '[code in a heading](docs/guide.md#upgrading-after-a-git-pull)' \
  '`[in code](nowhere.md)`' '```' '[fenced](nowhere.md)' '```' > "$TMP/site/good.md"
printf '%s\n' '[gone](docs/missing.md)' > "$TMP/site/nofile.md"
printf '%s\n' '[gone](docs/guide.md#no-such-heading)' > "$TMP/site/noanchor.md"
printf '%s\n' '![gone](docs/img/missing.png)' > "$TMP/site/noimg.md"
printf '%s\n' '[up](../outside.md)' > "$TMP/site/outside.md"
: > "$TMP/outside.md"
if node "$CHECK" "$TMP/site" good.md >/dev/null 2>&1; then got=passed; else got=refused; fi
assert_eq "the link check passes a good link, and ignores links inside code" "passed" "$got"
for f in nofile noanchor noimg outside; do
  if node "$CHECK" "$TMP/site" "$f.md" >/dev/null 2>&1; then got=passed; else got=refused; fi
  assert_eq "the link check refuses a broken link ($f)" "refused" "$got"
done

# ---- the feature tour ---------------------------------------------------------
# The tour is the README's "## Feature tour" section, up to the next "## " heading.
awk '/^## Feature tour/{on=1; next} on && /^## /{exit} on' "$ROOT/README.md" > "$TMP/tour.md"
if [ -s "$TMP/tour.md" ]; then got=present; else got=missing; fi
assert_eq "the README has a Feature tour section" "present" "$got"

lua - "$ROOT/cc-core.lua" > "$TMP/titles.txt" 2>/dev/null <<'LUA'
local core = dofile(arg[1])
for _, f in ipairs(core.FEATURES) do print(f.title) end
LUA
n="$(grep -c . "$TMP/titles.txt")"
if [ "$n" -ge 25 ]; then got=yes; else got="only $n"; fi
assert_eq "core.FEATURES was read (the in-app Features list)" "yes" "$got"

missing="" unlinked=""
while IFS= read -r title; do
  [ -n "$title" ] || continue
  line="$(grep -F -- "$title" "$TMP/tour.md" | head -1)"
  if [ -z "$line" ]; then missing="$missing [$title]"; continue; fi
  case "$line" in *"](docs/"*) ;; *) unlinked="$unlinked [$title]" ;; esac
done < "$TMP/titles.txt"
assert_eq "every core.FEATURES title is in the README's feature tour" "" "$missing"
assert_eq "...and each one links to its docs/ reference page" "" "$unlinked"

# ---- the docs index -----------------------------------------------------------------------
# Top-level pages only: docs/features/ and docs/assets/ keep their own indexes.
unindexed=""
while IFS= read -r rel; do
  case "$rel" in docs/*/*|"") continue ;; docs/*.md) ;; *) continue ;; esac
  grep -qF "]($rel" "$ROOT/README.md" || unindexed="$unindexed [$rel]"
done <<< "$MD_EXISTING"
assert_eq "every top-level docs/ page is linked from the README" "" "$unindexed"

# ---- what's on out of the box ---------------------------------------------------------------
# 2026-09-29: the Configuration section said the automations "are off until you turn them on",
# while defaults/cc-config.json -- what a fresh install starts from -- had turned six of them on.
# Every top-level block the defaults switch on (`enabled: true`) is named there by its key.
awk '/^## Configuration/{on=1; next} on && /^## /{exit} on' "$ROOT/README.md" > "$TMP/config.md"
unnamed=""
for k in $(jq -r 'to_entries[] | select((.value|type)=="object" and .value.enabled==true) | .key' "$ROOT/defaults/cc-config.json"); do
  grep -qF "\`$k\`" "$TMP/config.md" || unnamed="$unnamed [$k]"
done
assert_eq "the README's Configuration section names every block defaults/cc-config.json turns on" "" "$unnamed"
if tr '\n' ' ' < "$TMP/config.md" | tr -s ' ' | grep -qi "off until you turn them on" && [ -n "$(jq -r 'to_entries[] | select((.value|type)=="object" and .value.enabled==true) | .key' "$ROOT/defaults/cc-config.json")" ]; then
  got="claims every automation is off"; else got=accurate; fi
assert_eq "...and doesn't claim the automations are all off" "accurate" "$got"

# ---- it stays a front page ---------------------------------------------------------
lines="$(wc -l < "$ROOT/README.md" | tr -d ' ')"
if [ "$lines" -le 320 ]; then got=short; else got="$lines lines"; fi
assert_eq "the README stays a front page (320 lines at most; the detail lives in docs/)" "short" "$got"

finish
