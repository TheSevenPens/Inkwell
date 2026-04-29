#!/usr/bin/env bash
# Builds Inkwell and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/build.sh "${1:-release}"
open build/Inkwell.app
