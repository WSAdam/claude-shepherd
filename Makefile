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

# Tooling check: report jq (required) + the rg/fd accelerators (optional — fleet search
# and folder scan degrade to grep/find without them) and offer to brew-install any that are
# missing. Read-only; re-runnable any time. Same check `make setup` runs at the end.
.PHONY: doctor tools
doctor tools:
	@bash install.sh --tools-only

# Reload the live Hammerspoon config (needs the `hs` CLI: require('hs.ipc')). The reload
# is SCHEDULED 0.4s out so the `hs` command disconnects cleanly first -- an immediate
# hs.reload() tears down the IPC port mid-command, which exits non-zero and falsely looks
# like the CLI is missing (the reload actually worked).
.PHONY: reload
# The scheduled timer MUST be retained in a global: a bare hs.timer.doAfter can
# be GC'd before it fires (the project's own after() lesson), which silently
# skipped the reload while this target still echoed success -- field-proven:
# "deployed" code repeatedly wasn't live until a manual hs.reload().
reload:
	@hs -c "_G.__ccReloadTimer = hs.timer.doAfter(0.4, function() hs.reload() end)" >/dev/null 2>&1 && echo "✅ Hammerspoon reloading (config re-read)" || echo "⚠️  'hs' CLI not available — reload from the Hammerspoon menu"

# Test, deploy, then reload — one shot.
.PHONY: deploy
deploy: test install reload

# Build the standalone Shepherd.app Dock launcher (F6). Hand-rolled bundle (a
# shell stub that opens the hammerspoon:// toggle URL) — NOT an osacompile
# applet: applets share the "applet" executable/icon names and ship Assets.car
# + no bundle id, which left macOS's icon cache permanently stuck on the
# generic applet icon. make-icon.sh installs the shepherd icon (best-effort).
.PHONY: app
app:
	@bash app/build-app.sh "$(APP_DIR)/Shepherd.app"
	@echo "✅ built $(APP_DIR)/Shepherd.app — drag it to your Dock (first open: right-click → Open)"

# Pin Shepherd.app to the Dock (idempotent; builds the app first if missing). The
# Dock briefly restarts. Reversible: drag the icon off the Dock. Run `make app dock`.
.PHONY: dock
dock:
	@[ -d "$(APP_DIR)/Shepherd.app" ] || $(MAKE) app
	@bash app/add-to-dock.sh "$(APP_DIR)/Shepherd.app"
