#!/usr/bin/env bash
#
# install.sh - idempotent first-run setup for Claude Shepherd.
#
# Copies the hook scripts + pure core into ~/.claude and the dashboard into
# ~/.hammerspoon, merges our hooks into ~/.claude/settings.json (backing up
# first), ensures the dofile in ~/.hammerspoon/init.lua, and builds the
# Shepherd.app Dock launcher. SAFE TO RE-RUN: a second run is a no-op.
#
# The hook merge (cf. core.mergeHooks in cc-core.lua): for each event, append our
# whole group if none of OUR scripts (cc-status/approve/popup.sh) is wired yet;
# if SOME are wired (an older install, before a sibling hook existed), append just
# the missing entries into the group we own — never skip the event outright, or
# upgrades would leave newly-shipped hooks (cc-popup.sh) unwired forever.
# Matching our exact names (not a bare "cc-" substring) avoids colliding with a
# user's own cc-prefixed hook. The test() is an UNANCHORED substring (KEEP IN SYNC
# with core.OUR_HOOK_SCRIPTS), so a contrived my-cc-status.sh would be a false
# positive -- acceptable next to the old bare-"cc-" net.
#
# Env overrides (used by tests/install.test.sh to stay hermetic):
#   CC_INSTALL_CLAUDE_DIR, CC_INSTALL_HS_DIR, CC_INSTALL_NO_APP,
#   CC_INSTALL_HAMMERSPOON_APP (path probed for Hammerspoon.app)
#
# Pre-flight test gate: before ANYTHING is copied or merged, `make test` must pass
# (2026-09-15: the copy used to run first, so a red suite still put untested hook
# scripts where the already-wired hooks run them). Bypass with `--skip-tests` or
# CC_INSTALL_SKIP_TESTS=1 (tests/install.test.sh exports the latter so its own
# install.sh calls don't recurse back into the suite).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
CLAUDE_DIR="${CC_INSTALL_CLAUDE_DIR:-$HOME/.claude}"
HS_DIR="${CC_INSTALL_HS_DIR:-$HOME/.hammerspoon}"
SETTINGS="$CLAUDE_DIR/settings.json"
TEMPLATE="$HERE/settings-hooks.json"
INIT="$HS_DIR/init.lua"
DOFILE_LINE='dofile(os.getenv("HOME") .. "/.hammerspoon/claude-dashboard.lua")'

have_jq() { command -v jq >/dev/null 2>&1; }
have() { command -v "$1" >/dev/null 2>&1; }
have_lua() { command -v lua >/dev/null 2>&1; }
HAMMERSPOON_APP="${CC_INSTALL_HAMMERSPOON_APP:-/Applications/Hammerspoon.app}"
have_hammerspoon() { [ -d "$HAMMERSPOON_APP" ]; }

# Offer to `brew install` a missing tool when interactive (a tty on /dev/tty); otherwise
# just print the command. $2 = "--cask" for a cask. Never fails the caller.
offer_brew_install() {
  local tool="$1" cask="${2:-}" label
  label="brew install ${cask:+$cask }$tool"
  if have brew; then
    if [ -t 1 ] && [ -r /dev/tty ]; then
      printf '      install %s now with Homebrew? [y/N] ' "$tool"
      read -r ans </dev/tty 2>/dev/null || ans=""
      case "$ans" in
        y|Y) brew install ${cask:+$cask} "$tool" && printf '      ✅ installed %s\n' "$tool" \
               || printf '      ⚠️  %s failed — run it by hand\n' "$label";;
        *)   printf '      skipped — enable later with: %s\n' "$label";;
      esac
    else
      printf '      to enable: %s\n' "$label"
    fi
  else
    printf '      Homebrew not found — install %s, then it is auto-detected\n' "$tool"
  fi
}

