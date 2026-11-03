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
# A ".." component names a different dir than the path shows, so refuse it.
case "/$INSTALL_DIR/" in
*/../*)
  printf '  ✗ INSTALL_DIR must not contain a ".." component: %s\n' "$INSTALL_DIR" >&2
  exit 1
  ;;
esac
# A quoted ~ reaches us unexpanded. Pinning it would create a dir named "~".
# The source build cds away, so any other relative value is pinned first.
case "$INSTALL_DIR" in
/*) ;;
"~"*)
  # shellcheck disable=SC2016 # $HOME is literal text in the hint
  printf '  ✗ INSTALL_DIR starts with "~", which the shell did not expand. Use $HOME instead.\n' >&2
  exit 1
  ;;
*) INSTALL_DIR="$PWD/$INSTALL_DIR" ;;
esac
PREFIX="${PREFIX:-/opt/malt}"
# Same rules as INSTALL_DIR: root creates PREFIX, so a ".." or an unexpanded
# ~ must not steer it. The source build cds away, so pin a relative value.
case "/$PREFIX/" in
*/../*)
  printf '  ✗ PREFIX must not contain a ".." component: %s\n' "$PREFIX" >&2
  exit 1
  ;;
esac
case "$PREFIX" in
/*) ;;
"~"*)
  # shellcheck disable=SC2016 # $HOME is literal text in the hint
  printf '  ✗ PREFIX starts with "~", which the shell did not expand. Use $HOME instead.\n' >&2
  exit 1
  ;;
*) PREFIX="$PWD/$PREFIX" ;;
esac
# Owning a sticky dir such as /tmp lets you rename other users' entries.
if [ -k "$PREFIX" ]; then
  printf '  ✗ PREFIX is a sticky directory: %s\n' "$PREFIX" >&2
  exit 1
fi

# URL overrides — TESTING ONLY. In production both point at github.com.
# The regression tests under scripts/test/install_sh_test.sh drive the
# installer against a local fixture HTTP server, so each integrity-check
# code path (missing checksums, name not listed, SHA mismatch, happy
# path) can be exercised without hitting the real release surface.
RELEASES_BASE_URL="${MALT_TEST_RELEASES_URL:-https://github.com/${REPO}/releases/download}"
API_LATEST_URL="${MALT_TEST_API_URL:-https://api.github.com/repos/${REPO}/releases/latest}"

# Decide sudo per write target. SUDO covers PREFIX and the man page,
# BIN_SUDO covers INSTALL_DIR. One shared flag would make root create a
# bin directory the user could create, and root-owned dirs in the user's
# tree break later user-level installs. Root skips both.
SUDO="sudo"
BIN_SUDO="sudo"
if [ "$(id -u)" = 0 ]; then
  SUDO=""
  BIN_SUDO=""
else
  # An existing PREFIX must also be ours: chown needs root otherwise. A
  # missing one is created in its nearest existing ancestor, so root must
  # not make the missing parents.
  prefix_probe=$PREFIX
  while [ ! -e "$prefix_probe" ]; do
    prefix_probe=$(dirname "$prefix_probe")
  done
  if [ -d "$prefix_probe" ] && [ -w "$prefix_probe" ] &&
    { [ "$prefix_probe" != "$PREFIX" ] || [ -O "$PREFIX" ]; }; then
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
  # Retry any curl failure — GitHub's /releases/latest endpoint can
  # return 404 while the "latest" flag is in transition right after a
  # release is published, plus the usual 5xx/rate-limit/timeout.
  # Measured: transition can take 30-60s after publish, so the retry
  # budget has to be at least ~45s to cover it. Exponential backoff
  # across 5 attempts (3, 6, 12, 24) gives ~45s plus the fast-fail
  # per-attempt time — still bounded, and benefits every one-liner
  # user hitting a freshly-cut release, not just the CI smoke. Plain
  # --retry (no --retry-all-errors) needs 7.71+, so we do it in bash
  # for portability across macOS and older Linux.
  API_RESPONSE=""
  # Optional auth header — empty in normal user installs. The release
  # smoke sets this so polls survive the unauthenticated 60/hr-per-IP
  # ceiling on shared CI runners.
  api_auth_args=()
  if [ -n "${MALT_INSTALLER_API_TOKEN:-}" ]; then
    api_auth_args=(-H "Authorization: Bearer ${MALT_INSTALLER_API_TOKEN}")
  fi
  backoffs="3 6 12 24"
  attempt=0
  for delay in $backoffs end; do
    attempt=$((attempt + 1))
    if API_RESPONSE=$(curl -fsSL --connect-timeout 10 --max-time 30 \
      ${api_auth_args[@]+"${api_auth_args[@]}"} \
      "$API_LATEST_URL" 2>/dev/null); then
      break
    fi
    API_RESPONSE=""
    [ "$delay" != "end" ] && sleep "$delay"
  done
  if [ -n "$API_RESPONSE" ]; then
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
    zig build -Doptimize=safe
    BUILD_BIN_DIR="${REPO_ROOT}/zig-out/bin"
    MAN_SRC="${REPO_ROOT}/man/malt.1"
  else
    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    # Resolve the latest release tag without the GitHub API. Rewriting
    # git refs is a higher bar than rewriting main at a single moment.
    CLONE_REF=""
    if command -v git >/dev/null 2>&1; then
      CLONE_REF=$(git ls-remote --tags --refs "https://github.com/${REPO}.git" 'refs/tags/v*' 2>/dev/null |
        awk -F/ '{print $NF}' | sort -V | tail -1)
    fi

    if [ -n "$CLONE_REF" ]; then
      info "Cloning repository at ${CLONE_REF}..."
      git clone --depth 1 --branch "$CLONE_REF" "https://github.com/${REPO}.git" "$TMPDIR/malt"
    elif [ "${MALT_ALLOW_UNVERIFIED_SOURCE:-0}" = "1" ]; then
      warn "MALT_ALLOW_UNVERIFIED_SOURCE=1 — cloning default branch without a pinned tag"
      git clone --depth 1 "https://github.com/${REPO}.git" "$TMPDIR/malt"
    else
      error "Could not resolve a release tag to clone.
  Refusing to build from the default branch (untrusted).
  To bypass (not recommended): curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | MALT_ALLOW_UNVERIFIED_SOURCE=1 bash
  Or, from a downloaded copy: MALT_ALLOW_UNVERIFIED_SOURCE=1 bash /path/to/install.sh"
    fi

    info "Building (this may take a minute)..."
    cd "$TMPDIR/malt"
    zig build -Doptimize=safe
    BUILD_BIN_DIR="$TMPDIR/malt/zig-out/bin"
    MAN_SRC="$TMPDIR/malt/man/malt.1"
  fi

  BINARY_PATH="${BUILD_BIN_DIR}/malt"
  if [ ! -f "$BINARY_PATH" ]; then
    error "Build failed — binary not found"
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
  DOWNLOAD_URL="${RELEASES_BASE_URL}/${LATEST}/${ARCHIVE_NAME}"

  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  info "Downloading ${ARCHIVE_NAME}..."
  curl -fsSL "$DOWNLOAD_URL" -o "$TMPDIR/$ARCHIVE_NAME" ||
    error "Download failed. Check https://github.com/${REPO}/releases"

  # ── Verify checksum (required) ──────────────────────────────────
  # README promises SHA256 verification, so refuse to install without it.
  CHECKSUM_URL="${RELEASES_BASE_URL}/${LATEST}/checksums.txt"
  info "Verifying SHA256 checksum..."
  curl -fsSL "$CHECKSUM_URL" -o "$TMPDIR/checksums.txt" ||
    error "Could not fetch checksums.txt from ${CHECKSUM_URL}. Refusing to install without verification."

  # ── Verify cosign signature (required unless explicitly opted out) ──
  # The checksums file is signed keyless at release time by the
  # goreleaser workflow, producing a single .sigstore.json bundle that
  # carries both the signature and the Sigstore certificate. Verifying
  # here ties the SHA list to the exact workflow identity that produced
  # it; a token capable of uploading a replacement checksums.txt cannot
  # forge this signature without also being able to run that workflow.
  BUNDLE_URL="${CHECKSUM_URL}.sigstore.json"
  CERT_IDENTITY_REGEX="^https://github.com/${REPO}/\\.github/workflows/release\\.yml@"
  OIDC_ISSUER="https://token.actions.githubusercontent.com"

  if command -v cosign >/dev/null 2>&1; then
    info "Verifying cosign signature..."
    # Missing .sigstore.json is a signed-release regression, not a soft
    # fallback — fail the same way a missing checksum file would.
    curl -fsSL "$BUNDLE_URL" -o "$TMPDIR/checksums.txt.sigstore.json" ||
      error "Could not fetch ${BUNDLE_URL}. Refusing to install without signature verification."

    cosign verify-blob \
      --bundle "$TMPDIR/checksums.txt.sigstore.json" \
      --certificate-identity-regexp "$CERT_IDENTITY_REGEX" \
      --certificate-oidc-issuer "$OIDC_ISSUER" \
      "$TMPDIR/checksums.txt" >/dev/null 2>&1 ||
      error "cosign signature verification failed for checksums.txt."
    ok "cosign signature verified"
  elif [ "${MALT_ALLOW_UNVERIFIED:-0}" = "1" ]; then
    # Loud on purpose: users who hit this have stepped around a
    # trust anchor, not a cosmetic check.
    warn "cosign not installed; MALT_ALLOW_UNVERIFIED=1 — skipping signature verification"
    warn "install cosign to cryptographically verify the release: https://docs.sigstore.dev/cosign/system_config/installation/"
  else
    error "cosign is required to verify the release signature.
  Install: https://docs.sigstore.dev/cosign/system_config/installation/ (e.g. \`brew install cosign\`)
  To bypass (not recommended): curl -fsSL https://raw.githubusercontent.com/${REPO}/main/scripts/install.sh | MALT_ALLOW_UNVERIFIED=1 bash
  Or, from a downloaded copy: MALT_ALLOW_UNVERIFIED=1 bash /path/to/install.sh"
  fi

  # Compare the name field for equality. `grep "$ARCHIVE_NAME"` treated the
  # name as a regex and matched anywhere on the line; anchoring the start of
  # the field still leaves the near miss where `x.tar.gz` collects the hash
  # of `x.tar.gz.sig`. checksums.txt is cosign-verified above, so neither was
  # exploitable - the lookup just should not depend on what else is listed.
  EXPECTED=$(awk -v want="$ARCHIVE_NAME" '$2 == want {print $1; exit}' "$TMPDIR/checksums.txt")
  [ -n "$EXPECTED" ] || error "Checksum for ${ARCHIVE_NAME} not listed in checksums.txt."
  ACTUAL=$(shasum -a 256 "$TMPDIR/$ARCHIVE_NAME" | awk '{print $1}')
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    error "SHA256 mismatch! Expected: $EXPECTED  Got: $ACTUAL"
  fi
  ok "SHA256 verified"

  # ── Extract ─────────────────────────────────────────────────────
  info "Extracting..."
  tar -xzf "$TMPDIR/$ARCHIVE_NAME" -C "$TMPDIR"

  # Find the binary (may be in a subdirectory). `-perm -u+x` is
  # portable across BSD and GNU find; the old `+111` form is
  # deprecated BSD syntax.
  BINARY_PATH=$(find "$TMPDIR" -name "$BINARY" -type f -perm -u+x | head -1)
  [ -n "$BINARY_PATH" ] || error "Binary '${BINARY}' not found in archive"

  # The page rides the tarball at share/man/man1/malt.1. Locate it the
  # same way; absence is tolerated below so older tarballs still install.
  MAN_SRC=$(find "$TMPDIR" -name "malt.1" -type f | head -1)

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

# ── Install binary ──────────────────────────────────────────────────
# After the prefix step, so a bin dir under PREFIX is created by its owner.
# Test the nearest existing ancestor of INSTALL_DIR: a missing directory
# is as writable as the place it would be created in.
if [ -n "$BIN_SUDO" ]; then
  install_dir_probe=$INSTALL_DIR
  while [ ! -e "$install_dir_probe" ]; do
    install_dir_probe=$(dirname "$install_dir_probe")
  done
  if [ -d "$install_dir_probe" ] && [ -w "$install_dir_probe" ]; then
    BIN_SUDO=""
  fi
fi
info "Installing to ${INSTALL_DIR}..."
$BIN_SUDO mkdir -p "$INSTALL_DIR"
$BIN_SUDO install -m 755 "$BINARY_PATH" "${INSTALL_DIR}/${BINARY}"

# `mt` is a symlink to `malt`. Relative target survives prefix moves.
$BIN_SUDO ln -sfn "${BINARY}" "${INSTALL_DIR}/mt"

# ── Install man page ────────────────────────────────────────────────
# `man malt` resolves only when the page sits under ${PREFIX}/share/man,
# which `mt shellenv` puts on MANPATH. Place it after prefix creation so
# ${PREFIX} exists and is user-owned. A missing page (older tarball, or
# a build with no committed page) must never fail a binary install.
MAN1_DIR="${PREFIX}/share/man/man1"
if [ -n "${MAN_SRC:-}" ] && [ -f "$MAN_SRC" ]; then
  info "Installing man page..."
  $SUDO mkdir -p "$MAN1_DIR"
  $SUDO install -m 644 "$MAN_SRC" "${MAN1_DIR}/malt.1"
  # Match ${PREFIX} ownership so a later non-sudo reinstall can overwrite.
  $SUDO chown -R "$USER" "${PREFIX}/share"
  ok "Installed man page to ${MAN1_DIR}/malt.1"
else
  warn "No man page found; skipping (\`man malt\` lands on the next release)"
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
# Whole-entry match, trailing slash ignored, like doctor's PATH check.
case ":${PATH}:" in
*":${PREFIX}/bin:"* | *":${PREFIX}/bin/:"*)
  printf '%s%smalt is ready!%s\n' "${BOLD}" "${GREEN}" "${RESET}"
  ;;
*)
  # Never write dotfiles: a piped installer cannot ask for consent.
  # Login-shell files, like Homebrew's installer.
  SHELLENV_CMD="malt shellenv"
  [ "$PREFIX" = "/opt/malt" ] || SHELLENV_CMD="MALT_PREFIX=${PREFIX} malt shellenv"
  case "$(basename "${SHELL:-}")" in
  zsh) PROFILE_LINE="echo 'eval \"\$(${SHELLENV_CMD})\"' >> ~/.zprofile" ;;
  bash) PROFILE_LINE="echo 'eval \"\$(${SHELLENV_CMD})\"' >> ~/.bash_profile" ;;
  fish) PROFILE_LINE="${SHELLENV_CMD} fish | source    # in ~/.config/fish/config.fish" ;;
  *) PROFILE_LINE="eval \"\$(${SHELLENV_CMD})\"" ;;
  esac
  printf '%s%smalt is installed, but one more step is needed%s\n' "${BOLD}" "${YELLOW}" "${RESET}"
  echo "  ${PREFIX}/bin is not on your PATH, so installed commands will not be found."
  echo "  Add this to your shell profile:"
  echo "    ${PROFILE_LINE}"
  echo "  Then apply it to this shell:"
  case "$(basename "${SHELL:-}")" in
  fish) echo "    ${SHELLENV_CMD} fish | source" ;;
  *) echo "    eval \"\$(${SHELLENV_CMD})\"" ;;
  esac
  ;;
esac
echo ""
echo "  Get started:"
echo "    malt install tree         # install a formula"
echo "    malt install --cask app   # install a cask"
echo "    malt list                 # list installed packages"
echo "    malt --help               # see all commands"
echo ""
echo "  Alias: 'mt' is also available (e.g., mt install wget)"
echo ""
