import {
  barshelf,
  ui,
  type UINode,
  type WidgetActionContext,
  type WidgetLoadContext,
  type WidgetTimerContext,
} from "barshelf";

const STATE_KEY = "focus-state-v1";
const TIMER_ID = "focus-deadline";
const DEFAULT_MINUTES = 25;

type TimerStatus = "idle" | "running" | "paused" | "completed";

interface FocusState {
  status: TimerStatus;
  configuredDurationMs: number;
  durationMs: number;
  remainingMs: number;
  endsAtMs?: number;
  completedSessions: number;
}

function configuredDuration(settings: Record<string, unknown>): number {
  const raw = settings.focusMinutes;
  const minutes = typeof raw === "number" && Number.isFinite(raw)
    ? Math.round(raw)
    : DEFAULT_MINUTES;
  return Math.min(Math.max(minutes, 1), 120) * 60_000;
}

function initialState(durationMs: number): FocusState {
  return {
    status: "idle",
    configuredDurationMs: durationMs,
    durationMs,
    remainingMs: durationMs,
    completedSessions: 0,
  };
}

function validStatus(value: unknown): value is TimerStatus {
  return value === "idle" || value === "running" || value === "paused" ||
    value === "completed";
}

async function readState(durationMs?: number): Promise<FocusState> {
  const stored = await barshelf.storage.get<Partial<FocusState>>(STATE_KEY);
  const fallbackDuration = durationMs ?? DEFAULT_MINUTES * 60_000;
  if (!stored || !validStatus(stored.status)) {
    return initialState(fallbackDuration);
  }

  const configured = Number.isFinite(stored.configuredDurationMs)
    ? Math.max(Number(stored.configuredDurationMs), 60_000)
    : fallbackDuration;
  const duration = Number.isFinite(stored.durationMs)
    ? Math.max(Number(stored.durationMs), 60_000)
    : configured;
  const remaining = Number.isFinite(stored.remainingMs)
    ? Math.min(Math.max(Number(stored.remainingMs), 0), duration)
    : duration;

  return {
    status: stored.status,
    configuredDurationMs: configured,
    durationMs: duration,
    remainingMs: remaining,
    endsAtMs: Number.isFinite(stored.endsAtMs)
      ? Number(stored.endsAtMs)
      : undefined,
    completedSessions: Number.isFinite(stored.completedSessions)
      ? Math.max(Math.floor(Number(stored.completedSessions)), 0)
      : 0,
  };
}

async function saveState(state: FocusState): Promise<void> {
  await barshelf.storage.set(STATE_KEY, state);
}

