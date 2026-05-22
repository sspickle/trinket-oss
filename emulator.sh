#!/usr/bin/env bash
# emulator.sh — start the Firestore emulator for local development.
# Requires: firebase-tools (npm install -g firebase-tools)
#           Java 11+ on PATH

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
Usage: emulator.sh

Start the Firestore and Storage emulators for local development.
The emulator UI is available at http://localhost:4000.

Requires:
  firebase-tools   npm install -g firebase-tools
  Java 11+         on PATH
EOF
  exit 0
fi

exec firebase emulators:start --only firestore,storage --project "demo-trinket"
