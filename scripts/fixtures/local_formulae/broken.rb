# Fixture formula that parseRubyFormula must reject. Missing version,
# url, and sha256 — exercises the "Cannot parse local formula" branch
# in installLocalFormula.
class Broken < Formula
  desc "Intentionally malformed formula (smoke test negative path)"
  homepage "https://example.invalid/broken"
end
