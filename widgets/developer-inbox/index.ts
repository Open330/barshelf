import { barshelf, ui, type UINode, type WidgetLoadContext } from "barshelf";

const GH_PATHS = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"];
const PR_ARGS = [
  "search",
  "prs",
  "--review-requested",
  "@me",
  "--state",
  "open",
  "--limit",
  "10",
  "--json",
  "number,title,url,repository,author,isDraft,updatedAt",
];
const NOTIFICATION_ARGS = ["api", "notifications?per_page=30"];

interface PullRequest {
  number: number;
  title: string;
  url: string;
  repository: string;
  author: string;
  draft: boolean;
  updatedAt: string;
}

interface InboxNotification {
  id: string;
  reason: string;
  repository: string;
  title: string;
  type: string;
  url?: string;
  updatedAt: string;
}

function object(value: unknown): Record<string, unknown> | undefined {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? value as Record<string, unknown>
    : undefined;
}

function text(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function parseJson(stdout: string): unknown[] {
  try {
    const value = JSON.parse(stdout);
    return Array.isArray(value) ? value : [];
  } catch {
    return [];
  }
}

function parsePullRequests(stdout: string): PullRequest[] {
  return parseJson(stdout).flatMap((value) => {
    const row = object(value);
    const repository = object(row?.repository);
    const author = object(row?.author);
    const number = row?.number;
    const title = text(row?.title);
    const url = text(row?.url);
    if (typeof number !== "number" || title.length === 0 || url.length === 0) {
      return [];
    }
    return [{
      number,
      title,
      url,
      repository: text(repository?.nameWithOwner) || text(repository?.name),
      author: text(author?.login),
      draft: row?.isDraft === true,
      updatedAt: text(row?.updatedAt),
    }];
  });
}

function githubWebUrl(apiUrl: string): string | undefined {
  const match = apiUrl.match(
    /^https:\/\/api\.github\.com\/repos\/([^/]+\/[^/]+)\/(issues|pulls)\/(\d+)/,
  );
  if (!match) return undefined;
  const kind = match[2] === "pulls" ? "pull" : "issues";
  return `https://github.com/${match[1]}/${kind}/${match[3]}`;
}

function parseNotifications(stdout: string): InboxNotification[] {
  return parseJson(stdout).flatMap((value) => {
    const row = object(value);
    const repository = object(row?.repository);
    const subject = object(row?.subject);
    const id = text(row?.id);
    const title = text(subject?.title);
    if (id.length === 0 || title.length === 0) return [];
    return [{
      id,
      reason: text(row?.reason),
      repository: text(repository?.full_name),
      title,
      type: text(subject?.type),
      url: githubWebUrl(text(subject?.url)),
      updatedAt: text(row?.updated_at),
    }];
  });
}

function integerSetting(value: unknown): number {
  return typeof value === "number" && Number.isFinite(value)
    ? Math.min(10, Math.max(3, Math.round(value)))
    : 5;
}

function relativeDate(value: string, now: number): string {
  const timestamp = Date.parse(value);
  if (!Number.isFinite(timestamp)) return "";
  const minutes = Math.max(0, Math.round((now - timestamp) / 60_000));
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.round(minutes / 60);
  if (hours < 48) return `${hours}h ago`;
  return `${Math.round(hours / 24)}d ago`;
}

async function findGh(ctx: WidgetLoadContext): Promise<string | undefined> {
  for (const command of GH_PATHS) {
    try {
      await ctx.exec.run({
        command,
        args: ["--version"],
        parse: "text",
        timeoutMs: 3_000,
        sensitive: true,
      });
      return command;
    } catch {
      // Continue to the other standard Homebrew installation location.
    }
  }
  return undefined;
}

function placeholder(title: string, subtitle: string, icon = "tray"): UINode {
  return ui.empty({ icon, title, subtitle });
}

async function renderState(root: UINode, label?: string): Promise<void> {
  await barshelf.render(root, {
    status: { label, tooltip: "Developer Inbox" },
    cacheRoot: placeholder(
      "Developer Inbox",
      "Open to load private GitHub activity.",
      "tray.full",
    ),
    cacheTtlMs: 0,
    sensitive: true,
  });
}

function prRow(pr: PullRequest, now: number): UINode {
  return ui.card([
    ui.hstack([
      ui.text(pr.repository || "Repository", {
        role: "caption",
        foreground: "secondary",
        lineLimit: 1,
      }),
      ui.spacer(),
      pr.draft
        ? ui.badge("Draft", { tone: "neutral" })
        : ui.badge(`#${pr.number}`, { tone: "accent" }),
    ], { spacing: 5 }),
    ui.text(pr.title, { lineLimit: 2 }),
    ui.hstack([
      ui.text(
        [pr.author ? `by ${pr.author}` : "", relativeDate(pr.updatedAt, now)]
          .filter(Boolean).join(" · "),
        {
          role: "caption",
          foreground: "secondary",
          lineLimit: 1,
        },
      ),
      ui.spacer(),
      ui.button("Review", ui.action.openURL(pr.url), {
        icon: "arrow.up.right.square",
      }),
    ], { spacing: 5 }),
  ], { id: `pr-${pr.repository}-${pr.number}`, spacing: 4, padding: 7 });
}

function notificationRow(notification: InboxNotification, now: number): UINode {
  const content: UINode[] = [
    ui.hstack([
      ui.text(notification.repository || notification.type || "GitHub", {
        role: "caption",
        foreground: "secondary",
        lineLimit: 1,
      }),
      ui.spacer(),
      ui.badge(notification.reason || "unread", {
        tone: notification.reason === "review_requested"
          ? "warning"
          : "neutral",
      }),
    ], { spacing: 5 }),
    ui.text(notification.title, { lineLimit: 2 }),
    ui.text(relativeDate(notification.updatedAt, now), {
      role: "caption",
      foreground: "secondary",
    }),
  ];
  if (notification.url) {
    content.push(ui.button("Open", ui.action.openURL(notification.url), {
      icon: "arrow.up.right.square",
    }));
  }
  return ui.card(content, {
    id: `notification-${notification.id}`,
    spacing: 4,
    padding: 7,
  });
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  const gh = await findGh(ctx);
  if (!gh) {
    await renderState(placeholder(
      "GitHub CLI not found",
      "Install gh with Homebrew, then reopen this widget.",
      "terminal",
    ));
    return;
  }

  try {
    await ctx.exec.run({
      command: gh,
      args: ["auth", "status"],
      parse: "text",
      timeoutMs: 5_000,
      sensitive: true,
    });
  } catch {
    await renderState(ui.vstack([
      ui.banner("Run `gh auth login` in Terminal, then refresh.", {
        title: "GitHub sign-in required",
        tone: "warning",
      }),
      placeholder(
        "No authenticated account",
        "Developer Inbox uses your existing gh session.",
        "person.crop.circle.badge.exclamationmark",
      ),
    ], { spacing: 8 }));
    return;
  }

  const showNotifications = ctx.settings.showNotifications !== false;
  const limit = integerSetting(ctx.settings.itemLimit);
  const [prsResult, notificationsResult] = await Promise.allSettled([
    ctx.exec.run({
      command: gh,
      args: PR_ARGS,
      parse: "text",
      timeoutMs: 12_000,
      sensitive: true,
    }),
    showNotifications
      ? ctx.exec.run({
        command: gh,
        args: NOTIFICATION_ARGS,
        parse: "text",
        timeoutMs: 12_000,
        sensitive: true,
      })
      : Promise.resolve(undefined),
  ]);

  const prs = prsResult.status === "fulfilled"
    ? parsePullRequests(prsResult.value.stdout)
    : [];
  const notifications =
    notificationsResult.status === "fulfilled" && notificationsResult.value
      ? parseNotifications(notificationsResult.value.stdout)
      : [];
  const failed = prsResult.status === "rejected" ||
    (showNotifications && notificationsResult.status === "rejected");
  const total = prs.length + notifications.length;

  const children: UINode[] = [
    ui.header("Developer Inbox", {
      icon: "tray.full.fill",
      badge: total > 0 ? String(total) : "Clear",
      badgeTone: total > 0 ? "accent" : "good",
      subtitle: "GitHub activity that needs your attention",
    }),
    ui.hstack([
      ui.stat("Review requests", prs.length, {
        icon: "arrow.triangle.pull",
        tone: prs.length > 0 ? "warning" : "good",
      }),
      ui.stat("Unread", notifications.length, {
        icon: "bell.fill",
        tone: notifications.length > 0 ? "accent" : "good",
      }),
    ], { spacing: 6 }),
  ];

  if (failed) {
    children.push(
      ui.banner("Some GitHub data could not be loaded. Refresh to retry.", {
        title: "Partial results",
        tone: "warning",
      }),
    );
  }
  if (prs.length > 0) {
    children.push(
      ui.section(
        "Review requested",
        prs.slice(0, limit).map((pr) => prRow(pr, ctx.now)),
        { spacing: 6 },
      ),
    );
  }
  if (showNotifications && notifications.length > 0) {
    children.push(
      ui.section(
        "Notifications",
        notifications.slice(0, limit).map((item) =>
          notificationRow(item, ctx.now)
        ),
        { spacing: 6 },
      ),
    );
  }
  if (total === 0 && !failed) {
    children.push(
      placeholder(
        "Inbox zero",
        "No open review requests or unread notifications.",
        "checkmark.circle.fill",
      ),
    );
  }

  await renderState(
    ui.vstack(children, { spacing: 8 }),
    total > 0 ? String(total) : undefined,
  );
}

export default barshelf.widget({ load });
