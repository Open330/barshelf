# BarShelf 0.7.37

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes
- Menu bar readings stop refreshing while nobody can see the menu bar (the screen is locked or the display is asleep) and catch up the moment it is back. A widget that watches in the background, for an alert, keeps watching at its background pace.
- New in Settings ▸ General: "Reopen on the last page". On (the default), the popup opens on the page you left it on, and now does so after a restart too. Off, it always opens on the first page.
- The menu bar preview in a widget's settings now matches the menu bar. An icon-only widget given an emoji shares the BarShelf icon, as it does on the bar, instead of being shown as an item of its own with a graph it would not get; a widget with profiles previews one chip per profile in the cluster.
- Fixed data being left on disk after it should have gone: a removed widget's cached reading could be written back by a save already under way; a widget switched to hide its values kept its earlier menu bar chart points on disk for up to 30 seconds, and a chart history cleared right after launch stayed in last run's file; a reading waiting to be saved at quit could be dropped. A widget that is switched off, or that declines the desktop, can no longer have a render shared with the desktop widgets when the first write of the widget list fails.
