# BarShelf 0.4.1

> Unreleased. Requires macOS 14+ on Apple Silicon.

## Changes

- **A new BarShelf window.** The sidebar now has your workspace (Shelf, Menu
  Bar, Gallery, Create, Automation) and, below it, Settings split into
  General, Shortcuts, Updates, Privacy, and Advanced — one page each, no tabs
  inside tabs.
- **Menu Bar page.** Choose which widgets show a value in the menu bar, put
  them next to the BarShelf icon or on their own, reorder them, and set the
  style for all of them in one place.
- **Record your shortcut.** Click the shortcut field and press the keys,
  instead of typing "cmd+shift+b".
- **Updates you control.** Turn off the automatic check, see when BarShelf
  last checked, and skip a version you don't want to be reminded about.
- **Privacy page.** See what each widget is allowed to do in plain words, and
  allow, deny, or revoke it there.
- Resetting the layout now asks first, and also restores the order of pages.
- **The Shelf.** Your pages side by side, each widget where it sits in the
  popup. Drag a widget to reorder it or onto another page to move it, and
  select it to change its settings in the inspector next to it.
- **Settings apply as you change them.** No more Save button; ⌘Z undoes a
  change. A widget's settings are in four parts: General (page, size, and
  its own options), Look, Menu Bar, and About (version, permissions, and
  Remove).
- **A better Gallery.** Search with a result count, filter by type
  (Command, Workflow, Script) and category, and open any widget to see a
  large preview, its full description, what it's allowed to do in plain
  words, which tools it needs (with the install command), and Install,
  Update, Open, or Remove. Install from URL and Create Widget sit right above
  the grid.
- The Gallery no longer uses CPU in the background while its window is
  minimized or covered (#1).
- **No more double titles.** Bundled widgets no longer repeat their own name
  and icon under the card's header ("Battery" then "Battery" again), so the
  card goes straight to the reading. Your installed copies update on launch.
