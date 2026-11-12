#!/bin/bash
# studio-light: guided setup. Asks for your Mac password once, then has you watch the light.
cd "$(dirname "$0")" || exit 1
bash studio-light.sh setup
echo
echo "You can close this window."
