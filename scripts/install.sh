#!/usr/bin/env bash
# malt installer — https://github.com/indaco/malt
# Usage: curl -fsSL https://raw.githubusercontent.com/indaco/malt/main/scripts/install.sh | bash
set -euo pipefail

REPO="indaco/malt"
BINARY="malt"
# INSTALL_DIR and PREFIX honour env overrides so the installer can be
# smoke-tested against a throwaway location (e.g. `PREFIX=/tmp/malt
# INSTALL_DIR=/tmp/malt-bin ./scripts/install.sh`) without touching
# the system prefix.
INSTALL_DIR="${INSTALL_DIR:-/usr/local/bin}"
PREFIX="${PREFIX:-/opt/malt}"

# Use sudo only when we actually need it. Root obviously skips it; a
# non-root run skips it too when INSTALL_DIR and PREFIX are already
# writable (the common case when testing against /tmp).
SUDO="sudo"
if [ "$(id -u)" = 0 ]; then
  SUDO=""
else
  prefix_writable=0
  if [ -d "$PREFIX" ] && [ -w "$PREFIX" ]; then
    prefix_writable=1
  elif [ ! -e "$PREFIX" ] && [ -w "$(dirname "$PREFIX")" ]; then
    prefix_writable=1
  fi
  if [ -w "$INSTALL_DIR" ] && [ "$prefix_writable" = 1 ]; then
    SUDO=""
  fi
fi

# Colors (respect NO_COLOR)
if [ -z "${NO_COLOR:-}" ] && [ -t 1 ]; then
  BOLD=$'\033[1m'
  CYAN=$'\033[36m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  RESET=$'\033[0m'
else
  BOLD="" CYAN="" GREEN="" YELLOW="" RED="" RESET=""
fi

info() { printf "${CYAN}  ▸ ${RESET}%s\n" "$*"; }
ok() { printf "${GREEN}  ✓ ${RESET}%s\n" "$*"; }
warn() { printf "${YELLOW}  ⚠ ${RESET}%s\n" "$*"; }
error() {
  printf "${RED}  ✗ ${RESET}%s\n" "$*" >&2
  exit 1
}

# ── Platform detection ──────────────────────────────────────────────
OS="$(uname -s)"
ARCH="$(uname -m)"

[ "$OS" = "Darwin" ] || error "malt is macOS only. Detected: $OS"

case "$ARCH" in
  arm64 | aarch64) ARCH_LABEL="arm64" ;;
  x86_64) ARCH_LABEL="x86_64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac

info "Detected macOS $ARCH_LABEL"

# ── Check for local repo first ────────────────────────────────────
# Only trust the repo-root probe when the script is invoked as a real
# file on disk. When piped via `curl … | bash`, $0 is "bash" and
# dirname → ".", which would otherwise make $PWD look like a repo root
# and silently switch to build-from-source mode.
REPO_ROOT=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
fi
LATEST=""
API_FAILED=0

