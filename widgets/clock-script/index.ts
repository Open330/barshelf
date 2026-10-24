import {
  barshelf,
  ui,
  type WidgetLoadContext,
  type WidgetTimerContext,
} from "barshelf";

const TIMER_ID = "clock-minute";
const COUNT_KEY = "click-count";

/** The app's language at the last load (actions and timers carry none). */
let language: "en" | "ko" = "en";

/** Fixed text: Korean when the app is in Korean, else the English. */
function t(english: string, korean: string): string {
  return language === "ko" ? korean : english;
}

function formatTime(date: Date): string {
  return new Intl.DateTimeFormat(language === "ko" ? "ko-KR" : undefined, {
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
  const value = await barshelf.storage.get<number>(COUNT_KEY);
  return typeof value === "number" && Number.isFinite(value) ? value : 0;
}

async function renderClock(nowMs: number): Promise<void> {
  const now = new Date(nowMs);
  const count = await readCount();
  const seconds = now.getSeconds();
  const timeText = formatTime(now);

  await barshelf.render(
    ui.vstack([
      ui.hstack([
        ui.text(timeText, {
          id: "clock-time",
          role: "code",
          monospacedDigit: true,
          accessibility: {
            label: t("Current time", "현재 시간"),
            value: timeText,
          },
        }),
        ui.spacer(),
        ui.badge("TS", { id: "clock-badge", tone: "neutral" }),
      ], { id: "clock-header", spacing: 6 }),
      ui.progress(seconds / 60, {
        id: "clock-progress",
        label: t("Minute", "분"),
        tint: seconds >= 50 ? "warning" : "accent",
      }),
      ui.button(
        t("Count click", "클릭 세기"),
        ui.action.event("increment", { previousCount: count }),
        {
          id: "clock-increment",
          icon: "plus.circle",
          tooltip: t(
            "Increment the persistent storage counter",
            "저장된 카운터를 1 늘립니다",
          ),
        },
      ),
      ui.text(t(`Clicks: ${count}`, `클릭 ${count}회`), {
        id: "clock-count",
        role: "caption",
        monospacedDigit: true,
      }),
    ], { id: "clock-root", spacing: 8 }),
    {
      status: { label: timeText, tooltip: t("Script Clock", "스크립트 시계") },
      nextRefreshAt: nextMinuteStart(now),
      cacheTtlMs: 60_000,
    },
  );
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  language = typeof ctx.locale === "string" && /^ko(?:[-_]|$)/i.test(ctx.locale)
    ? "ko"
    : "en";
  await barshelf.timer.every(TIMER_ID, 60_000);
  await renderClock(ctx.now);
}

async function timer(ctx: WidgetTimerContext): Promise<void> {
  if (ctx.id === TIMER_ID) {
    await renderClock(ctx.now);
  }
}

export default barshelf.widget({
  load,

  async action(ctx) {
    if (ctx.actionId !== "increment") {
      return;
    }

    const count = await readCount();
    await barshelf.storage.set(COUNT_KEY, count + 1);
    await renderClock(ctx.now);
  },

  timer,
});
