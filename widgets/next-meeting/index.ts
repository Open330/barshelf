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

/** The app's language, set at the start of each load. */
let language: "en" | "ko" = "en";

/** Fixed text: Korean when the app is in Korean, else the English. */
function t(english: string, korean: string): string {
  return language === "ko" ? korean : english;
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
  if (minutes < 1) return t("Starting now", "곧 시작");
  if (minutes < 60) return t(`In ${minutes} min`, `${minutes}분 후`);
  const hours = Math.floor(minutes / 60);
  const remainder = minutes % 60;
  if (hours < 24) {
    return remainder === 0
      ? t(`In ${hours} hr`, `${hours}시간 후`)
      : t(`In ${hours} hr ${remainder} min`, `${hours}시간 ${remainder}분 후`);
  }
  const days = Math.floor(hours / 24);
  return t(`In ${days} day${days === 1 ? "" : "s"}`, `${days}일 후`);
}

function timeRange(data: MeetingData, locale: string): string {
  const start = new Date(data.startMs ?? 0);
  const end = new Date(data.endMs ?? data.startMs ?? 0);
  if (data.allDay) {
    return new Intl.DateTimeFormat(locale, {
      weekday: "short",
      month: "short",
      day: "numeric",
    }).format(start) + t(" · All day", " · 종일");
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
    ui.banner(
      t(
        "Calendar details load when the widget refreshes.",
        "위젯이 새로 고쳐지면 일정 정보를 불러옵니다.",
      ),
      {
        tone: "neutral",
        icon: "lock.shield",
      },
    ),
  ], { id: "next-meeting-redacted", spacing: 8 });
}

function emptyView(days: number): UINode {
  return ui.vstack([
    ui.empty({
      icon: "calendar.badge.checkmark",
      title: t("No upcoming events", "다가오는 일정 없음"),
      subtitle: t(
        `Your next ${days} day${days === 1 ? "" : "s"} are clear.`,
        `앞으로 ${days}일 동안 일정이 없습니다.`,
      ),
    }),
    ui.button(t("Open Calendar", "캘린더 열기"), openCalendar, {
      icon: "calendar",
    }),
  ], { id: "next-meeting-empty", spacing: 8 });
}

function meetingView(data: MeetingData, ctx: WidgetLoadContext): UINode {
  const startMs = data.startMs ?? ctx.now;
  const remaining = relativeTime(startMs, ctx.now);
  const details = [data.calendar, data.location].filter(Boolean).join(" · ");
  const actionButtons: UINode[] = [];

  if (data.meetingURL && /^https?:\/\//i.test(data.meetingURL)) {
    actionButtons.push(
      ui.button(t("Join", "참가"), ui.action.openURL(data.meetingURL), {
        id: "join-meeting",
        icon: "video.fill",
        role: "normal",
      }),
    );
  }
  actionButtons.push(ui.button(t("Calendar", "캘린더"), openCalendar, {
    id: "open-calendar",
    icon: "calendar",
  }));

  return ui.vstack([
    ui.card([
      ui.hstack([
        ui.text(data.title ?? t("Untitled event", "제목 없는 일정"), {
          role: "title",
          lineLimit: 2,
        }),
        ui.spacer(),
        ui.badge(remaining, {
          tone: startMs - ctx.now <= 15 * 60_000 ? "warning" : "accent",
        }),
      ], { spacing: 6 }),
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
  language = typeof ctx.locale === "string" && /^ko(?:[-_]|$)/i.test(ctx.locale)
    ? "ko"
    : "en";
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
      : t("Clear", "일정 없음");
    await ctx.render(root, {
      status: {
        label: statusLabel,
        tooltip: t("Next Calendar event", "다음 캘린더 일정"),
      },
      cacheRoot: redactedFallback(),
      cacheTtlMs: 60_000,
      sensitive: true,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await ctx.log("warn", `Calendar query failed: ${message}`);
    await ctx.render(
      ui.vstack([
        ui.banner(
          t(
            "Allow Calendar automation for BarShelf, then refresh this widget.",
            "BarShelf가 캘린더를 자동화하도록 허용한 뒤 이 위젯을 새로 고치세요.",
          ),
          {
            tone: "warning",
            icon: "lock.open",
          },
        ),
        ui.hstack([
          ui.button(t("Open Calendar", "캘린더 열기"), openCalendar, {
            icon: "calendar",
          }),
          ui.button(t("Try Again", "다시 시도"), ui.action.refresh(), {
            icon: "arrow.clockwise",
          }),
        ], { spacing: 6 }),
      ], { id: "next-meeting-error", spacing: 8 }),
      {
        status: {
          label: t("Calendar", "캘린더"),
          tooltip: t(
            "Calendar access is required",
            "캘린더 접근 권한이 필요합니다",
          ),
        },
        cacheRoot: redactedFallback(),
        cacheTtlMs: 60_000,
        sensitive: true,
      },
    );
  }
}

export default barshelf.widget({ load });
