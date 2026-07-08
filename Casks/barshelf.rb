# Homebrew cask for BarShelf.
#
# Install directly from this repo's tap:
#   brew install --cask Open330/barshelf/barshelf
# (add the tap once: `brew tap Open330/barshelf https://github.com/Open330/barshelf`)
#
# `version`/`sha256` are updated per release by scripts/release.sh.
cask "barshelf" do
  version "0.1.0"
  sha256 "5f54e4b0f779790efcb40d4c5eb7a7bfa91fb7f91c900f74b65f60b58a7dbefa"

  url "https://github.com/Open330/barshelf/releases/download/v#{version}/BarShelf-#{version}-arm64.zip",
      verified: "github.com/Open330/barshelf/"
  name "BarShelf"
  desc "Scriptable menu bar widget platform"
  homepage "https://github.com/Open330/barshelf"

  depends_on macos: :ventura
  depends_on arch: :arm64

  app "BarShelf.app"

  zap trash: [
    "~/Library/Application Support/barshelf",
    "~/Library/Caches/BarShelf",
    "~/Library/Logs/BarShelf",
  ]
end
