#!/usr/bin/env bash
#
# prune-ui.test.sh - tripwire checks for prune.hours Settings UI wiring.
# Grep-based: verifies the HTML input, load wiring, and save wiring are all present,
# and that the old hardcoded PRUNE_SECONDS constant is gone.

set -e

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DASHBOARD="$HERE/claude-dashboard.lua"

echo "🔍 Checking prune.hours Settings UI wiring..."

# 1. HTML input field must be present
if grep -q 'id="s-prune-hours"' "$DASHBOARD"; then
  echo "   ✅ HTML input field present (s-prune-hours)"
else
  echo "   ❌ MISSING: HTML input field (id=s-prune-hours)"
  exit 1
fi

# 2. HTML help text mentioning orphans
if grep -q "botched-hook orphan" "$DASHBOARD"; then
  echo "   ✅ HTML help text present"
else
  echo "   ❌ MISSING: HTML help text"
  exit 1
fi

# 3. Load wiring in showSettings
if grep -q 'val("s-prune-hours"' "$DASHBOARD"; then
  echo "   ✅ Load wiring present (showSettings)"
else
  echo "   ❌ MISSING: Load wiring in showSettings"
  exit 1
fi

# 4. Save wiring in persistSettings — look for the prune key in the save structure
if grep -q 'prune:.*hours:.*num("s-prune-hours"' "$DASHBOARD"; then
  echo "   ✅ Save wiring present (persistSettings)"
else
  echo "   ❌ MISSING: Save wiring in persistSettings"
  exit 1
fi

# 5. Old hardcoded PRUNE_SECONDS must be gone
if grep -q 'local PRUNE_SECONDS = 86400' "$DASHBOARD"; then
  echo "   ❌ FAILED: Old hardcoded PRUNE_SECONDS still present (should be removed)"
  exit 1
else
  echo "   ✅ Old hardcoded PRUNE_SECONDS removed"
fi

# 6. refreshList must read prune.hours from config
if grep -q 'core\.config(cfg, "prune\.hours"' "$DASHBOARD"; then
  echo "   ✅ refreshList reads prune.hours from config"
else
  echo "   ❌ MISSING: refreshList config read"
  exit 1
fi

echo "✅ prune-ui.test.sh passed"
