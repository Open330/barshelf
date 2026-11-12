# Clipboard Shelf

A privacy-first, short-lived clipboard history for BarShelf. It reads the
macOS text clipboard every 5 seconds (also while the popup is closed, unless
you turn off **Keep collecting while the popup is closed**), removes
duplicates, and lets you copy, pin, delete, search, or clear recent entries.

## Privacy model

- History lives only in the script process's memory and disappears when the
  process ends. The exception is what you pin: pinned entries are kept in
  BarShelf's per-widget storage on this Mac so they survive a restart, and
  are removed from it when you unpin, delete or clear them. Nothing is sent
  over the network.
- Private keys, common API-token formats, JWTs, password/secret assignments, and
  valid-looking payment-card numbers are skipped rather than displayed.
- `/usr/bin/pbpaste` is the only executable permission. Its output and every
  render are marked sensitive, and the cold-start cache contains only a redacted
  placeholder.
- Re-copy uses BarShelf's native `copyText` action; the widget does not execute
  `pbcopy`. An optional setting can clear a re-copied value after 1–300 seconds.
- Clipboard content is capped at 64 KiB and history is capped at 20 entries.

## Requirements

- macOS (for `/usr/bin/pbpaste`)
- Approval of the single, exact executable permission on first run

Collecting runs from a script timer at the host's 5-second floor. With the
setting off, the clipboard is read only while the widget is visible. The
app-wide **Pause while the popup is closed** option also stops it.
