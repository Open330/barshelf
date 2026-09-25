# GitHub Status

GitHub's own service status, from the public status page API, so you can tell
at a glance whether a failing push or a slow Actions run is on your side or
GitHub's.

## What it shows

- The status page name.
- GitHub's status indicator as a badge.
- The status description, for example "All Systems Operational".

## Permissions and refresh

The only permission is HTTPS access to `www.githubstatus.com`; no GitHub
account or token is involved. The widget refreshes when the popover opens,
every 15 minutes while it is visible, and when your Mac wakes, so a status
change that happened while the lid was closed shows up right away. Clicking it
opens githubstatus.com.

It is also a small example of an HTTP source with a wake trigger, useful as a
starting point for any status-page widget.
