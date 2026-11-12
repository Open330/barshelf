# Now Playing

The track that is playing right now, from Music or Spotify.

## What it shows

- The title, the artist and which app is playing it; clicking opens that app.
- "Nothing playing" when neither app is playing.
- A prompt with a button to the Automation settings when macOS has not let
  BarShelf read the player.

The widget checks Music first and falls back to Spotify. A player that is not
running is never asked (or launched). The title can sit in the menu bar.

## Permissions and refresh

The widget runs one fixed `/bin/sh -c` command that checks which player is
running with `pgrep` and asks only that one through `osascript` (JavaScript for
Automation). The first time, macOS asks whether BarShelf may control the
player; approve it once. You can change that later in System Settings ›
Privacy & Security › Automation.

It refreshes every 20 seconds while visible. The widget only reads the track
name and artist; it does not control playback.
