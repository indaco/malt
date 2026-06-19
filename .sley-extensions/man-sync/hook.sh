#!/usr/bin/env bash
set -euo pipefail

# Read JSON input from stdin
INPUT=$(cat)

# Extract project_root with parameter expansion (no jq dependency); cwd is the
# extension dir, so every path must derive from project_root.
PROJECT_ROOT=$(echo "$INPUT" | grep -o '"project_root"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*:.*"\([^"]*\)".*/\1/')

if [[ -z "$PROJECT_ROOT" ]]; then
  echo '{"success": false, "message": "Missing project_root in input"}'
  exit 1
fi

# Keep arbitrary tool output safe to embed in a JSON string so a failed bump
# stays diagnosable instead of aborting on malformed JSON.
sanitize() { tr '\n\r\t' '   ' | sed 's/[\\"]/ /g'; }

# sley does not build, so the hook must: the page reflects the just-released
# binary, and version-sync has already written the new version upstream.
if ! BUILD_LOG=$(cd "$PROJECT_ROOT" && zig build 2>&1); then
  echo "{\"success\": false, \"message\": \"zig build failed: $(printf '%s' "$BUILD_LOG" | sanitize)\"}"
  exit 1
fi

# Regenerate into the working tree only — the maintainer stages it by hand with
# the other bump artefacts, so the hook stays a pure generator.
if ! GEN_LOG=$("$PROJECT_ROOT/scripts/gen-man.sh" "$PROJECT_ROOT/dist/man/malt.1" 2>&1); then
  echo "{\"success\": false, \"message\": \"man generation failed: $(printf '%s' "$GEN_LOG" | sanitize)\"}"
  exit 1
fi

echo '{"success": true, "message": "Regenerated dist/man/malt.1"}'
