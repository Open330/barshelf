# Developer Inbox

A private GitHub attention dashboard for BarShelf. It combines pull requests
that request your review with unread GitHub notifications and opens each item in
the browser.

## Requirements

1. Install GitHub CLI at a standard Homebrew path (`/opt/homebrew/bin/gh` on
   Apple Silicon or `/usr/local/bin/gh` on Intel).
2. Authenticate once with `gh auth login`.
3. Approve the widget's exact `gh` executable permission.

No token is requested or stored by the widget. It reuses the GitHub CLI's
existing authenticated session and makes no direct network request.

## Privacy and failure behavior

- Command output can contain private repository names, PR titles, and account
  details. Every `gh` command and render is marked sensitive, and the persisted
  cold-start view is a generic redacted placeholder.
- The allowlist contains only version/auth checks, a fixed review-request query,
  and a fixed notifications query. Arbitrary `gh` arguments cannot be run.
- Missing CLI, missing authentication, empty inbox, partial API failure, and
  successful data states each have a dedicated UI instead of surfacing raw
  command errors.
- Refreshes happen on open, every five minutes while visible, and after wake.

Use widget settings to show 3–10 items per section or hide notifications.
