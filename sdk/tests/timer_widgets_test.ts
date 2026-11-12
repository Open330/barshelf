// Break Reminder and Focus Timer: what the ring and the menu bar say, and how
// they behave around sleep, snoozes, work hours and a new day.
import { context, fireTimer, host, sendAction, strings } from "barshelf";
import breakReminder from "../../widgets/break-reminder/index.ts";
import focusTimer from "../../widgets/focus-timer/index.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message = ""): void {
  assert(
    JSON.stringify(actual) === JSON.stringify(expected),
    `${message} expected ${JSON.stringify(expected)}, got ${
      JSON.stringify(actual)
    }`,
  );
}

function shown(): string[] {
  return strings(host.lastRender.root);
}

/** 10:00 local time, inside default work hours. */
const NOW = new Date(2026, 9, 24, 10, 0, 0).getTime();
const MIN = 60_000;

function load(now: number, settings: Record<string, unknown> = {}) {
  return context({
    widgetId: "test",
    reason: "open" as const,
    now,
    locale: "en-US",
    appearance: "light" as const,
    settings,
  });
}

// MARK: Break Reminder

Deno.test("Break Reminder's ring shows minutes, not raw seconds", async () => {
  host.reset();
  await breakReminder.handlers.load!(load(NOW));
  const texts = shown();
  assert(texts.includes("50m"), `no minutes in ${JSON.stringify(texts)}`);
  assert(!texts.includes("3000"), "raw seconds shown");
  const json = JSON.stringify(host.lastRender.root);
  assert(
    !json.includes("remainingSeconds"),
    "the host's seconds label is still used",
  );
  assertEquals(host.lastRender.options.status?.label, "50m");
});

Deno.test("Break Reminder after a long sleep starts over without a notification", async () => {
  host.reset();
  await breakReminder.handlers.load!(load(NOW));
  // Three hours later: the reminder could not have fired on time.
  await breakReminder.handlers.load!(load(NOW + 180 * MIN));
  assertEquals(host.notifications.length, 0, "notified after being away");
  assertEquals(host.lastRender.options.status?.label, "50m");
  assert(!shown().includes("Break time"), "shows as due after being away");

  // The same after a late timer.
  host.reset();
  await breakReminder.handlers.load!(load(NOW));
  await fireTimer(breakReminder.handlers, "break-due", NOW + 200 * MIN);
  assertEquals(host.notifications.length, 0, "late timer notified");
});

Deno.test("Break Reminder still notifies when the reminder is on time", async () => {
  host.reset();
  await breakReminder.handlers.load!(load(NOW, { snoozeMinutes: 10 }));
  await fireTimer(breakReminder.handlers, "break-due", NOW + 50 * MIN + 5_000);
  assertEquals(host.notifications.length, 1);
  assertEquals(host.notifications[0].title, "Time for a break");
  assert(
    shown().includes("Snooze 10 min"),
    `no snooze setting in ${JSON.stringify(shown())}`,
  );
  await sendAction(breakReminder.handlers, "snooze", NOW + 51 * MIN);
  assertEquals(host.lastRender.options.status?.label, "10m");
});

Deno.test("Break Reminder keeps quiet outside work hours", async () => {
  host.reset();
  const evening = new Date(2026, 9, 24, 20, 0, 0).getTime();
  const settings = { workHoursOnly: true, workStart: 9, workEnd: 18 };
  await breakReminder.handlers.load!(load(evening, settings));
  await fireTimer(
    breakReminder.handlers,
    "break-due",
    evening + 50 * MIN + 5_000,
  );
  assertEquals(host.notifications.length, 0, "notified outside work hours");
  assert(
    shown().some((text) => text.startsWith("Quiet outside 9:00")),
    `no quiet note in ${JSON.stringify(shown())}`,
  );
  // Back to the defaults for the other tests in this process.
  await breakReminder.handlers.load!(load(NOW));
});

// MARK: Focus Timer

Deno.test("Focus Timer shows the time left in minutes, in the ring and the menu bar", async () => {
  host.reset();
  await focusTimer.handlers.load!(load(NOW));
  assertEquals(
    host.lastRender.options.status?.label,
    "",
    "idle keeps just the icon",
  );
  await sendAction(focusTimer.handlers, "start", NOW);
  assertEquals(host.lastRender.options.status?.label, "25m");
  assert(!shown().includes("1500"), "raw seconds shown");
  await fireTimer(focusTimer.handlers, "focus-tick", NOW + 13 * MIN + 1_000);
  assertEquals(host.lastRender.options.status?.label, "12m");
  await sendAction(focusTimer.handlers, "pause", NOW + 14 * MIN);
  assertEquals(host.lastRender.options.status?.label, "Paused");
});

Deno.test("Focus Timer counts completed sessions per day", async () => {
  host.reset();
  await focusTimer.handlers.load!(load(NOW));
  await sendAction(focusTimer.handlers, "start", NOW);
  await fireTimer(focusTimer.handlers, "focus-deadline", NOW + 26 * MIN);
  assert(shown().includes("1 completed"), JSON.stringify(shown()));
  await focusTimer.handlers.load!(load(NOW + 24 * 60 * MIN));
  assert(
    shown().includes("0 completed"),
    `a new day kept the count: ${JSON.stringify(shown())}`,
  );
});
