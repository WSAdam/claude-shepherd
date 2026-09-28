# Kitty screen fixtures

What `kitty @ get-text --extent screen --ansi` returns for a Claude Code session, read by
`core.kittyScreenState` before an automated send (build program unit 11, 2026-09-28). Checked by
`tests/core.test.lua` (the parser, `core.readyToType`) and `tests/readiness.test.lua` (the real
dashboard, with get-text stubbed to return them).

`render.py` writes every `.ansi` file here. It draws each screen the way Claude Code 2.1.175 does,
then renders it through kitty's **own** screen (`kitty.window.as_text(screen, as_ansi=True)`, what
get-text calls), so the escape codes are kitty's: `\e[22;2m` for dim, an inverse cursor left open
at the end of a line, `\e[38:2:r:g:bm` colours, `\e[m` at line starts. Regenerate from the repo
root:

    kitty +runpy 'exec(open("tests/fixtures/kitty-screens/render.py").read(), {"__name__": "render"})'

The shapes come from the Claude Code 2.1.175 binary: the composer is a round-bordered box with
only its top and bottom rules (`promptBorder`), the prompt glyph is `figures.pointer` (❯), and a
placeholder or prompt suggestion is drawn as the cursor (inverse) on its first letter with the
rest dim. The trust dialog's words ("Quick safety check…", "Yes, I trust this folder") and the
session survey's ("How is Claude doing this session? (optional)") are copied from it. They were
not captured from a live session: launching one for the capture was refused, so a Claude Code
release that redraws its composer needs these redrawn.

| Fixture | Screen | State |
|---|---|---|
| `empty-composer.ansi` | nothing typed; the dim placeholder | empty |
| `dim-suggestion.ansi` | the dim prompt suggestion after a turn | empty |
| `typed-text.ansi` | a half-typed prompt, cursor at the end | text |
| `typed-text-cursor-inside.ansi` | the same, cursor moved inside it | text |
| `typed-one-letter.ansi` | one letter under the cursor (nothing dim follows it) | text |
| `model-menu.ansi` | the /model picker, no composer | menu |
| `session-survey.ansi` | the survey above an empty composer | menu |
| `trust-dialog.ansi` | the trust dialog of a new folder | trust |
