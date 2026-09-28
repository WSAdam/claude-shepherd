# Transcript fixtures

Windows of real Claude Code transcripts, replayed by `tests/transcript-replay.test.lua`.

Every other transcript test feeds the parsers three hand-written lines. The two worst bugs of
September 2026 reproduce in none of them: a quadratic line walk that froze the whole panel, and a
card stuck at "Working" for 2h35m. Both need a 16KB head torn mid-record, records in the order
Claude Code really writes them, and the bytes framed the way the dashboard frames them.

## The repo is public, so nothing readable lives here

`scrub.js` cuts a window from a real transcript and masks every readable string — prompts, paths,
project and client names, cwd, session ids, tool inputs (Bash command lines, Write/Edit contents)
and assistant text — to runs of `x`, keeping record shapes, key order, byte sizes, interleavings
and the torn last line exactly as they were.

`check-scrubbed.js` proves it: every word in a fixture must be either a mask or listed in
`vocabulary.txt` (Claude Code's own record keys, types and tags — short enough to read by eye). A
raw transcript dropped in here fails on its first sentence. `tests/worktree-hygiene.test.sh`
enforces the rest: fixtures are tracked, each under 100KB, no CRLF, and nothing but fixtures, the
two scripts and this README may live in the folder.

## The fixtures

**`head-first-prompt.jsonl`** — a session's first 16KB, cut from a real transcript. Two
queue-operation records, a hook attachment, the first prompt (a content *array*, as the VS Code
extension writes it), three attachments, then a 46KB attachment torn at byte 16384.

**`head-prompt-past-the-tear.jsonl`** — derived from the one above, same records and same
scrubbing, rearranged so its *only* user record is the torn final one. A 16KB window then holds
no whole prompt, so `core.firstPromptFromTranscript` must cross every byte before giving up, and
~15KB of the window is a single unterminated line.

That second fixture exists because the first cannot guard the bug it was cut for. In
`head-first-prompt` the prompt sits 1KB in, so the function returns long before it reaches the
tear: restore the f1252be pattern and the mutant **survives**. Rearranged, the pattern's cost
becomes the function's cost — measured on this head, the shipped walk is 0.002ms a call and the
f1252be mutant 903ms, because the backtrack is quadratic in the length of the torn remainder.
The suite times both, so the fixture is known to be one the old code chokes on rather than merely
assumed to be.

**`tail-ends-on-api-error.jsonl`** — the tick's 64KB tail of a session at the moment a turn died
on a 529 (2026-09-28). A prompt, its bookkeeping records, then the final failure: an `assistant`
record with `isApiErrorMessage: true`, model `<synthetic>` and `error: "server_error"`. Claude
Code fired StopFailure, not Stop, and flushed that turn's ten retry records only three minutes
later, when the next prompt arrived — so for those three minutes this record was the newest
thing in the file, and `core.transcriptError` read it as the session recovering. Cut with
`--tail 65536 --end-at` the end of that record; the error words (`API Error: 529 Overloaded`) are
the only ones kept from its text.

**`tail-turn-made-progress.jsonl`** — the last 89,500 bytes of a real session up to the Stop of a
turn that made two edits and ended on a statement (2026-09-28). `core.turnEvidence` has to find
the turn's own prompt (`origin.kind: "human"`) among the scrubbed records, count both edits and
label the turn *made progress*. Cut with `--tail 89500 --end-after system/stop_hook_summary:4`;
a 90,000-byte cut split a kept key in the torn first line, so the window was moved.

**`tail-unit-turn-from-peer.jsonl`** — the last 60,000 bytes of a real batch unit's session, up
to the Stop of its last turn (2026-09-28). A batch unit never gets a prompt from Adam: every one is
its driver's message, a `user` record with `origin.kind: "peer"` and `isMeta: true`. Here the
driver says the merge has landed and the unit answers in one paragraph with no tools, so
`core.turnEvidence` has to start the turn at that message and label it *only planned*. Cut with
`--tail 60000`.

**`tail-turn-prompt-out-of-reach.jsonl`** — the last 90,000 bytes of another unit's session, up to
the Stop of its merge-and-deploy turn (2026-09-28). The message that started the turn is 600KB
back, so the window holds no prompt at all: the whole window is inside one turn, which ran eight
commands that change things and reads *made progress*. Cut with `--tail 90000`.

`scrub.js` keeps a prompt's `origin.kind` (`human`, `peer`, `task-notification`) since these two
were cut; the fixtures above them were cut before that, so their `origin` is masked.

## Regenerating

`node scrub.js <transcript.jsonl> [--bytes N] > out.jsonl`, then
`node check-scrubbed.js out.jsonl` (add `--list` to review every non-mask word before trusting a
new one). Read the result by eye before committing it: the checker proves no *stranger words*
survive, not that a mask is the right shape.
