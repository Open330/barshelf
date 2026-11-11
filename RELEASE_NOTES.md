# BarShelf 0.7.27

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- BarShelf's Bitwarden no longer locks the `bw` you use in Terminal. BarShelf keeps its own Bitwarden sign-in, separate from Terminal: before, unlocking or auto-locking the vault in BarShelf ended your terminal session. The first time, the card asks you to sign in once (server and email filled in; two-step codes from an authenticator app, email or YubiKey are supported), and every unlock syncs BarShelf's copy of the vault (Bitwarden 0.4.0).
