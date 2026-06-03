# Babysitter — developer tasks. Tests are side-effect-free (temp dirs + recorder
# doubles): they never touch ~/.claude/cc-status, fire keystrokes, or spawn.

.PHONY: test
test:
	@bash tests/run.sh
