#!/usr/bin/env bash
set -euo pipefail

if ! command -v bats >/dev/null 2>&1; then
  echo "Error: bats is not installed. Install bats-core and rerun." >&2
  exit 2
fi

bats tests/pull.bats
