# Claude Shepherd — developer tasks. Tests are side-effect-free (temp dirs + recorder
# doubles): they never touch ~/.claude/cc-status, fire keystrokes, or spawn.

HS_DIR ?= $(HOME)/.hammerspoon
APP_DIR ?= $(HOME)/Applications

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

# First-run setup: copy scripts + core into place, merge hooks (with a backup),
# ensure the init.lua dofile, and build the Dock launcher. Idempotent.
.PHONY: setup
setup:
	@bash install.sh

# Reload the live Hammerspoon config (needs the `hs` CLI: require('hs.ipc')).
.PHONY: reload
reload:
	@hs -c "hs.reload()" && echo "✅ Hammerspoon reloaded" || echo "⚠️  'hs' CLI not available — reload from the Hammerspoon menu"

# Test, deploy, then reload — one shot.
.PHONY: deploy
deploy: test install reload

# Build the standalone Shepherd.app Dock launcher (F6). osacompile generates the
# bundle from app/Shepherd.applescript (no binary committed); make-icon.sh installs
# a sheep icon (best-effort). Drag the result to your Dock; clicking toggles the panel.
.PHONY: app
app:
	@rm -rf "$(APP_DIR)/Shepherd.app"
	@osacompile -o "$(APP_DIR)/Shepherd.app" app/Shepherd.applescript
	@bash app/make-icon.sh "$(APP_DIR)/Shepherd.app" || true
	@echo "✅ built $(APP_DIR)/Shepherd.app — drag it to your Dock (first open: right-click → Open)"

# Pin Shepherd.app to the Dock (idempotent; builds the app first if missing). The
# Dock briefly restarts. Reversible: drag the icon off the Dock. Run `make app dock`.
.PHONY: dock
dock:
	@[ -d "$(APP_DIR)/Shepherd.app" ] || $(MAKE) app
	@bash app/add-to-dock.sh "$(APP_DIR)/Shepherd.app"
