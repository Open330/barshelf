# Sensors

Hardware temperatures, fans, and power draw, read straight from the Mac — the
kind of readings a system monitor like [Stats](https://github.com/exelban/stats)
shows, as a BarShelf widget.

- CPU / GPU / battery temperature in °C, with a health-colored CPU meter
- every fan the Mac reports, by name and RPM
- system total power draw in watts, when the Mac publishes it
- a live CPU temperature in the menu bar

## Settings

| Setting | Choices | Effect |
| --- | --- | --- |
| **Menu bar shows** | CPU / GPU / Battery / Peak | Which reading the menu bar label carries. The card always shows all of them. |
| **Temperature unit** | Celsius / Fahrenheit | Applies to the card *and* the menu bar. Fahrenheit labels say `°F`, so `123°F` is never read as a Celsius figure. |

The health colouring stays calibrated in Celsius whichever unit you pick — the
thresholds are a property of the hardware, not of how you prefer to read it.

## Setup

Nothing to configure. Install it and it reads the machine it runs on.

Installing it does not put anything on the menu bar. To show the temperature
there, right-click the BarShelf icon and tick this widget under **Menu Bar ▸**
(or use the widget's **Settings → Menu Bar**).

Once it is on, it shares one status item with the BarShelf mark
(`✦ 21% · 46°`) or takes an item of its own, and keeps refreshing on its
3-second interval even while the popup is closed. Turning on **Pause When
Closed** in app settings freezes it, and the menu bar dims the frozen value
rather than passing it off as live.

## Permissions

`permissions.system: ["sensors"]` — nothing else. No commands are run, no files
are read, and nothing leaves the machine. The readings come from `AppleSMC`
over IOKit, with the Apple Silicon HID sensor plane as a fallback.

## What your Mac actually reports

Every reading is optional, and the widget shows what it has rather than filling
gaps with zeros:

| You see | It means |
| --- | --- |
| `—` next to GPU or Battery | this Mac publishes no such sensor |
| `Fans — none` | a fanless Mac (MacBook Air, most iPads-turned-Macs) |
| no watts in the header | no `PSTR` power key on this model |
| "No hardware sensors are readable on this Mac" | no sensor backend answered at all |

That last case is expected in two places: a **sandboxed build** (the Mac App
Store variant has no SMC access) and a **virtual machine**. The widget says so
instead of showing a plausible-looking 0 °C.

Sensor names differ per chip generation and Apple publishes no key dictionary,
so the widget summarizes by key prefix — `Tp*`/`Te*` are CPU core dies, `Tg*`
the GPU, `TB*` the battery. `peak` is the hottest of those summarized sensors.

## Troubleshooting

**Temperatures look lower than another monitor's.** The CPU figure is the mean
of the core die sensors, not the hottest one. Compare against `peak` in the
tooltip.

**The menu bar value is greyed out.** The last successful reading is older than
the widget's cadence allows — check whether **Pause When Closed** is on, or
whether the widget shows an error in the popup.
