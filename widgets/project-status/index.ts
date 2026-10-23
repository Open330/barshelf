import { barshelf, ui, type UINode, type WidgetLoadContext } from "barshelf";

interface GitStatus {
  branch: string;
  upstream?: string;
  ahead: number;
  behind: number;
  dirtyFiles: number;
  detached: boolean;
}

interface LastCommit {
  hash: string;
  subject: string;
  timestampMs: number;
}

/** The app's language, set at the start of each load. */
let language: "en" | "ko" = "en";

/** Fixed text: Korean when the app is in Korean, else the English. */
function t(english: string, korean: string): string {
  return language === "ko" ? korean : english;
}

function settingString(settings: Record<string, unknown>, key: string): string {
  const value = settings[key];
  return typeof value === "string" ? value.trim() : "";
}

function directoryName(path: string): string {
  const normalized = path.replace(/\/+$/, "");
  return normalized.split("/").filter(Boolean).pop() ?? path;
}

function parseStatus(output: string): GitStatus {
  const lines = output.split(/\r?\n/).filter(Boolean);
  const head = lines.find((line) => line.startsWith("# branch.head "))
    ?.slice("# branch.head ".length);
  const oid = lines.find((line) => line.startsWith("# branch.oid "))
    ?.slice("# branch.oid ".length, "# branch.oid ".length + 7);
  const upstream = lines.find((line) => line.startsWith("# branch.upstream "))
    ?.slice("# branch.upstream ".length);
  const divergence = lines.find((line) => line.startsWith("# branch.ab "))
    ?.match(/\+(\d+)\s+-(\d+)/);
  const detached = head === "(detached)";

  return {
    branch: detached && oid
      ? t(`Detached @ ${oid}`, `분리된 HEAD @ ${oid}`)
      : head ?? t("Unknown", "알 수 없음"),
    upstream,
    ahead: Number(divergence?.[1] ?? 0),
    behind: Number(divergence?.[2] ?? 0),
    dirtyFiles: lines.filter((line) => !line.startsWith("# ")).length,
    detached,
  };
}

function parseCommit(output: string): LastCommit | null {
  const [hash, subject, timestamp] = output.trim().split("\x1f");
  const timestampMs = Number(timestamp) * 1000;
  if (!hash || !subject || !Number.isFinite(timestampMs)) {
    return null;
  }
  return { hash, subject, timestampMs };
}

function relativeDate(
  timestampMs: number,
  nowMs: number,
  locale: string,
): string {
  const deltaSeconds = Math.round((timestampMs - nowMs) / 1000);
  const formatter = new Intl.RelativeTimeFormat(locale, { numeric: "auto" });
  if (Math.abs(deltaSeconds) < 60) {
    return formatter.format(deltaSeconds, "second");
  }
  const deltaMinutes = Math.round(deltaSeconds / 60);
  if (Math.abs(deltaMinutes) < 60) {
    return formatter.format(deltaMinutes, "minute");
  }
  const deltaHours = Math.round(deltaMinutes / 60);
  if (Math.abs(deltaHours) < 24) return formatter.format(deltaHours, "hour");
  return formatter.format(Math.round(deltaHours / 24), "day");
}

function webRemote(remote: string): { url: string; host: string } | null {
  const trimmed = remote.trim().replace(/\.git$/, "");
  const scp = trimmed.match(/^git@([^:]+):(.+)$/);
  const ssh = trimmed.match(/^ssh:\/\/(?:git@)?([^/]+)\/(.+)$/);
  if (scp) return { url: `https://${scp[1]}/${scp[2]}`, host: scp[1] };
  if (ssh) return { url: `https://${ssh[1]}/${ssh[2]}`, host: ssh[1] };

  try {
    const url = new URL(trimmed);
    if (url.protocol !== "https:" && url.protocol !== "http:") return null;
    url.username = "";
    url.password = "";
    return { url: url.toString().replace(/\/$/, ""), host: url.hostname };
  } catch {
    return null;
  }
}

