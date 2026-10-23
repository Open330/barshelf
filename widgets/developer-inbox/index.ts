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

/** The app's language, set at the start of each load. */
let language: "en" | "ko" = "en";

/** Fixed text: Korean when the app is in Korean, else the English. */
function t(english: string, korean: string): string {
  return language === "ko" ? korean : english;
}

/** GitHub's notification reasons (a fixed vocabulary); others as sent. */
const KOREAN_REASONS: Record<string, string> = {
  assign: "할당됨",
  author: "작성자",
  comment: "댓글",
  ci_activity: "CI 활동",
  invitation: "초대",
  manual: "구독함",
  mention: "멘션",
  review_requested: "리뷰 요청",
  security_alert: "보안 알림",
  state_change: "상태 변경",
  subscribed: "지켜보는 중",
  team_mention: "팀 멘션",
};

function reasonLabel(reason: string): string {
  if (!reason) return t("unread", "읽지 않음");
  return language === "ko" ? KOREAN_REASONS[reason] ?? reason : reason;
}

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
  if (minutes < 60) return t(`${minutes}m ago`, `${minutes}분 전`);
  const hours = Math.round(minutes / 60);
  if (hours < 48) return t(`${hours}h ago`, `${hours}시간 전`);
  const days = Math.round(hours / 24);
  return t(`${days}d ago`, `${days}일 전`);
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
    status: { label, tooltip: t("Developer Inbox", "개발자 받은편지함") },
    cacheRoot: placeholder(
      t("Developer Inbox", "개발자 받은편지함"),
      t(
        "Open to load private GitHub activity.",
        "열면 비공개 GitHub 활동을 불러옵니다.",
      ),
      "tray.full",
    ),
    cacheTtlMs: 0,
    sensitive: true,
  });
}

function prRow(pr: PullRequest, now: number): UINode {
  return ui.card([
    ui.hstack([
      ui.text(pr.repository || t("Repository", "저장소"), {
        role: "caption",
        foreground: "secondary",
        lineLimit: 1,
      }),
      ui.spacer(),
      pr.draft
        ? ui.badge(t("Draft", "초안"), { tone: "neutral" })
        : ui.badge(`#${pr.number}`, { tone: "accent" }),
    ], { spacing: 5 }),
    ui.text(pr.title, { lineLimit: 2 }),
    ui.hstack([
      ui.text(
        [
          pr.author ? t(`by ${pr.author}`, `${pr.author} 작성`) : "",
          relativeDate(pr.updatedAt, now),
        ]
          .filter(Boolean).join(" · "),
        {
          role: "caption",
          foreground: "secondary",
          lineLimit: 1,
        },
      ),
      ui.spacer(),
      ui.button(t("Review", "리뷰"), ui.action.openURL(pr.url), {
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
      ui.badge(reasonLabel(notification.reason), {
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
    content.push(
      ui.button(t("Open", "열기"), ui.action.openURL(notification.url), {
        icon: "arrow.up.right.square",
      }),
    );
  }
  return ui.card(content, {
    id: `notification-${notification.id}`,
    spacing: 4,
    padding: 7,
  });
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  language = typeof ctx.locale === "string" && /^ko(?:[-_]|$)/i.test(ctx.locale)
    ? "ko"
    : "en";
  const gh = await findGh(ctx);
  if (!gh) {
    await renderState(placeholder(
      t("GitHub CLI not found", "GitHub CLI를 찾을 수 없습니다"),
      t(
        "Install gh with Homebrew, then reopen this widget.",
        "Homebrew로 gh를 설치한 뒤 이 위젯을 다시 여세요.",
      ),
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
      ui.banner(
        t(
          "Run `gh auth login` in Terminal, then refresh.",
          "터미널에서 `gh auth login`을 실행한 뒤 새로 고치세요.",
        ),
        {
          title: t("GitHub sign-in required", "GitHub 로그인 필요"),
          tone: "warning",
        },
      ),
      placeholder(
        t("No authenticated account", "로그인된 계정 없음"),
        t(
          "Developer Inbox uses your existing gh session.",
          "개발자 받은편지함은 이미 로그인된 gh 세션을 사용합니다.",
        ),
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
    ui.hstack([
      ui.stat(t("Review requests", "리뷰 요청"), prs.length, {
        icon: "arrow.triangle.pull",
        tone: prs.length > 0 ? "warning" : "good",
      }),
      ui.stat(t("Unread", "읽지 않음"), notifications.length, {
        icon: "bell.fill",
        tone: notifications.length > 0 ? "accent" : "good",
      }),
    ], { spacing: 6 }),
  ];

  if (failed) {
    children.push(
      ui.banner(
        t(
          "Some GitHub data could not be loaded. Refresh to retry.",
          "일부 GitHub 데이터를 불러오지 못했습니다. 새로 고쳐 다시 시도하세요.",
        ),
        {
          title: t("Partial results", "일부 결과"),
          tone: "warning",
        },
      ),
    );
  }
  if (prs.length > 0) {
    children.push(
      ui.section(
        t("Review requested", "리뷰 요청됨"),
        prs.slice(0, limit).map((pr) => prRow(pr, ctx.now)),
        { spacing: 6 },
      ),
    );
  }
  if (showNotifications && notifications.length > 0) {
    children.push(
      ui.section(
        t("Notifications", "알림"),
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
        t("Inbox zero", "모두 확인함"),
        t(
          "No open review requests or unread notifications.",
          "열린 리뷰 요청도, 읽지 않은 알림도 없습니다.",
        ),
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
