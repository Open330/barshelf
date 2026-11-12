import {
  barshelf,
  ui,
  type UINode,
  type WidgetActionContext,
  type WidgetLoadContext,
  type WidgetTimerContext,
} from "barshelf";

interface ClipboardItem {
  id: string;
  value: string;
  capturedAt: number;
  pinned: boolean;
}

const HARD_LIMIT = 20;
const MAX_CLIPBOARD_BYTES = 65_536;
let items: ClipboardItem[] = [];
let historyLimit = 8;
let clearAfterSec = 0;
let sequence = 0;
let ignoredSensitive = false;
/** Poll the clipboard from a script timer, so copies made while the popup is closed are kept. */
let collectInBackground = true;
let pinsRestored = false;
/** The last value read, so an unchanged clipboard is not re-processed every poll. */
let lastValue: string | undefined;

const CAPTURE_TIMER = "capture";
/** The host's floor for `timer.every`. */
const CAPTURE_MS = 5_000;
/** Pinned entries, the only ones written to BarShelf storage. */
const PINS_KEY = "pins-v1";

/**
 * The app's language at the last load. Actions carry no locale, so they
 * speak the language the widget was last loaded in.
 */
let language: "en" | "ko" = "en";

/** Fixed text: Korean when the app is in Korean, else the English. */
function t(english: string, korean: string): string {
  return language === "ko" ? korean : english;
}

function integerSetting(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.min(max, Math.max(min, Math.round(value)))
    : fallback;
}

function luhn(candidate: string): boolean {
  const digits = candidate.replace(/[ -]/g, "");
  if (!/^\d{13,19}$/.test(digits)) return false;
  let sum = 0;
  let doubleDigit = false;
  for (let index = digits.length - 1; index >= 0; index -= 1) {
    let digit = Number(digits[index]);
    if (doubleDigit) {
      digit *= 2;
      if (digit > 9) digit -= 9;
    }
    sum += digit;
    doubleDigit = !doubleDigit;
  }
  return sum % 10 === 0;
}

function looksSensitive(value: string): boolean {
  if (/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(value)) {
    return true;
  }
  if (
    /\b(?:github_pat_|gh[pousr]_|sk-(?:proj-)?|xox[baprs]-|AKIA)[A-Za-z0-9_-]{8,}\b/
      .test(value)
  ) return true;
  if (/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b/.test(value)) {
    return true;
  }
  if (
    /(?:password|passwd|secret|api[_ -]?key|access[_ -]?token)\s*[:=]\s*\S{4,}/i
      .test(value)
  ) return true;
  return value.match(/(?:\d[ -]?){13,19}/g)?.some(luhn) ?? false;
}

function preview(value: string): string {
  const compact = value.replace(/\s+/g, " ").trim();
  return compact.length > 78 ? `${compact.slice(0, 75)}…` : compact;
}

function trimHistory(): void {
  const limit = Math.min(HARD_LIMIT, historyLimit);
  while (items.length > limit) {
    const removable = items.findLastIndex((item) => !item.pinned);
    items.splice(removable >= 0 ? removable : items.length - 1, 1);
  }
}

/** Reads the clipboard once; true when the history (or the warning) changed. */
async function capture(
  exec: WidgetLoadContext["exec"],
  now: number,
): Promise<boolean> {
  const result = await exec.run({
    command: "/usr/bin/pbpaste",
    args: [],
    parse: "text",
    timeoutMs: 2_000,
    sensitive: true,
  });
  const value = result.stdout.replace(/\0+$/g, "");
  if (value === lastValue) return false;
  lastValue = value;
  const wasIgnored = ignoredSensitive;
  ignoredSensitive = false;
  if (
    value.length === 0 ||
    new TextEncoder().encode(value).length > MAX_CLIPBOARD_BYTES
  ) return wasIgnored;
  if (looksSensitive(value)) {
    ignoredSensitive = true;
    return true;
  }

  const existing = items.find((item) => item.value === value);
  if (existing) {
    existing.capturedAt = now;
    items = [existing, ...items.filter((item) => item.id !== existing.id)];
  } else {
    items.unshift({
      id: `clip-${now}-${sequence++}`,
      value,
      capturedAt: now,
      pinned: false,
    });
  }
  trimHistory();
  return true;
}