function setupView(message: string): UINode {
  return ui.vstack([
    ui.empty({
      icon: "folder.badge.gearshape",
      title: t("Choose a project", "프로젝트 선택"),
      subtitle: message,
    }),
  ], { id: "project-status-setup", spacing: 8 });
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  language = typeof ctx.locale === "string" && /^ko(?:[-_]|$)/i.test(ctx.locale)
    ? "ko"
    : "en";
  const directory = settingString(ctx.settings, "projectDirectory");
  if (!directory) {
    await ctx.render(
      setupView(
        t(
          "Open widget settings and select a Git repository.",
          "위젯 설정을 열고 Git 저장소를 고르세요.",
        ),
      ),
    );
    return;
  }
  if (!directory.startsWith("/")) {
    await ctx.render(
      setupView(
        t(
          "Select an absolute path with the directory picker.",
          "폴더 선택기로 절대 경로를 고르세요.",
        ),
      ),
    );
    return;
  }

  const [statusResult, commitResult, remoteResult] = await Promise.all([
    ctx.exec.run({
      command: "/usr/bin/git",
      args: [
        "-C",
        directory,
        "status",
        "--porcelain=v2",
        "--branch",
        "--untracked-files=normal",
      ],
      parse: "text",
      timeoutMs: 5_000,
      sensitive: true,
    }),
    ctx.exec.run({
      command: "/usr/bin/git",
      args: ["-C", directory, "log", "-1", "--format=%h%x1f%s%x1f%ct"],
      parse: "text",
      timeoutMs: 5_000,
      sensitive: true,
    }),
    ctx.exec.run({
      command: "/usr/bin/git",
      args: ["-C", directory, "remote", "get-url", "origin"],
      parse: "text",
      timeoutMs: 5_000,
      sensitive: true,
    }),
  ]);

  if (statusResult.exitCode !== 0) {
    await ctx.render(
      ui.vstack([
        ui.banner(
          t(
            "The selected directory is unavailable or is not a Git repository.",
            "선택한 폴더를 열 수 없거나 Git 저장소가 아닙니다.",
          ),
          {
            title: t("Unable to read repository", "저장소를 읽을 수 없음"),
            tone: "warning",
          },
        ),
        ui.button(
          t("Open in Finder", "Finder에서 열기"),
          ui.action.openFile(directory),
          {
            icon: "folder",
          },
        ),
      ], { id: "project-status-error", spacing: 8 }),
      { sensitive: true },
    );
    return;
  }

  const status = parseStatus(statusResult.stdout);
  const commit = commitResult.exitCode === 0
    ? parseCommit(commitResult.stdout)
    : null;
  const remote = remoteResult.exitCode === 0
    ? webRemote(remoteResult.stdout)
    : null;
  const clean = status.dirtyFiles === 0;
  const cleanText = t("Clean", "깨끗함");
  const changedText = t(
    `${status.dirtyFiles} changed`,
    `${status.dirtyFiles}개 변경됨`,
  );
  const syncText = status.upstream
    ? `↑${status.ahead}  ↓${status.behind}`
    : t("No upstream", "업스트림 없음");
  const syncTone = status.behind > 0
    ? "warning"
    : status.ahead > 0
    ? "accent"
    : "good";

  const actions: UINode[] = [
    ui.button("Finder", ui.action.openFile(directory), {
      id: "open-project",
      icon: "folder",
    }),
  ];
  if (remote) {
    actions.push(ui.button(
      remote.host.toLowerCase() === "github.com"
        ? "GitHub"
        : t("Remote", "원격"),
      ui.action.openURL(remote.url),
      { id: "open-remote", icon: "arrow.up.right.square" },
    ));
  }
  actions.push(
    ui.button(t("Refresh", "새로 고침"), ui.action.refresh(), {
      id: "refresh-project",
      icon: "arrow.clockwise",
    }),
  );

  await ctx.render(
    ui.vstack([
      ui.header(directoryName(directory), {
        subtitle: status.branch,
        badge: clean ? cleanText : changedText,
        badgeTone: clean ? "good" : "warning",
      }),
      ui.hstack([
        ui.stat(t("Branch", "브랜치"), status.branch, {
          icon: status.detached ? "link.badge.plus" : "arrow.triangle.branch",
          tone: "accent",
        }),
        ui.stat(
          t("Working tree", "작업 트리"),
          clean
            ? cleanText
            : t(`${status.dirtyFiles} files`, `파일 ${status.dirtyFiles}개`),
          {
            icon: clean ? "checkmark.circle.fill" : "pencil.circle.fill",
            tone: clean ? "good" : "warning",
          },
        ),
      ], { spacing: 6 }),
      ui.stat(t("Upstream", "업스트림"), syncText, {
        icon: "arrow.up.arrow.down",
        caption: status.upstream ??
          t(
            "This branch is not tracking a remote branch.",
            "이 브랜치는 원격 브랜치를 추적하지 않습니다.",
          ),
        tone: syncTone,
      }),
      commit
        ? ui.card([
          ui.hstack([
            ui.text(t("Last commit", "마지막 커밋"), {
              role: "caption",
              foreground: "secondary",
            }),
            ui.spacer(),
            ui.badge(commit.hash, { tone: "neutral" }),
          ]),
          ui.text(commit.subject, { lineLimit: 2 }),
          ui.text(relativeDate(commit.timestampMs, ctx.now, ctx.locale), {
            role: "caption",
            foreground: "secondary",
          }),
        ], { id: "last-commit", spacing: 4, tone: "neutral" })
        : ui.banner(
          t(
            "This repository has no commits yet.",
            "이 저장소에는 아직 커밋이 없습니다.",
          ),
          { tone: "neutral" },
        ),
      ui.hstack(actions, { id: "project-actions", spacing: 6 }),
    ], { id: "project-status-root", spacing: 8 }),
    {
      status: {
        label: clean
          ? status.branch
          : `${status.branch} • ${status.dirtyFiles}`,
        tooltip: `${directoryName(directory)} · ${
          clean ? t("clean", "깨끗함") : changedText
        }`,
      },
      cacheTtlMs: 60_000,
      sensitive: true,
    },
  );
}

export default barshelf.widget({ load });
