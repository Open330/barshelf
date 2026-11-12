# Weather

The current temperature and conditions for any place, from the free
[Open-Meteo](https://open-meteo.com) API. No API key or account is needed.

## What it shows

- The place name you set.
- The temperature in °C or °F, rounded to a whole degree.
- A condition and matching icon from the WMO weather code: Clear, Partly
  cloudy, Cloudy, Fog, Rain, Snow, Showers, Snow showers or Thunderstorm, with
  night icons after dark.
- Its own message when you are offline, the service does not answer, or the
  latitude/longitude is out of range.

## Settings

| Setting | Default | Effect |
|---|---|---|
| Place name | Seoul | The label on the card. |
| Latitude | 37.57 | Where to read the weather (−90 to 90). |
| Longitude | 126.98 | Where to read the weather (−180 to 180). |
| Temperature unit | Celsius | °C or °F. |

The place name is only a label; the latitude and longitude decide the forecast.
The temperature and a condition icon can sit in the menu bar.

## Permissions and refresh

The only permission is HTTPS access to `api.open-meteo.com`. The widget
refreshes every 15 minutes while visible and when your Mac wakes. Clicking it
opens the Weather app.
