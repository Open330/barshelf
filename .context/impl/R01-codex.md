Implemented Task B only.

Changed:
- [scripts/build_app.sh](/Users/jiun/workspace/menubucket/scripts/build_app.sh): release build, `MenuBucket.app` assembly, plist rendering, widget resource copy, ad-hoc codesign.
- [scripts/Info.plist.template](/Users/jiun/workspace/menubucket/scripts/Info.plist.template): LSUIElement app plist template with bundle ID `dev.menubucket.app` and macOS 13.0 minimum.
- [schema/widget-0.1.json](/Users/jiun/workspace/menubucket/schema/widget-0.1.json): draft-07 manifest schema for the M0 subset, with permissive `permissions`/`settings`.
- [README.md](/Users/jiun/workspace/menubucket/README.md): intro, 3-layer architecture, build/app bundle instructions, widget quickstart, roadmap link.

Verified:
- `bash -n scripts/build_app.sh` passed.
- `jq empty schema/widget-0.1.json` passed.
- `plutil -lint scripts/Info.plist.template` passed.

I did not run the full build script, and I did not modify `Package.swift`, `Sources/`, `Tests/`, `widgets/`, or `.context/impl/R01-codex.md`.