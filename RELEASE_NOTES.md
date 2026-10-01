# BarShelf 0.4.0

> Unreleased. Requires macOS 14+ on Apple Silicon.

## New

- **Keyboard and window extensions.** Settings → Extensions runs a
  JavaScript extension with global shortcuts, keyboard remapping, and window
  moves, so a Hammerspoon navigation setup can move into BarShelf. Import your
  `init.lua`, review the generated script, and enable it. See
  [Automation](docs/AUTOMATION.md).
- **Shortcuts that work everywhere.** ⌘, opens Settings, ⌘R refreshes every
  widget, ⌘N creates a widget, ⌘F searches the popup, and ⌘Q quits — from the
  popup and from the BarShelf window, not only while the menu bar icon's menu
  is open. While the BarShelf window is open, these also appear in the
  menu bar.

## Changes

- **Clearer names.** "Panels" are now **pages**, matching the dots under the
  popup. Card sizes say what they do (Strip, Half Width, Full Width, Tall),
  card heights read Auto, Short, Medium, and Tall, and the gallery calls widget
  types Command, Workflow, and Script.
- **Refresh Speed** replaces Refresh Cadence: Faster, Normal, Slower, Slowest,
  with a note on what each does. Your setting carries over.
- Banners, badges, and cards in the BarShelf window share one set of corners
  and colours.

## Requirements

- **BarShelf now needs macOS 14 (Sonoma) or later.** The settings redesign
  that starts with this release builds on controls macOS 13 does not have. On macOS 13, the in-app
  updater from 0.3.13 on says this release needs a newer macOS and keeps your
  current copy; 0.3.12 and earlier install it, see it fail to start, and put
  the previous version back.
