#!/usr/bin/env bash
# A two-arch formula written as `if Hardware::CPU.<arch>? ... else ... end`
# must resolve the running arch's url from whichever branch holds it. The
# arch scanner keys off markers, and a bare `else` carries none, so the
# branch it opens used to be skipped entirely — leaving the parse with no
# url/sha256 and the install refused outright.
#
# Refusing is itself correct for a formula that really has nothing for us,
# so the wrong-arch-only case is asserted too: the fix must not buy the
# `else` branch back by re-arming the arch-blind global fallback, which
# would resolve the other arch's self-consistent (checksum-passing) pair.
#
# Parsing happens before any download, so this stays offline. URLs use
# reserved .invalid hosts: on a broken tree that resolves the wrong branch
# and proceeds to download, DNS fails fast instead of hanging.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
BIN="${MALT_BIN:-$ROOT/zig-out/bin/malt}"
[[ -x "$BIN" ]] || {
  echo "build malt first: zig build" >&2
  exit 2
}

PREFIX="$(mktemp -d)/opt-malt"
export MALT_PREFIX="$PREFIX"
export NO_COLOR=1
export MALT_NO_EMOJI=1
mkdir -p "$PREFIX"
trap 'rm -rf "$(dirname "$PREFIX")"' EXIT

if [[ "$(uname -m)" == arm64 ]]; then
  ours="arm?"
  theirs="intel?"
  other_block="on_intel"
else
  ours="intel?"
  theirs="arm?"
  other_block="on_arm"
fi

RIGHT="https://right.invalid/probe-1.2.3-ours.tar.gz"
WRONG="https://wrong.invalid/probe-1.2.3-other.tar.gz"
SHA_OURS="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_THEIRS="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

out="$PREFIX/out.log"

# Gate names the OTHER arch: `else` is the branch that must win.
cat >"$PREFIX/else_branch.rb" <<RB
class Probe < Formula
  version "1.2.3"
  if Hardware::CPU.$theirs
    url "$WRONG"
    sha256 "$SHA_THEIRS"
  else
    url "$RIGHT"
    sha256 "$SHA_OURS"
  end
end
RB

if ! "$BIN" install --dry-run --local "$PREFIX/else_branch.rb" >"$out" 2>&1; then
  echo "FAIL: arch if/else formula did not parse; the else branch was skipped" >&2
  cat "$out" >&2
  exit 1
fi
grep -q "$RIGHT" "$out" || {
  echo "FAIL: resolved the wrong branch's url" >&2
  cat "$out" >&2
  exit 1
}

# Mirror: gate names OUR arch, so the `if` branch must win and the flip
# must not invert. Guards against a fix that merely swaps the defect.
cat >"$PREFIX/if_branch.rb" <<RB
class Probe < Formula
  version "1.2.3"
  if Hardware::CPU.$ours
    url "$RIGHT"
    sha256 "$SHA_OURS"
  else
    url "$WRONG"
    sha256 "$SHA_THEIRS"
  end
end
RB

if ! "$BIN" install --dry-run --local "$PREFIX/if_branch.rb" >"$out" 2>&1; then
  echo "FAIL: arch if/else formula gating our own arch stopped parsing" >&2
  cat "$out" >&2
  exit 1
fi
grep -q "$RIGHT" "$out" || {
  echo "FAIL: else branch leaked over the matching if branch" >&2
  cat "$out" >&2
  exit 1
}

# A heredoc body holds arbitrary text - real formulas ship `caveats` and
# config templates - so a line reading `else` inside one must not be mistaken
# for the branch's own. Same stakes as the nested case below.
cat >"$PREFIX/heredoc.rb" <<RB
class Probe < Formula
  version "1.2.3"
  if Hardware::CPU.$theirs
    caveats <<~EOS
      else
    EOS
    url "$WRONG"
    sha256 "$SHA_THEIRS"
  else
    url "$RIGHT"
    sha256 "$SHA_OURS"
  end
end
RB

if "$BIN" install --dry-run --local "$PREFIX/heredoc.rb" >"$out" 2>&1; then
  grep -q "$WRONG" "$out" && {
    echo "FAIL: an else inside a heredoc was believed; wrong arch resolved" >&2
    cat "$out" >&2
    exit 1
  }
fi

# A nested conditional owns its own `else`, so the arch branch is no longer
# straight-line and the flip must be abandoned. Claiming that `else` would
# install the other arch's binary behind the checksum that matches it.
cat >"$PREFIX/nested.rb" <<RB
class Probe < Formula
  version "1.2.3"
  if Hardware::CPU.$theirs
    if build.head?
      url "$WRONG"
    else
      url "$WRONG"
      sha256 "$SHA_THEIRS"
    end
  else
    url "$RIGHT"
    sha256 "$SHA_OURS"
  end
end
RB

if "$BIN" install --dry-run --local "$PREFIX/nested.rb" >"$out" 2>&1; then
  grep -q "$WRONG" "$out" && {
    echo "FAIL: a nested else was mistaken for the arch else; wrong arch resolved" >&2
    cat "$out" >&2
    exit 1
  }
fi

# A lone wrong-arch block still has nothing for us: refuse, never fall back.
cat >"$PREFIX/only_other.rb" <<RB
class Only < Formula
  version "1.2.3"
  $other_block do
    url "$WRONG"
    sha256 "$SHA_THEIRS"
  end
end
RB

if "$BIN" install --dry-run --local "$PREFIX/only_other.rb" >"$out" 2>&1; then
  echo "FAIL: wrong-arch-only formula resolved; the fallback guard regressed" >&2
  cat "$out" >&2
  exit 1
fi
grep -q "Cannot parse local formula" "$out" || {
  echo "FAIL: wrong-arch-only formula refused for the wrong reason" >&2
  cat "$out" >&2
  exit 1
}

echo "OK: arch if/else resolves the running arch from either branch"
exit 0
