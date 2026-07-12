import {
  barshelf,
  type NodeAction,
  ui,
  type UINode,
  type WidgetLoadContext,
} from "barshelf";

interface MeetingData {
  status: "ok" | "empty";
  lookAheadDays?: number;
  title?: string;
  startMs?: number;
  endMs?: number;
  allDay?: boolean;
  calendar?: string;
  location?: string;
  meetingURL?: string;
}

const openCalendar = {
  type: "openApp",
  value: "com.apple.iCal",
} as unknown as NodeAction;

function integerSetting(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed)
    ? Math.min(max, Math.max(min, Math.floor(parsed)))
    : fallback;
}

function booleanSetting(value: unknown, fallback: boolean): boolean {
  if (typeof value === "boolean") return value;
  if (typeof value === "string") return value.toLowerCase() === "true";
  return fallback;
}

function isMeetingData(value: unknown): value is MeetingData {
  if (typeof value !== "object" || value === null) return false;
  const status = (value as { status?: unknown }).status;
  return status === "ok" || status === "empty";
}

function relativeTime(startMs: number, nowMs: number): string {
  const minutes = Math.max(0, Math.ceil((startMs - nowMs) / 60_000));
  if (minutes < 1) return "Starting now";
  if (minutes < 60) return `In ${minutes} min`;
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  if (hours < 24) {
    return remainder === 0
      ? `In ${hours} hr`
      : `In ${hours} hr ${remainder} min`;
  }
  const days = Math.floor(hours / 24);
  return `In ${days} day${days === 1 ? "" : "s"}`;
}

function timeRange(data: MeetingData, locale: string): string {
  const start = new Date(data.startMs ?? 0);
  const end = new Date(data.endMs ?? data.startMs ?? 0);
  if (data.allDay) {
    return new Intl.DateTimeFormat(locale, {
      weekday: "short",
      month: "short",
      day: "numeric",
    }).format(start) + " · All day";
  }
  const day = new Intl.DateTimeFormat(locale, {
    weekday: "short",
    month: "short",
    day: "numeric",
  }).format(start);
  const time = new Intl.DateTimeFormat(locale, {
    hour: "2-digit",
    minute: "2-digit",
  });
  return `${day} · ${time.format(start)}–${time.format(end)}`;
}

function redactedFallback(): UINode {
  return ui.vstack([
    ui.header("Next Meeting", { icon: "calendar.badge.clock" }),
    ui.banner("Calendar details load when the widget refreshes.", {
      tone: "neutral",
      icon: "lock.shield",
    }),
  ], { id: "next-meeting-redacted", spacing: 8 });
}

function emptyView(days: number): UINode {
  return ui.vstack([
    ui.header("Next Meeting", {
      icon: "calendar.badge.checkmark",
      badge: "Clear",
      badgeTone: "good",
      tint: "good",
    }),
    ui.empty({
      icon: "calendar.badge.checkmark",
      title: "No upcoming events",
      subtitle: `Your next ${days} day${days === 1 ? "" : "s"} are clear.`,
    }),
    ui.button("Open Calendar", openCalendar, { icon: "calendar" }),
  ], { id: "next-meeting-empty", spacing: 8 });
}

function meetingView(data: MeetingData, ctx: WidgetLoadContext): UINode {
  const startMs = data.startMs ?? ctx.now;
  const remaining = relativeTime(startMs, ctx.now);
  const details = [data.calendar, data.location].filter(Boolean).join(" · ");
  const actionButtons: UINode[] = [];

  if (data.meetingURL && /^https?:\/\//i.test(data.meetingURL)) {
    actionButtons.push(ui.button("Join", ui.action.openURL(data.meetingURL), {
      id: "join-meeting",
      icon: "video.fill",
      role: "normal",
    }));
  }
  actionButtons.push(ui.button("Calendar", openCalendar, {
    id: "open-calendar",
    icon: "calendar",
  }));

  return ui.vstack([
    ui.header("Next Meeting", {
      icon: "calendar.badge.clock",
      badge: remaining,
      badgeTone: startMs - ctx.now <= 15 * 60_000 ? "warning" : "accent",
    }),
    ui.card([
      ui.text(data.title ?? "Untitled event", {
        role: "title",
        lineLimit: 2,
      }),
      ui.text(timeRange(data, ctx.locale), {
        role: "body",
        monospacedDigit: true,
      }),
      ...(details
        ? [ui.text(details, {
          role: "caption",
          foreground: "secondary",
          lineLimit: 2,
        })]
        : []),
    ], { id: "meeting-card", tone: "accent", spacing: 5 }),
    ui.hstack(actionButtons, { id: "meeting-actions", spacing: 6 }),
  ], { id: "next-meeting-root", spacing: 8 });
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  const days = integerSetting(ctx.settings.lookAheadDays, 7, 1, 30);
  const includeAllDay = booleanSetting(ctx.settings.includeAllDay, false);

  try {
    const result = await ctx.exec.run({
      command: "/usr/bin/osascript",
      args: [
        "-l",
        "JavaScript",
        "./calendar.js",
        String(days),
        String(includeAllDay),
      ],
      parse: "json",
      timeoutMs: 15_000,
      sensitive: true,
    });
    if (result.exitCode !== 0 || !isMeetingData(result.json)) {
      throw new Error(
        result.stderr.trim() || "Calendar returned an unexpected response.",
      );
    }

    const data = result.json;
    const root = data.status === "empty"
      ? emptyView(days)
      : meetingView(data, ctx);
    const statusLabel = data.status === "ok" && data.startMs
      ? relativeTime(data.startMs, ctx.now)
      : "Clear";
    await ctx.render(root, {
      status: { label: statusLabel, tooltip: "Next Calendar event" },
      cacheRoot: redactedFallback(),
      cacheTtlMs: 60_000,
      sensitive: true,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await ctx.log("warn", `Calendar query failed: ${message}`);
    await ctx.render(
      ui.vstack([
        ui.header("Next Meeting", {
          icon: "calendar.badge.exclamationmark",
          badge: "Needs access",
          badgeTone: "warning",
          tint: "warning",
        }),
        ui.banner(
          "Allow Calendar automation for BarShelf, then refresh this widget.",
          {
            tone: "warning",
            icon: "lock.open",
          },
        ),
        ui.hstack([
          ui.button("Open Calendar", openCalendar, { icon: "calendar" }),
          ui.button("Try Again", ui.action.refresh(), {
            icon: "arrow.clockwise",
          }),
        ], { spacing: 6 }),
      ], { id: "next-meeting-error", spacing: 8 }),
      {
        status: { label: "Calendar", tooltip: "Calendar access is required" },
        cacheRoot: redactedFallback(),
        cacheTtlMs: 60_000,
        sensitive: true,
      },
    );
  }
}

export default barshelf.widget({ load });