/** Pins survive a restart; nothing else is written anywhere. */
async function savePins(): Promise<void> {
  const pins = items.filter((item) => item.pinned)
    .map(({ id, value, capturedAt }) => ({ id, value, capturedAt }));
  try {
    if (pins.length === 0) await barshelf.storage.delete(PINS_KEY);
    else await barshelf.storage.set(PINS_KEY, pins);
  } catch {
    await barshelf.log("warn", "Pinned clipboard items could not be saved.");
  }
}

async function restorePins(): Promise<void> {
  if (pinsRestored) return;
  pinsRestored = true;
  try {
    const saved = await barshelf.storage.get<unknown>(PINS_KEY);
    if (!Array.isArray(saved)) return;
    for (const entry of saved) {
      const record = entry as Partial<ClipboardItem> | null;
      if (
        typeof record?.value !== "string" || typeof record.id !== "string" ||
        looksSensitive(record.value) || items.some((item) => item.value === record.value)
      ) continue;
      items.push({
        id: record.id,
        value: record.value,
        capturedAt: typeof record.capturedAt === "number" ? record.capturedAt : 0,
        pinned: true,
      });
    }
  } catch {
    // Storage unavailable: start without pins.
  }
}

function redactedCache(): UINode {
  return ui.empty({
    icon: "clipboard",
    title: t("Clipboard Shelf", "클립보드 선반"),
    subtitle: t(
      "Open to read your current clipboard privately.",
      "열면 현재 클립보드를 비공개로 읽습니다.",
    ),
  });
}

function itemRow(item: ClipboardItem): UINode {
  const toast = t("Copied", "복사됨");
  const copyOptions = clearAfterSec > 0 ? { toast, clearAfterSec } : { toast };
  return ui.card([
    ui.hstack([
      ui.image(item.pinned ? "pin.fill" : "doc.on.clipboard", {
        size: 13,
        tint: item.pinned ? "accent" : "secondary",
      }),
      ui.text(preview(item.value), { role: "body", lineLimit: 2 }),
    ], { spacing: 6 }),
    ui.hstack([
      ui.button(
        t("Copy", "복사"),
        ui.action.copyText(item.value, copyOptions),
        {
          id: `copy-${item.id}`,
          icon: "doc.on.doc",
        },
      ),
      ui.button(
        item.pinned ? t("Unpin", "고정 해제") : t("Pin", "고정"),
        ui.action.event("toggle-pin", { id: item.id }),
        { id: `pin-${item.id}`, icon: item.pinned ? "pin.slash" : "pin" },
      ),
      ui.spacer(),
      ui.button(undefined, ui.action.event("delete", { id: item.id }), {
        id: `delete-${item.id}`,
        icon: "trash",
        accessibilityLabel: t("Delete clipboard item", "클립보드 항목 삭제"),
      }),
    ], { spacing: 5 }),
  ], { id: item.id, spacing: 5, padding: 7 });
}