if [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/build.zig" ] && [ -f "${REPO_ROOT}/src/main.zig" ]; then
  info "Local repository detected at ${REPO_ROOT}"
else
  # ── Find latest release ──────────────────────────────────────────
  info "Fetching latest release..."
  if API_RESPONSE=$(curl -fsSL --connect-timeout 5 --max-time 10 "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null); then
    LATEST=$(printf '%s' "$API_RESPONSE" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"//;s/".*//')
  else
    API_FAILED=1
  fi
fi

if [ -z "$LATEST" ]; then
  # Build from source (local checkout or freshly cloned).
  if [ -z "$REPO_ROOT" ] || [ ! -f "${REPO_ROOT}/build.zig" ]; then
    if [ "$API_FAILED" -eq 1 ]; then
      warn "Could not reach GitHub API. Falling back to build from source."
    else
      warn "No releases found on GitHub. Falling back to build from source."
    fi
  fi

  if ! command -v zig >/dev/null 2>&1; then
    error "Zig is required to build from source. Install: https://ziglang.org/download/"
  fi

  if [ -n "$REPO_ROOT" ] && [ -f "${REPO_ROOT}/build.zig" ] && [ -f "${REPO_ROOT}/src/main.zig" ]; then
    info "Building from local source (${REPO_ROOT})..."
    cd "$REPO_ROOT"
    zig build -Doptimize=ReleaseSafe
    BUILD_BIN_DIR="${REPO_ROOT}/zig-out/bin"
  else
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    info "Cloning repository..."
    git clone --depth 1 "https://github.com/${REPO}.git" "$TMPDIR/malt"

    info "Building (this may take a minute)..."
    cd "$TMPDIR/malt"
    zig build -Doptimize=ReleaseSafe
    BUILD_BIN_DIR="$TMPDIR/malt/zig-out/bin"
  fi

  BINARY_PATH="${BUILD_BIN_DIR}/malt"
  if [ ! -f "$BINARY_PATH" ]; then
    error "Build failed — binary not found"
  fi

  info "Installing to ${INSTALL_DIR}..."
  $SUDO install -m 755 "$BINARY_PATH" "${INSTALL_DIR}/${BINARY}"

  # `zig build` produces both `malt` and `mt`. Install the real `mt`
  # if it's there; otherwise fall back to a symlink.
  if [ -f "${BUILD_BIN_DIR}/mt" ]; then
    $SUDO install -m 755 "${BUILD_BIN_DIR}/mt" "${INSTALL_DIR}/mt"
  else
    $SUDO ln -sf "${INSTALL_DIR}/${BINARY}" "${INSTALL_DIR}/mt"
  fi

else
  VERSION="${LATEST#v}"
  info "Latest version: ${VERSION}"

  # ── Download ────────────────────────────────────────────────────
  # GoReleaser publishes a single universal binary as `_darwin_all`
  # (lowercase os, arch literal `all`). `$ARCH_LABEL` is only used
  # for the "Detected macOS …" banner; the tarball name no longer
  # depends on the host arch.
  ARCHIVE_NAME="malt_${VERSION}_darwin_all.tar.gz"
  DOWNLOAD_URL="https://github.com/${REPO}/releases/download/${LATEST}/${ARCHIVE_NAME}"

  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  info "Downloading ${ARCHIVE_NAME}..."
  curl -fsSL "$DOWNLOAD_URL" -o "$TMPDIR/$ARCHIVE_NAME" ||
    error "Download failed. Check https://github.com/${REPO}/releases"

  # ── Verify checksum (required) ──────────────────────────────────
  # README promises SHA256 verification, so refuse to install without it.
  CHECKSUM_URL="https://github.com/${REPO}/releases/download/${LATEST}/checksums.txt"
  info "Verifying SHA256 checksum..."
  curl -fsSL "$CHECKSUM_URL" -o "$TMPDIR/checksums.txt" ||
    error "Could not fetch checksums.txt from ${CHECKSUM_URL}. Refusing to install without verification."
  EXPECTED=$(grep "$ARCHIVE_NAME" "$TMPDIR/checksums.txt" | awk '{print $1}')
  [ -n "$EXPECTED" ] || error "Checksum for ${ARCHIVE_NAME} not listed in checksums.txt."
  ACTUAL=$(shasum -a 256 "$TMPDIR/$ARCHIVE_NAME" | awk '{print $1}')
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    error "SHA256 mismatch! Expected: $EXPECTED  Got: $ACTUAL"
  fi
  ok "SHA256 verified"

  # ── Extract ─────────────────────────────────────────────────────
  info "Extracting..."
  tar -xzf "$TMPDIR/$ARCHIVE_NAME" -C "$TMPDIR"

  # Find the binaries (may be in a subdirectory). `-perm -u+x` is
  # portable across BSD and GNU find; the old `+111` form is
  # deprecated BSD syntax.
  BINARY_PATH=$(find "$TMPDIR" -name "$BINARY" -type f -perm -u+x | head -1)
  [ -n "$BINARY_PATH" ] || error "Binary '${BINARY}' not found in archive"
  MT_PATH=$(find "$TMPDIR" -name mt -type f -perm -u+x | head -1)

  # ── Install binary ──────────────────────────────────────────────
  info "Installing to ${INSTALL_DIR}..."
  $SUDO install -m 755 "$BINARY_PATH" "${INSTALL_DIR}/${BINARY}"

  # Install `mt` — prefer the real binary shipped in the archive,
  # fall back to a symlink if it isn't there.
  if [ -n "$MT_PATH" ]; then
    $SUDO install -m 755 "$MT_PATH" "${INSTALL_DIR}/mt"
  else
    $SUDO ln -sf "${INSTALL_DIR}/${BINARY}" "${INSTALL_DIR}/mt"
  fi
fi

# ── Create prefix directory ─────────────────────────────────────────
if [ ! -d "$PREFIX" ]; then
  info "Creating ${PREFIX}..."
  $SUDO mkdir -p "$PREFIX"
  $SUDO chown "$USER" "$PREFIX"
  ok "Created ${PREFIX} (owned by ${USER})"
else
  # Ensure current user owns it
  if [ "$(stat -f '%Su' "$PREFIX" 2>/dev/null || stat -c '%U' "$PREFIX" 2>/dev/null)" != "$USER" ]; then
    warn "${PREFIX} exists but is not owned by ${USER}"
    info "Fixing ownership..."
    $SUDO chown "$USER" "$PREFIX"
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
printf '%s%smalt is ready!%s\n' "${BOLD}" "${GREEN}" "${RESET}"
echo ""
echo "  Get started:"
echo "    malt install jq           # install a formula"
echo "    malt install --cask app   # install a cask"
echo "    malt list                 # list installed packages"
echo "    malt --help               # see all commands"
echo ""
echo "  Alias: 'mt' is also available (e.g., mt install wget)"
echo ""
