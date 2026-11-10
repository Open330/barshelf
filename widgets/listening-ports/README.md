# Listening Ports

The TCP ports your processes are listening on, sorted by port: the port, the
process name, its pid, and whether it is reachable only from this Mac
(loopback), on every interface, or on one address.

## What it shows

- One row per process and port; IPv4 and IPv6 listeners on the same port are
  merged. Rows open to the network are tinted so they stand out.
- A search field to filter by port or process name.
- Clicking a row copies `host:port`; **Open** opens `http://host:port`.
- The **Show** setting narrows the list to loopback-only or network-reachable
  listeners.

Without root, `lsof` sees only your own processes, so system daemons running
as other users are not listed.

The widget cannot stop a process. BarShelf's quit action only quits regular
apps (never a server or command-line tool), and a free-form kill command would
let the widget end any process, so it is left out on purpose.

## Permissions and refresh

One fixed `/bin/sh -c` pipeline: `/usr/sbin/lsof -nP +c 0 -iTCP -sTCP:LISTEN -F pcn`
into `/usr/bin/awk`, which turns it into JSON. It refreshes when opened and
every 30 seconds while visible.
