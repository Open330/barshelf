# Stock

A live quote for any ticker from the Yahoo Finance chart API: a large price
and the change since the previous close.

## What it shows

- The ticker symbol and the currency it trades in.
- The latest market price, with thousands separators.
- The change against the previous close and its percentage, with ▲ in green or
  ▼ in red; the menu bar item is tinted the same way.
- Its own message when the ticker is unknown or you are offline, never an
  empty price.

## Settings

| Setting | Default | Effect |
|---|---|---|
| Ticker | `AAPL` | Any symbol Yahoo Finance knows, such as `MSFT` or `005930.KS`. |

## Permissions and refresh

The only permission is HTTPS access to `query1.finance.yahoo.com`. The request
sends a browser User-Agent header, which the API requires; the widget is also
BarShelf's example of an HTTP source with custom headers. It refreshes every
five minutes while the popover is visible and when your Mac wakes. Clicking it opens the quote page on
Yahoo Finance. Prices can be delayed; do not trade on them.
