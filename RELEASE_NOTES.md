# BarShelf 0.7.34

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- The app no longer bundles seven widgets that were never in the Gallery: the samples Hello, Script Clock and Visit Counter, and Downloads Watch, Local Time, Top Processes and the script Battery, which a Gallery widget already covers (Downloads, Clock and World Clock, System, Battery). A copy you already installed keeps working; it just no longer updates with the app. They live in the repository's `examples/` folder and install with `barshelf install ./examples/<name>`.
- The recorder that makes the website's videos and stills is no longer inside BarShelf.app.
- Under the hood, the keyboard and window extension, the Dock and the widget builder each have their state and logic in a module of their own, separate from the app's windows. Nothing about how they behave is meant to change.
- The website and README now open with what BarShelf is for: one icon for your whole menu bar, and for the tools that never had one.
