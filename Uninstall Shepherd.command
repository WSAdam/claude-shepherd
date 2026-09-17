#!/bin/bash
# Double-click to remove Claude Shepherd from this Mac (uninstall.sh). Hammerspoon, VS Code,
# Claude Code and the Homebrew packages stay installed.
cd "$(dirname "$0")" || exit 1
read -r -p "Also delete Shepherd's settings and history (cc-config.json, status, ledger)? [y/N] " purge
case "$purge" in
  y|Y) bash ./uninstall.sh --purge ;;
  *)   bash ./uninstall.sh ;;
esac
echo
read -r -p "Press Return to close this window..." _
