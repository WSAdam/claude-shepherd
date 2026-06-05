#!/usr/bin/env bash
#
# cc-popup.sh - conditionally pop (focus) the editor window for a project.
#
# Wired into Stop (event "complete") and PermissionRequest/Notification (event
# "approval"). Pops ONLY when the matching flag is true AND the session runs in a
# GUI editor (VS Code / Cursor) -- kitty/terminal sessions are left alone, since
# popping VS Code for a terminal user is wrong (the old hardcoded behavior).
# Default off, so it's always safe to leave wired.
#
# Usage: cc-popup.sh [project-dir] [event:complete|approval]
#   focus.popOnComplete  governs the "complete" event (Stop)
#   focus.popOnApproval  governs the "approval" event (PermissionRequest/Notification)
#   legacy focus.popEditor seeds both when the split flags are unset.

set -u

# shellcheck source=cc-lib.sh
. "$(dirname "$0")/cc-lib.sh" 2>/dev/null || . "$HOME/.claude/cc-lib.sh"

DIR="${1:-$PWD}"
EVENT="${2:-complete}"

# Pick the governing flag (legacy popEditor is the fallback default for both).
case "$EVENT" in
  approval) FLAG="$(cc_config '.focus.popOnApproval' "$(cc_config '.focus.popEditor' 'false')")" ;;
  *)        FLAG="$(cc_config '.focus.popOnComplete' "$(cc_config '.focus.popEditor' 'false')")" ;;
esac
[ "$FLAG" = "true" ] || exit 0

# Route to the detected editor; empty (kitty/terminal) -> nothing to pop.
APP="$(cc_editor_app "$(cc_detect_editor)")"
[ -n "$APP" ] || exit 0

open -a "$APP" "$DIR" 2>/dev/null || true
exit 0
