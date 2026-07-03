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
#   CC_INSTALL_CLAUDE_DIR, CC_INSTALL_HS_DIR, CC_INSTALL_NO_APP

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

# Tooling status: jq (required) + the rg/fd accelerators (optional — they make fleet search
# and the spawn modal's folder scan faster/gitignore-aware, but degrade to grep/find when
# absent). Offers to brew-install a missing accelerator ONLY when interactive (a tty on
# /dev/tty); otherwise just prints the command. Read-only probing; never hard-fails on an
# optional tool. Reused by `make doctor` via `install.sh --tools-only`.
tooling_check() {
  echo "🔧 Tooling check:"
  if have_jq; then printf '   ✅ %-4s %s\n' jq "$(command -v jq)"
  else printf '   ❌ %-4s MISSING (required) — install: brew install jq\n' jq; fi
  # tool:fallback pairs (optional accelerators)
  for entry in rg:grep fd:find; do
    tool="${entry%%:*}"; fb="${entry##*:}"
    if have "$tool"; then
      printf '   ✅ %-4s %s\n' "$tool" "$(command -v "$tool")"
    else
      printf '   ⚠️  %-4s missing — degrades to %s\n' "$tool" "$fb"
      if have brew; then
        if [ -t 1 ] && [ -r /dev/tty ]; then
          printf '      install %s now with Homebrew? [y/N] ' "$tool"
          read -r ans </dev/tty 2>/dev/null || ans=""
          case "$ans" in
            y|Y) brew install "$tool" && printf '      ✅ installed %s\n' "$tool" \
                   || printf '      ⚠️  brew install %s failed — run it by hand\n' "$tool";;
            *)   printf '      skipped — enable later with: brew install %s\n' "$tool";;
          esac
        else
          printf '      to enable: brew install %s\n' "$tool"
        fi
      else
        printf '      Homebrew not found — install %s, then it is auto-detected\n' "$tool"
      fi
    fi
  done
}

# `install.sh --tools-only` (or CC_TOOLS_ONLY=1): just run the tooling check and exit
# (powers `make doctor`). Defined before any copy/merge so it never touches your config.
if [ "${1:-}" = "--tools-only" ] || [ -n "${CC_TOOLS_ONLY:-}" ]; then tooling_check; exit 0; fi

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

# 1. Scripts + core -> ~/.claude ; dashboard + core -> ~/.hammerspoon.
for f in cc-lib.sh cc-status.sh cc-approve.sh cc-popup.sh cc-core.lua; do
  install_file "$HERE/$f" "$CLAUDE_DIR"
done
chmod +x "$CLAUDE_DIR"/cc-*.sh
for f in claude-dashboard.lua cc-core.lua; do
  install_file "$HERE/$f" "$HS_DIR"
done
echo "✅ copied hook scripts + core -> $CLAUDE_DIR ; dashboard -> $HS_DIR"

# 2. Merge hooks into settings.json (back up first; idempotent append-if-missing).
if have_jq; then
  if [ ! -f "$SETTINGS" ]; then
    jq --argjson tmpl "$(cat "$TEMPLATE")" -n '{hooks: $tmpl.hooks}' > "$SETTINGS"
    echo "✅ wrote hooks to new $SETTINGS"
  else
    merged="$(jq --argjson tmpl "$(cat "$TEMPLATE")" '
      # Give an existing cc-approve.sh hook entry the 130s timeout it needs
      # (the gate polls up to 120s; Claude Code'\''s 60s default would kill it
      # mid-wait). Idempotent: entries that already carry a timeout pass through.
      def patch_approve:
        if ((.command? // "") | test("cc-approve\\.sh")) and (has("timeout") | not)
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
          ([ (.hooks[$e.key] // [])[].hooks[]?.command? // empty ]) as $cmds
          | if ($cmds | any(test(our_re))) | not
            then .hooks[$e.key] = ((.hooks[$e.key] // []) + $e.value)
            elif (.hooks[$e.key] | type) != "array" then .
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
                  (map([.hooks[]?.command? // empty] | any(test(our_re))) | index(true)) as $i
                  | if $i == null then . + [{hooks: $missing}]
                    else .[$i].hooks += $missing end)
                end
            end)
      | .hooks |= migrate_timeout
    ' "$SETTINGS" 2>/dev/null)"
    if [ -z "$merged" ]; then
      echo "⚠️  couldn't parse $SETTINGS — leaving it; merge $TEMPLATE by hand"
    elif [ "$merged" = "$(cat "$SETTINGS")" ]; then
      echo "✅ hooks already present in $SETTINGS (no change)"
    else
      cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
      # Write-temp + rename, not `> "$SETTINGS"`: live Claude Code processes
      # re-read settings.json, and an in-place truncate+write lets one read a
      # half-written file. Same-dir mv is an atomic rename.
      printf '%s\n' "$merged" > "$CLAUDE_DIR/.settings.json.tmp.$$" \
        && mv -f "$CLAUDE_DIR/.settings.json.tmp.$$" "$SETTINGS"
      echo "✅ merged hooks into $SETTINGS (backup made)"
    fi
  fi
else
  echo "⚠️  jq not found — install jq, then merge $TEMPLATE into $SETTINGS"
fi

# 3. Ensure init.lua dofiles the dashboard.
if [ ! -f "$INIT" ] || ! grep -Fq "claude-dashboard.lua" "$INIT"; then
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

# 4. Build the Dock launcher (skipped in tests). Hand-rolled bundle -- no
# osacompile dependency (see app/build-app.sh for why applets were dropped).
if [ -z "${CC_INSTALL_NO_APP:-}" ]; then
  make -C "$HERE" app || echo "⚠️  Shepherd.app build skipped"
fi

# 5. Tooling check (jq required; rg/fd optional accelerators). Non-interactive when no tty,
# so tests and `make setup` never block; re-runnable any time via `make doctor`.
tooling_check

echo "ℹ️  Kitty users: Shepherd can auto-enable remote control in kitty.conf (Settings)."
echo "✅ install complete — open/reload Hammerspoon to start the panel."