# Tooling status: jq (required) + the rg/fd accelerators (optional — they make fleet search
# and the spawn modal's folder scan faster/gitignore-aware, but degrade to grep/find when
# absent). Offers to brew-install a missing accelerator ONLY when interactive (a tty on
# /dev/tty); otherwise just prints the command. Read-only probing; never hard-fails on an
# optional tool. Reused by `make doctor` via `install.sh --tools-only`.
tooling_check() {
  echo "🔧 Tooling check:"
  if have_jq; then printf '   ✅ %-4s %s\n' jq "$(command -v jq)"
  else printf '   ❌ %-4s MISSING (required) — install: brew install jq\n' jq; fi
  # lua + node run the test suite (the pre-flight gate); required unless you --skip-tests
  # (2026-09-15: node was never named, so a machine without it hit "command not found")
  for t in lua node; do
    if have "$t"; then printf '   ✅ %-4s %s\n' "$t" "$(command -v "$t")"
    else printf '   ❌ %-4s MISSING (required to run the tests) — install: brew install %s\n' "$t" "$t"; fi
  done
  # Hammerspoon hosts the panel itself — probed on disk, not on PATH
  if have_hammerspoon; then printf '   ✅ %-4s %s\n' hs "$HAMMERSPOON_APP"
  else
    printf '   ❌ %-4s Hammerspoon.app MISSING (required) — the panel needs it\n' hs
    offer_brew_install hammerspoon --cask
  fi
  # tool:fallback pairs (optional accelerators)
  for entry in rg:grep fd:find; do
    tool="${entry%%:*}"; fb="${entry##*:}"
    if have "$tool"; then
      printf '   ✅ %-4s %s\n' "$tool" "$(command -v "$tool")"
    else
      printf '   ⚠️  %-4s missing — degrades to %s\n' "$tool" "$fb"
      offer_brew_install "$tool"
    fi
  done
}

# `install.sh --tools-only` (or CC_TOOLS_ONLY=1): just run the tooling check and exit
# (powers `make doctor`). Defined before any copy/merge so it never touches your config.
if [ "${1:-}" = "--tools-only" ] || [ -n "${CC_TOOLS_ONLY:-}" ]; then tooling_check; exit 0; fi

SKIP_TESTS=0
for arg in "$@"; do [ "$arg" = "--skip-tests" ] && SKIP_TESTS=1; done
[ -n "${CC_INSTALL_SKIP_TESTS:-}" ] && SKIP_TESTS=1

# Pre-flight gate (step 1): prove the code works BEFORE anything is copied into
# ~/.claude / ~/.hammerspoon or merged into settings.json / init.lua. A hard abort here
# leaves nothing behind. A missing `lua` or `node` (the suite needs both) is treated the
# same as a failing test: we cannot verify, so we do not touch your config.
run_test_gate() {
  if [ "$SKIP_TESTS" -eq 1 ]; then
    echo "⏭️  pre-flight tests skipped (--skip-tests)"
    return 0
  fi
  local missing=0 t
  for t in lua node; do
    if ! have "$t"; then
      echo "❌ cannot verify: $t not found — install it (brew install $t) or re-run with --skip-tests"
      missing=1
    fi
  done
  [ "$missing" -eq 1 ] && exit 1
  echo "🧪 running pre-flight tests..."
  # The run is kept in a log, and a failure is summarised at the end (2026-09-17: the one failing
  # test sat thousands of lines above "SOME TESTS FAILED" on a coworker's screen).
  local log="${CC_INSTALL_TEST_LOG:-${TMPDIR:-/tmp}/shepherd-install-tests.log}"
  make -C "$HERE" test 2>&1 | tee "$log"
  if [ "${PIPESTATUS[0]}" -ne 0 ]; then
    echo "❌ pre-flight tests failed — aborting before touching your settings.json/init.lua."
    echo "   Failing:"
    # -a: a log with a stray NUL is still text (2026-09-17: grep printed "Binary file matches")
    grep -aE '^(FAIL - |lua: |node: )|: error:|^Error' "$log" | head -n 40 | sed 's/^/     /'
    echo "   Full test log: $log"
    echo "   Fix the failures above, or re-run with --skip-tests to bypass."
    exit 1
  fi
  echo "✅ pre-flight tests passed"
}

