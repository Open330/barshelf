# Exchange

The US dollar to Korean won exchange rate as one large figure, from the free
[open.er-api.com](https://open.er-api.com) API. No API key is needed.

## What it shows

- The pair, "USD → KRW".
- The rate as a large won amount per dollar.

The widget is also a compact example of BarShelf's HTTP source: one request,
one value pulled out of the JSON, and a native card, with no code. To follow a
different pair, copy the widget and change the currency in the workflow's URL
and expression.

## Permissions and refresh

The only permission is HTTPS access to `open.er-api.com`. The widget refreshes
when the popover opens if the last rate is more than an hour old, and every
hour while it is visible. Clicking it opens a currency converter in your
browser.
