#!/usr/bin/env bash
#
# cc-popup.sh - conditionally pop (focus) the editor window for a project.
#
# Wired into the Stop / Notification / PermissionRequest hooks. Pops the editor
# only when `focus.popEditor` is true in ~/.claude/cc-config.json (default off,
# toggled from the Claude Shepherd ⚙ settings panel). Otherwise it's a no-op, so
# it's always safe to leave in the hooks.
#
# Usage: cc-popup.sh [project-dir]   (defaults to $PWD)

set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

# Off (or jq missing / no config) -> do nothing.
[ "$(cc_config '.focus.popEditor' 'false')" = "true" ] || exit 0

open -a "Visual Studio Code" "${1:-$PWD}" 2>/dev/null || true
exit 0
