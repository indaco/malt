#!/usr/bin/env bash
# Declarative command wrappers must retain their environment and arguments
# through installation and offline rollback, and use the binary link guards.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"

zig build test-bin
zig-out/test-bin/cask_binary_zip_test
