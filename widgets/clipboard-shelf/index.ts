import {
  barshelf,
  ui,
  type UINode,
  type WidgetActionContext,
  type WidgetLoadContext,
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

async function capture(ctx: WidgetLoadContext): Promise<void> {
  ignoredSensitive = false;
  const result = await ctx.exec.run({
    command: "/usr/bin/pbpaste",
    args: [],
    parse: "text",
    timeoutMs: 2_000,
    sensitive: true,
  });
  const value = result.stdout.replace(/\0+$/g, "");
  if (
    value.length === 0 ||
    new TextEncoder().encode(value).length > MAX_CLIPBOARD_BYTES
  ) return;
  if (looksSensitive(value)) {
    ignoredSensitive = true;
    return;
  }

  const existing = items.find((item) => item.value === value);
  if (existing) {
    existing.capturedAt = ctx.now;
    items = [existing, ...items.filter((item) => item.id !== existing.id)];
  } else {
    items.unshift({
      id: `clip-${ctx.now}-${sequence++}`,
      value,
      capturedAt: ctx.now,
      pinned: false,
    });
  }
  trimHistory();
}

function redactedCache(): UINode {
  return ui.empty({
    icon: "clipboard",
    title: "Clipboard Shelf",
    subtitle: "Open to read your current clipboard privately.",
  });
}

function itemRow(item: ClipboardItem): UINode {
  const copyOptions = clearAfterSec > 0
    ? { toast: "Copied", clearAfterSec }
    : { toast: "Copied" };
  return ui.card([
    ui.hstack([
      ui.image(item.pinned ? "pin.fill" : "doc.on.clipboard", {
        size: 13,
        tint: item.pinned ? "accent" : "secondary",
      }),
      ui.text(preview(item.value), { role: "body", lineLimit: 2 }),
    ], { spacing: 6 }),
    ui.hstack([
      ui.button("Copy", ui.action.copyText(item.value, copyOptions), {
        id: `copy-${item.id}`,
        icon: "doc.on.doc",
      }),
      ui.button(
        item.pinned ? "Unpin" : "Pin",
        ui.action.event("toggle-pin", { id: item.id }),
        { id: `pin-${item.id}`, icon: item.pinned ? "pin.slash" : "pin" },
      ),
      ui.spacer(),
      ui.button(undefined, ui.action.event("delete", { id: item.id }), {
        id: `delete-${item.id}`,
        icon: "trash",
        accessibilityLabel: "Delete clipboard item",
      }),
    ], { spacing: 5 }),
  ], { id: item.id, spacing: 5, padding: 7 });
}

async function render(now: number): Promise<void> {
  const pinned = items.filter((item) => item.pinned).length;
  const children: UINode[] = [
    ui.header("Clipboard Shelf", {
      icon: "clipboard.fill",
      badge: `${items.length}/${historyLimit}`,
      badgeTone: "accent",
      subtitle: "Memory-only history · secrets are skipped",
    }),
  ];

  if (ignoredSensitive) {
    children.push(
      ui.banner("A clipboard value that looked sensitive was not captured.", {
        title: "Protected",
        tone: "warning",
      }),
    );
  }

  if (items.length === 0) {
    children.push(ui.empty({
      icon: "clipboard",
      title: "No clipboard history yet",
      subtitle: "Copy some text, then reopen this shelf.",
    }));
  } else {
    children.push(ui.list(items.map(itemRow), {
      spacing: 6,
      searchPlaceholder: "Search clipboard history",
    }));
    children.push(ui.hstack([
      ui.text(
        pinned > 0 ? `${pinned} pinned` : "Stored only until this widget stops",
        {
          role: "caption",
          foreground: "secondary",
        },
      ),
      ui.spacer(),
      ui.button("Clear all", ui.action.event("clear-all"), {
        id: "clear-all",
        icon: "trash",
      }),
    ], { spacing: 6 }));
  }

  await barshelf.render(ui.vstack(children, { spacing: 8 }), {
    status: {
      label: items.length > 0 ? String(items.length) : undefined,
      tooltip: `${items.length} recent clipboard item${
        items.length === 1 ? "" : "s"
      }`,
    },
    cacheRoot: redactedCache(),
    cacheTtlMs: 0,
    sensitive: true,
    nextRefreshAt: now + 5_000,
  });
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  historyLimit = integerSetting(ctx.settings.historyLimit, 8, 3, HARD_LIMIT);
  clearAfterSec = integerSetting(ctx.settings.clearAfterSec, 0, 0, 300);
  trimHistory();
  try {
    await capture(ctx);
  } catch {
    await ctx.log(
      "warn",
      "Clipboard read failed; no clipboard data was retained.",
    );
  }
  await render(ctx.now);
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
  await render(ctx.now);
}

export default barshelf.widget({ load, action: handleAction });
