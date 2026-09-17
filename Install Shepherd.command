#!/bin/bash
# Double-click to install Claude Shepherd and everything it needs (bootstrap.sh).
# A downloaded copy is blocked the first time: right-click it → Open, or System Settings → Privacy & Security → Open Anyway.
cd "$(dirname "$0")" || exit 1
bash ./bootstrap.sh
status=$?
echo
read -r -p "Press Return to close this window..." _
exit $status