async function render(now: number): Promise<void> {
  const pinned = items.filter((item) => item.pinned).length;
  const children: UINode[] = [
    ui.hstack([
      ui.text(
        collectInBackground
          ? t(
            "Collects every 5 s · secrets are skipped",
            "5초마다 수집 · 비밀 정보는 건너뜀",
          )
          : t(
            "Collects while open · secrets are skipped",
            "열려 있을 때만 수집 · 비밀 정보는 건너뜀",
          ),
        {
          role: "caption",
          foreground: "secondary",
          lineLimit: 1,
        },
      ),
      ui.spacer(),
      ui.badge(`${items.length}/${historyLimit}`, { tone: "accent" }),
    ], { spacing: 6 }),
  ];

  if (ignoredSensitive) {
    children.push(
      ui.banner(
        t(
          "A clipboard value that looked sensitive was not captured.",
          "민감해 보이는 클립보드 값은 저장하지 않았습니다.",
        ),
        {
          title: t("Protected", "보호됨"),
          tone: "warning",
        },
      ),
    );
  }

  if (items.length === 0) {
    children.push(ui.empty({
      icon: "clipboard",
      title: t("No clipboard history yet", "아직 클립보드 기록이 없습니다"),
      subtitle: collectInBackground
        ? t("Text you copy shows up here.", "복사한 텍스트가 여기에 나타납니다.")
        : t(
          "Copy some text, then reopen this shelf.",
          "텍스트를 복사한 뒤 이 선반을 다시 여세요.",
        ),
    }));
  } else {
    children.push(ui.list(items.map(itemRow), {
      spacing: 6,
      searchPlaceholder: t("Search clipboard history", "클립보드 기록 검색"),
    }));
    children.push(ui.hstack([
      ui.text(
        pinned > 0
          ? t(
            `${pinned} pinned · pins are kept on this Mac`,
            `고정 ${pinned}개 · 고정 항목은 이 Mac에 보관`,
          )
          : t(
            "Stored only until this widget stops",
            "이 위젯이 멈출 때까지만 보관됩니다",
          ),
        {
          role: "caption",
          foreground: "secondary",
        },
      ),
      ui.spacer(),
      ui.button(t("Clear all", "모두 지우기"), ui.action.event("clear-all"), {
        id: "clear-all",
        icon: "trash",
      }),
    ], { spacing: 6 }));
  }

  await barshelf.render(ui.vstack(children, { spacing: 8 }), {
    status: {
      label: items.length > 0 ? String(items.length) : undefined,
      tooltip: t(
        `${items.length} recent clipboard item${items.length === 1 ? "" : "s"}`,
        `최근 클립보드 항목 ${items.length}개`,
      ),
    },
    cacheRoot: redactedCache(),
    cacheTtlMs: 0,
    sensitive: true,
    nextRefreshAt: now + 5_000,
  });
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  language = typeof ctx.locale === "string" && /^ko(?:[-_]|$)/i.test(ctx.locale)
    ? "ko"
    : "en";
  historyLimit = integerSetting(ctx.settings.historyLimit, 8, 3, HARD_LIMIT);
  clearAfterSec = integerSetting(ctx.settings.clearAfterSec, 0, 0, 300);
  collectInBackground = ctx.settings.collectInBackground !== false;
  await restorePins();
  trimHistory();
  // A script timer keeps running while the popup is closed (unless the
  // user pauses hidden work), which is what makes this a history rather
  // than one entry per popup open.
  if (collectInBackground) await ctx.timer.every(CAPTURE_TIMER, CAPTURE_MS);
  else await ctx.timer.clear(CAPTURE_TIMER);
  try {
    await capture(ctx.exec, ctx.now);
  } catch {
    await ctx.log(
      "warn",
      "Clipboard read failed; no clipboard data was retained.",
    );
  }
  await render(ctx.now);
}

async function handleTimer(
  ctx: WidgetTimerContext,
  event: { id: string; now: number },
): Promise<void> {
  if (event.id !== CAPTURE_TIMER || !collectInBackground) return;
  let changed = false;
  try {
    changed = await capture(ctx.exec, event.now);
  } catch {
    return;
  }
  if (changed) await render(event.now);
}

async function handleAction(ctx: WidgetActionContext): Promise<void> {
  const payload = ctx.payload as { id?: unknown } | undefined;
  const id = typeof payload?.id === "string" ? payload.id : undefined;
  if (ctx.actionId === "toggle-pin" && id) {
    const item = items.find((candidate) => candidate.id === id);
    if (item) item.pinned = !item.pinned;
  } else if (ctx.actionId === "delete" && id) {
    items = items.filter((item) => item.id !== id);
  } else if (ctx.actionId === "clear-all") {
    items = [];
  } else {
    return;
  }
  await savePins();
  await render(ctx.now);
}

export default barshelf.widget({ load, action: handleAction, timer: handleTimer });
