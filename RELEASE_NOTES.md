# BarShelf 0.7.35

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- The website, the README, the welcome window and the Gallery now speak to everyone first: ready-made widgets and what they show come before anything about commands or code, and the Gallery lists everyday widgets and packs before developer ones. Everything for widget authors is still there, under "For developers".
- The keyboard and window extension now runs in a process of its own, so it keeps working when BarShelf is busy, restarting or has crashed. BarShelf starts itself a second time for this (Activity Monitor shows two BarShelf processes while the extension is on); it is the same signed app, so there is nothing new to allow. If BarShelf goes away without being quit, the helper keeps your shortcuts and remapped keys alive and opens BarShelf again; quitting BarShelf normally stops both. Key remaps also run on a thread that does nothing else, so typing never waits for something BarShelf is drawing.
- Usage on This Mac: BarShelf counts, on this Mac only, how often you open the shelf and use each widget, so you can see what you never use. Settings ▸ Privacy shows the last 30 days, lets you clear the counts or turn counting off, and `barshelf usage` prints the same. Nothing is sent anywhere.
- xbar and SwiftBar plugins run as widgets: `barshelf install <plugin file>` wraps one, with its refresh interval taken from the file name and its command behind the usual permission. The title line becomes the menu bar reading and the dropdown becomes the card; tables drawn in a fixed-width font (a calendar, for instance) keep their columns. Parameters that are not supported are listed in the widget authoring guide.
- Fixed a crash that could happen when a widget refreshed at the same moment widgets were reloaded or another refresh started.
