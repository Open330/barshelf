# BarShelf 0.7.1

> Unreleased. Requires macOS 14+ on Apple Silicon.

BarShelf 0.7.0 adds an optional dock: apps, folders, links, Shortcuts, and live
widgets on a screen edge, alongside the Apple Dock or instead of it, with
profiles that can rearrange the Apple Dock too. Automation imports
Karabiner-Elements rules and can switch input sources the moment a shortcut
goes down. Desktop widgets refresh in place and come in extra large.

## BarShelf Dock

Off by default; turn it on in **BarShelf ▸ Dock**. See [the Dock guide](docs/DOCK.md).

- **Alongside the Apple Dock, or instead of it.** "Instead" hides the Apple
  Dock while BarShelf runs and brings it back when you quit or switch the mode
  off (also after a crash, or with `barshelf dock restore-apple-dock`).
- **What goes in it:** apps (with open-app dots and drop-to-open), folders as
  coloured tiles that open as a grid like the Apple Dock's stacks, files,
  links, Shortcuts, spaces, dividers, the Trash, open apps that aren't in it,
  recent apps, and **live widgets** — at icon height in Classic, as full cards
  in Shelf.
- **Looks like the Apple Dock:** Liquid Glass, the Apple Dock's size by
  default (it follows when you change it), magnification, names on hover, a
  bounce while an app opens.
- **Profiles** (Work, Personal, …) each carry their own items, and can carry a
  saved Apple Dock layout and a popup page. Switch with ⌃⌥1–9, a swipe or
  ⌘-scroll on the dock, the BarShelf menu, `barshelf://dock?profile=…`, or
  `barshelf dock use`. A Shortcuts automation lets a Focus switch it.
- **Full-screen apps:** the dock waits at the edge and slides out when the
  pointer rests there. With more than one display it can follow the pointer.

## Automation

- **Import Karabiner-Elements rules.** Key-to-key mappings run natively on the
  keyboard monitor; anything that would change behavior and can't be carried
  over is reported before importing.
- **`barshelf.selectNextInputSource()`** switches to the next keyboard input
  source as soon as its shortcut goes down, instead of when ⌘ comes back up as
  the system's "Select next source" does. Bind it to ⌘Space and turn the
  system shortcut off. See AUTOMATION.md.
- The keyboard monitor is recreated if macOS drops it, and failures are
  reported instead of leaving the extension looking active.

## Desktop widgets

- **Refresh from the desktop.** Medium and larger widgets have a ↻ button; in
  the small size, the orange clock that marks an old reading is the button.
- **Extra large:** lists and meters in two columns, up to twelve thumbnails.
- **For widget authors:** `desktop.style`, `desktop.offer: false`, and
  `desktopRole` on nodes. See WIDGET-SPEC and AGENTS.md §8B.

## Performance and reliability

- Script widgets: output limits by size rather than message count, so a burst
  of log lines no longer stops a healthy script; bounded stderr and timers.
- A widget reload no longer throws away refreshes already running for
  widgets that didn't change.
- Memory/disk sampling is shared between widgets, and a slow volume no longer
  holds up the others.
- Thumbnails, remote images, and folder watchers retry and clean up more
  carefully.
