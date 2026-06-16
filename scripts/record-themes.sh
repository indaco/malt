#!/usr/bin/env bash
#
# Render the builtin-theme gallery for the README. For each theme it captures two
# stills — a real `malt install` (the CLI palette) and the mt tui Installed tab —
# and stitches them side by side into docs/themes/theme-<name>.png.
#
# Deterministic capture, faithful render. Each program is driven inside a tmux
# pane and the script POLLS the actual rendered screen (`tmux capture-pane`) until
# it shows the expected content, THEN dumps it to an ANSI file — no timers, no
# races against malt. VHS then replays that static dump (scripts/theme-shot.tape.tmpl)
# to a PNG, because VHS renders truecolor and the reverse-video selection
# background faithfully (freeze drops both). Driving and rendering are split so
# neither half has to be both deterministic and pretty.
#
# Usage:
#   ./scripts/record-themes.sh                                  # all themes
#   ONLY="rose-pine default-dark" ./scripts/record-themes.sh    # just those labels
#   INSTALL_PKG=ffmpeg ./scripts/record-themes.sh               # showcase a different install
#   KEEP_PREFIX=1 / KEEP_WORK=1 ...                             # leave temp dirs in place
#
# Requires: tmux, vhs, imagemagick, and a built zig-out/bin/malt.

set -euo pipefail

cd "$(dirname "$0")/.."

for tool in tmux vhs; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "error: $tool not found. Install with: brew install $tool" >&2
    exit 1
  }
done
if command -v magick >/dev/null 2>&1; then
  IM=(magick)
elif command -v convert >/dev/null 2>&1; then
  IM=(convert)
else
  echo "error: ImageMagick not found. Install with: brew install imagemagick" >&2
  exit 1
fi

if [[ ! -x zig-out/bin/malt ]]; then
  echo "==> Building release malt binary..."
  zig build -Doptimize=ReleaseSafe
fi

# Builtin themes grouped by polarity (src/ui/themes.zig). malt colours the
# foreground only, so the VHS terminal background must match the theme polarity.
# Each row: <label>|<MALT_THEME>|<VHS theme>. The default palette is captured by
# pinning MALT_THEME=dark/light.
DARK_ROWS=(
  "default-dark|dark|Dracula"
  "dracula|dracula|Dracula"
  "catppuccin-mocha|catppuccin-mocha|Dracula"
  "rose-pine|rose-pine|Dracula"
  "nord|nord|Dracula"
  "tokyo-night|tokyo-night|Dracula"
  "gruvbox-dark|gruvbox-dark|Dracula"
  "everforest|everforest|Dracula"
)
LIGHT_ROWS=(
  "default-light|light|OneHalfLight"
  "catppuccin-latte|catppuccin-latte|OneHalfLight"
  "rose-pine-dawn|rose-pine-dawn|OneHalfLight"
  "gruvbox-light|gruvbox-light|OneHalfLight"
)
DARK_BG="#282a36"  # VHS "Dracula" background
DARK_SEP="#6272a4" # dracula comment blue — visible on the dark gap
LIGHT_BG="#fafafa" # VHS "OneHalfLight" background
LIGHT_SEP="#c0c0c0"

# The CLI still is a real install — every colour role on screen, and it populates
# the prefix for the TUI.
INSTALL_PKG="${INSTALL_PKG:-wget}"
CLI_CMD="${CLI_CMD:-malt install $INSTALL_PKG}"

OUT_DIR="docs/themes"
mkdir -p "$OUT_DIR"

# Throwaway prefix — the same path for every theme so the prefix shown in the TUI
# header is identical across the gallery. The cache lives outside it so it
# survives the per-theme wipe (warm installs ~3s instead of cold).
PREFIX=/tmp/mt-th
export MALT_PREFIX="$PREFIX"
export MALT_CACHE=/tmp/mt-cache
export PATH="$PWD/zig-out/bin:$PATH"
export COLORTERM=truecolor        # satisfy malt's truecolor gate so hex themes don't degrade
export MALT_NO_VERSION_NOTIFIER=1 # keep the update notice out of the install output

echo "==> Warming cache: malt install $INSTALL_PKG"
rm -rf "$PREFIX" && mkdir -p "$PREFIX"
malt install "$INSTALL_PKG" >/dev/null

WORK="$OUT_DIR/.work"
mkdir -p "$WORK"

