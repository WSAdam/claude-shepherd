#!/usr/bin/env bash
# bootstrap.test.sh - the double-click installer (2026-09-17). "Install Shepherd.command" runs
# bootstrap.sh, which puts every prerequisite on a Mac that may have none of them -- Xcode
# command-line tools, Homebrew, jq/lua/node/ripgrep/fd, Hammerspoon, VS Code, Claude Code and its
# VS Code extension -- then runs install.sh. Every outside tool here is a stub on PATH that
# records its calls and "installs" by creating the next stub, so nothing real is installed.
. "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT

# A fake machine: $1 = "bare" (nothing installed) or "ready" (everything installed).
setup_machine() {
  M="$TMP/$1"; BIN="$M/bin"; BREWBIN="$M/brew-prefix/bin"; APPS="$M/Applications"; CALLS="$M/calls"
  rm -rf "$M"   # each case starts from its own clean machine
  mkdir -p "$BIN" "$BREWBIN" "$APPS" "$M/home"
  : > "$CALLS"
  stub() { printf '#!/bin/sh\n%s\n' "$2" > "$1"; chmod +x "$1"; }
  stub "$BIN/uname" 'echo Darwin'
  stub "$BIN/mdfind" 'exit 0'
  stub "$BIN/open" "echo \"open \$*\" >> '$CALLS'"
  stub "$BIN/osascript" 'exit 0'
  stub "$BIN/pgrep" 'exit 1'
  stub "$BIN/xattr" 'exit 0'
  stub "$BIN/sleep" 'exit 0'
  stub "$BIN/xcode-select" "case \"\$1\" in
  -p) [ -e '$M/clt' ] && echo /Library/Developer/CommandLineTools || exit 2 ;;
  --install) echo 'xcode-select --install' >> '$CALLS'; touch '$M/clt' ;;
esac"
  # Homebrew's own installer (fetched with curl) creates brew; brew install creates each tool
  cat > "$M/make-brew" <<EOF
#!/bin/sh
cat > '$BREWBIN/brew' <<'BREW'
#!/bin/sh
echo "brew \$*" >> '$CALLS'
if [ "\$1" = shellenv ]; then echo 'export PATH="$BREWBIN:\$PATH"'; exit 0; fi
if [ "\$1" = install ] && [ "\$2" = --cask ]; then
  case "\$3" in
    hammerspoon) mkdir -p '$APPS/Hammerspoon.app' ;;
    visual-studio-code) mkdir -p '$APPS/Visual Studio Code.app/Contents/Resources/app/bin'
      printf '#!/bin/sh\necho "code \$*" >> $CALLS\n[ "\$1" = --list-extensions ] && cat $M/exts 2>/dev/null\n[ "\$1" = --install-extension ] && echo "\$2" >> $M/exts\nexit 0\n' > '$APPS/Visual Studio Code.app/Contents/Resources/app/bin/code'
      chmod +x '$APPS/Visual Studio Code.app/Contents/Resources/app/bin/code' ;;
  esac
  exit 0
fi
if [ "\$1" = install ]; then
  t="\$2"; [ "\$t" = ripgrep ] && t=rg
  [ -e "$M/fail-\$2" ] && exit 1
  printf '#!/bin/sh\nexit 0\n' > '$BREWBIN/'"\$t"; chmod +x '$BREWBIN/'"\$t"
fi
exit 0
BREW
chmod +x '$BREWBIN/brew'
EOF
  chmod +x "$M/make-brew"
  stub "$BIN/curl" "echo \"curl \$*\" >> '$CALLS'
case \"\$*\" in
  *Homebrew/install*) echo 'echo homebrew-installer >> $CALLS; $M/make-brew' ;;
  *claude.ai/install.sh*) echo 'echo claude-installer >> $CALLS; mkdir -p $M/home/.local/bin; printf \"#!/bin/sh\\nexit 0\\n\" > $M/home/.local/bin/claude; chmod +x $M/home/.local/bin/claude' ;;
esac"
  if [ "$1" = ready ]; then
    touch "$M/clt"; "$M/make-brew"
    for t in jq lua node rg fd; do stub "$BREWBIN/$t" 'exit 0'; done
    "$BREWBIN/brew" install --cask hammerspoon; "$BREWBIN/brew" install --cask visual-studio-code
    mkdir -p "$M/home/.local/bin"; stub "$M/home/.local/bin/claude" 'exit 0'
    echo anthropic.claude-code > "$M/exts"
    : > "$CALLS"
  fi
}

