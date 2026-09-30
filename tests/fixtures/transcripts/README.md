# Transcript fixtures

Windows of real Claude Code transcripts, replayed by `tests/transcript-replay.test.lua` (the parsers,
bug by bug) and `tests/scenario-replay.test.lua` (the corpus: every transcript detector's verdict on
each tail window, against what was really true at that moment, and each detector's accuracy).

Every other transcript test feeds the parsers three hand-written lines. The two worst bugs of
September 2026 reproduce in none of them: a quadratic line walk that froze the whole panel, and a
card stuck at "Working" for 2h35m. Both need a 16KB head torn mid-record, records in the order
Claude Code really writes them, and the bytes framed the way the dashboard frames them.

## The repo is public, so nothing readable lives here

`scrub.js` cuts a window from a real transcript and masks every readable string — prompts, paths,
project and client names, cwd, session ids, tool inputs (Bash command lines, Write/Edit contents)
and assistant text — to runs of `x`, keeping record shapes, key order, byte sizes, interleavings
and the torn last line exactly as they were. The rules live in `cc-scrub.js` at the repo root
(2026-09-29): Shepherd's **Capture as scenario** runs the installed copy of it on a live card, so a
capture is scrubbed exactly as a fixture is. `scrub.js` adds the vocabulary check before it writes
anything here.

What the scrubber keeps is what the detectors read and nothing else: record and block types,
roles, models, built-in tool names, the interrupt marker, Claude Code's own tags, generic API-error
words, a prompt's `origin.kind`, an assistant record's `attributionSkill`, the key names (never the
values) of the tool inputs the loop and file detectors read (`file_path`, `command`, `path`, ...,
and since 2026-09-30 a Read's `offset`, `limit` and `pages`, whose numbers are never masked),
and a small outcome vocabulary: the words a denied tool result is known by (`denied`, `rejected`,
`doesn't want to proceed`) and, in a Bash command, the three ways a turn says it finished
something: `git commit`, an in-place `sed` of `TODO.md` (a line ticked) and `cc-merge.sh done
--result merged`. So a turn that ended on a denial reads *blocked*, and one that committed, ticked
its TODO lines or landed its merge reads *done*. Those words (`sed`, `i`, `TODO`, `md`, `cc`,
`merge`, `sh`, `done`, `result`, `merged`, with `gsed`, `perl` and `pi`) are kept wherever they
stand in a Bash command; none of them names anything.

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
commands that change things and reads *made progress*. Cut with `--tail 90000`. The corpus labels
it *done*: one of those commands is a `sed -i` flipping the unit's TODO lines to `[x]`, which the
turn label only counts through an Edit of TODO.md -- a known miss, pinned as one. Since 2026-09-30
the turn label does count a `sed -i` tick and `cc-merge.sh done --result merged`, so the raw
transcript reads *done*; this window still reads *made progress*, because the scrubber masks those
commands' words (it keeps `git commit` alone). The miss stays pinned until the scrubber keeps them
and the window is cut again from the raw transcript.

Cut again on 2026-09-30 (build program unit 47), once the scrubber kept those words: the same
bytes of the same transcript (`--tail 90000 --end-at 703921`; the session had written 923 bytes
more since the first cut). Four lines differ from the first cut, all of them Bash commands: the
`sed -i ... TODO.md` and the `cc-merge.sh done --result merged` the label reads, and two `git`
commands whose `merge` is now kept. The window reads *done*, as the real turn does, and the
corpus no longer pins a miss.

`scrub.js` keeps a prompt's `origin.kind` (`human`, `peer`, `task-notification`) since these two
were cut; the fixtures above them were cut before that, so their `origin` is masked.

**Cut for the corpus (2026-09-29)** — one window per detector that had no case, and per turn label
with none. Each is labelled in `tests/scenario-replay.test.lua`, which says what was true and why.

- **`tail-interrupted-for-tool-use.jsonl`** — Voice-Agent's "2h Working" leftover (2026-09-18): Adam
  stopped a `TaskOutput` wait, Claude Code wrote a rejected tool use and the interrupt marker, and
  no Stop hook fired. *Interrupted*; the turn reads *blocked* through the kept denial words.
  `--tail 32768`, to the end of the file.
- **`tail-awaiting-a-question.jsonl`** — the same session four minutes earlier, an
  `AskUserQuestion` unanswered: *awaiting a tool*. `--tail 16384 --end-at 461666`.
- **`tail-one-file-edited-three-times.jsonl`** — three different edits of one file in a row, each
  landing. Not a loop, but `core.toolCallSig` signed an Edit by its path alone, so the loop detector
  said it was -- the commonest "loop" in Adam's transcripts, pinned as a known miss until
  2026-09-30, when an edit came to be signed by its whole input. The scrub masks each edit's
  strings to their own shape (and the keys `old_string` / `new_string` to one name, of which a
  JSON reader keeps the last), so three different edits still read as three.
  `--tail 16384 --end-at 526900`.
- **`tail-one-edit-repeated-three-times.jsonl`** — **derived** from the window above, not cut
  (2026-09-30): the same records, with the first Edit's input repeated in the second and third
  calls, so it reads as one edit attempted three times. Once different edits stopped reading as a
  loop the corpus had no window where the loop detector says yes; this is the one that holds it to
  a true repeat. Only those two inputs differ from its source (the two lines' lengths with them).
- **`tail-one-file-read-in-three-chunks.jsonl`** — cut 2026-09-30 (build program unit 47): three
  Reads of one long file in a row, each a different `offset` and `limit`. Not a loop, but
  `core.toolCallSig` signed a Read by its path alone, so the loop detector said it was. A Read is
  signed by its chunk too now, and the scrubber keeps the keys `offset` and `limit` (their numbers
  were never masked) so the window shows three different reads. `--tail 20480 --end-at 15173247`.
- **`tail-connection-dropped-retrying.jsonl`** / **`tail-connection-dropped-recovered.jsonl`** — a
  dropped connection (`ECONNRESET`) while Claude Code retried, and the same session seven seconds
  later, answering again: *error*, then not. `--tail 16400` (at 16384 the torn first line split a
  kept key) and `--tail 16384`, each `--end-at` a record's end.
- **`tail-turn-ends-on-a-question.jsonl`** — a reply that ends by asking Adam which he meant:
  *needs follow-up*. `--tail 20480 --end-at` its Stop.
- **`tail-turn-committed.jsonl`** — "commit and push": a turn that committed reads *done* through
  the kept `git commit`. `--tail 16420` (16384 and 16400 split a word in the torn first line).

## Regenerating

```sh
node tests/fixtures/transcripts/scrub.js --src ~/.claude/projects/<project>/<session>.jsonl \
     --out tests/fixtures/transcripts/<name>.jsonl (--head BYTES | --tail BYTES) \
     [--end-at OFFSET | --end-after WHAT [--then TYPE]] [--tear BYTES]
```

`--end-after` names a record (`type[/subtype][:N]`, `interrupt[:N]`, `longest`); `cc-scrub.js`'s
header documents every flag. The cutter refuses to write a window with a word outside
`vocabulary.txt` and names it: add a word only when it asks and the word is Claude Code's own (a
record key, type or value) or one the scrubber keeps on purpose. A fragment of a word (`ent` of
`hookEvent`) means the torn first line split a key: move the window a few bytes instead.
`node check-scrubbed.js --list <fixture>` prints every non-mask word to review. Read the result by
eye before committing it: the checker proves no *stranger words* survive, not that a mask is the
right shape.

## From a capture to a fixture

A card's **Capture as scenario** writes `~/.claude/cc-scenarios/<when>-<project>-<status>.jsonl`
(already scrubbed) and a `.label.json` beside it: the tail to read it back with, when the card last
read done (on the window's clock), what Shepherd's detectors said, and one blank verdict per
detector. Fill in what was really true; `lua tests/scenario-replay.test.lua --captures` replays your
labelled captures and reports their accuracy, on your Mac only. To add one to the corpus, run
`node check-scrubbed.js` on it (a capture skips the vocabulary check), copy it here as
`tail-<what>.jsonl`, and add its label as a row in `tests/scenario-replay.test.lua` with a line
saying what was true and why.
