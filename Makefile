# Claude Shepherd — developer tasks. Tests are side-effect-free (temp dirs + recorder
# doubles): they never touch ~/.claude/cc-status, fire keystrokes, or spawn.

HS_DIR ?= $(HOME)/.hammerspoon
CLAUDE_DIR ?= $(HOME)/.claude
APP_DIR ?= $(HOME)/Applications

.PHONY: test
test:
	@bash tests/run.sh

# Static analysis: luacheck (if installed) on the two production Lua files + a guard
# against GC-unsafe (unretained) hs.timer.doAfter/doEvery. Degrades gracefully if
# luacheck is absent (like `make doctor` does for rg/fd). Wired into `deploy` so
# nothing ships that fails lint. Install luacheck: `brew install luacheck`.
.PHONY: lint
lint:
	@if command -v luacheck >/dev/null 2>&1; then \
		luacheck cc-core.lua claude-dashboard.lua || exit 1; \
	else \
		echo "⚠️  luacheck not installed — skipping static analysis (brew install luacheck)"; \
	fi
	@bash tests/lint-timers.sh
	@luac -p cc-core.lua claude-dashboard.lua && echo "✅ lint: luac syntax OK"

# Deploy the dashboard + its logic module to Hammerspoon. The running config
# dofiles ~/.hammerspoon/claude-dashboard.lua, so edits in this repo aren't live
# until they're copied. Run this after every change (then `make reload`).
.PHONY: install
install:
	@cp claude-dashboard.lua cc-core.lua "$(HS_DIR)/"
	@echo "✅ copied claude-dashboard.lua + cc-core.lua -> $(HS_DIR)/"
# The hooks run from $(CLAUDE_DIR), so a deploy that ships only the Lua leaves edits
# to the status writer SILENTLY unshipped -- the panel reloads, the hooks do not.
# Mirrors install.sh's file set (same scripts, same chmod).
# Each script is swapped in with a RENAME, never rewritten in place: bash reads a script
# lazily from its open fd, so a hook running right now (a gate waiter, a merge request
# waiting for Adam) would resume inside the new file's bytes. Same rule as install.sh.
	@for f in cc-lib.sh cc-status.sh cc-approve.sh cc-popup.sh cc-merge.sh cc-fleet.sh cc-ask.sh cc-core.lua; do \
		cp "$$f" "$(CLAUDE_DIR)/.$$f.tmp.$$$$" && mv -f "$(CLAUDE_DIR)/.$$f.tmp.$$$$" "$(CLAUDE_DIR)/$$f" || exit 1; \
	done
	@chmod +x "$(CLAUDE_DIR)"/cc-*.sh
	@echo "✅ copied hook scripts + core -> $(CLAUDE_DIR)/"
	@[ -n "$(NO_TAB_BRIDGE)" ] || $(MAKE) --no-print-directory tab-bridge

# The Shepherd companion VS Code extension (vscode-bridge/): packaged with plain zip and
# installed with VS Code's own CLI -- no Marketplace, no npm. install-vsix.sh skips when
# that version is already installed, so a deploy only reinstalls on a version bump
# (FORCE=1 make tab-bridge reinstalls). Warn-only: no VS Code never fails a deploy.
BRIDGE_BUILD ?= build
.PHONY: tab-bridge
tab-bridge:
	@vsix="$$(bash vscode-bridge/build-vsix.sh "$(BRIDGE_BUILD)")" && bash vscode-bridge/install-vsix.sh "$$vsix" \
		|| echo "⚠️  Shepherd tab bridge not built -- Close on shared-window tabs stays refused"

# First-run setup: copy scripts + core into place, merge hooks (with a backup),
# ensure the init.lua dofile, and build the Dock launcher. Idempotent.
.PHONY: setup
setup:
	@bash install.sh

# Remove Shepherd: its hooks, scripts, dashboard, init.lua line, app, VS Code bridge and the
# methodology block in ~/.claude/CLAUDE.md. Settings and state stay; PURGE=1 removes them too.
.PHONY: uninstall
uninstall:
	@bash uninstall.sh $(if $(PURGE),--purge,)

# The worktree demo (demo/GUIDE.md): a fresh little Deno app, opened in a new VS Code window,
# where "run the worktree demo" drives two units in parallel to main. Same as `deno task demo`.
.PHONY: demo
demo:
	@deno task demo

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
# The client gets ~10s: a reload that drops the IPC port while `hs` is mid-reply can leave
# the client waiting forever (a deploy sat 10 minutes on it), and by then the reload is
# already scheduled -- so a hung client is stopped, not waited on.
reload:
	@hs -c "_G.__ccReloadTimer = hs.timer.doAfter(0.4, function() hs.reload() end)" >/dev/null 2>&1 & hp=$$!; \
	n=0; while kill -0 $$hp 2>/dev/null && [ $$n -lt 20 ]; do sleep 0.5; n=$$((n+1)); done; \
	if kill -0 $$hp 2>/dev/null; then kill $$hp 2>/dev/null; \
		echo "✅ Hammerspoon reloading (config re-read; the hs CLI hung after sending and was stopped)"; \
	elif wait $$hp; then echo "✅ Hammerspoon reloading (config re-read)"; \
	else echo "⚠️  'hs' CLI not available — reload from the Hammerspoon menu"; fi

# Lint, test, deploy, then reload — one shot.
.PHONY: deploy
deploy: lint test install reload

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
