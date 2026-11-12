# Exchange

An exchange rate as one large figure, from the free
[open.er-api.com](https://open.er-api.com) API. No API key is needed.

## What it shows

- The pair, for example "USD → KRW".
- The rate with thousands separators and the target currency's symbol, for
  example "₩1,337.42", per one unit of the base currency.
- Its own message when you are offline or the pair has no rate.

## Settings

| Setting | Default | Effect |
|---|---|---|
| From currency | USD | The base currency. |
| To currency | KRW | The currency the rate is given in. |

Twelve major currencies are offered. The rate can sit in the menu bar.

## Permissions and refresh

The only permission is HTTPS access to `open.er-api.com`. The service updates
its rates daily; the widget refreshes every hour while visible and when your
Mac wakes. Clicking it opens a currency converter in your browser.
