#!/usr/bin/env bash
# Hardware-free parser, state and PTY service contracts.
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
exec nice -n 10 make -C "$repo/mkosi/runtime/power-link" check
