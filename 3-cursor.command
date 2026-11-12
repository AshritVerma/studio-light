#!/bin/bash
# Cursor sounds: installs cursor-ping and its hook, then ties them to the light's hours.
cd "$(dirname "$0")" || exit 1
bash cursor/install.sh
echo
echo "You can close this window."
