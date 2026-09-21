# BarShelf 0.3.1

Two fixes to `barshelf upgrade`, both found by using it.

> Requires macOS 13+ on Apple Silicon. Script widgets need
> [Deno](https://deno.land) (`brew install deno`); exec and workflow widgets do
> not.

## Fixes

- **A Homebrew-installed CLI is no longer replaced behind brew's back.**
  `brew install barshelf-cli` puts the binaries in the Cellar with a symlink in
  `<prefix>/bin`, and `upgrade` resolved that symlink and swapped the files.
  The Cellar's *files* are read-only, but the directory holding them is owned
  by you — and a swap changes a directory entry, not the file, so it succeeded
  while `brew list --versions` still reported the version brew installed. The
  next `brew upgrade` would then quietly revert your update. The CLI now gets
  the same deferral the app has had, and points at `brew upgrade barshelf-cli`.
  It is checked before the signature and writability checks, because a Homebrew
  copy passes both.

- **`--app <path>` no longer talks about the wrong copy.** Updating an
  installation somewhere else reported "BarShelf.app is still running the
  previous build" about the one in /Applications — and with `--restart` it
  would have quit that one and reopened the other. The running process is now
  matched by the full executable path inside the bundle being replaced, and
  only for your own user.

## Homebrew

The cask and the `barshelf-cli` formula now live only in
[`open330/homebrew-tap`](https://github.com/Open330/homebrew-tap), which syncs
itself from published releases daily. A second copy of the cask in this
repository had drifted three releases behind, so anyone who installed with
Homebrew was told by the app to run `brew upgrade` and told by brew that they
were already current.

```bash
brew tap open330/tap
brew install --cask barshelf     # app
brew install barshelf-cli        # CLI, optional
```

## Under the hood

CI now builds on the toolchain releases are actually cut with (macOS 26 /
Xcode 26.6 / Swift 6.3, against Xcode 27 / Swift 6.4 locally) instead of one
three majors older that the runner image no longer even carries. And the check
that stops the docs advertising a superseded build was blind to any version
followed by a Korean particle — `v0.2.1은` had no word boundary for it to
match — which is how the landing page kept pointing at 0.2.1.
