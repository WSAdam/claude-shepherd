# Providers and integrations

[← README](../README.md) · [Configuration](configuration.md) · [Controls](controls.md)

Other models and backends, saved agent profiles, the MCP and skills inventory, Claude Code's Remote
Control, and sessions on other machines.

## Providers and models

Shepherd supervises **Claude Code** sessions, and Claude Code can talk to other backends, so a
"provider profile" is a **named bundle of environment variables plus a model id** injected into the
`claude` launch. Define profiles in **⚙ Settings → Spawn → Providers**, pick one per session in the
**New session** dialog (or set a default), and switch a running session's model live with the detail
panel's **Model** dropdown (`/model`). The tile and detail panel show a **model** badge for what's
actually running.

Two kinds:

- **Claude** (`kind: "anthropic"`) sets `ANTHROPIC_MODEL` (for example a Claude Opus, Sonnet or Haiku
  model id) against the normal endpoint.
- **Gateway** (`kind: "gateway"`) also sets `ANTHROPIC_BASE_URL`, so Claude Code talks to an
  **Anthropic-Messages-compatible endpoint**: a [LiteLLM](https://docs.litellm.ai/) proxy (which
  translates to Gemini, OpenAI and others), or a local or remote server (Ollama, vLLM, LM Studio,
  optionally behind LiteLLM). Set `baseUrl`, the `model` id your gateway expects, and optionally
  `smallFastModel` / `headers`.

**No API keys are stored.** A profile names an **environment variable** in `authTokenEnv` (for
example `MY_LITELLM_KEY`). The spawned **login shell** expands `$MY_LITELLM_KEY` at launch, so the
key lives in your shell (`~/.zshrc` or a secrets manager), never in `cc-config.json` and never in
Shepherd's process.

```json
{
  "spawn": { "provider": "claude-opus" },
  "providers": [
    { "id": "claude-opus", "label": "Claude Opus", "kind": "anthropic", "model": "claude-opus-4-8" },
    { "id": "gemini", "label": "Gemini (LiteLLM)", "kind": "gateway",
      "baseUrl": "http://localhost:4000", "model": "gemini-2.5-pro", "authTokenEnv": "MY_LITELLM_KEY" }
  ]
}
```

