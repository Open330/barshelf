import {
  barshelf,
  JsonRpcError,
  ProtocolErrorCode,
  ui,
  type UINode,
  type WidgetLoadContext,
  type WidgetTimerContext,
} from "barshelf";

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

type GhFailure = "missing" | "auth" | "offline" | "rateLimited" | "timeout" | "error";

/** Reads why a gh call failed: a thrown host error, or a non-zero exit's stderr. */
function ghFailure(result: GhResult): GhFailure | undefined {
  if (result.thrown !== undefined) {
    const code = result.thrown instanceof JsonRpcError ? result.thrown.code : undefined;
    if (code === ProtocolErrorCode.ExecNotFound) return "missing";
    if (code === ProtocolErrorCode.Timeout) return "timeout";
    return "error";
  }
  if (result.exitCode === 0) return undefined;
  const text = result.stderr.toLowerCase();
  if (
    ["auth login", "not logged", "authentication", "bad credentials", "http 401"]
      .some((marker) => text.includes(marker))
  ) return "auth";
  if (
    [
      "could not resolve",
      "no such host",
      "dial tcp",
      "network is unreachable",
      "connection refused",
      "i/o timeout",
      "tls handshake timeout",
      "not connected to the internet",
      "error connecting to",
      "check your internet connection",
    ].some((marker) => text.includes(marker))
  ) return "offline";
  if (text.includes("rate limit")) return "rateLimited";
  return "error";
}

interface GhResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  thrown?: unknown;
}

/**
 * Runs gh, found by the host from the manifest's `source.discover`
 * (Homebrew on Apple silicon or Intel, then PATH). Never throws: a missing
 * gh or a timeout comes back as `thrown`.
 */
async function gh(
  exec: WidgetLoadContext["exec"],
  args: string[],
): Promise<GhResult> {
  try {
    const result = await exec.run({
      command: "gh",
      args,
      parse: "text",
      timeoutMs: 12_000,
      sensitive: true,
    });
    return { exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr ?? "" };
  } catch (error) {
    return { exitCode: -1, stdout: "", stderr: "", thrown: error };
  }
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
          relativeDate(pr.updatedAt, now),
          pr.author ? t(`by ${pr.author}`, `${pr.author} 작성`) : "",
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
  // Releases, discussions and check suites have no web URL we can derive;
  // they still open on GitHub's notification list.
  content.push(
    ui.button(
      t("Open", "열기"),
      ui.action.openURL(notification.url ?? "https://github.com/notifications"),
      { icon: "arrow.up.right.square" },
    ),
  );
  return ui.card(content, {
    id: `notification-${notification.id}`,
    spacing: 4,
    padding: 7,
  });
}

function failureView(failure: GhFailure): UINode {
  const retry = ui.button(t("Try Again", "다시 시도"), ui.action.refresh(), {
    id: "retry",
    icon: "arrow.clockwise",
  });
  switch (failure) {
    case "missing":
      return ui.vstack([
        placeholder(
          t("GitHub CLI not found", "GitHub CLI를 찾을 수 없습니다"),
          t(
            "Install gh (Homebrew: brew install gh), sign in, then try again.",
            "gh를 설치하고(Homebrew: brew install gh) 로그인한 뒤 다시 시도하세요.",
          ),
          "terminal",
        ),
        ui.hstack([
          ui.spacer(),
          ui.button(
            t("Get GitHub CLI", "GitHub CLI 받기"),
            ui.action.openURL("https://cli.github.com"),
            { id: "get-gh", icon: "arrow.down.circle" },
          ),
          retry,
          ui.spacer(),
        ], { spacing: 6 }),
      ], { spacing: 8 });
    case "auth":
      return ui.vstack([
        ui.banner(
          t(
            "Run gh auth login in Terminal, then try again.",
            "터미널에서 gh auth login을 실행한 뒤 다시 시도하세요.",
          ),
          {
            title: t("GitHub sign-in required", "GitHub 로그인 필요"),
            tone: "warning",
          },
        ),
        ui.hstack([
          ui.button(
            t("Copy gh auth login", "gh auth login 복사"),
            ui.action.copyText("gh auth login", { toast: t("Copied", "복사됨") }),
            { id: "copy-login", icon: "doc.on.doc" },
          ),
          retry,
          ui.spacer(),
        ], { spacing: 6 }),
      ], { spacing: 8 });
    case "offline":
      return placeholder(
        t("You’re offline", "오프라인 상태"),
        t(
          "Review requests come back when this Mac is online again.",
          "Mac이 다시 온라인이 되면 리뷰 요청이 돌아옵니다.",
        ),
        "wifi.slash",
      );
    case "rateLimited":
      return placeholder(
        t("GitHub is limiting requests", "GitHub이 요청을 제한하고 있음"),
        t("Trying again on the next refresh.", "다음 새로고침 때 다시 시도합니다."),
        "hourglass",
      );
    case "timeout":
      return ui.vstack([
        placeholder(
          t("GitHub didn’t answer in time", "GitHub이 제때 응답하지 않음"),
          t("Trying again on the next refresh.", "다음 새로고침 때 다시 시도합니다."),
          "clock.badge.exclamationmark",
        ),
        ui.hstack([ui.spacer(), retry, ui.spacer()]),
      ], { spacing: 8 });
    case "error":
      return ui.vstack([
        placeholder(
          t("GitHub couldn’t be read", "GitHub을 읽지 못했습니다"),
          t(
            "gh search prs failed. Try again, or run it in Terminal to see why.",
            "gh search prs가 실패했습니다. 다시 시도하거나 터미널에서 실행해 원인을 확인하세요.",
          ),
          "exclamationmark.triangle",
        ),
        ui.hstack([ui.spacer(), retry, ui.spacer()]),
      ], { spacing: 8 });
  }
}