mkdir -p "$CLAUDE_DIR" "$HS_DIR"

# Atomic file install: cp to a dot-prefixed temp in the destination dir, then mv
# (same-dir rename) over the target. A plain `cp src dst` rewrites dst IN PLACE
# (same inode, O_TRUNC): bash reads scripts lazily from its open fd, so a hook
# mid-execution — e.g. a cc-approve.sh waiter blocked in its 120s poll loop with
# the teardown still unread — would resume at its saved byte offset inside the
# NEW content and execute garbled half-lines. rename swaps the directory entry;
# running readers keep the old inode until they exit. Dot-prefix keeps the temp
# out of the cc-*.sh chmod glob below.
install_file() {
  local src="$1" dstdir="$2" base
  base="$(basename "$src")"
  cp "$src" "$dstdir/.$base.tmp.$$" && mv -f "$dstdir/.$base.tmp.$$" "$dstdir/$base"
}

CLAUDE_FILES="cc-lib.sh cc-status.sh cc-approve.sh cc-popup.sh cc-merge.sh cc-fleet.sh cc-ask.sh cc-core.lua"
HS_FILES="claude-dashboard.lua cc-core.lua"

# 0. Every file we ship must be in the checkout, or we'd wire a hook to a file that
# doesn't exist (2026-09-15: a missing cc-ask.sh printed "copied" and "install complete").
for f in $CLAUDE_FILES $HS_FILES settings-hooks.json; do
  if [ ! -r "$HERE/$f" ]; then
    echo "❌ $f is missing from the checkout ($HERE) — aborting before touching anything."
    exit 1
  fi
done

# 1. Pre-flight test gate — nothing below this line runs if the suite is red.
run_test_gate

# 2. Scripts + core -> ~/.claude ; dashboard + core -> ~/.hammerspoon. Only the scripts we
# ship get +x: a user's own cc-*.sh in ~/.claude is theirs to mode.
for f in $CLAUDE_FILES; do
  install_file "$HERE/$f" "$CLAUDE_DIR" || { echo "❌ couldn't copy $f -> $CLAUDE_DIR"; exit 1; }
  case "$f" in *.sh) chmod +x "$CLAUDE_DIR/$f" ;; esac
done
for f in $HS_FILES; do
  install_file "$HERE/$f" "$HS_DIR" || { echo "❌ couldn't copy $f -> $HS_DIR"; exit 1; }
done
echo "✅ copied hook scripts + core -> $CLAUDE_DIR ; dashboard -> $HS_DIR"

# Follow a symlink chain to the real file (a dotfiles-managed settings.json is a link;
# 2026-09-15: renaming over the link replaced it with a plain file and the dotfiles copy
# never got the hooks). Relative link targets resolve against the link's own directory.
resolve_link() {
  local p="$1" t n=0
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
    n=$((n + 1))
  done
  printf '%s' "$p"
}

