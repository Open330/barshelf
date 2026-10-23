# BarShelf Privacy Policy

Effective date: July 8, 2026

BarShelf is a macOS menu bar utility for running local widgets. BarShelf does not include first-party analytics, advertising SDKs, or tracking code.

## Data Stored Locally

BarShelf stores widget manifests, preferences, refresh state, cached registry data, and logs on your Mac. If a widget requests secret storage and you approve it, BarShelf stores that widget secret in the macOS Keychain.

Widget installs and local state are under `~/Library/Application Support/barshelf/`.
Removing a widget stops its managed work and erases that instance's stored values,
widget-owned Keychain secrets, preferences and render cache. Other instances keep
their own data. A cleanup failure is reported and the widget remains installed so
you can retry. Revoking permission stops access; it does not erase previously
stored values. Shared environment credentials are separate from widget-owned
secrets and can still be used by other widgets that you approve.

Widget execution logs and their rotated files under
`~/Library/Logs/BarShelf/widgets/`, and audit history, survive removal for
diagnosis. Removal does not retract data an approved command or widget already
wrote outside BarShelf. Permission withdrawal clears the live reading from the
shelf, Dock and menu bar and withdraws desktop exports; previously stored local
values and render caches remain until removal. They are not displayed again
while permission is withdrawn.

## Widget Permissions

Widgets can request permissions such as command execution, file access, network access, system telemetry (CPU, memory, disk and hardware sensor readings, all read locally and never transmitted by BarShelf), environment variables, notifications, and Keychain access. BarShelf shows permission gates for widget capabilities, but third-party widgets are responsible for what they do after you approve them.

These gates control BarShelf's host APIs. Approved external commands run with your macOS user account; their own file and network activity is not constrained by the widget's host API allowlists. Review the commands as well as the requested capabilities before allowing a widget.

Revoking or denying permission stops running script instances of that package and blocks subsequent host API requests until the current permission set is approved again. A command or request that already completed cannot be undone by revocation.

## Network Access

BarShelf checks the official GitHub Releases feed for updates and, when you ask it to install one, downloads that release's archive from GitHub. It may also connect to the project widget registry or widget install URLs that you choose. Network requests made through BarShelf's host APIs require the widget to declare the destination and receive approval. Approved external commands can also make their own network requests as described above.

BarShelf does not send analytics or a persistent advertising identifier with update or registry requests.

## Contact

For privacy or support questions, open an issue at:

https://github.com/Open330/barshelf/issues
