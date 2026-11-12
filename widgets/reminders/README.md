# Reminders

How many reminders you still have open, as one large number, so you can see
whether the list is growing without opening the app.

## What it shows

- The count of incomplete reminders across all your lists, also available in
  the menu bar.
- When Reminders cannot be read, says why instead of showing 0: a button to
  the Automation settings when macOS refused access, or a retry when Reminders
  was too slow to answer.

## Permissions and refresh

The widget runs one fixed `/bin/sh -c` command that asks Reminders for the
count through AppleScript. The first time it runs, macOS asks whether BarShelf
may control Reminders; approve it once in the Automation prompt. You can change
that later in System Settings › Privacy & Security › Automation.

The widget reads only the count, never reminder titles or notes. It refreshes
every five minutes while visible and when your Mac wakes. Clicking it opens
Reminders.
