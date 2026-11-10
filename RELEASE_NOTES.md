# BarShelf 0.7.22

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- 17 new widgets in the Gallery. Everyday: World Clock, Countdown (D-day), Air Quality, Crypto, Quick Note, Break Reminder. System: Bluetooth Battery (AirPods, mice, keyboards), Internet Quality, Tailscale. Developer: GitHub Actions, Site Monitor, Listening Ports, Homebrew Updates, Docker, Kubernetes, Hacker News. Security: Bitwarden. The packs now include them, plus a new Infrastructure pack.
- Widget translations now cover copy toasts and alert notifications.
- Internet Quality now watches the connection itself with a light ping every few minutes (latency, jitter, loss; can sit in the menu bar and notify when the connection drops) and runs a short, 10-second speed test once a day, every 6 hours or only when you press Test now.
- Widget authors: workflows can read `widget.requested`, true only on a refresh the user asked for, to keep expensive work for an explicit request.
- Bitwarden can now be unlocked from its card: search your vault and copy a username, password or verification code, cleared from the clipboard after 30 seconds. BarShelf keeps only the session, in memory, and locks after 10 minutes without use, an hour at most, and on screen lock or sleep. The widget never sees a password.
- Widget authors: `permissions.vault` (built-in providers, Bitwarden first) with a `vault.items` source and `vaultUnlock` / `vaultLock` / `vaultCopy` actions.
