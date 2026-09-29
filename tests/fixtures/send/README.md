# cc-send transcript fixtures

Literal transcripts for `tests/send.test.sh`: what `cc-send.sh --wait` reads after it hands a
session a prompt. They are hand-written, not cut from a real session, so nothing here needs
scrubbing; each record keeps the shape and order Claude Code really writes (checked against live
transcripts on 2026-09-29).

`before.jsonl` is the session's transcript when the prompt is sent: a turn in progress. The test
writes it first, answers the request with its size as the offset, then appends one of the others,
line by line, while `cc-send.sh --wait` follows along. Every one carries the marker
`cc-send #1790000000-4242` (the request's id, as `core.sendMarker` writes it).

- **`turn-end.jsonl`** — the session was busy. Its turn ends (`stop_hook_summary`), the Stop hook
  hands the prompt over by blocking the stop (the reason is in that summary's `hookErrors`), and the
  session carries on: a tool call, then a reply in two text blocks of one message, then the next
  `stop_hook_summary` — the turn end. A prompt and reply after it are not part of the answer.
  Expected reply: `There are 412 tests, all green.` + blank line + `Nothing failed.`
- **`queued-prompt.jsonl`** — Shepherd typed the prompt just as the session went busy, so Claude
  Code queued it: a `queue-operation` and a `queued_command` attachment carry the marker first, then
  the running turn ends, then the prompt arrives as a `user` record. Neither the queued copies nor
  the running turn's end count. Expected reply: `There are 412 tests.`
- **`session-start.jsonl`** — the prompt waited in the mailbox and a resumed session was shown it
  at its start (a SessionStart `hook_success` attachment). The reply is that session's next turn.
  Expected reply: `There are 412 tests.`
- **`interrupted.jsonl`** — the prompt was typed, then the turn was interrupted (`[Request
  interrupted by user for tool use]`): no reply, and no Stop.
- **`api-error.jsonl`** — the prompt was typed, then the turn died on an API error (an `assistant`
  record with `isApiErrorMessage: true`; Claude Code fires StopFailure, never Stop).
