import { mb, ui, type WidgetLoadContext, type WidgetTimerContext } from "barshelf";

const TIMER_ID = "clock-minute";
const COUNT_KEY = "click-count";

function formatTime(date: Date): string {
  return new Intl.DateTimeFormat(undefined, {
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
  }).format(date);
}

function nextMinuteStart(date: Date): number {
  const ms = date.getTime();
  return Math.floor(ms / 60_000) * 60_000 + 60_000;
}

async function readCount(): Promise<number> {
  const value = await mb.storage.get<number>(COUNT_KEY);
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

async function renderClock(nowMs: number): Promise<void> {
  const now = new Date(nowMs);
  const count = await readCount();
  const seconds = now.getSeconds();
  const timeText = formatTime(now);

  await mb.render(
    ui.vstack([
      ui.hstack([
        ui.image("clock", { id: "clock-icon", size: 16, tint: "accent" }),
        ui.text("Script Clock", { id: "clock-title", role: "title" }),
        ui.spacer(),
        ui.badge("TS", { id: "clock-badge", tone: "neutral" }),
      ], { id: "clock-header", spacing: 6 }),
      ui.text(timeText, {
        id: "clock-time",
        role: "code",
        monospacedDigit: true,
        accessibility: { label: "Current time", value: timeText },
      }),
      ui.progress(seconds / 60, {
        id: "clock-progress",
        label: "Minute",
        tint: seconds >= 50 ? "warning" : "accent",
      }),
      ui.button("Count click", ui.action.event("increment", { previousCount: count }), {
        id: "clock-increment",
        icon: "plus.circle",
        tooltip: "Increment the persistent storage counter",
      }),
      ui.text(`Clicks: ${count}`, {
        id: "clock-count",
        role: "caption",
        monospacedDigit: true,
      }),
    ], { id: "clock-root", spacing: 8 }),
    {
      status: { label: timeText, tooltip: "Script Clock" },
      nextRefreshAt: nextMinuteStart(now),
      cacheTtlMs: 60_000,
    },
  );
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  await mb.timer.every(TIMER_ID, 60_000);
  await renderClock(ctx.now);
}

async function timer(ctx: WidgetTimerContext): Promise<void> {
  if (ctx.id === TIMER_ID) {
    await renderClock(ctx.now);
  }
}

export default mb.widget({
  load,

  async action(ctx) {
    if (ctx.actionId !== "increment") {
      return;
    }

    const count = await readCount();
    await mb.storage.set(COUNT_KEY, count + 1);
    await renderClock(ctx.now);
  },

  timer,
});