# 3. Merge hooks into settings.json (back up first; idempotent append-if-missing).
if have_jq; then
  if [ ! -f "$SETTINGS" ]; then
    jq --argjson tmpl "$(cat "$TEMPLATE")" -n '{hooks: $tmpl.hooks}' > "$SETTINGS"
    echo "✅ wrote hooks to new $SETTINGS"
  elif ! jq -e . "$SETTINGS" >/dev/null 2>&1; then
    echo "⚠️  couldn't parse $SETTINGS — leaving it; merge $TEMPLATE by hand"
  else
    merge_err="$CLAUDE_DIR/.settings.merge.err.$$"
    merged="$(jq --argjson tmpl "$(cat "$TEMPLATE")" '
      # Give an existing cc-approve.sh hook entry the 130s timeout it needs
      # (the gate polls up to 120s; Claude Code'\''s 60s default would kill it
      # mid-wait). Idempotent; a value at or above 130 passes through, a lower one
      # (2026-09-15: an old 60 was kept, and the wait was killed halfway) is raised.
      def patch_approve:
        if ((.command? // "") | test("cc-approve\\.sh"))
           and (((.timeout? // 0) | if type == "number" then . else 0 end) < 130)
        then . + {timeout: 130} else . end;
      # SHAPE-PRESERVING migration over every event group (including ones we
      # do not own). Invariants — pinned by install.test.sh'\''s "shape:" checks:
      #   * object-valued event groups pass through the type=="array" guard;
      #   * stray non-object array elements survive: `.hooks?` on a string
      #     suppresses to EMPTY, and an `if` yielding empty makes `map` DROP
      #     the element — `(.hooks? // null)` turns that into null instead.
      def migrate_timeout:
        with_entries(.value |= (if type == "array" then map(
          if ((.hooks? // null) | type) == "array"
          then .hooks |= map(patch_approve)
          else . end)
        else . end));
      def our_re: "cc-(status|approve|popup)\\.sh";
      .hooks //= {}
      | reduce ($tmpl.hooks | to_entries[]) as $e (.;
          # An event group that is not a list (a hand-edited object) is left exactly as
          # it is -- 2026-09-15: `[]` on it made the filter fail and the valid file was
          # reported as unparseable. The shell warns about it after the merge.
          (if ((.hooks[$e.key] // []) | type) == "array" then .hooks[$e.key] // [] else [] end) as $grp
          | ([ $grp[].hooks[]?.command? // empty ]) as $cmds
          | if ((.hooks[$e.key] // []) | type) != "array" then .
            elif ($cmds | any(test(our_re))) | not
            then .hooks[$e.key] = ($grp + $e.value)
            else
              # Per-entry upgrade: the event already carries SOME of our scripts,
              # but a hook shipped AFTER that install (cc-popup.sh postdates the
              # Stop/Notification/PermissionRequest wiring of early installs) is
              # still missing. Skipping the whole template group would leave it
              # unwired forever — instead append just OUR missing entries into
              # the first group we already own, preserving its matcher.
              ([ $e.value[].hooks[]?
                 | select((.command? // "") | test(our_re))
                 | (.command | capture("(?<n>" + our_re + ")").n) as $n
                 | select(($cmds | any(contains($n))) | not) ]) as $missing
              | if ($missing | length) == 0 then .
                else .hooks[$e.key] |= (
                  # $i = index of the first existing group in this event that already
                  # carries one of our scripts; append the missing siblings THERE so
                  # they inherit its matcher. null (no such group) => add a fresh group.
                  (map([.hooks[]?.command? // empty] | any(test(our_re))) | index(true)) as $i
                  | if $i == null then . + [{hooks: $missing}]
                    else .[$i].hooks += $missing end)
                end
            end)
      | .hooks |= migrate_timeout
      # cc-ask.sh (2026-09-11) lives in its OWN PreToolUse group (matcher AskUserQuestion,
      # a long timeout: it holds the question for Shepherd). The per-entry upgrade above
      # would drop it into the matcher-"" group and run it for every tool, so an install
      # that predates it gets the template group itself, once.
      | if ([ (.hooks.PreToolUse // [])[]?.hooks[]?.command? // empty ] | any(contains("cc-ask.sh"))) then .
        elif ((.hooks.PreToolUse // []) | type) != "array" then .
        else .hooks.PreToolUse = ((.hooks.PreToolUse // [])
               + [ $tmpl.hooks.PreToolUse[] | select(.matcher == "AskUserQuestion") ])
        end
    ' "$SETTINGS" 2>"$merge_err")"
    if [ -z "$merged" ]; then
      echo "⚠️  hook merge failed on $SETTINGS — leaving it; merge $TEMPLATE by hand"
      sed 's/^/      jq: /' "$merge_err"
    # Compare through jq's printer on both sides (2026-09-15: the raw file was compared
    # with jq's re-serialisation, so a fully wired file in any other layout was rewritten
    # and backed up on every run).
    elif [ "$merged" = "$(jq . "$SETTINGS")" ]; then
      echo "✅ hooks already present in $SETTINGS (no change)"
    else
      cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
      # Write-temp + rename, not `> "$SETTINGS"`: live Claude Code processes
      # re-read settings.json, and an in-place truncate+write lets one read a
      # half-written file. Same-dir mv is an atomic rename -- in the REAL file's
      # directory, so a symlinked settings.json stays a link to an updated file.
      real="$(resolve_link "$SETTINGS")"
      printf '%s\n' "$merged" > "$(dirname "$real")/.settings.json.tmp.$$" \
        && mv -f "$(dirname "$real")/.settings.json.tmp.$$" "$real"
      echo "✅ merged hooks into $SETTINGS (backup made)"
    fi
    rm -f "$merge_err"
    # Events we ship hooks for whose group is not a list were left alone above; say so,
    # or the user believes those hooks are wired.
    if [ -n "$merged" ]; then
      for ev in $(printf '%s' "$merged" | jq -r --argjson tmpl "$(cat "$TEMPLATE")" \
          '[ ($tmpl.hooks | keys[]) as $k | select((.hooks[$k] // []) | type != "array") | $k ] | .[]'); do
        echo "⚠️  hooks.$ev in $SETTINGS is an object, not a list — its Shepherd hooks weren't wired; make it a list and re-run"
      done
    fi
  fi
else
  echo "⚠️  jq not found — install jq, then merge $TEMPLATE into $SETTINGS"
fi

# 3b. The Claude Code settings the worktree flow relies on (defaults/claude-settings.json:
# worktrees branch from HEAD, Remote Control at startup, push notifications, effort) --
# each added only where the user has no value of their own (2026-09-17: a coworker's fresh
# install should work like Adam's machine without overriding anything they chose).
DEFAULT_CLAUDE_SETTINGS="$HERE/defaults/claude-settings.json"
if have_jq && [ -r "$DEFAULT_CLAUDE_SETTINGS" ] && [ -f "$SETTINGS" ] && jq -e . "$SETTINGS" >/dev/null 2>&1; then
  filled="$(jq --argjson d "$(cat "$DEFAULT_CLAUDE_SETTINGS")" '
    . as $orig
    | try (reduce ($d | paths(scalars)) as $p (.;
             if getpath($p) == null then setpath($p; $d | getpath($p)) else . end))
      catch $orig' "$SETTINGS" 2>/dev/null)"
  if [ -n "$filled" ] && [ "$filled" != "$(jq . "$SETTINGS")" ]; then
    cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
    real="$(resolve_link "$SETTINGS")"
    printf '%s\n' "$filled" > "$(dirname "$real")/.settings.json.tmp.$$" \
      && mv -f "$(dirname "$real")/.settings.json.tmp.$$" "$real"
    echo "✅ added Shepherd's default Claude Code settings you hadn't set (backup made)"
  fi
fi

# 3c. Shepherd's own settings: Adam's (defaults/cc-config.json) on a machine that has none.
# An existing ~/.claude/cc-config.json is the user's and is never touched.
if [ ! -e "$CLAUDE_DIR/cc-config.json" ] && [ -r "$HERE/defaults/cc-config.json" ]; then
  install_file "$HERE/defaults/cc-config.json" "$CLAUDE_DIR" \
    && echo "✅ wrote Shepherd's default settings -> $CLAUDE_DIR/cc-config.json"
fi

# 3d. The methodology Claude sessions follow with Shepherd (methodology/CLAUDE.md) goes into
# ~/.claude/CLAUDE.md between two marker lines: appended once, replaced on a re-install, and
# skipped for a CLAUDE.md that already keeps the worktree workflow by hand (Adam's own).
METHODOLOGY="$HERE/methodology/CLAUDE.md"
MD="$CLAUDE_DIR/CLAUDE.md"
MARK_START='<!-- shepherd-methodology:start (written by the Shepherd installer; re-installing replaces this block) -->'
MARK_END='<!-- shepherd-methodology:end -->'
if [ -r "$METHODOLOGY" ]; then
  if [ -f "$MD" ] && grep -q 'shepherd-methodology:start' "$MD"; then
    tmpmd="$(dirname "$(resolve_link "$MD")")/.CLAUDE.md.tmp.$$"
    awk -v s="$MARK_START" -v e="$MARK_END" -v src="$METHODOLOGY" '
      /shepherd-methodology:start/ { print s; while ((getline l < src) > 0) print l; skip = 1; next }
      /shepherd-methodology:end/   { print e; skip = 0; next }
      !skip { print }' "$MD" > "$tmpmd"
    if cmp -s "$tmpmd" "$MD"; then rm -f "$tmpmd"; echo "✅ Shepherd methodology already current in $MD"
    else mv -f "$tmpmd" "$(resolve_link "$MD")"; echo "✅ updated the Shepherd methodology block in $MD"; fi
  elif [ -f "$MD" ] && grep -q '^## Parallel Worktree Workflow' "$MD"; then
    echo "✅ $MD already has the worktree workflow -- Shepherd methodology not added"
  else
    {
      if [ -s "$MD" ]; then
        cat "$MD"
        [ -n "$(tail -c1 "$MD")" ] && printf '\n'
        printf '\n'
      fi
      printf '%s\n' "$MARK_START"; cat "$METHODOLOGY"; printf '%s\n' "$MARK_END"
    } > "$CLAUDE_DIR/.CLAUDE.md.tmp.$$"
    real="$MD"; [ -e "$MD" ] && real="$(resolve_link "$MD")"
    mv -f "$CLAUDE_DIR/.CLAUDE.md.tmp.$$" "$real"
    echo "✅ added the Shepherd methodology to $MD"
  fi
fi

# 4. Ensure init.lua dofiles the dashboard. Any non-comment line that loads it counts
# (a user may load it their own way; a second load would double every hotkey and timer),
# a commented-out one does not (2026-09-15: a bare grep counted it and never re-added).
if [ ! -f "$INIT" ] || ! grep -v '^[[:space:]]*--' "$INIT" | grep -Fq "claude-dashboard.lua"; then
  # A pre-existing init.lua may lack a trailing newline; appending straight onto
  # its last line would glue the dofile into invalid Lua (breaking the user's
  # whole config). Separate first. ($() strips a trailing \n, so non-empty
  # output from tail -c1 means the last byte is NOT a newline.)
  if [ -s "$INIT" ] && [ -n "$(tail -c1 "$INIT")" ]; then printf '\n' >> "$INIT"; fi
  printf '%s\n' "$DOFILE_LINE" >> "$INIT"
  echo "✅ added dofile to $INIT"
else
  echo "✅ dofile already in $INIT"
fi

# 5. Build the Dock launcher (skipped in tests). Hand-rolled bundle -- no
# osacompile dependency (see app/build-app.sh for why applets were dropped).
if [ -z "${CC_INSTALL_NO_APP:-}" ]; then
  make -C "$HERE" app || echo "⚠️  Shepherd.app build skipped"
fi

# 5b. The companion VS Code extension (vscode-bridge/): lets Shepherd close one exact
# Claude tab without keystrokes. Local package + VS Code's own CLI, warn-only.
if [ -z "${CC_INSTALL_NO_BRIDGE:-}" ]; then
  make -C "$HERE" --no-print-directory tab-bridge || echo "⚠️  Shepherd tab bridge install skipped"
fi

# 6. Tooling check (jq required; rg/fd optional accelerators). Non-interactive when no tty,
# so tests and `make setup` never block; re-runnable any time via `make doctor`.
tooling_check

echo "ℹ️  Kitty users: Shepherd can auto-enable remote control in kitty.conf (Settings)."
echo "✅ install complete — open/reload Hammerspoon to start the panel."
