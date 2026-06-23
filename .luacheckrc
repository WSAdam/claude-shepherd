-- .luacheckrc — lint config for Claude Shepherd.
-- Goal: catch real correctness issues (undefined/accidental globals = typos, unused
-- vars) without drowning in cosmetic noise on two ~10k-line files. Run via `make lint`.
-- Kept deliberately strict on W111/W113/W211 — those earned their keep (W113 caught a
-- closure-capture bug where a callback read a nil global `t` instead of its task handle).

std = "max" -- union of all Lua stdlib globals (covers whatever Lua Hammerspoon ships)
self = false -- not OO; avoids spurious implicit-self diagnostics

-- Hammerspoon injects `hs` and we assign to some of its fields (e.g.
-- hs.shutdownCallback), so it's a writable global, not read-only.
globals = { "hs" }

files["claude-dashboard.lua"] = {
  -- `print` is intentionally shadowed to mirror output to the log file (see header).
  -- `refreshList` is a deliberate file-internal global: it's referenced both far above
  -- and below its definition, and the main chunk is near Lua's 200-local-per-scope cap
  -- (the appearance CSS is already wrapped in do/end for it), so it can't become a
  -- forward-declared local without restructuring. Documented here so a NEW accidental
  -- global still trips W111/W113.
  globals = { "print", "refreshList" },
}

-- cc-core.lua is pure logic with NO globals (M.json is injected onto the module).

max_line_length = false
ignore = {
  "212", -- unused argument (callbacks routinely ignore some args)
  "213", -- unused loop variable (`for _, v` / index-only loops)
  "231", -- variable never set after `local x` (forward declarations)
  "241", -- mutated but never read: the after()/timer pendingTimers table is write-only
          --   BY DESIGN (it exists only to hold strong refs so timers aren't GC'd).
  "311", -- value assigned is unused: the `opts = opts or {}` API-symmetry idiom on
          --   functions that reserve an opts param for future use.
  "42",  -- shadowing a local/argument (pervasive intentional `local ok, err` reuse)
  "43",  -- shadowing an upvalue
  "542", -- empty if branch (intentional idempotent no-ops, each with an explanatory comment)
  "581", -- `not (x == y)` form (kept where it reads as "not exactly y")
  "611", "612", "613", "614", -- trailing/leading whitespace, empty lines
  "631", -- line too long
}
