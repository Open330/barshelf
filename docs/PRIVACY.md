# BarShelf Privacy Policy

Effective date: July 8, 2026

BarShelf is a macOS menu bar utility for running local widgets. BarShelf does not include first-party analytics, advertising SDKs, or tracking code.

## Data Stored Locally

BarShelf stores widget manifests, preferences, refresh state, cached registry data, and logs on your Mac. If a widget requests secret storage and you approve it, BarShelf stores that widget secret in the macOS Keychain.

## Widget Permissions

Widgets can request permissions such as command execution, file access, network access, environment variables, notifications, and Keychain access. BarShelf shows permission gates for widget capabilities, but third-party widgets are responsible for what they do after you approve them.

## Network Access

BarShelf checks the official GitHub Releases feed for updates and may connect to the project widget registry or widget install URLs that you choose. Individual widgets may also make network requests only when their manifest declares the destination and you approve that permission.

BarShelf does not send analytics or a persistent advertising identifier with update or registry requests.

## Contact

For privacy or support questions, open an issue at:

https://github.com/Open330/barshelf/issues
