# Fixture that tries to downgrade the archive fetch to plaintext HTTP.
# `malt install --local` must refuse the download before the HTTP
# client ever sees this URL.
class Insecure < Formula
  desc "Fixture: plaintext http:// URL — must be refused"
  homepage "http://attacker.invalid/"
  version "1.0"
  url "http://attacker.invalid/payload.tar.gz"
  sha256 "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
end
