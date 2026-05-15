#!/usr/bin/env bash
# local.sh — run trinket-oss locally against the Firestore emulator.
# Assumes the emulator is already running:
#   firebase emulators:start --only firestore --project demo-trinket

set -euo pipefail

export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

nvm use 16

export FIRESTORE_EMULATOR_HOST="${FIRESTORE_EMULATOR_HOST:-localhost:8080}"
export GOOGLE_CLOUD_PROJECT="${GOOGLE_CLOUD_PROJECT:-demo-trinket}"
export NODE_ENV="${NODE_ENV:-development}"

exec node app.js
