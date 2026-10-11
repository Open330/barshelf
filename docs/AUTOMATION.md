# Keyboard and window extensions

BarShelf can replace the keyboard and window-navigation portion of a
Hammerspoon setup. Open the BarShelf window's **Automation** page, import your configuration,
review the script, and save it. Grant **Accessibility** access, quit Hammerspoon,
and enable the extension. An enabled extension starts with BarShelf; turning it
off immediately unregisters its shortcuts and keyboard event tap.

No additional runtime is required. Extensions use macOS
[JavaScriptCore](https://developer.apple.com/documentation/javascriptcore),
with native Carbon shortcuts, Quartz keyboard remapping, and Accessibility
window actions. These are app extensions, separate from widget scripts and
widget permissions. Use the regular, non-sandboxed BarShelf distribution for
system-wide keyboard and window control.

## Importing existing settings

**Import Settings → Hammerspoon** reads `~/.hammerspoon/init.lua`.
**Import Settings → Karabiner-Elements** reads
`~/.config/karabiner/karabiner.json` (or `$XDG_CONFIG_HOME/karabiner/karabiner.json`).
**Choose File…** accepts another `.lua` profile, Karabiner `.json`, or a `.js` extension.
Import creates an editor draft; it does not execute window actions, enable the
extension, overwrite the original file, or stop Hammerspoon.

The Lua importer supports the navigation profile composed of:

- `INTERNAL_TYPES` and `MAP` tables for Fn + letter → arrow mappings;
- `safeBind` callbacks calling `moveMouseToScreen`, `moveWindowToScreen`, or
  `rotateWindowFocus`;
- the associated Fn taps/watchdog, screen helpers, and spatial window-cycle
  helper from the supported profile in `HammerspoonImporter.referenceSource`.

Modifier lists, shortcut keys, screen numbers, keyboard types, and arrow
mappings can differ from the example. Comments, whitespace, and simple quote
style changes are accepted. The importer checks the remaining Lua code against
the supported helper implementations. Extra APIs, changed helper behavior,
Spoons, or other arbitrary Lua code cause an error **before anything is
imported**. This is a profile migration tool, not a general Lua interpreter or
transpiler. Custom behavior can be written in JavaScript using the API below.
Lua startup log messages and diagnostic binding labels are replaced by the
host's status messages; the watchdog is implemented natively.

Imported settings preserve the configured keyboard types. Type `91` is the
identifier in the current internal-keyboard profile, not a universal hardware
detector. Physical letter keys work across English and Korean input sources;
`ㅑ/ㅓ/ㅏ/ㅣ` aliases resolve to the same keys as `i/j/k/l`.

### Karabiner-Elements

Import accepts a full configuration (the selected profile), a complex-modifications
rules file, or one exported rule. It converts global `simple_modifications` and
`basic` key-to-key manipulators to native `barshelf.remapKeys` rules. Letters,
digits, arrows, Escape, Tab, Return, Space, deletion and navigation keys are
supported. Modifier matching accepts `command`, `control`, `option`, `shift`,
`fn`, and `caps_lock`; optional `any` preserves additional modifiers. Mandatory
modifiers are removed from output, matching Karabiner semantics.

Rules apply to **all keyboards**. Device/app/input-source conditions, left/right
modifier distinctions, modifier-key outputs (including Hyper), function/media
keys, key sequences, shell actions, variables, tap/hold actions, output modifiers,
and chained mappings are not supported. Such behavior rejects the entire import
with an error identifying its location. Nonempty device settings, function-key
tables and custom parameters in a selected full profile also reject import;
export a supported rules file separately to migrate only those rules.

Import produces an editor draft and **replaces**, rather than merges with, the
saved extension when applied. Disable the matching Karabiner rules before enabling
the replacement. The importer never alters the original tool or configuration.
Other tool converters can be added through `AutomationImporter`; their native
export formats are not yet supported.

## JavaScript API

```javascript
barshelf.remapFn({
  keyboardTypes: [91],
  keys: {i: "up", j: "left", k: "down", l: "right"}
});

hs.hotkey.bind(["alt", "shift"], "i", () => moveMouseToScreen(2));
hs.hotkey.bind(["alt", "shift"], "u", () => moveMouseToScreen(1));
hs.hotkey.bind(["ctrl", "alt", "shift"], "i", () => moveWindowToScreen(2));
hs.hotkey.bind(["ctrl", "alt", "shift"], "u", () => moveWindowToScreen(1));
hs.hotkey.bind(["alt", "shift"], "j", () => rotateWindowFocus("backward"));
hs.hotkey.bind(["alt", "shift"], "k", () => rotateWindowFocus("forward"));
```

| API | Behavior |
| --- | --- |
| `barshelf.bind(modifiers, key, callback)` | Register a global shortcut. `hs.hotkey.bind` is an alias. Up to 64 registrations; duplicate combinations are rejected. |
| `barshelf.remapFn({keyboardTypes, keys})` | Declare one set of physical Fn mappings. Supports letter keys → `up`, `down`, `left`, `right`. Other modifiers and key repeat are retained. |
| `barshelf.remapKeys(rules)` | Up to 128 ordered physical key-to-key rules on all keyboards. Each rule has `from`, `to`, and optional `mandatory`/`optional` modifier arrays. Use either this API or `remapFn` in one extension. |
| `barshelf.moveMouseToScreen(index)` | Move the pointer to the screen center and focus its first titled window in front-to-back order. |
| `barshelf.moveWindowToScreen(index)` | Move the focused window, preserving proportions within usable screen bounds. |
| `barshelf.rotateWindowFocus(direction)` | Cycle titled visible windows on the focused window's screen, ordered top-to-bottom then left-to-right; center the pointer in the new window. `direction` is `"forward"` or `"backward"`. |
| `barshelf.log(message)` | Display a callback diagnostic in extension settings. |

The three window-action functions also have global aliases with the same names,
so converted callbacks remain close to their Lua equivalents. Modifiers accept
`cmd/command`, `ctrl/control`, `alt/opt/option`, and `shift`. Shortcut keys use
BarShelf's existing key grammar: letters, digits, space, return, and tab.

For example, a Karabiner-style Fn mapping with Shift selection preserved:

```javascript
barshelf.remapKeys([
  {from: "i", to: "up_arrow", mandatory: ["fn"], optional: ["any"]}
]);
```

Rules run in order; the first match wins. Mandatory modifiers are removed from
output while optional modifiers remain. Held-key repeat and key-up retain the
original target even if modifiers are released first. Modifier keys themselves
cannot be remapped by this API.

Register shortcuts/remaps at the top level. Invoke window actions and logging
inside callbacks. JavaScript closures retain state until reload. There is no
Node.js, browser DOM, `require`, shell execution, network API, or general `hs`
module system. Import/save evaluates trusted JavaScript to collect registrations;
like other in-process scripting, unbounded loops must be avoided.

## Permissions, displays, and recovery

Accessibility access is required to enable the extension. The settings button
opens the macOS permission pane. If keyboard event tap creation fails, BarShelf
reports it; follow any Input Monitoring request from macOS and restart the app.
Permission cannot be granted by an extension itself.

Screen numbers are **1-based**, primary first. Settings lists the current screen
names and display IDs. Numbers can change after connecting displays; check the
list when migrating. A missing screen or absent focused window is a no-op.
Fullscreen windows must leave fullscreen before being moved. Apps that reject
Accessibility movement/resizing report an error in extension settings.

The host uses public AX window attributes and Quartz on-screen bounds to match
visible windows without requesting screen recording. Unusual apps whose AX
bounds differ from their Quartz bounds may be omitted from focus cycling.

Fn remapping runs natively without executing JavaScript on the keyboard event
tap. Key-up still reaches the remapped arrow when Fn is released first. The tap
is re-enabled after timeout, and a 30-second watchdog plus wake notifications
recover disabled monitoring. Disable/reload cleans up held arrows, event taps,
shortcut registrations, and observers.

Save & Reload validates a candidate first. Registration or persistence failure
restores the previous extension where possible, and reports any restoration
failure. A conflicting shortcut never appears as successfully enabled.
The existing popup shortcut uses a separate event signature.

Source and enabled state are written atomically to
`~/Library/Application Support/barshelf/automation.json` (the same app-support
root used by the host). **Export…** writes the editor draft to a `.js` file.

## Verification

```sh
swift test --filter 'AutomationTests|KarabinerImporterTests|HotkeySupportTests'
BARSHELF_IMPORT_LUA="$HOME/.hammerspoon/init.lua" swift test --filter AutomationTests.testActualHammerspoonFileWhenRequested
BARSHELF_SHOT_DIR=/tmp swift test --filter AutomationTests.testRenderExtensionSettingsWhenRequested
```

After granting Accessibility on a signed build, verify on the actual hardware:
Fn I/J/K/L in English and Korean, key repeat, Shift+Fn selection, releasing Fn
before the letter, external-keyboard exclusion, both monitor moves, window-cycle
wraparound, sleep/wake recovery, and disabling the extension. Automated tests
cover conversion, JavaScript callbacks/errors, remap state, geometry, and
persistence; they do not grant TCC permission or simulate these hardware checks.
