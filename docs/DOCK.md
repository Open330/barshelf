# BarShelf Dock

BarShelf is menu-bar-first; the dock is an option, off by default. Open the
BarShelf window's **Dock** page to turn it on.

## Modes

| Mode | What happens |
| --- | --- |
| **Off** | No BarShelf Dock. Profiles can still switch the Apple Dock's apps (below). |
| **Alongside the Apple Dock** | The BarShelf Dock sits on its edge next to the Apple Dock. On the same edge it sits just above it. |
| **Instead of the Apple Dock** | The Apple Dock is hidden while BarShelf runs. |

Hiding the Apple Dock uses the only method macOS allows: BarShelf turns on its
auto-hide with a very long delay, then restarts the Dock. First it saves your
own `autohide` and `autohide-delay` settings to `dock.json`, and it puts them
back when you switch modes or quit BarShelf. If BarShelf crashes, the next
launch puts them back too. If the Apple Dock ever stays hidden anyway:

```bash
barshelf dock restore-apple-dock
```

With BarShelf running, this asks the app to put the Apple Dock back and leave
"Instead of the Apple Dock"; otherwise it restores the saved settings itself.

macOS has no public way to make other apps' windows stay clear of a dock that
isn't Apple's. Windows can go under the BarShelf Dock, as they do under an
auto-hidden Apple Dock. Turn on **Automatically hide and show the dock** if
that gets in the way. The dock then slides in when the pointer reaches the
screen edge.

## What goes in the dock

- **Apps**: click to open or bring forward. Drop files on an app to open them
  with it. A dot means the app is running. Apps that are open but not in the
  profile come after a divider (optional).
- **Folders**: click for a menu of the folder's contents, with subfolders as
  submenus. A folder can be a coloured tile with a letter or two.
- **Files** and **links**: open on click.
- **Shortcuts**: run on click, through the `shortcuts` tool.
- **Widgets**: any BarShelf widget, live. A dock widget refreshes on its own
  schedule even while the popup is closed, as a menu bar item does. An
  auto-hidden dock stops refreshing until it shows again.
- **Spaces** and **dividers**, and the **Trash** (drop files on it to throw them away).

Drag apps, folders, files, or web links onto the dock to add them. Drag an
item onto another to move it. Right-click any item for its menu, including
**Remove from Dock**.

The Apple Dock's own settings are there too: size, magnification and how
much, which display (the main one, or the one the pointer rests at the edge
of), auto-hide and how long the pointer waits at the edge, opening
animation, and indicators for open apps.

**Classic** looks like the Apple Dock: its icon size by default, icons on
clear Liquid Glass (macOS 26 and later), names on hover, optional
magnification. Widgets keep to icon height there, showing their name and main
reading (or two small bars). **Shelf** is a sturdier bar with names under
icons and widgets as full cards.

## Profiles

Each profile has its own items. It can also carry:

- **An Apple Dock layout.** Arrange the Apple Dock, then click **Save Current
  Apple Dock**. With **Switch the Apple Dock's apps with the profile** on,
  switching profiles rewrites the Apple Dock's pinned apps and folders and
  restarts the Dock for a moment. Open apps and windows aren't affected. The
  layout being replaced goes to `dock-backups/` first (the last ten are kept).
- **A popup page**, which the BarShelf popup turns to.

Ways to switch:

- **⌃⌥1–9** for the first nine profiles (turn on in **Switching**). A number
  another app or an Automation shortcut already uses is marked as taken.
- A **two-finger sideways swipe** on the dock, or **⌘-scroll** over it.
- **BarShelf menu ▸ Dock**, or right-click the dock.
- A link: `barshelf://dock?profile=Work` (name, id, or number; the link
  **Dock ▸ Switching** copies uses the id, so renaming the profile does not
  break it),
  `barshelf://dock?next`, `barshelf://dock?previous`.
- Terminal: `barshelf dock use Work`, `barshelf dock next`, `barshelf dock list`.

### Following a Focus

macOS doesn't tell other apps which Focus is on, so this goes through Shortcuts:

1. Open **Shortcuts ▸ Automation ▸ New Automation ▸ Focus**, pick the Focus,
   and choose **When Turning On** and **Run Immediately**.
2. Add the **Open URLs** action with the profile's link. **Dock ▸ Switching**
   shows it, with a Copy button.
3. To go back when the Focus ends, add a **When Turning Off** automation with
   the other profile's link.

## Files

| Path (under `~/Library/Application Support/barshelf/`) | Contents |
| --- | --- |
| `dock.json` | Mode, look, profiles, and the Apple Dock backup while it is hidden |
| `dock-backups/apple-dock-*.plist` | The Apple Dock layouts replaced by profile switches |

## Not possible (no public API)

Badges on app icons (unread counts), window previews, and minimised windows in
the dock.
