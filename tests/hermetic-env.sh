# hermetic-env.sh - sourced by tests/run.sh before any suite (2026-09-17): drop every CC_* variable
# inherited from the shell running the tests. Shepherd's code honors overrides such as
# CC_BRIDGE_DIR / CC_STATUS_DIR, so a machine's own settings would point the suites at real state
# (the install gate runs this suite in the user's shell). Each suite sets what it needs itself.
for __cc_var in $(env | sed -n 's/^\(CC_[A-Za-z0-9_]*\)=.*/\1/p'); do unset "$__cc_var"; done
unset __cc_var
