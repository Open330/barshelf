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
- **Everything in the popup, no right-click needed.** The page name at the top
  is now a menu of all your pages. A new **⋯** button holds Edit Shelf (⌘E),
  Add Widget…, Menu Bar, Open BarShelf…, Settings… (⌘,), Check for Updates…, and Quit —
  the same list the menu bar icon shows when you right-click it.
- **Edit Shelf.** Press ⌘E (or ⋯ ▸ Edit Shelf) to rearrange: every card shows
  a drag handle, a Half Width / Full Width switch, and a remove button. Drag a
  card onto a page dot to move it to that page. Press Esc or Done to finish.
- **Card headers are on.** Each card shows its name, when it last updated, and
  a spinner while it refreshes. Widgets that turned the header off keep it off.
- **Errors say what to do.** A failing widget explains the cause in plain
  words — a missing command, a timeout, no connection, an HTTP error, bad data,
  a blocked permission — with a Retry button, the full message under Details,
  and a link to its settings. A widget showing older data marks it "Cached".
- **Clearer permission requests.** New widgets list what they want to do, with
  Allow and Deny buttons. A denied widget shrinks to a small card where you can
  review its permissions again or remove it. A widget stopped after crashing
  offers Restart and Open Logs.
- **A dot on the menu bar icon** when a widget is waiting for your approval or
  has an error.
- **The popup grows to fit.** It is as tall as your widgets need, up to the
  height of your screen.
- A widget's card opened from its own menu bar item closes with Esc, shows
  "Copied" when you copy, and no longer offers page options that do not apply
  there.
- Pin explains its limit: with two cards pinned it reads "Pin (2 max — unpin
  one first)".
- The gear on a card opens that widget's settings in the BarShelf window.
- **A welcome on first launch.** Keep the starter widgets you want, set a
  shortcut and login item, and pick values for the menu bar, then BarShelf
  opens its popup.
- **Updates wait for you.** When a new version is out, the menu bar icon gets
  a dot and the ⋯ menu offers "Update to BarShelf …" — no dialog appears over
  your work at launch.
- macOS asks about notifications when you allow a widget that sends them,
  not the first time one happens to fire.
- The Create preview now looks exactly like the card it makes, and widgets
  made with Create no longer show their name twice.
- Every control in BarShelf has a name for VoiceOver.
- **BarShelf speaks Korean.** Menus, the popup, the BarShelf window, alerts,
  and onboarding appear in Korean when Korean is your Mac's preferred
  language.