const SEEN_KEY = "seen-review-requests";
const POLL_TIMER = "review-requests";
const POLL_MS = 10 * 60_000;

/** The last load's settings and language, for the background timer. */
let lastSettings: Record<string, unknown> = {};

/**
 * Opt-in: a notification for review requests that were not there at the
 * previous check. Only the PR URLs are kept (BarShelf storage), and only
 * while the setting is on; the first check after turning it on is the
 * baseline and never notifies.
 */
async function notifyNewReviews(prs: PullRequest[], enabled: boolean): Promise<void> {
  if (!enabled) {
    await barshelf.storage.delete(SEEN_KEY);
    return;
  }
  const seen = await barshelf.storage.get<string[]>(SEEN_KEY);
  const fresh = Array.isArray(seen)
    ? prs.filter((pr) => !seen.includes(pr.url))
    : [];
  await barshelf.storage.set(SEEN_KEY, prs.map((pr) => pr.url));
  if (fresh.length === 0) return;
  const first = fresh[0];
  await barshelf.notify.show({
    title: fresh.length === 1
      ? t("New review request", "새 리뷰 요청")
      : t(`${fresh.length} new review requests`, `새 리뷰 요청 ${fresh.length}개`),
    body: [first.repository, first.title].filter(Boolean).join(": "),
  });
}

async function refresh(
  exec: WidgetLoadContext["exec"],
  settings: Record<string, unknown>,
  now: number,
): Promise<void> {
  const showNotifications = settings.showNotifications !== false;
  const notifyReviews = settings.notifyReviewRequests === true;
  const limit = integerSetting(settings.itemLimit);
  const [prsResult, notificationsResult] = await Promise.all([
    gh(exec, PR_ARGS),
    showNotifications ? gh(exec, NOTIFICATION_ARGS) : Promise.resolve(undefined),
  ]);

  const prsFailure = ghFailure(prsResult);
  if (prsFailure) {
    // Nothing reliable to show: lead with what to do, not a zero.
    await renderState(failureView(prsFailure), "—");
    return;
  }

  const prs = parsePullRequests(prsResult.stdout);
  const notifications = notificationsResult && !ghFailure(notificationsResult)
    ? parseNotifications(notificationsResult.stdout)
    : [];
  const failed = showNotifications &&
    (notificationsResult === undefined || ghFailure(notificationsResult) !== undefined);
  const total = prs.length + notifications.length;
  try {
    await notifyNewReviews(prs, notifyReviews);
  } catch {
    // A notification or storage failure must not hide the inbox.
  }
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
        prs.slice(0, limit).map((pr) => prRow(pr, now)),
        { spacing: 6 },
      ),
    );
  }
  if (showNotifications && notifications.length > 0) {
    children.push(
      ui.section(
        t("Notifications", "알림"),
        notifications.slice(0, limit).map((item) =>
          notificationRow(item, now)
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
    failed && total === 0 ? "—" : String(total),
  );
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  language = typeof ctx.locale === "string" && /^ko(?:[-_]|$)/i.test(ctx.locale)
    ? "ko"
    : "en";
  lastSettings = ctx.settings;
  if (ctx.settings.notifyReviewRequests === true) {
    // Script timers keep running while the popup is closed, so a new
    // review request is noticed without the widget being on screen.
    await ctx.timer.every(POLL_TIMER, POLL_MS);
  } else {
    await ctx.timer.clear(POLL_TIMER);
  }
  await refresh(ctx.exec, ctx.settings, ctx.now);
}

async function timer(ctx: WidgetTimerContext, event: { id: string; now: number }): Promise<void> {
  if (event.id !== POLL_TIMER) return;
  await refresh(ctx.exec, lastSettings, event.now);
}

export default barshelf.widget({ load, timer });
