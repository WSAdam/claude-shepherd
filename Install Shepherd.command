#!/bin/bash
# Double-click to install Claude Shepherd and everything it needs (bootstrap.sh).
# macOS may say it's from an unidentified developer the first time: right-click it → Open.
cd "$(dirname "$0")" || exit 1
bash ./bootstrap.sh
status=$?
echo
read -r -p "Press Return to close this window..." _
exit $status
