# Staged copy of the cask. The live one belongs in Stixum/homebrew-tap as
# Casks/burnline.rb — this file is kept here so it is reviewable alongside the
# release that produced it.
#
# sha256 below is for the DMG built at 1.0. It MUST match the artefact
# actually attached to the GitHub release, or every install fails the checksum.
cask "burnline" do
  version "1.0"
  sha256 "0837d752c547e0856925e8785ccdd6a400d0039535ab1743a86119d1a2b5f7ff"

  url "https://github.com/Stixum/Burnline/releases/download/v#{version}/Burnline.dmg"
  name "Burnline"
  desc "Menu bar app showing Claude usage against the weekly pace target"
  homepage "https://github.com/Stixum/Burnline"

  depends_on macos: ">= :sonoma"

  app "Burnline.app"

  # Deliberately does NOT remove the statusLine key from ~/.claude/settings.json.
  # A cask cannot safely edit a user's config file, and a leftover key pointing
  # at a deleted binary merely prints "command not found" in the status line —
  # annoying, but it does not break Claude Code. Removing it wrongly would.
  zap trash: [
    "~/Library/Application Support/Burnline",
  ]
end
