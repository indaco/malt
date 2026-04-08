#!/usr/bin/env bash
# malt installer — https://github.com/indaco/malt
# Usage: curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash
set -euo pipefail

REPO="indaco/malt"
BINARY="malt"
INSTALL_DIR="/usr/local/bin"
PREFIX="/opt/malt"

# Colors (respect NO_COLOR)
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  BOLD="\033[1m"
  CYAN="\033[36m"
  GREEN="\033[32m"
  YELLOW="\033[33m"
  RED="\033[31m"
  RESET="\033[0m"
else
  BOLD="" CYAN="" GREEN="" YELLOW="" RED="" RESET=""
fi

info()  { printf "${CYAN}==> ${RESET}%s\n" "$*"; }
ok()    { printf "${GREEN}==> ${RESET}%s\n" "$*"; }
warn()  { printf "${YELLOW}Warning: ${RESET}%s\n" "$*"; }
error() { printf "${RED}Error: ${RESET}%s\n" "$*" >&2; exit 1; }

# ── Platform detection ──────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

[ "$OS" = "Darwin" ] || error "malt is macOS only. Detected: $OS"

case "$ARCH" in
  arm64|aarch64) ARCH_LABEL="arm64" ;;
  x86_64)        ARCH_LABEL="x86_64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac

info "Detected macOS $ARCH_LABEL"

# ── Find latest release ────────────────────────────────────────────
info "Fetching latest release..."

LATEST=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null \
  | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')

if [ -z "$LATEST" ]; then
  # No releases yet — try building from source
  warn "No releases found on GitHub. Falling back to build from source."

  if ! command -v zig >/dev/null 2>&1; then
    error "Zig is required to build from source. Install: https://ziglang.org/download/"
  fi

  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  info "Cloning repository..."
  git clone --depth 1 "https://github.com/${REPO}.git" "$TMPDIR/malt"

  info "Building (this may take a minute)..."
  cd "$TMPDIR/malt"
  zig build -Doptimize=ReleaseSafe

  BINARY_PATH="$TMPDIR/malt/zig-out/bin/malt"

  if [ ! -f "$BINARY_PATH" ]; then
    error "Build failed — binary not found"
  fi

  info "Installing to ${INSTALL_DIR}..."
  sudo install -m 755 "$BINARY_PATH" "${INSTALL_DIR}/${BINARY}"

  # Create alias
  sudo ln -sf "${INSTALL_DIR}/${BINARY}" "${INSTALL_DIR}/mt" 2>/dev/null || true

else
  VERSION="${LATEST#v}"
  info "Latest version: ${VERSION}"

  # ── Download ────────────────────────────────────────────────────
  ARCHIVE_NAME="malt_${VERSION}_Darwin_${ARCH_LABEL}.tar.gz"
  DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST}/${ARCHIVE_NAME}"

  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  info "Downloading ${ARCHIVE_NAME}..."
  curl -fsSL "$DOWNLOAD_URL" -o "$TMPDIR/$ARCHIVE_NAME" \
    || error "Download failed. Check https://github.com/${REPO}/releases"

  # ── Verify checksum (if available) ──────────────────────────────
  CHECKSUM_URL="https://github.com/${REPO}/releases/download/${LATEST}/checksums.txt"
  if curl -fsSL "$CHECKSUM_URL" -o "$TMPDIR/checksums.txt" 2>/dev/null; then
    EXPECTED=$(grep "$ARCHIVE_NAME" "$TMPDIR/checksums.txt" | awk '{print $1}')
    if [ -n "$EXPECTED" ]; then
      ACTUAL=$(shasum -a 256 "$TMPDIR/$ARCHIVE_NAME" | awk '{print $1}')
      if [ "$EXPECTED" != "$ACTUAL" ]; then
        error "SHA256 mismatch!\n  Expected: $EXPECTED\n  Got:      $ACTUAL"
      fi
      ok "SHA256 verified"
    fi
  fi

  # ── Extract ─────────────────────────────────────────────────────
  info "Extracting..."
  tar -xzf "$TMPDIR/$ARCHIVE_NAME" -C "$TMPDIR"

  # Find the binary (may be in a subdirectory)
  BINARY_PATH=$(find "$TMPDIR" -name "$BINARY" -type f -perm +111 | head -1)
  [ -n "$BINARY_PATH" ] || error "Binary '${BINARY}' not found in archive"

  # ── Install binary ──────────────────────────────────────────────
  info "Installing to ${INSTALL_DIR}..."
  sudo install -m 755 "$BINARY_PATH" "${INSTALL_DIR}/${BINARY}"

  # Create mt alias
  sudo ln -sf "${INSTALL_DIR}/${BINARY}" "${INSTALL_DIR}/mt" 2>/dev/null || true
fi

# ── Create prefix directory ─────────────────────────────────────────
if [ ! -d "$PREFIX" ]; then
  info "Creating ${PREFIX}..."
  sudo mkdir -p "$PREFIX"
  sudo chown "$USER" "$PREFIX"
  ok "Created ${PREFIX} (owned by ${USER})"
else
  # Ensure current user owns it
  if [ "$(stat -f '%Su' "$PREFIX" 2>/dev/null || stat -c '%U' "$PREFIX" 2>/dev/null)" != "$USER" ]; then
    warn "${PREFIX} exists but is not owned by ${USER}"
    info "Fixing ownership..."
    sudo chown "$USER" "$PREFIX"
  fi
  ok "${PREFIX} already exists"
fi

# ── Verify ──────────────────────────────────────────────────────────
if command -v malt >/dev/null 2>&1; then
  INSTALLED_VERSION=$(malt --version 2>/dev/null || echo "unknown")
  ok "Installed: ${INSTALLED_VERSION}"
else
  warn "malt was installed to ${INSTALL_DIR} but is not in PATH"
  echo "  Add this to your shell profile:"
  echo "    export PATH=\"${INSTALL_DIR}:\$PATH\""
fi

echo ""
printf "${BOLD}${GREEN}malt is ready!${RESET}\n"
echo ""
echo "  Get started:"
echo "    malt install jq           # install a formula"
echo "    malt install --cask app   # install a cask"
echo "    malt list                 # list installed packages"
echo "    malt --help               # see all commands"
echo ""
echo "  Alias: 'mt' is also available (e.g., mt install wget)"
echo ""
