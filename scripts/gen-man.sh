#!/usr/bin/env bash
# scripts/gen-man.sh — generate the single `man malt` page from the binary's
# own --help output. Emits roff to <output-path>.
#
# Why generate from the binary: the root command list lives in main.zig's
# printUsage while per-command help lives in a separate map — only running the
# built binary unifies both, so the page cannot drift from what users see.
#
# Determinism is load-bearing: the CI `man-check` diff flakes on any
# wall-clock date / $USER / absolute path, so the .TH date slot carries the
# version (from .version) instead. Re-running must be byte-identical.
#
# Usage:
#   scripts/gen-man.sh dist/man/malt.1
#   MALT_BIN=/path/to/malt scripts/gen-man.sh out.1

set -euo pipefail

OUT="${1:?usage: gen-man.sh <output-path>}"
ROOT=$(cd "$(dirname "$0")/.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"

[ -x "$BIN" ] || {
  echo "malt binary not found at $BIN (run: zig build)" >&2
  exit 1
}
VERSION=$(tr -d '[:space:]' <"$ROOT/.version")
[ -n "$VERSION" ] || {
  echo "empty .version at $ROOT/.version" >&2
  exit 1
}

# Escape a verbatim help block for a .nf/.fi no-fill region: no-fill stops
# roff filling text, not interpreting control lines, so a backslash must
# survive as \e and a leading . or ' must be neutralised with \&.
esc() { sed -e 's/\\/\\e/g' -e 's/^\([.'\'']\)/\\\&\1/'; }

# Capture a command's help. Merge stderr: services/bundle print their usage to
# stderr, not stdout, so stdout-only would yield an empty section. Suppress the
# version notifier (a network-dependent stderr line) and colour to keep the
# page byte-deterministic.
help() { MALT_NO_VERSION_NOTIFIER=1 NO_COLOR=1 "$BIN" "$@" --help 2>&1; }

# Token stream of the root --help Commands column (one per line, e.g.
# "tap/untap", "services"). The same scrape drives coverage in the test.
commands() {
  help | awk '/^Commands:/{f=1;next} /^Global flags:/{f=0} f && /^  [^ ]/{print $1}'
}

emit() {
  printf '.TH MALT 1 "malt %s" "malt %s" "malt manual"\n' "$VERSION" "$VERSION"

  printf '.SH NAME\n'
  printf 'malt \\- a fast, drop-in Homebrew alternative for macOS\n'

  printf '.SH SYNOPSIS\n.nf\n'
  printf 'malt <command> [options] [arguments]\n'
  printf 'mt   <command> [options] [arguments]\n'
  printf '.fi\n'

  # DESCRIPTION: the root --help, minus its trailing Environment block (which
  # gets its own section). Split on malt's own stable "Environment:" heading.
  printf '.SH DESCRIPTION\n.nf\n'
  help | awk '/^Environment:/{exit} {print}' | esc
  printf '.fi\n'

  printf '.SH COMMANDS\n'
  while IFS= read -r tok; do
    # tap/untap documents the canonical command; run its pre-slash form.
    cmd="${tok%%/*}"
    printf '.SS %s\n.nf\n' "$tok"
    help "$cmd" | esc
    printf '.fi\n'
  done < <(commands)

  printf '.SH ENVIRONMENT\n.nf\n'
  help | awk '/^Environment:/{f=1} f{print}' | esc
  printf '.fi\n'

  printf '.SH SEE ALSO\n'
  printf '.BR brew (1)\n'
}

mkdir -p "$(dirname "$OUT")"
emit >"$OUT"
