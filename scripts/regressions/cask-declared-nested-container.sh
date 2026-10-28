#!/usr/bin/env bash
# Exercise declared container classification and ZIP-with-nested-tar placement
# without downloading Steam or touching the user's applications.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

zig build test-bin
zig-out/test-bin/cask_test
