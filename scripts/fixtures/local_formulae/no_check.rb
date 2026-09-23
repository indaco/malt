# Fixture formula that opts out of checksum verification. malt requires a
# pinned sha256, so installLocalFormula must refuse it and name the reason.
class NoCheck < Formula
  desc "Unpinned download (smoke test negative path)"
  homepage "https://example.invalid/no_check"
  url "https://example.invalid/no_check-1.0.0.tar.gz"
  version "1.0.0"
  sha256 :no_check
end
