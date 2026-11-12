# Homebrew Updates

Outdated Homebrew formulae and casks, from `brew outdated --json=v2`. Requires
Homebrew.

## What it shows

- How many packages have an update, split into formulae and casks.
- Each package with its installed and current version; pinned ones are marked.
- **Copy upgrade command** copies `brew upgrade` (or `--formula` / `--cask`,
  following the **Show** setting). The widget never upgrades anything itself.
- The count in the menu bar, if you add it there.
- Optionally (**Notify when updates are available**, off by default), a
  notification when updates appear after a check that found none.

If Homebrew is not installed the card says so and links to brew.sh.

## Permissions and refresh

One fixed `/bin/sh -c` wrapper that looks for `brew` at `/opt/homebrew/bin`
and `/usr/local/bin` and runs `brew outdated --json=v2` with
`HOMEBREW_NO_AUTO_UPDATE=1`, so it does not fetch taps. Homebrew may still
refresh its package index the way any `brew` command does. It refreshes when
opened and every three hours while visible; while the popup is closed it
checks about every twelve hours (the menu bar item keeps its own interval).
