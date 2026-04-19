#!/usr/bin/env bash
# scripts/contrast_preview.sh
#
# Emits a canonical sample of every malt output style using the same
# palette cells the runtime picks. Render both backgrounds at both
# colour tiers (truecolor and basic) to eyeball readability side by
# side.
#
# THEME=dark|light    (default dark)
# TIER=truecolor|basic  (default truecolor)
#
# Usage:
#   scripts/contrast_preview.sh
#   THEME=light TIER=basic scripts/contrast_preview.sh

set -euo pipefail

THEME="${THEME:-dark}"
TIER="${TIER:-truecolor}"

RESET=$'\033[0m'
BOLD=$'\033[1m'

# Palette cells — kept byte-identical to src/ui/color.zig.
if [[ "$TIER" == truecolor && "$THEME" == dark ]]; then
  INFO=$'\033[38;2;125;211;252m'
  WARN=$'\033[38;2;251;191;36m'
  SUCCESS=$'\033[38;2;74;222;128m'
  ERR=$'\033[38;2;248;113;113m'
  DETAIL=$'\033[38;2;148;163;184m'
elif [[ "$TIER" == truecolor && "$THEME" == light ]]; then
  INFO=$'\033[38;2;2;132;199m'
  WARN=$'\033[38;2;180;83;9m'
  SUCCESS=$'\033[38;2;21;128;61m'
  ERR=$'\033[38;2;185;28;28m'
  DETAIL=$'\033[38;2;71;85;105m'
elif [[ "$TIER" == basic && "$THEME" == dark ]]; then
  INFO=$'\033[36m'
  WARN=$'\033[33m'
  SUCCESS=$'\033[32m'
  ERR=$'\033[31m'
  DETAIL=$'\033[2m'
else # basic + light
  INFO=$'\033[34m'
  WARN=$'\033[35m'
  SUCCESS=$'\033[32m'
  ERR=$'\033[31m'
  DETAIL=$'\033[90m'
fi

PFX_INFO="  ${INFO}▸${RESET} "
PFX_WARN="  ${WARN}⚠${RESET} "
PFX_SUCCESS="  ${SUCCESS}✓${RESET} "
PFX_ERROR="  ${ERR}✗${RESET} "

header() { printf '\n%s── %s ──%s\n\n' "$BOLD" "$*" "$RESET"; }

header "Info (▸) — progress + resolution lines"
printf '%sResolving tap user/repo/formula...\n' "$PFX_INFO"
printf '%sFound hello 1.2.3\n' "$PFX_INFO"
printf '%sLinking hello...\n' "$PFX_INFO"

header "Warn (⚠) — load-bearing security warning"
printf "%sInstalling from local file '/Users/alice/formulas/hello.rb'. Only install .rb files you trust.\n" "$PFX_WARN"
printf '%sLocal formula is world-writable — any local user could rewrite it between reads.\n' "$PFX_WARN"
printf '%s%d local keg(s) reference a .rb that no longer exists on disk.\n' "$PFX_WARN" 2

header "Success (✓) — terminal-state confirmations"
printf '%spcre2 10.47_1 installed\n' "$PFX_SUCCESS"
printf '%smalt doctor: clean\n' "$PFX_SUCCESS"

header "Error (✗) — diagnostics on failure"
printf '%sCannot open local formula: /tmp/does_not_exist.rb\n' "$PFX_ERROR"
printf '%sSHA256 mismatch for pcre2\n' "$PFX_ERROR"
printf '%sRefusing to fetch non-HTTPS archive URL for evil: http://attacker/payload.tar.gz\n' "$PFX_ERROR"

header "Detail spans — \`mt list\` / \`mt info\` / doctor rows"
printf '  %s▸%s hello %s(1.2.3)%s\n' "$INFO" "$RESET" "$DETAIL" "$RESET"
printf '  %s✓%s SQLite integrity %s— ok%s\n' "$SUCCESS" "$RESET" "$DETAIL" "$RESET"
printf '  %s⚠%s Local formula sources %s— 1/3 local keg(s) reference a .rb that no longer exists on disk.%s\n' "$WARN" "$RESET" "$DETAIL" "$RESET"

header "Progress bar — mid-flight (60%) and finished (100%)"
bar_mid() {
  local filled="" empty="" i
  for ((i = 0; i < 18; i++)); do filled+=$'\xe2\x94\x81'; done
  for ((i = 0; i < 12; i++)); do empty+=$'\xe2\x94\x80'; done
  printf '  %s▸%s %-8s %s%s%s%s%s%s  60%% %s(1.8 MB / 3.0 MB | 1.2 MB/s | ETA 1s)%s\n' \
    "$INFO" "$RESET" "pcre2" "$INFO" "$filled" "$RESET" "$DETAIL" "$empty" "$RESET" "$DETAIL" "$RESET"
}
bar_done() {
  local filled="" i
  for ((i = 0; i < 30; i++)); do filled+=$'\xe2\x94\x81'; done
  printf '  %s✓%s %-8s %s%s%s 100%% %s(3.0 MB / 3.0 MB | 1.5 MB/s | ETA 0s)%s\n' \
    "$SUCCESS" "$RESET" "pcre2" "$SUCCESS" "$filled" "$RESET" "$DETAIL" "$RESET"
}
bar_mid
bar_done

printf '\n'
