# BarShelf 0.3.0

Updating from the terminal.

> Requires macOS 13+ on Apple Silicon. Script widgets need
> [Deno](https://deno.land) (`brew install deno`); exec and workflow widgets do
> not.

## Highlights

- **`barshelf upgrade`.** The app has been able to update itself since 0.2.1;
  the CLI could not, and there was no way to update both without downloading
  two assets by hand. One command now does it:

  ```
  $ barshelf upgrade --check
  latest release: 0.3.0  [Open330/barshelf]
    cli  0.2.1 → 0.3.0             /usr/local/bin/barshelf, /usr/local/bin/bsf
    app  0.2.1 → 0.3.0             /Applications/BarShelf.app
  ```

  `barshelf upgrade` then downloads, verifies and swaps both. `--check` only
  reports, `--yes` skips the prompt, `--restart` quits and reopens the app so
  the new build is the one actually running. `barshelf update` works too.

- **The same verification the menu item uses.** The terminal and
  **Check for Updates…** share one implementation, so they accept and refuse
  exactly the same builds. Each component is anchored to its *own* signature:
  a replacement has to be a Developer ID build from the team that signed the
  copy being replaced, not from whoever signed the `barshelf` you typed.
  `barshelf` and `bsf` are both verified before either is swapped, so you never
  end up with a new CLI next to an old one.

- **It says no for the right reasons.** A Homebrew-installed app is left to
  `brew upgrade --cask barshelf`, a locally built copy is refused because there
  is no release identity to pin against, and an unwritable install directory is
  reported with what to do about it. Every refusal leaves what you have
  installed untouched.

## Notes

A standalone Mach-O cannot carry a stapled notarization ticket, and
`spctl --assess` reports one as "not an app", so the CLI binaries are gated on
the Developer ID requirement rather than on Gatekeeper's full verdict. The app
bundle still gets the full Gatekeeper check, and `scripts/verify-release.sh`
matches each published CLI binary's CDHash against the accepted notarization
ticket before a release goes out.

See [`docs/CLI.md`](docs/CLI.md#자가-업데이트) for the full rules.
