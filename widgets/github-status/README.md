# GitHub Status

GitHub's own service status, from the public status page API, so you can tell
at a glance whether a failing push or a slow Actions run is on your side or
GitHub's.

## What it shows

- The status description, for example "All Systems Operational", with the
  overall level as a badge: OK in green, Minor in orange, Major or Critical in
  red.
- Every unresolved incident, with its stage and when it was last updated; a row
  opens the incident page.
- In the menu bar, "GitHub OK", tinted only while there is an incident.

## Settings

| Setting | Default | Effect |
|---|---|---|
| Notify when GitHub has an incident | Off | Sends a notification when the status leaves OK. |

## Permissions and refresh

HTTPS access to `www.githubstatus.com` (no GitHub account or token), and
notifications for the opt-in alert. The widget refreshes when the popover
opens, every 15 minutes while it is visible (less often while it is closed),
and when your Mac wakes. Clicking the header opens githubstatus.com.