function formatDuration(durationMs: number): string {
  const totalSeconds = Math.max(Math.ceil(durationMs / 1000), 0);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${String(minutes).padStart(2, "0")}:${
    String(seconds).padStart(2, "0")
  }`;
}

function statusTitle(status: TimerStatus): string {
  if (status === "running") return "Focusing";
  if (status === "paused") return "Paused";
  if (status === "completed") return "Complete";
  return "Ready";
}

function remainingAt(state: FocusState, nowMs: number): number {
  if (state.status === "running" && state.endsAtMs !== undefined) {
    return Math.max(state.endsAtMs - nowMs, 0);
  }
  return state.remainingMs;
}

async function notifyComplete(): Promise<void> {
  try {
    await barshelf.notify.show({
      title: "Focus session complete",
      body: "Nice work. Take a moment before your next session.",
    });
  } catch (error) {
    await barshelf.log(
      "warn",
      `Unable to show completion notification: ${String(error)}`,
    );
  }
}

async function complete(state: FocusState): Promise<FocusState> {
  if (state.status === "completed") return state;
  const completed: FocusState = {
    ...state,
    status: "completed",
    remainingMs: 0,
    endsAtMs: undefined,
    completedSessions: state.completedSessions + 1,
  };
  await barshelf.timer.clear(TIMER_ID);
  await saveState(completed);
  await notifyComplete();
  return completed;
}

function timerProgress(state: FocusState, nowMs: number): UINode {
  if (state.status === "running" && state.endsAtMs !== undefined) {
    return ui.progress({
      id: "focus-countdown",
      style: "ring",
      countdown: {
        from: state.endsAtMs - state.durationMs,
        until: state.endsAtMs,
      },
      labelFrom: "remainingSeconds",
      tint: "accent",
      tintRules: [
        { whenRemainingLtSeconds: 10, tint: "danger" },
        { whenRemainingLtSeconds: 60, tint: "warning" },
      ],
      size: 72,
      accessibility: {
        label: "Focus time remaining",
        value: formatDuration(remainingAt(state, nowMs)),
      },
    });
  }

  const remaining = remainingAt(state, nowMs);
  return ui.progress({
    id: "focus-countdown",
    style: "ring",
    value: state.durationMs > 0 ? remaining / state.durationMs : 0,
    label: formatDuration(remaining),
    tint: state.status === "completed"
      ? "good"
      : state.status === "paused"
      ? "warning"
      : "accent",
    size: 72,
  });
}

async function render(state: FocusState, nowMs: number): Promise<void> {
  const controls: UINode[] = [];
  if (state.status === "running") {
    controls.push(ui.button("Pause", ui.action.event("pause"), {
      id: "pause-focus",
      icon: "pause.fill",
    }));
  } else {
    const startTitle = state.status === "completed"
      ? "Start again"
      : state.status === "paused"
      ? "Resume"
      : "Start";
    controls.push(ui.button(startTitle, ui.action.event("start"), {
      id: "start-focus",
      icon: "play.fill",
    }));
  }
  controls.push(ui.button("Reset", ui.action.event("reset"), {
    id: "reset-focus",
    icon: "arrow.counterclockwise",
  }));

  const detail = state.status === "running" && state.endsAtMs !== undefined
    ? `Ends at ${
      new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit" })
        .format(new Date(state.endsAtMs))
    }`
    : state.status === "completed"
    ? "Session finished"
    : `${Math.round(state.durationMs / 60_000)} minute session`;

  await barshelf.render(
    ui.vstack([
      ui.header("Focus Timer", {
        icon: "timer",
        badge: statusTitle(state.status),
        badgeTone: state.status === "completed"
          ? "good"
          : state.status === "paused"
          ? "warning"
          : "accent",
      }),
      ui.card([
        ui.hstack([
          timerProgress(state, nowMs),
          ui.vstack([
            ui.text(statusTitle(state.status), { role: "title" }),
            ui.text(detail, { role: "caption", foreground: "secondary" }),
            ui.text(`${state.completedSessions} completed`, {
              role: "caption",
              foreground: "secondary",
              monospacedDigit: true,
            }),
          ], { spacing: 4 }),
        ], { spacing: 12 }),
      ], {
        id: "focus-card",
        tone: state.status === "completed" ? "good" : "accent",
        padding: 10,
      }),
      state.status === "completed"
        ? ui.banner("Focus session complete. Ready for another?", {
          tone: "good",
        })
        : ui.text("The countdown ring updates live while the popup is open.", {
          role: "caption",
          foreground: "secondary",
        }),
      ui.hstack(controls, { id: "focus-controls", spacing: 6 }),
    ], { id: "focus-timer-root", spacing: 8 }),
    {
      status: {
        label: statusTitle(state.status),
        tooltip: `Focus Timer · ${statusTitle(state.status)}`,
      },
      nextRefreshAt: state.status === "running" ? state.endsAtMs : undefined,
      cacheTtlMs: 60_000,
    },
  );
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  const requestedDuration = configuredDuration(ctx.settings);
  let state = await readState(requestedDuration);

  if (state.configuredDurationMs !== requestedDuration) {
    state.configuredDurationMs = requestedDuration;
    if (state.status === "idle" || state.status === "completed") {
      state.durationMs = requestedDuration;
      state.remainingMs = state.status === "completed" ? 0 : requestedDuration;
    }
    await saveState(state);
  }

  if (state.status === "running") {
    if (state.endsAtMs === undefined || state.endsAtMs <= ctx.now) {
      state = await complete(state);
    } else {
      await barshelf.timer.once(TIMER_ID, state.endsAtMs);
    }
  }
  await render(state, ctx.now);
}

async function action(ctx: WidgetActionContext): Promise<void> {
  let state = await readState();

  if (ctx.actionId === "start") {
    if (state.status !== "running") {
      const remaining = state.status === "completed" || state.remainingMs <= 0
        ? state.configuredDurationMs
        : state.remainingMs;
      state = {
        ...state,
        status: "running",
        durationMs: state.status === "completed"
          ? state.configuredDurationMs
          : state.durationMs,
        remainingMs: remaining,
        endsAtMs: ctx.now + remaining,
      };
      await saveState(state);
      await barshelf.timer.once(TIMER_ID, ctx.now + remaining);
    }
  } else if (ctx.actionId === "pause" && state.status === "running") {
    const remaining = remainingAt(state, ctx.now);
    if (remaining <= 0) {
      state = await complete(state);
    } else {
      state = {
        ...state,
        status: "paused",
        remainingMs: remaining,
        endsAtMs: undefined,
      };
      await barshelf.timer.clear(TIMER_ID);
      await saveState(state);
    }
  } else if (ctx.actionId === "reset") {
    await barshelf.timer.clear(TIMER_ID);
    state = {
      ...state,
      status: "idle",
      durationMs: state.configuredDurationMs,
      remainingMs: state.configuredDurationMs,
      endsAtMs: undefined,
    };
    await saveState(state);
  }

  await render(state, ctx.now);
}

async function timer(ctx: WidgetTimerContext): Promise<void> {
  if (ctx.id !== TIMER_ID) return;
  let state = await readState();
  if (state.status !== "running") return;

  if (state.endsAtMs !== undefined && state.endsAtMs > ctx.now) {
    await barshelf.timer.once(TIMER_ID, state.endsAtMs);
  } else {
    state = await complete(state);
  }
  await render(state, ctx.now);
}

export default barshelf.widget({ load, action, timer });
