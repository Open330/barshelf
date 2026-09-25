# Now Playing

The track that is playing right now, from Music or Spotify, as one line in the
BarShelf popover.

## What it shows

- The current track as "Title - Artist".
- "Nothing playing" when neither app is playing.

The widget asks Music first and falls back to Spotify, so whichever app is
playing is the one you see.

## Permissions and refresh

The widget runs one fixed `/bin/sh -c` command that asks Music and Spotify
through AppleScript. The first time it runs, macOS asks whether BarShelf may
control those apps; approve it once in the Automation prompt. You can change
that later in System Settings › Privacy & Security › Automation.

It refreshes every five seconds while the popover is visible and stops when it
is closed. Clicking the card opens Music. The widget only reads the track name
and artist; it does not control playback.
