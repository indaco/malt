#!/usr/bin/env bash
set -euo pipefail

# Read JSON input from stdin
INPUT=$(cat)

# Extract values using parameter expansion (no jq dependency)
VERSION=$(echo "$INPUT" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')
PROJECT_ROOT=$(echo "$INPUT" | grep -o '"project_root"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')

if [[ -z "$VERSION" || -z "$PROJECT_ROOT" ]]; then
  echo '{"success": false, "message": "Missing version or project_root in input"}'
  exit 1
fi

# Files to update
ZON_FILE="${PROJECT_ROOT}/build.zig.zon"
README_FILE="${PROJECT_ROOT}/README.md"

ERRORS=""

# build.zig.zon carries the bare semver: .version = "X.Y.Z"
if [[ -f "$ZON_FILE" ]]; then
  if ! sed -i '' "s/\.version = \"[^\"]*\"/.version = \"${VERSION}\"/" "$ZON_FILE"; then
    ERRORS="${ERRORS}Failed to update ${ZON_FILE}. "
  fi
else
  ERRORS="${ERRORS}File not found: ${ZON_FILE}. "
fi

# README "One-liner script" section pins a vX.Y.Z release tag in the
# out-of-band verification prose and its curl URL. Match a v-prefixed semver.
if [[ -f "$README_FILE" ]]; then
  SEMVER='v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*'
  if ! sed -i '' \
    -e "s|indaco/malt/${SEMVER}/scripts/install.sh|indaco/malt/v${VERSION}/scripts/install.sh|" \
    -e "s|replace \`${SEMVER}\` below|replace \`v${VERSION}\` below|" \
    "$README_FILE"; then
    ERRORS="${ERRORS}Failed to update ${README_FILE}. "
  fi
else
  ERRORS="${ERRORS}File not found: ${README_FILE}. "
fi

if [[ -n "$ERRORS" ]]; then
  echo "{\"success\": false, \"message\": \"${ERRORS}\"}"
  exit 1
fi

echo "{\"success\": true, \"message\": \"Updated version to ${VERSION} in build.zig.zon and README.md\"}"
