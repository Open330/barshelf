# BarShelf 0.7.25

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Bitwarden shows the vault right after you unlock it. A refresh you ask for while a widget is already refreshing now runs once more afterwards instead of being dropped, which left the card locked until the next refresh. The card also says Unlocking… while the master password is checked (Bitwarden 0.3.2).
- Vault unlocks, listings and locks are recorded in the audit log with their duration, never with a secret.
