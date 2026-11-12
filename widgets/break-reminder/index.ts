import {
  barshelf,
  ui,
  type UINode,
  type WidgetActionContext,
  type WidgetLoadContext,
  type WidgetTimerContext,
} from "barshelf";

const STATE_KEY = "break-state-v1";
const DUE_TIMER = "break-due";
const TICK_TIMER = "break-tick";
const DEFAULT_MINUTES = 50;
const DEFAULT_SNOOZE_MINUTES = 5;
const TICK_MS = 60_000;

type Status = "running" | "paused";

interface BreakState {
  status: Status;
  /** The interval the user configured, in ms. */
  intervalMs: number;
  /** When the current cycle started (running) — the ring's start. */
  startedAtMs: number;
  /** When the next reminder is due (running only). */
  nextAtMs: number;
  /** Time left when paused. */
  remainingMs: number;
  /** A reminder fired and the break has not been taken yet. */
  due: boolean;
  /** Breaks taken today, and which local day that count belongs to. */
  breaksToday: number;
  day: string;
}

/**
 * The app's language at the last load. Actions and timers carry no locale,
 * so they speak the language the widget was last loaded in.
 */
let language: "en" | "ko" = "en";

function setLanguage(locale: unknown): void {
  language = typeof locale === "string" && /^ko(?:[-_]|$)/i.test(locale)
    ? "ko"
    : "en";
}

function t(english: string, korean: string): string {
  return language === "ko" ? korean : english;
}

/**
 * The settings at the last load. Like the language, actions and timers carry
 * none, so they use what the widget was last loaded with.
 */
interface Config {
  snoozeMs: number;
  /** Remind only between these local hours (start inclusive, end exclusive). */
  workHours: { start: number; end: number } | null;
}

let config: Config = {
  snoozeMs: DEFAULT_SNOOZE_MINUTES * 60_000,
  workHours: null,
};

function integer(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  const n = typeof value === "number" && Number.isFinite(value)
    ? Math.round(value)
    : fallback;
  return Math.min(Math.max(n, min), max);
}

function readConfig(settings: Record<string, unknown>): Config {
  const start = integer(settings.workStart, 9, 0, 23);
  const end = integer(settings.workEnd, 18, 1, 24);
  return {
    snoozeMs: integer(settings.snoozeMinutes, DEFAULT_SNOOZE_MINUTES, 1, 60) *
      60_000,
    workHours: settings.workHoursOnly === true && end > start
      ? { start, end }
      : null,
  };
}

function withinWorkHours(nowMs: number): boolean {
  if (!config.workHours) return true;
  const hour = new Date(nowMs).getHours();
  return hour >= config.workHours.start && hour < config.workHours.end;
}

function dayKey(ms: number): string {
  const d = new Date(ms);
  return `${d.getFullYear()}-${d.getMonth() + 1}-${d.getDate()}`;
}

function configuredInterval(settings: Record<string, unknown>): number {
  const raw = settings.intervalMinutes;
  const minutes = typeof raw === "number" && Number.isFinite(raw)
    ? Math.round(raw)
    : DEFAULT_MINUTES;
  return Math.min(Math.max(minutes, 5), 180) * 60_000;
}

function freshState(intervalMs: number, nowMs: number): BreakState {
  return {
    status: "running",
    intervalMs,
    startedAtMs: nowMs,
    nextAtMs: nowMs + intervalMs,
    remainingMs: intervalMs,
    due: false,
    breaksToday: 0,
    day: dayKey(nowMs),
  };
}

