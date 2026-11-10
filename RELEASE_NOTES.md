# BarShelf 0.7.23

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- Bitwarden can reopen with Touch ID. Tick "Reopen with Touch ID for the next 8 hours" when you type the master password: after an idle lock, screen lock or sleep, the card offers Unlock with Touch ID instead of asking for the password again. BarShelf keeps the session sealed to the Secure Enclave, in memory only; a new or removed fingerprint, Lock, quit or 8 hours since the password ends it, and Bitwarden locks fully. Off by default; while it's on, the Bitwarden CLI stays unlocked between Touch ID uses.
