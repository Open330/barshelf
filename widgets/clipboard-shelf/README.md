# Clipboard Shelf

A privacy-first, short-lived clipboard history for BarShelf. It captures the
current macOS text clipboard while the widget is visible, removes duplicates,
and lets you copy, pin, delete, search, or clear recent entries.

## Privacy model

- History lives only in the script process's memory. It is never written to
  BarShelf storage, a file, or the network, and disappears when the process ends.
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

The five-second refresh runs only while the widget is visible. Background
clipboard monitoring is intentionally disabled.
