# BarShelf 0.7.42

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- A widget's saved data is no longer wiped when its file cannot be read once. BarShelf used to start that widget empty and then save the empty state over the file. Now the unreadable file is kept beside it (with "corrupt" and the time in its name) and BarShelf tells you. The same goes for the usage counts and for the record of which alerts have fired.
- Switching Dock profiles no longer changes the Apple Dock when its current layout could not be backed up first. Before, the layout was replaced anyway, with nothing to restore it from. The Dock settings now say why nothing changed.
- A Shortcut tile in the Dock that fails now says so, with what the Shortcuts tool reported (a renamed or deleted Shortcut, for example). It used to do nothing.
- `barshelf pack` no longer hangs when `zip` prints a lot of output.
- In Settings ▸ Privacy, VoiceOver reads the Revoke buttons in Korean on a Korean Mac. The label added in 0.7.40 had no translation.
- If the keyboard extension is ever dropped while a remapped key is held down, that key is released. Nothing else about the extension changes: its code is now checked by the compiler for thread safety, like the rest of the app.