cleanup() {
  tmux kill-server 2>/dev/null || true
  if [[ "${KEEP_PREFIX:-0}" == "1" ]]; then
    echo "==> Leaving $PREFIX and $MALT_CACHE in place (KEEP_PREFIX=1)"
  else
    rm -rf "$PREFIX" "$MALT_CACHE"
  fi
  if [[ "${KEEP_WORK:-0}" == "1" ]]; then
    echo "==> Leaving $WORK in place (KEEP_WORK=1)"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# Poll the tmux pane's rendered content until it matches a regex — the determinism
# seam. Returns non-zero if it never matches within ~30s.
wait_for() {
  local re="$1" i
  for ((i = 0; i < 150; i++)); do
    tmux capture-pane -p -t shot 2>/dev/null | grep -qE "$re" && return 0
    sleep 0.2
  done
  return 1
}

# Render <ansi> to <out.png> by replaying it through VHS under <vhs-theme>.
render() {
  local ansi="$1" out="$2" vhs_theme="$3" tape="$WORK/replay.tape"
  sed \
    -e "s|@SINK@|$WORK/replay.gif|" \
    -e "s|@VHS_THEME@|$vhs_theme|" \
    -e "s|@ANSI@|$ansi|" \
    -e "s|@OUT@|$out|" \
    scripts/theme-shot.tape.tmpl >"$tape"
  vhs "$tape" >/dev/null
  rm -f "$WORK/replay.gif"
}

# Render one theme. Row format: <label>|<MALT_THEME>|<VHS theme>.
shoot() {
  local row="$1" bg="$2" sep="$3"
  local label="${row%%|*}" rest="${row#*|}"
  local theme="${rest%%|*}" vhs_theme="${rest#*|}"

  if [[ -n "${ONLY:-}" && " $ONLY " != *" $label "* ]]; then
    return
  fi

  echo "==> $label"
  local cli_ansi="$WORK/cli-$label.ansi" tui_ansi="$WORK/tui-$label.ansi"
  local cli="$WORK/cli-$label.png" tui="$WORK/tui-$label.png"

  # Fresh prefix so the in-tape install runs from scratch (download bars, not
  # "already installed"); the shared cache keeps it warm.
  rm -rf "$PREFIX" && mkdir -p "$PREFIX"

  # CLI: run the install in a bare bash (no user shell theme), wait until the
  # requested package's final "installed" line is really on screen, dump it.
  tmux kill-server 2>/dev/null || true
  tmux new-session -d -s shot -x 112 -y 34 "bash --norc --noprofile"
  tmux send-keys -t shot "PS1='> '; export MALT_THEME=$theme; clear" Enter
  sleep 0.3
  tmux send-keys -t shot "$CLI_CMD" Enter
  wait_for "$INSTALL_PKG [0-9][0-9.]* installed" ||
    echo "    WARNING: $label CLI install never completed — inspect manually" >&2
  tmux capture-pane -e -p -t shot >"$cli_ansi"
  tmux kill-server 2>/dev/null || true

  # TUI: launch on the now-populated prefix, switch to the Installed tab, wait
  # until its list has rendered the package row, dump it.
  tmux new-session -d -s shot -x 112 -y 34 "bash --norc --noprofile"
  tmux send-keys -t shot "PS1='> '; export MALT_THEME=$theme; clear" Enter
  sleep 0.3
  tmux send-keys -t shot "mt tui" Enter
  wait_for "Doctor" || true
  tmux send-keys -t shot "2"
  wait_for "$INSTALL_PKG +[0-9]" ||
    echo "    WARNING: $label Installed list never loaded — inspect manually" >&2
  tmux capture-pane -e -p -t shot >"$tui_ansi"
  tmux send-keys -t shot "q"
  tmux kill-server 2>/dev/null || true

  render "$cli_ansi" "$cli" "$vhs_theme"
  render "$tui_ansi" "$tui" "$vhs_theme"

  # Stitch CLI | gap | TUI (both same size), then draw a divider down the gap centre.
  local w h
  w=$("${IM[@]}" identify -format '%w' "$cli")
  h=$("${IM[@]}" identify -format '%h' "$cli")
  "${IM[@]}" "$cli" "$tui" -background "$bg" +smush 30 "$WORK/$label-stitch.png"
  "${IM[@]}" "$WORK/$label-stitch.png" -fill "$sep" \
    -draw "rectangle $((w + 13)),0 $((w + 16)),$h" \
    "$OUT_DIR/theme-$label.png"
}

for row in "${DARK_ROWS[@]}"; do
  shoot "$row" "$DARK_BG" "$DARK_SEP"
done
for row in "${LIGHT_ROWS[@]}"; do
  shoot "$row" "$LIGHT_BG" "$LIGHT_SEP"
done

echo "==> Done. Composites in $OUT_DIR/theme-*.png."
echo "    Upload the theme-*.png to indaco/gh-assets under malt/themes/ for the README."
