# Internet Quality

Two measurements at two costs:

- **Connection** — every refresh (5 minutes while visible, about 20 minutes in the
  background) pings 1.1.1.1 five times: latency, jitter and packet loss. Almost no
  data, so it can live in the menu bar and notify you when the connection drops
  or turns unstable (turn that off in the widget's settings).
- **Speed** — Apple's built-in `networkQuality`, capped at 10 seconds: download,
  upload and responsiveness (RPM). It runs once a day by default, every 6 hours,
  or only when you press **Test now**. A test moves a few hundred MB on a fast line,
  so pick "Only when I press Test now" on a metered connection.

The last speed result is kept between tests. Needs BarShelf 0.7.22 or later.
