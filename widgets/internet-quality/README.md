# Internet Quality

Download and upload speed and responsiveness, measured by Apple's built-in
`networkQuality` tool.

## What it shows

- Download and upload in Mbps.
- Responsiveness in RPM (round trips per minute under load) with Apple's
  rating: Low below 300, Medium below 1000, High from 1000.
- Idle latency and the interface the test used.
- The download speed in the menu bar, if you add it there.

## Bandwidth

A single test can move hundreds of megabytes, more than a gigabyte on a fast
line. So the widget never polls: it runs when you open it and the last result
is more than six hours old, or when you press **Run test again**. It does not
run on wake or in the background. A test takes about 10 to 20 seconds and is
capped at 30.

## Permissions

It runs exactly `/usr/bin/networkQuality -c -M 30` and nothing else.
