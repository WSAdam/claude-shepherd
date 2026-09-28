# Regenerate the kitty screen fixtures: Claude Code's screen shapes rendered through kitty's OWN
# screen, written exactly as `kitty @ get-text --ansi` returns them (kitty.window.as_text with
# as_ansi=True). Run from the repo root:
#   kitty +runpy 'exec(open("tests/fixtures/kitty-screens/render.py").read(), {"__name__": "render"})'
# The shapes follow Claude Code 2.1.175: the composer is a round-bordered box with only its top
# and bottom rules (promptBorder rgb(136,136,136)), the prompt glyph is figures.pointer, and a
# placeholder or prompt suggestion is the cursor (inverse) on its first letter + the rest dim.
from kitty.fast_data_types import Screen
from kitty.window import as_text

class CB:
    def __getattr__(self, name):
        return lambda *a, **k: None

def render(data, lines=12, cols=60):
    cb = CB()
    s = Screen(cb, lines, cols, 0, 10, 20, 0, cb)
    mv = memoryview(data.encode("utf-8"))
    while mv:
        dest = s.test_create_write_buffer()
        n = s.test_commit_write_buffer(mv, dest)
        mv = mv[n:]
        s.test_parse_written_data()
    return as_text(s, as_ansi=True)

E = "\x1b"
W = 60
RULE = E + "[38;2;136;136;136m" + "─" * W + E + "[39m"
DIM = lambda t: E + "[2m" + t + E + "[22m"
INV = lambda t: E + "[7m" + t + E + "[27m"
BULLET = E + "[38;2;255;255;255m⏺" + E + "[39m "
HIST = BULLET + "Done. All 412 checks pass.\r\n\r\n"
FOOT = "  " + DIM("? for shortcuts")
PTR = "❯"

def composer(line):
    return HIST + RULE + "\r\n" + line + "\r\n" + RULE + "\r\n" + FOOT

SCREENS = {
  # nothing typed: the placeholder's first letter carries the cursor, the rest is dim
  "empty-composer": composer(DIM(PTR) + " " + INV("T") + DIM('ry "fix lint errors"')),
  # Adam's half-typed prompt, the cursor after it (an inverse space)
  "typed-text": composer(PTR + " run the tests" + INV(" ")),
  # typed, the cursor moved back inside the text
  "typed-text-cursor-inside": composer(PTR + " run " + INV("t") + "he tests"),
  # one letter typed with the cursor on it: nothing dim follows, so it is not a placeholder
  "typed-one-letter": composer(PTR + " " + INV("y")),
  # after a turn: the dim prompt suggestion (Tab accepts it) in an otherwise empty composer
  "dim-suggestion": composer(DIM(PTR) + " " + INV("c") + DIM("ommit these changes")),
  # the /model picker: no composer, a numbered option under the pointer
  "model-menu": HIST + RULE + "\r\n" + E + "[1mSelect model" + E + "[22m\r\n" + DIM("Switch between Claude models.")
                + "\r\n\r\n" + PTR + " 1. Default (recommended)\r\n  2. Sonnet\r\n  3. Haiku\r\n\r\n"
                + DIM("Enter to confirm · Esc to exit"),
  # the trust dialog of a folder Claude Code hasn't been told to trust
  "trust-dialog": E + "[1m/Users/adam/Scratch/demo" + E + "[22m\r\n\r\nQuick safety check: Is this a project you created or one\r\n"
                  + "you trust?\r\n\r\n" + PTR + " 1. Yes, I trust this folder\r\n  2. No, exit\r\n\r\n"
                  + DIM("Enter to confirm · Esc to cancel"),
  # the session survey above an empty composer: a digit typed there answers it
  "session-survey": BULLET + "Done.\r\n\r\n" + "How is Claude doing this session? (optional)\r\n"
                    + "1: Bad    2: Fine   3: Good   0: Dismiss\r\n" + RULE + "\r\n" + DIM(PTR) + " " + INV(" ")
                    + "\r\n" + RULE + "\r\n" + FOOT,
}

for name, data in SCREENS.items():
    with open("tests/fixtures/kitty-screens/" + name + ".ansi", "w", encoding="utf-8", newline="") as f:
        f.write(render(data))
print("wrote", len(SCREENS), "screens")
