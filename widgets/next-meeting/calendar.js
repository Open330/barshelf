/*
 * Queried through /usr/bin/osascript by index.ts. Keep this file free of
 * BarShelf protocol output: stdout must contain exactly one JSON document.
 */

function stringProperty(object, property) {
  try {
    const value = object[property]();
    return value == null ? "" : String(value);
  } catch (_) {
    return "";
  }
}

function booleanProperty(object, property) {
  try {
    return Boolean(object[property]());
  } catch (_) {
    return false;
  }
}

function firstMeetingURL(event) {
  const directURL = stringProperty(event, "url");
  const candidates = [
    directURL,
    stringProperty(event, "location"),
    stringProperty(event, "description"),
  ];
  const meetingPattern = /https?:\/\/[^\s<>"']+/gi;
  const preferredHosts =
    /(?:zoom\.us|meet\.google\.com|teams\.microsoft\.com|teams\.live\.com|webex\.com|whereby\.com)/i;
  let directHTTPURL = "";

  for (let i = 0; i < candidates.length; i += 1) {
    const matches = candidates[i].match(meetingPattern) || [];
    for (let j = 0; j < matches.length; j += 1) {
      const cleaned = matches[j].replace(/[),.;]+$/, "");
      if (i === 0 && !directHTTPURL) directHTTPURL = cleaned;
      if (preferredHosts.test(cleaned)) return cleaned;
    }
  }
  // Calendar's dedicated URL field is still useful for providers that are not
  // in the preferred-host list. Arbitrary links from notes/location are not
  // offered as a misleading Join action.
  return directHTTPURL;
}

function run(argv) {
  const requestedDays = Number(argv[0]);
  const lookAheadDays = Number.isFinite(requestedDays)
    ? Math.min(30, Math.max(1, Math.floor(requestedDays)))
    : 7;
  const includeAllDay = String(argv[1]).toLowerCase() === "true";
  const now = new Date();
  const horizon = new Date(now.getTime() + lookAheadDays * 24 * 60 * 60 * 1000);
  const Calendar = Application("Calendar");
  const calendars = Calendar.calendars();
  let next = null;

  for (
    let calendarIndex = 0;
    calendarIndex < calendars.length;
    calendarIndex += 1
  ) {
    const calendar = calendars[calendarIndex];
    let events = [];

    try {
      events = calendar.events.whose({
        _and: [
          { startDate: { _greaterThan: now } },
          { startDate: { _lessThan: horizon } },
        ],
      })();
    } catch (_) {
      // Older Calendar versions can reject compound object specifiers. The
      // one-sided fallback is still bounded below and is filtered in JS.
      events = calendar.events.whose({ startDate: { _greaterThan: now } })();
    }

    for (let eventIndex = 0; eventIndex < events.length; eventIndex += 1) {
      const event = events[eventIndex];
      let start;
      let end;
      try {
        start = new Date(event.startDate());
        end = new Date(event.endDate());
      } catch (_) {
        continue;
      }

      if (
        !Number.isFinite(start.getTime()) || start <= now || start > horizon
      ) continue;
      const allDay = booleanProperty(event, "alldayEvent");
      if (allDay && !includeAllDay) continue;
      if (next && start >= next.start) continue;

      next = {
        event: event,
        start: start,
        end: end,
        allDay: allDay,
        calendar: stringProperty(calendar, "name"),
      };
    }
  }

  if (!next) {
    return JSON.stringify({ status: "empty", lookAheadDays: lookAheadDays });
  }

  return JSON.stringify({
    status: "ok",
    title: stringProperty(next.event, "summary") || "Untitled event",
    startMs: next.start.getTime(),
    endMs: next.end.getTime(),
    allDay: next.allDay,
    calendar: next.calendar,
    location: stringProperty(next.event, "location"),
    meetingURL: firstMeetingURL(next.event),
  });
}
