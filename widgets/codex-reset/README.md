# Codex Reset

An unofficial forecast of whether OpenAI Codex usage limits will reset in the
next 48 hours, from the public feed at
[willcodexquotareset.com](https://www.willcodexquotareset.com/). It is not
affiliated with OpenAI; treat the number as a community estimate, not a promise.

## What it shows

- A 0–100 chance of a reset within the forecast window, as a large number and
  a meter, tinted when it reaches your alert threshold.
- How long ago the last reset was ("3 days ago"), and whether alerts are on.

The chance can sit in the menu bar as "Codex 16%".

## Settings

| Setting | Default | Effect |
|---|---|---|
| Notify when a reset looks likely | On | Sends a notification when the chance rises to the threshold. |
| Notify at this chance (%) | 70 | The threshold. |

## Permissions and refresh

HTTPS access to `www.willcodexquotareset.com`, and notifications for the alert.
The feed re-derives its forecast about every 30 minutes, so the widget
refreshes on the same cadence (less often while the popover is closed), plus
when the popover opens and when your Mac wakes. Clicking it opens the site.
