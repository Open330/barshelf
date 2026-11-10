# Bluetooth Battery

Battery levels of your connected Bluetooth devices: AirPods (left, right and
case), Magic Mouse, Magic Keyboard, Magic Trackpad, and other devices that
report a level to macOS. It is a pure workflow widget with a small JXA helper,
so it needs no Deno and no extra tools.

## What it shows

- One row per device with a level meter, lowest first. AirPods show left,
  right and case under the meter; their level is the lower earbud.
- The lowest level in the menu bar, if you add it there.
- A notification when the lowest device drops to the alert level (20% by
  default, set in the widget's settings). It fires once on the way down and
  again only after the level has recovered.

Devices without a battery reading, and devices that are paired but not
connected, are not listed.

## Permissions and refresh

The widget runs `/usr/bin/osascript -l JavaScript ./bluetooth-battery.js`. The
helper runs `system_profiler SPBluetoothDataType -json` and
`ioreg -r -k BatteryPercent -a` directly (no shell), keeps names and levels,
and drops serial numbers. It refreshes when opened, on wake, and every five
minutes (less often while the popup is closed) so the alert can fire.
Clicking the card opens Bluetooth settings.
