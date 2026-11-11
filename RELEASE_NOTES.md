# BarShelf 0.7.25

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Bitwarden shows the vault right after you unlock it. A refresh you ask for while a widget is already refreshing now runs once more afterwards instead of being dropped, which left the card locked until the next refresh. The card also says Unlocking… while the master password is checked (Bitwarden 0.3.2).
- Vault unlocks, listings and locks are recorded in the audit log with their duration, never with a secret.

- Settings pages have a header: the page's icon, name and what it is for, and the figures that matter at a glance (Privacy: allowed, waiting, sensitive access; Advanced: working, failing; Menu Bar, Dock and Shortcuts their own). Content keeps a readable width in wide windows, and every section title has the same style.
- Privacy puts widgets waiting for you first, shows each permission as a chip (sensitive ones in the Privacy colour), and switches between By Widget and By Capability, which now lists only access in effect. General shows the menu bar icons as you would see them. Updates leads with the version and what the last check found. Shortcuts shows keys as keycaps.
