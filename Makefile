# Claude Shepherd — developer tasks. Tests are side-effect-free (temp dirs + recorder
# doubles): they never touch ~/.claude/cc-status, fire keystrokes, or spawn.

HS_DIR ?= $(HOME)/.hammerspoon

.PHONY: test
test:
	@bash tests/run.sh

# Deploy the dashboard + its logic module to Hammerspoon. The running config
# dofiles ~/.hammerspoon/claude-dashboard.lua, so edits in this repo aren't live
# until they're copied. Run this after every change (then `make reload`).
.PHONY: install
install:
	@cp claude-dashboard.lua cc-core.lua "$(HS_DIR)/"
	@echo "✅ copied claude-dashboard.lua + cc-core.lua -> $(HS_DIR)/"

# Reload the live Hammerspoon config (needs the `hs` CLI: require('hs.ipc')).
.PHONY: reload
reload:
	@hs -c "hs.reload()" && echo "✅ Hammerspoon reloaded" || echo "⚠️  'hs' CLI not available — reload from the Hammerspoon menu"

# Test, deploy, then reload — one shot.
.PHONY: deploy
deploy: test install reload
