# BarShelf 0.7.21

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- When a widget you allowed first reads Downloads, Documents, the Desktop or another guarded folder, macOS's one-time prompt now says why. It used to show a blank line.

- Settings ▸ Privacy adds a By Capability view: which installed widgets may run which commands, reach which hosts, read which paths, send notifications and so on, with each one's state. Its note now says plainly that a command you allow runs with your access.
- Widgets made from a workflow can now send a notification when one of their values changes: low, back to normal, finished. They notify once when the condition starts, not on every refresh, and stay quiet for a cooldown. A widget needs the notifications permission and background refresh to do it.
