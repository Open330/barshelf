# BarShelf 0.7.5

> Unreleased. Requires macOS 14+ on Apple Silicon.

BarShelf 0.7.5 is a quality release, shaped by a review of BarShelf as seven
kinds of user would meet it: a first-time Korean user, an everyday user, a
widget developer, someone moving from Hammerspoon, a keyboard and VoiceOver
user, a privacy- and battery-conscious laptop user, and a multi-display user.

## Changes

- **Taking a permission back stops the widget.** Revoking or denying a
  widget's permissions now stops every copy of it at once: its script, the
  commands it started (including their child processes), its timers and its
  pending requests. Approving brings every copy back.
- **Removing a widget removes its data.** Its saved storage and its Keychain
  secrets go with it. If the Keychain can't be changed, the widget stays
  installed with its data intact and BarShelf says why.
- **Hidden menu bar icons are noticed.** When the menu bar is full or the icon
  sits behind the camera notch, BarShelf opens its window once and says how to
  make room; the Menu Bar and Shelf pages keep showing it until then. Opening
  BarShelf from Finder or Spotlight always brings back its window.
- **Korean throughout.** Onboarding, the gallery (search in Korean finds
  날씨, 배터리…), bundled widgets and messages read in Korean, in one consistent
  tone, and a missing translation now fails the build's tests.
- **Onboarding explains permissions before asking**, with an Allow for each
  starter widget that needs one.
- **Choose how often a shelf widget refreshes**, and see accurate copy about
  what "pause while closed" pauses: hidden widgets and script timers stop,
  menu bar and Dock widgets keep going.
- **Search finds more**: every word, in any order, ignoring case and accents,
  by a widget's name in either language.
- **Keyboard and VoiceOver**: search announces its results, moving cards has
  keyboard controls, toasts are read once, Reduce Motion and Increase Contrast
  are honoured, and Esc in Focus Dock hands the keyboard back.
- **Clearer errors**: a missing Deno, a widget's own permission limits and
  unreadable data each get their own explanation and next step.
- **Safer updates**: the updater refuses a build that is not newer than the
  one running, even if it is genuinely signed.
- **Widget authors**: `barshelf pack` keeps hidden entry files and refuses
  symbolic links; `barshelf validate` rejects runtimes BarShelf can't run;
  widgets can carry `localizations` for their display text.
