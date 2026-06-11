-- Shepherd.app — a tiny Dock launcher for the Claude Shepherd panel.
--
-- The panel itself lives inside Hammerspoon (claude-dashboard.lua). This app just
-- asks Hammerspoon to show/hide it via Hammerspoon's built-in URL scheme, so it
-- needs no `hs` CLI on PATH and no custom URL-scheme registration. Build it with
-- `make app` (osacompile); drag the result to your Dock. Clicking the Dock icon
-- (run, or reopen when already running) toggles the panel — like Chrome/VS Code.
--
-- The `on idle` handler makes osacompile produce a STAY-OPEN applet: the app keeps
-- running after launch instead of quitting, so the Dock shows its running indicator
-- (the white dot) the whole time Shepherd is open. It does no periodic work — it just
-- returns a long interval to stay alive cheaply. Quit it like any app (right-click the
-- Dock icon → Quit) to drop the dot.

on toggleShepherd()
	do shell script "open 'hammerspoon://ccShepherdToggle'"
end toggleShepherd

on run
	toggleShepherd()
end run

on reopen
	toggleShepherd()
end reopen

on idle
	return 86400
end idle