function finite(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

async function readState(
  nowMs: number,
  intervalMs?: number,
): Promise<BreakState> {
  const stored = await barshelf.storage.get<Partial<BreakState>>(STATE_KEY);
  const fallbackInterval = intervalMs ?? DEFAULT_MINUTES * 60_000;
  if (!stored || (stored.status !== "running" && stored.status !== "paused")) {
    return freshState(fallbackInterval, nowMs);
  }
  const interval = Math.max(
    finite(stored.intervalMs, fallbackInterval),
    60_000,
  );
  const state: BreakState = {
    status: stored.status,
    intervalMs: interval,
    startedAtMs: finite(stored.startedAtMs, nowMs),
    nextAtMs: finite(stored.nextAtMs, nowMs + interval),
    remainingMs: Math.min(
      Math.max(finite(stored.remainingMs, interval), 0),
      interval,
    ),
    due: stored.due === true,
    breaksToday: Math.max(Math.floor(finite(stored.breaksToday, 0)), 0),
    day: typeof stored.day === "string" ? stored.day : dayKey(nowMs),
  };
  if (state.day !== dayKey(nowMs)) {
    state.day = dayKey(nowMs);
    state.breaksToday = 0;
  }
  return state;
}

async function saveState(state: BreakState): Promise<void> {
  await barshelf.storage.set(STATE_KEY, state);
}

/** Starts a new cycle of `ms` from now and schedules its reminder. */
async function startCycle(
  state: BreakState,
  nowMs: number,
  ms: number,
): Promise<BreakState> {
  const next: BreakState = {
    ...state,
    status: "running",
    startedAtMs: nowMs,
    nextAtMs: nowMs + ms,
    remainingMs: ms,
  };
  await barshelf.timer.once(DUE_TIMER, next.nextAtMs);
  await barshelf.timer.every(TICK_TIMER, TICK_MS);
  return next;
}

async function notifyBreak(state: BreakState): Promise<void> {
  const minutes = Math.round(state.intervalMs / 60_000);
  try {
    await barshelf.notify.show({
      title: t("Time for a break", "쉴 시간입니다"),
      body: t(
        `${minutes} minutes since your last break. Stand up, stretch, and look at something far away for 20 seconds.`,
        `마지막 휴식 후 ${minutes}분이 지났습니다. 일어나서 몸을 펴고, 20초 동안 먼 곳을 바라보세요.`,
      ),
    });
  } catch (error) {
    await barshelf.log(
      "warn",
      `Unable to show break notification: ${String(error)}`,
    );
  }
}

/** A reminder is due: notify, mark it, and keep cycling so it repeats if ignored. */
async function fire(state: BreakState, nowMs: number): Promise<BreakState> {
  if (!withinWorkHours(nowMs)) {
    // Outside work hours: no reminder, just keep the cycle going.
    const next = await startCycle(
      { ...state, due: false },
      nowMs,
      state.intervalMs,
    );
    await saveState(next);
    return next;
  }
  await notifyBreak(state);
  const next = await startCycle(
    { ...state, due: true },
    nowMs,
    state.intervalMs,
  );
  await saveState(next);
  return next;
}

/**
 * Overdue by more than a whole interval means the reminder could not have
 * fired on time: the Mac slept, or BarShelf was not running. The person was
 * away, which is a break, so start a fresh cycle without a notification
 * instead of greeting them with "50 minutes since your last break".
 */
function wasAway(state: BreakState, nowMs: number): boolean {
  return state.status === "running" &&
    nowMs - state.nextAtMs > state.intervalMs;
}

async function restartAfterAway(
  state: BreakState,
  nowMs: number,
): Promise<BreakState> {
  const next = await startCycle(
    { ...state, due: false },
    nowMs,
    state.intervalMs,
  );
  await saveState(next);
  return next;
}

function remainingAt(state: BreakState, nowMs: number): number {
  return state.status === "running"
    ? Math.max(state.nextAtMs - nowMs, 0)
    : state.remainingMs;
}

function shortDuration(ms: number): string {
  const minutes = Math.ceil(ms / 60_000);
  if (minutes >= 60) {
    const h = Math.floor(minutes / 60);
    const m = minutes % 60;
    return `${h}:${String(m).padStart(2, "0")}`;
  }
  return `${minutes}m`;
}

function clock(ms: number): string {
  return new Intl.DateTimeFormat(language === "ko" ? "ko-KR" : undefined, {
    hour: "2-digit",
    minute: "2-digit",
  }).format(new Date(ms));
}

/**
 * The ring with the time left in minutes at its center. The host's own
 * countdown label is whole seconds ("2972"), so the center is a text laid
 * over the ring; the widget re-renders every minute, which keeps it current.
 */
function ring(state: BreakState, nowMs: number): UINode {
  const remaining = remainingAt(state, nowMs);
  const center = ui.text(shortDuration(remaining), {
    id: "break-ring-label",
    role: "caption",
    monospacedDigit: true,
    foreground: state.status === "running" ? "primary" : "secondary",
  });
  const progress = state.status === "running"
    ? ui.progress({
      id: "break-ring",
      style: "ring",
      countdown: { from: state.startedAtMs, until: state.nextAtMs },
      tint: state.due ? "warning" : "accent",
      tintRules: [{ whenRemainingLtSeconds: 60, tint: "warning" }],
      size: 64,
      accessibility: {
        label: t("Time until the next break", "다음 휴식까지 남은 시간"),
        value: shortDuration(remaining),
      },
    })
    : ui.progress({
      id: "break-ring",
      style: "ring",
      value: state.intervalMs > 0 ? remaining / state.intervalMs : 0,
      tint: "secondary",
      size: 64,
    });
  return ui.zstack([progress, center], { id: "break-ring-stack" });
}

async function render(state: BreakState, nowMs: number): Promise<void> {
  const remaining = remainingAt(state, nowMs);
  const minutes = Math.round(state.intervalMs / 60_000);

  const title = state.status === "paused"
    ? t("Paused", "일시 정지됨")
    : state.due
    ? t("Break time", "쉴 시간")
    : t(
      `Break in ${shortDuration(remaining)}`,
      `${shortDuration(remaining)} 후 휴식`,
    );
  const hours = config.workHours;
  const detail = state.status === "paused"
    ? t(
      "Reminders are off until you resume.",
      "재개할 때까지 알림이 꺼져 있습니다.",
    )
    : hours && !withinWorkHours(nowMs)
    ? t(
      `Quiet outside ${hours.start}:00–${hours.end}:00`,
      `${hours.start}:00–${hours.end}:00 밖에는 알리지 않습니다`,
    )
    : t(
      `Next reminder at ${clock(state.nextAtMs)}`,
      `${clock(state.nextAtMs)}에 다음 알림`,
    );
  const snoozeMinutes = Math.round(config.snoozeMs / 60_000);

  const controls: UINode[] = [
    ui.button(t("Took a break", "휴식 완료"), ui.action.event("took-break"), {
      id: "took-break",
      icon: "figure.walk",
    }),
  ];
  if (state.status === "running") {
    if (state.due) {
      controls.push(
        ui.button(
          t(`Snooze ${snoozeMinutes} min`, `${snoozeMinutes}분 뒤에`),
          ui.action.event("snooze"),
          {
            id: "snooze",
            icon: "zzz",
          },
        ),
      );
    }
    controls.push(ui.button(t("Pause", "일시 정지"), ui.action.event("pause"), {
      id: "pause",
      icon: "pause.fill",
    }));
  } else {
    controls.push(ui.button(t("Resume", "재개"), ui.action.event("resume"), {
      id: "resume",
      icon: "play.fill",
    }));
  }

  const children: UINode[] = [
    ui.card([
      ui.hstack([
        ring(state, nowMs),
        ui.vstack([
          ui.text(title, { role: "title" }),
          ui.text(detail, { role: "caption", foreground: "secondary" }),
          ui.text(
            t(
              `Every ${minutes} min · ${state.breaksToday} today`,
              `${minutes}분마다 · 오늘 ${state.breaksToday}번`,
            ),
            { role: "caption", foreground: "secondary", monospacedDigit: true },
          ),
        ], { spacing: 4 }),
      ], { spacing: 12 }),
    ], {
      id: "break-card",
      tone: state.due ? "warning" : "accent",
      padding: 10,
    }),
  ];
  if (state.due && state.status === "running") {
    children.push(ui.banner(
      t(
        "Stand up, stretch, and rest your eyes — then tap Took a break.",
        "일어나서 몸을 펴고 눈을 쉬게 한 뒤 '휴식 완료'를 누르세요.",
      ),
      { tone: "warning", icon: "figure.stand" },
    ));
  }
  children.push(ui.hstack(controls, { id: "break-controls", spacing: 6 }));

  const label = state.status === "paused"
    ? t("Paused", "정지")
    : state.due
    ? t("Break", "휴식")
    : shortDuration(remaining);

  await barshelf.render(
    ui.vstack(children, { id: "break-reminder-root", spacing: 8 }),
    {
      status: {
        label,
        tooltip: `${t("Break Reminder", "휴식 알림")} · ${title}`,
        icon: state.due ? "figure.stand" : undefined,
        tint: state.due && state.status === "running" ? "warning" : undefined,
      },
      nextRefreshAt: state.status === "running" ? state.nextAtMs : undefined,
      cacheTtlMs: TICK_MS,
    },
  );
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  setLanguage(ctx.locale);
  config = readConfig(ctx.settings);
  const interval = configuredInterval(ctx.settings);
  let state = await readState(ctx.now, interval);

  if (state.intervalMs !== interval) {
    // A new interval starts a fresh cycle at the new length.
    state.intervalMs = interval;
    state = state.status === "running"
      ? await startCycle(state, ctx.now, interval)
      : { ...state, remainingMs: interval };
    await saveState(state);
  }

  if (state.status === "running") {
    if (wasAway(state, ctx.now)) {
      state = await restartAfterAway(state, ctx.now);
    } else if (state.nextAtMs <= ctx.now) {
      state = await fire(state, ctx.now);
    } else {
      await barshelf.timer.once(DUE_TIMER, state.nextAtMs);
      await barshelf.timer.every(TICK_TIMER, TICK_MS);
    }
  }
  await saveState(state);
  await render(state, ctx.now);
}

async function action(ctx: WidgetActionContext): Promise<void> {
  let state = await readState(ctx.now);

  if (ctx.actionId === "took-break") {
    state = await startCycle(
      { ...state, due: false, breaksToday: state.breaksToday + 1 },
      ctx.now,
      state.intervalMs,
    );
  } else if (ctx.actionId === "snooze" && state.status === "running") {
    state = await startCycle(
      { ...state, due: false },
      ctx.now,
      config.snoozeMs,
    );
  } else if (ctx.actionId === "pause" && state.status === "running") {
    state = {
      ...state,
      status: "paused",
      due: false,
      remainingMs: remainingAt(state, ctx.now) || state.intervalMs,
    };
    await barshelf.timer.clear(DUE_TIMER);
    await barshelf.timer.clear(TICK_TIMER);
  } else if (ctx.actionId === "resume" && state.status === "paused") {
    const left = state.remainingMs > 0 ? state.remainingMs : state.intervalMs;
    // Keep the ring where it was paused: the cycle "started" interval-left ago.
    state = {
      ...state,
      status: "running",
      startedAtMs: ctx.now - (state.intervalMs - left),
      nextAtMs: ctx.now + left,
      remainingMs: left,
    };
    await barshelf.timer.once(DUE_TIMER, state.nextAtMs);
    await barshelf.timer.every(TICK_TIMER, TICK_MS);
  }

  await saveState(state);
  await render(state, ctx.now);
}

async function timer(ctx: WidgetTimerContext): Promise<void> {
  let state = await readState(ctx.now);
  if (state.status !== "running") {
    await barshelf.timer.clear(TICK_TIMER);
    return;
  }
  if (wasAway(state, ctx.now)) {
    state = await restartAfterAway(state, ctx.now);
  } else if (ctx.id === DUE_TIMER || state.nextAtMs <= ctx.now) {
    if (state.nextAtMs <= ctx.now) {
      state = await fire(state, ctx.now);
    } else {
      await barshelf.timer.once(DUE_TIMER, state.nextAtMs);
    }
  }
  await render(state, ctx.now);
}

export default barshelf.widget({ load, action, timer });