run_bootstrap() {
  HOME="$M/home" PATH="$BIN:/usr/bin:/bin" \
  CC_BOOT_BREW_PATHS="$BREWBIN/brew" CC_BOOT_APP_DIRS="$APPS" CC_BOOT_ZPROFILE="$M/home/.zprofile" \
  CC_BOOT_INSTALL="echo install.sh >> '$CALLS'" \
    bash "$ROOT/bootstrap.sh" "$@" > "$M/out" 2>&1
  echo $? > "$M/rc"
}
called() { grep -cxF -- "$1" "$CALLS" 2>/dev/null || true; }

# ---- a Mac with nothing installed ----
setup_machine bare
run_bootstrap
assert_eq "bare Mac: asks macOS for the command-line tools" "1" "$(called 'xcode-select --install')"
assert_eq "bare Mac: runs Homebrew's own installer" "1" "$(called 'homebrew-installer')"
for f in jq lua node ripgrep fd; do
  # macOS 15 ships /usr/bin/jq: then jq is already there and rightly not installed
  [ "$f" = jq ] && [ -x /usr/bin/jq ] && continue
  assert_eq "bare Mac: brew installs $f" "1" "$(called "brew install $f")"
done
assert_eq "bare Mac: brew installs Hammerspoon" "1" "$(called 'brew install --cask hammerspoon')"
assert_eq "bare Mac: brew installs VS Code" "1" "$(called 'brew install --cask visual-studio-code')"
assert_eq "bare Mac: runs Claude Code's installer" "1" "$(called 'claude-installer')"
assert_eq "bare Mac: installs Claude Code's VS Code extension" "1" "$(called 'code --install-extension anthropic.claude-code')"
assert_eq "bare Mac: then runs Shepherd's installer" "1" "$(called 'install.sh')"
assert_eq "bare Mac: ends successfully" "0" "$(cat "$M/rc")"
assert_eq "bare Mac: new shells find brew (.zprofile)" "1" "$(grep -c 'brew shellenv' "$M/home/.zprofile" 2>/dev/null || true)"

# ---- a Mac that already has everything ----
setup_machine ready
run_bootstrap
assert_eq "ready Mac: installs nothing with brew" "0" "$(grep -c '^brew install' "$CALLS" || true)"
assert_eq "ready Mac: fetches no installer" "0" "$(grep -c '^curl' "$CALLS" || true)"
assert_eq "ready Mac: no extension reinstalled" "0" "$(called 'code --install-extension anthropic.claude-code')"
assert_eq "ready Mac: runs Shepherd's installer" "1" "$(called 'install.sh')"
assert_eq "ready Mac: ends successfully" "0" "$(cat "$M/rc")"
run_bootstrap
assert_eq "re-run: .zprofile gets the brew line once" "1" "$(grep -c 'brew shellenv' "$M/home/.zprofile" 2>/dev/null || true)"

# ---- a required tool that won't install stops before touching anything ----
setup_machine bare
touch "$M/fail-node"
run_bootstrap
assert_eq "a required tool that fails to install: Shepherd's installer never runs" "0" "$(called 'install.sh')"
assert_eq "...exits non-zero" "yes" "$([ "$(cat "$M/rc")" != 0 ] && echo yes || echo no)"
assert_eq "...and names the tool" "1" "$(grep -c 'node' "$M/out" | awk '{print ($1 > 0) ? 1 : 0}')"

# ---- an optional accelerator that won't install is only a warning ----
setup_machine bare
touch "$M/fail-fd"
run_bootstrap
assert_eq "an optional tool that fails: Shepherd still installs" "1" "$(called 'install.sh')"

# ---- the double-click files ----
for f in "Install Shepherd.command" "Uninstall Shepherd.command"; do
  assert_eq "$f is tracked as executable (double-clickable)" "100755" \
    "$(git -C "$ROOT" ls-files -s -- "$f" | cut -c1-6)"
done
assert_eq "Install Shepherd.command runs bootstrap.sh" "yes" \
  "$(grep -qE '^[^#]*bash \./bootstrap\.sh' "$ROOT/Install Shepherd.command" 2>/dev/null && echo yes || echo no)"
assert_eq "Uninstall Shepherd.command runs uninstall.sh" "yes" \
  "$(grep -qE '^[^#]*bash \./uninstall\.sh' "$ROOT/Uninstall Shepherd.command" 2>/dev/null && echo yes || echo no)"

finish
