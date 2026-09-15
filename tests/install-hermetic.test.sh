#!/usr/bin/env bash
# install-hermetic.test.sh - the installer's own suite must give the same verdict on a machine
# that lacks the optional tools (ripgrep, fd, Homebrew). It is part of the pre-flight gate
# `make setup` runs, so a host-dependent assertion there turns "optional" into "required to
# install". Runs install.test.sh twice (the real PATH, then a PATH double without the optional
# tools) and compares the FAIL lists; never touches the real ~/.claude or VS Code.
source "$(dirname "$0")/lib.sh"

TMP="$(mktemp_dir)"
trap 'rm -rf "$TMP"' EXIT

# ---- the pre-flight gate on a machine without ripgrep or Homebrew (2026-09-15) ----
# 2026-09-15: install.test.sh symlinked the HOST's rg/brew into its tool double and asserted they
# were present, so a machine without them failed the gate and `make setup` aborted.
BIN="$TMP/bin"; mkdir -p "$BIN"
for b in bash lua jq make; do
  src="$(command -v "$b" 2>/dev/null)"; [ -n "$src" ] && ln -sf "$src" "$BIN/$b"
done
bash "$ROOT/tests/install.test.sh" </dev/null 2>&1 | grep '^FAIL' | sort > "$TMP/with-tools"
PATH="$BIN:/usr/bin:/bin" bash "$ROOT/tests/install.test.sh" </dev/null 2>&1 | grep '^FAIL' | sort > "$TMP/without-tools"
assert_eq "installer suite gives the same verdict on a machine without ripgrep or Homebrew" "" \
  "$(comm -13 "$TMP/with-tools" "$TMP/without-tools")"

finish
