# BarShelf 0.7.45

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- The public JSON schemas agree with the widget runtime on storage permissions, System process metrics, literal values, and workflow options. Editors can flag misplaced filter, sort, and limit options before those settings are ignored at runtime.
- CI now validates the gallery registry and all bundled widget and example manifests and workflows against the public schemas.
- Release quality snapshots measure the app and the keyboard helper together. The quality guide now specifies what to verify on real Macs.
- The Keyboard & Window Extension settings compile without the controller initialization warning on Xcode 27.2.
