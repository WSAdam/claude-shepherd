#!/usr/bin/env bash
#
# bootstrap.sh - everything Claude Shepherd needs, on a Mac that may have none of it, then
# Shepherd itself (2026-09-17). "Install Shepherd.command" runs this on a double-click.
#
#   1. Xcode command-line tools (git, make)       -- macOS's own installer dialog
#   2. Homebrew                                    -- Homebrew's official installer (asks for your password)
#   3. jq, lua, node (required); ripgrep, fd (faster search, optional)
#   4. Hammerspoon and VS Code                     -- brew casks
#   5. Claude Code                                 -- Anthropic's official installer
#   6. Claude Code's VS Code extension
#   7. install.sh                                  -- Shepherd, its settings and methodology
#   8. starts Hammerspoon and opens the Accessibility pane it needs
#
# Anything already installed is left alone, so it is safe to re-run. A required piece that
# won't install stops here, before install.sh touches your settings.
#
# Test overrides (tests/bootstrap.test.sh): CC_BOOT_BREW_PATHS, CC_BOOT_APP_DIRS, CC_BOOT_ZPROFILE,
# CC_BOOT_INSTALL (the command run instead of install.sh).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BREW_PATHS="${CC_BOOT_BREW_PATHS:-/opt/homebrew/bin/brew /usr/local/bin/brew}"
APP_DIRS="${CC_BOOT_APP_DIRS:-/Applications $HOME/Applications}"
ZPROFILE="${CC_BOOT_ZPROFILE:-$HOME/.zprofile}"
HOMEBREW_URL="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
CLAUDE_URL="https://claude.ai/install.sh"

