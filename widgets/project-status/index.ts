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
    ?.slice("# branch.head ".length) ?? "Unknown";
  const oid = lines.find((line) => line.startsWith("# branch.oid "))
    ?.slice("# branch.oid ".length, "# branch.oid ".length + 7);
  const upstream = lines.find((line) => line.startsWith("# branch.upstream "))
    ?.slice("# branch.upstream ".length);
  const divergence = lines.find((line) => line.startsWith("# branch.ab "))
    ?.match(/\+(\d+)\s+-(\d+)/);
  const detached = head === "(detached)";

  return {
    branch: detached && oid ? `Detached @ ${oid}` : head,
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
    ui.header("Project Status", {
      icon: "point.3.connected.trianglepath.dotted",
    }),
    ui.empty({
      icon: "folder.badge.gearshape",
      title: "Choose a project",
      subtitle: message,
    }),
  ], { id: "project-status-setup", spacing: 8 });
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  const directory = settingString(ctx.settings, "projectDirectory");
  if (!directory) {
    await ctx.render(
      setupView("Open widget settings and select a Git repository."),
    );
    return;
  }
  if (!directory.startsWith("/")) {
    await ctx.render(
      setupView("Select an absolute path with the directory picker."),
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
        ui.header("Project Status", {
          icon: "point.3.connected.trianglepath.dotted",
        }),
        ui.banner(
          "The selected directory is unavailable or is not a Git repository.",
          {
            title: "Unable to read repository",
            tone: "warning",
          },
        ),
        ui.button("Open in Finder", ui.action.openFile(directory), {
          icon: "folder",
        }),
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
  const syncText = status.upstream
    ? `↑${status.ahead}  ↓${status.behind}`
    : "No upstream";
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
      remote.host.toLowerCase() === "github.com" ? "GitHub" : "Remote",
      ui.action.openURL(remote.url),
      { id: "open-remote", icon: "arrow.up.right.square" },
    ));
  }
  actions.push(
    ui.button("Refresh", ui.action.refresh(), {
      id: "refresh-project",
      icon: "arrow.clockwise",
    }),
  );

  await ctx.render(
    ui.vstack([
      ui.header(directoryName(directory), {
        icon: "point.3.connected.trianglepath.dotted",
        subtitle: status.branch,
        badge: clean ? "Clean" : `${status.dirtyFiles} changed`,
        badgeTone: clean ? "good" : "warning",
      }),
      ui.hstack([
        ui.stat("Branch", status.branch, {
          icon: status.detached ? "link.badge.plus" : "arrow.triangle.branch",
          tone: "accent",
        }),
        ui.stat(
          "Working tree",
          clean ? "Clean" : `${status.dirtyFiles} files`,
          {
            icon: clean ? "checkmark.circle.fill" : "pencil.circle.fill",
            tone: clean ? "good" : "warning",
          },
        ),
      ], { spacing: 6 }),
      ui.stat("Upstream", syncText, {
        icon: "arrow.up.arrow.down",
        caption: status.upstream ??
          "This branch is not tracking a remote branch.",
        tone: syncTone,
      }),
      commit
        ? ui.card([
          ui.hstack([
            ui.text("Last commit", {
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
        : ui.banner("This repository has no commits yet.", { tone: "neutral" }),
      ui.hstack(actions, { id: "project-actions", spacing: 6 }),
    ], { id: "project-status-root", spacing: 8 }),
    {
      status: {
        label: clean
          ? status.branch
          : `${status.branch} • ${status.dirtyFiles}`,
        tooltip: `${directoryName(directory)} · ${
          clean ? "clean" : `${status.dirtyFiles} changed`
        }`,
      },
      cacheTtlMs: 60_000,
      sensitive: true,
    },
  );
}

export default barshelf.widget({ load });
