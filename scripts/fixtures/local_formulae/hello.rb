# Fixture formula for scripts/smoke_install_local.sh.
# Mirrors a GoReleaser-style Homebrew tap: version at top level, per-arch
# url + sha256 inside on_macos / on_arm / on_intel blocks. The URL points
# at an unreachable host on purpose — the smoke test only exercises the
# parse + dry-run path, never the download.
class Hello < Formula
  desc "Fixture formula for malt install --local smoke tests"
  homepage "https://example.invalid/hello"
  version "1.2.3"

  on_macos do
    on_arm do
      url "https://example.invalid/hello-#{version}-arm64.tar.gz"
      sha256 "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    end
    on_intel do
      url "https://example.invalid/hello-#{version}-x86_64.tar.gz"
      sha256 "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    end
  end

  def install
    bin.install "hello"
  end
end