say()  { printf '%s\n' "$*"; }
fail() { say "❌ $*"; say "   Fix that, then double-click Install Shepherd again -- finished steps are skipped."; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

say "🚀 Installing Claude Shepherd and everything it needs"
say ""

[ "$(uname)" = "Darwin" ] || fail "Shepherd runs on macOS only."

# A downloaded copy carries macOS's quarantine flag, which blocks the scripts and the app it builds.
xattr -dr com.apple.quarantine "$HERE" 2>/dev/null || true

# 1. Xcode command-line tools
if xcode-select -p >/dev/null 2>&1; then
  say "✅ Xcode command-line tools"
else
  say "🔍 Installing the Xcode command-line tools -- click Install in the dialog that opens, then wait here"
  xcode-select --install >/dev/null 2>&1 || true
  waited=0
  until xcode-select -p >/dev/null 2>&1; do
    [ "$waited" -ge 3600 ] && fail "the command-line tools didn't finish installing within an hour."
    sleep 10; waited=$((waited + 10))
  done
  say "✅ Xcode command-line tools installed"
fi

# 2. Homebrew
find_brew() {
  local b
  if have brew; then command -v brew; return 0; fi
  for b in $BREW_PATHS; do [ -x "$b" ] && { printf '%s' "$b"; return 0; }; done
  return 1
}
BREW="$(find_brew || true)"
if [ -z "$BREW" ]; then
  say "🔍 Installing Homebrew -- it will ask for your Mac password"
  /bin/bash -c "$(curl -fsSL "$HOMEBREW_URL")" || fail "Homebrew's installer failed."
  BREW="$(find_brew || true)"
  [ -n "$BREW" ] || fail "Homebrew still isn't installed."
  say "✅ Homebrew installed"
else
  say "✅ Homebrew"
fi
eval "$("$BREW" shellenv)"
# New Terminal windows need brew on their PATH too (Homebrew's installer only prints this step).
if ! grep -qs 'brew shellenv' "$ZPROFILE"; then
  printf '\neval "$(%s shellenv)"\n' "$BREW" >> "$ZPROFILE"
fi

# 3. Command-line tools: formula:command:required
for entry in jq:jq:1 lua:lua:1 node:node:1 ripgrep:rg:0 fd:fd:0; do
  formula="${entry%%:*}"; rest="${entry#*:}"; cmd="${rest%%:*}"; required="${rest##*:}"
  if have "$cmd"; then say "✅ $formula"; continue; fi
  say "🔍 brew install $formula"
  if "$BREW" install "$formula" && have "$cmd"; then
    say "✅ $formula installed"
  elif [ "$required" = 1 ]; then
    fail "$formula didn't install (brew install $formula)."
  else
    say "⚠️  $formula didn't install -- optional, Shepherd searches more slowly without it"
  fi
done

# 4. Apps
find_app() {
  local d
  for d in $APP_DIRS; do [ -d "$d/$1" ] && { printf '%s' "$d/$1"; return 0; }; done
  [ -n "${2:-}" ] && mdfind "kMDItemCFBundleIdentifier == '$2'" 2>/dev/null | head -n 1 | grep . && return 0
  return 1
}
if find_app Hammerspoon.app org.hammerspoon.Hammerspoon >/dev/null; then say "✅ Hammerspoon"
else
  say "🔍 brew install --cask hammerspoon"
  "$BREW" install --cask hammerspoon && find_app Hammerspoon.app >/dev/null || fail "Hammerspoon didn't install."
  say "✅ Hammerspoon installed"
fi
VSCODE="$(find_app "Visual Studio Code.app" com.microsoft.VSCode || true)"
if [ -n "$VSCODE" ]; then say "✅ VS Code"
else
  say "🔍 brew install --cask visual-studio-code"
  "$BREW" install --cask visual-studio-code || fail "VS Code didn't install."
  VSCODE="$(find_app "Visual Studio Code.app" || true)"
  [ -n "$VSCODE" ] || fail "VS Code didn't install."
  say "✅ VS Code installed"
fi

# 5. Claude Code
if have claude || [ -x "$HOME/.local/bin/claude" ]; then say "✅ Claude Code"
else
  say "🔍 Installing Claude Code"
  curl -fsSL "$CLAUDE_URL" | bash || fail "Claude Code's installer failed."
  { have claude || [ -x "$HOME/.local/bin/claude" ]; } || fail "Claude Code still isn't installed."
  say "✅ Claude Code installed"
fi

# 6. Claude Code's VS Code extension
CODE="$VSCODE/Contents/Resources/app/bin/code"
if [ -x "$CODE" ]; then
  if "$CODE" --list-extensions 2>/dev/null | grep -qx 'anthropic.claude-code'; then
    say "✅ Claude Code for VS Code"
  else
    say "🔍 Installing Claude Code for VS Code"
    "$CODE" --install-extension anthropic.claude-code >/dev/null 2>&1 \
      && say "✅ Claude Code for VS Code installed" \
      || say "⚠️  couldn't install Claude Code's VS Code extension -- install \"Claude Code\" from VS Code's Extensions view"
  fi
else
  say "⚠️  VS Code's command-line tool wasn't found -- install \"Claude Code\" from VS Code's Extensions view"
fi
export CC_CODE_CLI="$CODE"

# 7. Shepherd
say ""
say "🚀 Installing Shepherd"
if [ -n "${CC_BOOT_INSTALL:-}" ]; then
  eval "$CC_BOOT_INSTALL" || fail "Shepherd's installer failed (see above)."
else
  bash "$HERE/install.sh" || fail "Shepherd's installer failed (see above)."
fi

# 8. Hammerspoon hosts the panel: (re)start it so it loads Shepherd, and open the pane where
# macOS grants it Accessibility (needed to focus windows and type into sessions).
if [ -z "${CC_BOOT_INSTALL:-}" ]; then
  if pgrep -xq Hammerspoon; then osascript -e 'quit app "Hammerspoon"' >/dev/null 2>&1; sleep 2; fi
  open -a Hammerspoon
  open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" 2>/dev/null || true
fi

say ""
say "✅ Shepherd is installed. Last steps, once:"
say "   1. In System Settings → Privacy & Security → Accessibility, turn on Hammerspoon."
say "   2. Open VS Code, open the Claude Code panel and sign in to your Claude account."
say "   3. The Shepherd panel appears top-right (Hammerspoon's menu-bar icon → Reload Config if it doesn't)."