**Limits.** Every Shepherd control keeps working because the **harness is still Claude Code**; only
the backend model changes. A non-Claude backend may ignore Claude-specific behaviour (effort,
thinking), but slash commands, hooks and approvals are Claude Code client features and still
work. A session's **base URL is fixed at launch**: switching the *model* within a provider is live
through `/model`, but switching the *provider* means a **new session**. Running a *different agent
CLI* (aider, gemini-cli) is out of scope: those have no hook system, so tiles and approvals couldn't
work. A per-provider `contextLimit` sets the context bar's window
([Usage and cost](usage-and-cost.md#context-fullness-bar)).

## Agent profiles

Beyond presets (folder + editor + mode + provider), the New session dialog has an **Agents** row:
saved, reusable **agent profiles** you hand work to. A profile is a name, a persona (role, goal,
backstory), a provider and model, a permission mode, an optional seed task, and attached **skills**,
**MCP servers**, **knowledge** folders and **plugins**. Click an **✦ agent chip** to spawn from it in
one click; **Save as agent** captures the current form.

The **✦ Agents** editor (☰ menu) creates, edits, forks, archives, favourites and deletes profiles,
and spawns from them. Its **⚙ MCP servers** sub-editor manages the servers you can attach (id,
label, stdio / sse / http, command and arguments or URL, allowed tools, and the *name* of the
environment variable that holds the auth token). Profiles live in `~/.claude/cc-agents.json` and
servers in `~/.claude/cc-mcp.json`: operator data with **no secrets**; an MCP server's auth is an
environment-variable name your shell expands, never a value. `modelByMode` and `requiredEnv` are
hand-edit only (the editor keeps them).

Spawning from an agent emits the matching Claude Code launch flags: `--append-system-prompt`
(persona and skills), `--mcp-config` (built from `cc-mcp.json`, secrets as `${VAR}` references),
`--add-dir` (knowledge), `--agent` and `--plugin-dir`. Real spawning still honours `spawn.live`.

## Find-only audit

The **🔍 Audit (find-only)** chip in the New session dialog is a built-in preset: it spawns an
auditor in the folder you picked that can **look** and **write down what it finds**, and nothing
else. It reads the code (Read, Grep, Glob) and drives the running app in a headless Playwright
browser (isolated profile, 1280×800 viewport). The only file it can write is its findings file,
`~/.cc-audit/<project>/AUDIT-FINDINGS.md`, outside the repo, so the audited checkout never
changes. An initial task, if you type one, becomes its focus; with none, it audits the whole
project.

It launches with `--permission-mode dontAsk` and
`--allowedTools=Read Grep Glob mcp__playwright__* Edit(//<findings file>)`: anything not allowed is
refused rather than asked. Claude Code applies `Edit(path)` rules to every file-writing tool, so
that one rule is the auditor's one writable path (a `Write(path)` rule is ignored). Its launch files
live in `~/.claude/cc-audit/<project>/` (`settings.json`, `mcp.json`, and `playwright/` for the
files Playwright names itself), where the auditor can't rewrite them. Claude Code protects every
`.claude` folder under `dontAsk`, which is also why the findings file lives in `~/.cc-audit/`
instead.

A PreToolUse hook that answers "allow" overrides `dontAsk`: Shepherd's gate, autopilot, an
auto-allow pattern or your **Approve** on the card can do that. A deny rule wins over any hook, so
`--settings` carries the rules that must hold whatever the gate says:

- **deny** `Bash`, `NotebookEdit`, Playwright's `browser_run_code_unsafe` (it runs arbitrary code
  in the MCP server), and `Edit(//<folder>/**)` for the audited folder and its repo root;
- **a PreToolUse hook** that denies any Playwright call naming a `filename`. Claude Code hands MCP
  servers its working folder as their root, so a snapshot or screenshot saved by name would land in
  the repo. Without a name, the result comes back to the auditor and Playwright's own files go to
  `playwright/`.

Outside the repo, a write the gate or you approve can still go through; inside it, nothing can.
MCP servers are strict (`--strict-mcp-config`): only Playwright, none of yours.

**Findings format**: one line per finding, numbered in the order found, and a section for what
works:

```markdown
# Audit findings — /Users/you/Code/shop
- [ ] [HIGH] AUD-001 Checkout button does nothing on /cart (app.js:40): click it, nothing is posted
- [ ] [LOW] AUD-002 Footer "Terms" link 404s
## Already works
- Login with a valid account
```

Severities are `CRITICAL`, `HIGH`, `MEDIUM` and `LOW`. The findings file imports into the project's
**My List** tab with its `TODO.md` ([My List](fleet.md#my-list)): each finding becomes a verify-me
item with a **🔍 severity** chip (the id in its tooltip), and re-syncs when the file changes. A
finding is never marked done, even from an `[x]` in the file: an auditor fixes nothing, and the
checkbox stays yours. Lines under **Already works**, and checkboxes that aren't `[SEV] AUD-NNN`
findings, are left out. `uninstall.sh --purge` removes the launch files (`~/.claude/cc-audit/`) and
leaves your findings in `~/.cc-audit/`.

## MCPs and Skills

**🔌 MCPs & Skills** (☰ menu) is a read-only catalogue of what's installed for Claude Code, distinct
from the agent-profile registry above:

- **MCP servers**, read from `~/.claude.json` (the user-scope `mcpServers` plus every project's,
  de-duplicated; a server defined in both shows `user+project`). Each row shows scope, transport and
  the command or URL; **environment values are never shown**. **Re-check** runs `claude mcp list`
  through your login shell (on demand only, never on a timer) to add the claude.ai connectors and live
  **connected / failed / needs-auth** health, cached for the next open.
- **Skills**: your `~/.claude/skills` (SKILL.md) and `~/.claude/commands` (`/slash` files), plus a
  pinned list of Claude Code's built-in skills, each with its `/command` and description.
- **CLI tools**: the external programs Shepherd shells out to, each marked **installed** or
  **missing** with its resolved path: `jq` (the one required dependency), `ripgrep` and `fd` (search
  and folder-scan accelerators; when missing, the row names the fallback, `grep` or `find`), `rsync`
  (the SSH status bridge), and `ffmpeg` + `whisper-cli` (the Stream Deck voice key).

It is read-only: Shepherd never edits your MCP config, skills or tools.

## Remote Control (claude.ai and mobile)

Claude Code's own **Remote Control** lets you drive a *local* session from claude.ai or the Claude
app. Shepherd can turn it on for you (⚙ Settings → Spawn → **Claude Code Remote Control**; on by
default). This is separate from Kitty's `kitty @` remote control, which is how Shepherd itself types
into Kitty windows.

- **On spawn** (`remoteControl.onSpawn`): sessions Shepherd spawns launch with `--remote-control`.
  Only **local, native-Anthropic** sessions: Remote Control needs a claude.ai login and rejects
  gateway and SSH providers, so the flag is skipped for those.
- **On startup** (`remoteControl.sweepOnStartup`): when Shepherd starts, it types `/rc` into
  already-running idle or finished local **terminal** sessions (Kitty / Terminal), so Remote Control
  is re-armed after a restart. It skips sessions mid-turn or waiting on you, and never types into a
  VS Code or Cursor tab (the extension has no `/rc`, and its slash menu used to turn it into another
  command).
- **Sessions you start yourself** aren't Shepherd-spawned. To register them automatically, run
  `/config` inside Claude Code once and set **Enable Remote Control for all sessions**; there is no
  documented settings.json key for that, so Shepherd can't set it for you. (The installer's
  [default Claude Code settings](install.md#what-the-install-sets-up) turn on Remote Control at
  startup where you haven't set it.)

> **Security: this is on by default.** A session with Remote Control can be driven from your
> claude.ai account, so anyone with access to that account (or the Claude mobile app) can type into
> a **local** shell session. That widens the trust boundary from "whoever is at this machine" to
> "whoever can reach my claude.ai". Turn `remoteControl.onSpawn` / `sweepOnStartup` off in ⚙ Settings
> if that's broader than you want.

## SSH status bridge

A provider can carry `ssh: {"host": "devbox", "user": "me"}`: its sessions run `claude` on the remote
machine inside a local terminal. With **⚙ Settings → Spawn → SSH status bridge** on, Shepherd also
pulls each such host's remote `~/.claude/cc-status/` with rsync (every `bridge.intervalSeconds`;
key-based auth required), so those remote sessions show as **⇄ tiles** with live status.

- Remote tiles are **headless only**: Approve and Deny travel back over ssh as nonce-bound decision
  files (the verb and nonce only; a deny's typed reason stays local). Keystroke actions (nudge, stop,
  clear, …) are disabled.
- Remote staleness gets `bridge.staleSlackSeconds` of slack for sync lag, and a stalled sync shows
  "bridge offline" on the tile.
- The remote machine needs this repo's `make install` run on it.
- It is off by default, and **not yet verified on real hardware**.
