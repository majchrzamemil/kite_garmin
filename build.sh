#!/bin/bash
# Build the Kite Jump Tracker Garmin app for the Instinct 2 family.
#
# Wraps the Connect IQ SDK `monkeyc` tool. SDK 9.x requires an explicit
# `-y <private_key>` flag for every build. This wrapper injects the key path
# so a plain `./build.sh` works the same as the SDK Manager does.
#
# Usage:
#   ./build.sh           - build app.prg for the default target (instinct2)
#   ./build.sh -e        - build app.iq package for publishing (all manifest devices)
#   ./build.sh -d fr255  - build for a different target device
#   ./build.sh -y KEY    - override the default developer key path
#
# Result: ./build/app.prg (sideload) or ./build/app.iq (store publish)

set -euo pipefail

# Resolve paths relative to this script so it works from any cwd.
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

DEV_KEY="${HOME}/.Garmin/connect_iq_dev_key.der"
DEVICE="instinct2"
PACKAGE_MODE=false

# Allow CLI overrides. Anything starting with "-" and equal to "-y", "-d",
# or "-e" wins; everything else falls through to monkeyc.
ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -y)    DEV_KEY="$2"; shift 2 ;;
    -d)    DEVICE="$2"; shift 2 ;;
    -e|--iq) PACKAGE_MODE=true; shift ;;
    *)     ARGS+=("$1"); shift ;;
  esac
done

if [[ ! -s "$DEV_KEY" ]]; then
  echo "ERROR: developer key not found at $DEV_KEY" >&2
  echo "Generate one via VS Code (Cmd-Shift-P → 'Monkey C: Generate a Developer Key')" >&2
  exit 1
fi

# Clean intermediate dir, keep our output as the only artifact we care about.
rm -rf build/
mkdir -p build/

# Shell-quote the key path so spaces are handled if anyone customizes it.
if [[ "$PACKAGE_MODE" == true ]]; then
  monkeyc -y "$DEV_KEY" -e -o "build/app.iq" -f monkey.jungle ${ARGS[@]+"${ARGS[@]}"}
else
  monkeyc -y "$DEV_KEY" -o "build/app.prg" -d "$DEVICE" -f monkey.jungle ${ARGS[@]+"${ARGS[@]}"}
fi
