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

# 2026-09-30: the check above read only the README's Configuration section. The tour's Automate
# group, docs/automation.md and docs/configuration.md each still opened with "off until you turn
# it on" after the defaults had turned auto-continue, resume and auto-compact on.
claims=""
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  if tr -d '*' < "$ROOT/$rel" | tr '\n' ' ' | tr -s ' ' | grep -qi "off until you turn"; then claims="$claims [$rel]"; fi
done <<< "$MD_EXISTING"
[ -n "$(jq -r 'to_entries[] | select((.value|type)=="object" and .value.enabled==true) | .key' "$ROOT/defaults/cc-config.json")" ] || claims=""
assert_eq "no page says the automations are off until you turn them on (a fresh install turns some on)" "" "$claims"

# ---- the reference pages against the code (2026-09-30) ----------------------------------------
# The final docs pass of the build program found four lists the units had outgrown: the config
# reference (no coach, decide, radar, schedLock, timeLost...), the files Shepherd keeps (a dozen
# new folders), the detail panel's tabs and buttons (no Requirements, Verify, Coach, Trace, Time)
# and the ☰ menu (no Inbox, Tickets, Automation trace, Restart fleet). Each is read from the code.
CONF="$ROOT/docs/configuration.md"

# Every config block: what the Lua reads through core.config, what the hooks read through
# cc_config, and the top-level keys of the example and the defaults.
blocks="$( {
  grep -ohE 'config\([A-Za-z_.() ]+, *"[A-Za-z]+' "$ROOT/cc-core.lua" "$ROOT/claude-dashboard.lua" | sed -E 's/.*"//'
  grep -ohE "cc_config '\.[A-Za-z]+" "$ROOT"/cc-*.sh | sed -E "s/.*\.//"
  jq -r 'keys[] | select(startswith("_") | not)' "$ROOT/cc-config.example.json" "$ROOT/defaults/cc-config.json"
} | sort -u)"
n="$(printf '%s\n' "$blocks" | grep -c .)"
if [ "$n" -ge 50 ]; then got=yes; else got="only $n"; fi
assert_eq "the config blocks were read from the code, the example and the defaults" "yes" "$got"
undocumented=""
for k in $blocks; do
  grep -qE "\`$k(\`|\.)" "$CONF" || undocumented="$undocumented [$k]"
done
assert_eq "docs/configuration.md names every config block the code reads" "" "$undocumented"

# Every file and folder `uninstall.sh --purge` removes is in the page's files table.
state="$(sed -n '/^STATE="/,/"$/p' "$ROOT/uninstall.sh" | tr -d '"' | sed 's/^STATE=//' | tr -s ' \n' '\n\n' | grep .)"
n="$(printf '%s\n' "$state" | grep -c .)"
if [ "$n" -ge 40 ]; then got=yes; else got="only $n"; fi
assert_eq "uninstall.sh's STATE list was read" "yes" "$got"
unlisted=""
for f in $state; do
  grep -qE "\`$f/?\`" "$CONF" || unlisted="$unlisted [$f]"
done
assert_eq "docs/configuration.md lists every file and folder --purge removes" "" "$unlisted"

# section <file> <heading>: that "## " section's text up to the next "## ", as one line (a label
# that wraps across two lines of prose is still named).
flat() { tr '\n' ' ' | tr -s ' '; }
section() { awk -v h="## $2" '$0==h{on=1; next} on && /^## /{exit} on' "$1" | flat; }

# The detail panel's tabs (core.DETAIL_TABS) in docs/fleet.md.
section "$ROOT/docs/fleet.md" "The detail panel" > "$TMP/detail-tabs.md"
lua - "$ROOT/cc-core.lua" > "$TMP/tabs.txt" 2>/dev/null <<'LUA'
local core = dofile(arg[1])
for _, t in ipairs(core.DETAIL_TABS) do print(t.label) end
LUA
n="$(grep -c . "$TMP/tabs.txt")"
if [ "$n" -ge 10 ]; then got=yes; else got="only $n"; fi
assert_eq "core.DETAIL_TABS was read" "yes" "$got"
untold=""
while IFS= read -r label; do
  [ -n "$label" ] || continue
  grep -qF -- "**$label**" "$TMP/detail-tabs.md" || untold="$untold [$label]"
done < "$TMP/tabs.txt"
assert_eq "docs/fleet.md's detail panel section names every tab" "" "$untold"

# The detail panel's buttons (the panel's #d-actions row) in docs/controls.md.
section "$ROOT/docs/controls.md" "The detail panel" > "$TMP/detail-buttons.md"
awk '/<div id="d-actions">/{on=1; next} on && /<\/div>/{exit} on' "$ROOT/claude-dashboard.lua" \
  | sed -nE 's/.*<button id="b-[a-z]+"[^>]*>([^<]+)<\/button>.*/\1/p' > "$TMP/buttons.txt"
n="$(grep -c . "$TMP/buttons.txt")"
if [ "$n" -ge 15 ]; then got=yes; else got="only $n"; fi
assert_eq "the detail panel's buttons were read from the panel" "yes" "$got"
untold=""
while IFS= read -r label; do
  [ -n "$label" ] || continue
  grep -qF -- "$label" "$TMP/detail-buttons.md" || untold="$untold [$label]"
done < "$TMP/buttons.txt"
assert_eq "docs/controls.md's detail panel section names every button" "" "$untold"

# The ☰ menu's entries (the panel's .tm-item buttons) in docs/controls.md.
sed -nE 's/.*class="tm-item".*<\/span> ([^<]+)<.*/\1/p' "$ROOT/claude-dashboard.lua" | sed 's/&amp;/\&/g' > "$TMP/menu.txt"
n="$(grep -c . "$TMP/menu.txt")"
if [ "$n" -ge 18 ]; then got=yes; else got="only $n"; fi
assert_eq "the ☰ menu's entries were read from the panel" "yes" "$got"
flat < "$ROOT/docs/controls.md" > "$TMP/controls.md"
untold=""
while IFS= read -r label; do
  [ -n "$label" ] || continue
  grep -qF -- "$label" "$TMP/controls.md" || untold="$untold [$label]"
done < "$TMP/menu.txt"
assert_eq "docs/controls.md names every ☰ menu entry" "" "$untold"

# ---- it stays a front page ---------------------------------------------------------
lines="$(wc -l < "$ROOT/README.md" | tr -d ' ')"
if [ "$lines" -le 320 ]; then got=short; else got="$lines lines"; fi
assert_eq "the README stays a front page (320 lines at most; the detail lives in docs/)" "short" "$got"

finish
