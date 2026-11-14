# BarShelf 0.7.38

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- The red dot on the BarShelf icon now says why it is there. Point at the icon to see each widget with a problem and what is wrong ("Recent Files: The folder doesn't exist."), along with any permission request, update, Dock or keyboard issue; VoiceOver reads the same. When the widget with the problem is on another page, the popup shows it in one line with a button that takes you there.
- Keep Awake no longer draws its own "!" in the menu bar when PowerDisplayGuard isn't answering. The item shows a warning sign and the problem goes to the red dot like any other, so one problem is reported once. It also waits 45 seconds instead of 15 before deciding the guard has stopped answering. Widgets can do the same with the new `status.problem` field.
