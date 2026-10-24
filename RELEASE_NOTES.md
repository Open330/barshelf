# BarShelf 0.7.6

> Unreleased. Requires macOS 14+ on Apple Silicon.

BarShelf 0.7.6 fixes what live checks of 0.7.5 turned up.

## Changes

- **Desktop widgets stay current after an update.** macOS kept the widget
  extension from before an update running until the Mac restarted, so
  desktop widgets could show readings from weeks ago while BarShelf had fresh
  ones. BarShelf now restarts a leftover extension when it launches.
- **Search finds widgets by any of their names.** A widget can be found by
  its name in any language it carries (시스템 finds System while BarShelf is
  shown in English), and a reading shown twice is listed once.
- **"1 widget", not "1 widgets"**, in the gallery and in VoiceOver page labels.
