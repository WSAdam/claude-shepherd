# Red-flag diffs

Unified diffs that both red-flag scanners read (2026-10-03, mining round 2 unit A3):
`core.diffRedFlags` (`cc-core.lua`, the merge checker) and its bash port `cc_diff_red_flags`
(`cc-lib.sh`, the Stop hook's fake-completion check, `stopGuards.fakeDone`).
`tests/stop-guards.test.sh` runs both over every `*.diff` here, and over a CRLF copy of each, and
needs the same skip/only, stub and deleted-test flags from both. So the two rule sets can't drift.

Hand-written, not cut from real repos. Keep them LF (the suite makes the CRLF copies itself).
`torn.diff` ends mid-line on purpose: the hook cuts the diff at a fixed size.
