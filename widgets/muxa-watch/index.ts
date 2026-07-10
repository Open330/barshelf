import { barshelf, ui, type UINode, type WidgetLoadContext } from "barshelf";

type AgentState =
  | "starting"
  | "working"
  | "idle"
  | "waiting_input"
  | "waiting_choice"
  | "error"
  | "stopped";

interface MuxaAgent {
  kind: string;
  session_id: string;
  state: AgentState;
  pane: string | null;
  location: string;
  cwd: string | null;
  model: string | null;
  last_prompt: string | null;
  last_notification: string | null;
  context_used_pct: number | null;
  cost_usd: number | null;
  started_at: string;
  last_activity_at: string;
  state_entered_at: string;
}

interface MuxaStatus {
  schema_version: number;
  generated_at: string;
  agents: MuxaAgent[];
}

interface StateStyle {
  label: string;
  tone: string;
  marker: string;
}

interface PreparedView {
  root: UINode;
  status: { label: string; tooltip: string };
}

const runtimeState = { hasRendered: false };

const STATE_STYLE: Record<AgentState, StateStyle> = {
  error: {
    label: "Error",
    tone: "danger",
    marker: "■",
  },
  waiting_choice: {
    label: "Choose",
    tone: "warning",
    marker: "◆",
  },
  waiting_input: {
    label: "Needs input",
    tone: "warning",
    marker: "▶",
  },
  working: { label: "Working", tone: "good", marker: "●" },
  starting: { label: "Starting", tone: "accent", marker: "◌" },
  idle: { label: "Idle", tone: "neutral", marker: "○" },
  stopped: { label: "Stopped", tone: "neutral", marker: "×" },
};

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAgentState(value: unknown): value is AgentState {
  return typeof value === "string" && value in STATE_STYLE;
}

function parseStatus(value: unknown): MuxaStatus {
  if (
    !isRecord(value) || value.schema_version !== 1 ||
    !Array.isArray(value.agents)
  ) {
    throw new Error("unsupported muxa status payload");
  }

  const agents = value.agents.filter((item): item is MuxaAgent =>
    isRecord(item) &&
    typeof item.kind === "string" &&
    typeof item.session_id === "string" &&
    isAgentState(item.state) &&
    typeof item.location === "string" &&
    typeof item.last_activity_at === "string" &&
    typeof item.state_entered_at === "string"
  );

  return {
    schema_version: 1,
    generated_at: typeof value.generated_at === "string"
      ? value.generated_at
      : new Date().toISOString(),
    agents,
  };
}

function booleanSetting(value: unknown, fallback: boolean): boolean {
  return typeof value === "boolean" ? value : fallback;
}

function integerSetting(
  value: unknown,
  fallback: number,
  min: number,
  max: number,
): number {
  const number = typeof value === "number" ? Math.round(value) : fallback;
  return Math.min(Math.max(number, min), max);
}

function kindLabel(kind: string): string {
  switch (kind) {
    case "claude_code":
      return "Claude Code";
    case "codex":
      return "Codex";
    case "gemini_cli":
      return "Gemini CLI";
    case "opencode":
      return "opencode";
    case "task":
      return "Task";
    default:
      return kind.replaceAll("_", " ");
  }
}

function basename(path: string | null): string | null {
  if (!path) return null;
  const parts = path.split("/").filter(Boolean);
  return parts.at(-1) ?? path;
}

function age(iso: string, now: number): string {
  const timestamp = Date.parse(iso);
  if (!Number.isFinite(timestamp)) return "now";
  const seconds = Math.max(0, Math.floor((now - timestamp) / 1000));
  if (seconds < 60) return `${seconds}s`;
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h`;
  return `${Math.floor(hours / 24)}d`;
}

function oneLine(value: string, maxLength = 160): string {
  const compact = value.replace(/\s+/g, " ").trim();
  return compact.length > maxLength
    ? `${compact.slice(0, maxLength - 1)}…`
    : compact;
}

function agentTitle(agent: MuxaAgent): string {
  if (agent.location && agent.location !== "-") return agent.location;
  return basename(agent.cwd) ?? kindLabel(agent.kind);
}

function promptFor(agent: MuxaAgent): string | null {
  const prompt = agent.last_prompt ?? agent.last_notification;
  return prompt ? oneLine(prompt) : null;
}

function agentTableRow(
  agent: MuxaAgent,
  index: number,
  now: number,
  showPrompts: boolean,
): UINode {
  const style = STATE_STYLE[agent.state];
  const prompt = showPrompts ? promptFor(agent) ?? "-" : "-";
  return ui.hstack([
    ui.text(agentTitle(agent), {
      role: "body",
      lineLimit: 1,
      widthFill: true,
    }),
    ui.text(style.marker, {
      role: "code",
      foreground: style.tone,
      accessibilityLabel: style.label,
    }),
    ui.text(age(agent.last_activity_at, now), {
      role: "code",
      foreground: "secondary",
      monospacedDigit: true,
      lineLimit: 1,
    }),
    ui.text(oneLine(prompt, 80), {
      role: "caption",
      foreground: prompt === "-" ? "tertiary" : "primary",
      lineLimit: 1,
      widthFill: true,
    }),
  ], { id: `agent-${index}`, spacing: 7, padding: 3 });
}

function sortedAgents(agents: MuxaAgent[]): MuxaAgent[] {
  return [...agents].sort((left, right) => {
    const activity = Date.parse(right.last_activity_at) -
      Date.parse(left.last_activity_at);
    return activity !== 0
      ? activity
      : agentTitle(left).localeCompare(agentTitle(right));
  });
}

function statusLabel(
  attention: number,
  working: number,
  active: number,
): string {
  if (attention > 0) return `⚠ ${attention}`;
  if (working > 0) return `● ${working}`;
  return active > 0 ? String(active) : "Idle";
}

function redactedCacheStatus(snapshot: MuxaStatus): MuxaStatus {
  return {
    ...snapshot,
    agents: snapshot.agents.map((agent) => ({
      ...agent,
      session_id: "",
      pane: null,
      cwd: null,
      model: null,
      last_prompt: null,
      last_notification: null,
      context_used_pct: null,
      cost_usd: null,
    })),
  };
}

function prepareStatusView(
  ctx: WidgetLoadContext,
  snapshot: MuxaStatus,
  redacted = false,
): PreparedView {
  const includeStopped = booleanSetting(ctx.settings.includeStopped, false);
  const showPrompts = !redacted &&
    booleanSetting(ctx.settings.showPrompts, true);
  const maxAgents = integerSetting(ctx.settings.maxAgents, 5, 1, 10);
  const agents = sortedAgents(snapshot.agents).filter((agent) =>
    includeStopped || agent.state !== "stopped"
  );
  const active =
    snapshot.agents.filter((agent) => agent.state !== "stopped").length;
  const working =
    snapshot.agents.filter((agent) => agent.state === "working").length;
  const attention =
    snapshot.agents.filter((agent) =>
      agent.state === "waiting_input" || agent.state === "waiting_choice" ||
      agent.state === "error"
    ).length;
  const status = {
    label: statusLabel(attention, working, active),
    tooltip: `${active} active · ${working} working · ${attention} need you`,
  };

  if (agents.length === 0) {
    return {
      root: ui.empty({
        icon: "checkmark.circle.fill",
        title: "No active agents",
        subtitle: "Tracked agents will appear here as soon as they start.",
      }),
      status: { label: "Idle", tooltip: "No active muxa agents" },
    };
  }

  const visible = agents.slice(0, maxAgents);
  const hidden = Math.max(agents.length - visible.length, 0);
  const rows: UINode[] = [];
  for (const [index, agent] of visible.entries()) {
    rows.push(agentTableRow(agent, index, ctx.now, showPrompts));
    if (index < visible.length - 1) rows.push(ui.divider());
  }
  return {
    root: ui.vstack([
      ui.hstack([
        ui.text("NAME", {
          role: "caption",
          foreground: "secondary",
          widthFill: true,
        }),
        ui.text("ST", { role: "caption", foreground: "secondary" }),
        ui.text("ACT", {
          role: "caption",
          foreground: "secondary",
          monospacedDigit: true,
        }),
        ui.text("LAST PROMPT", {
          role: "caption",
          foreground: "secondary",
          widthFill: true,
        }),
      ], { spacing: 7, padding: 3 }),
      ui.divider(),
      ...rows,
      ...(hidden > 0
        ? [
          ui.hstack([
            ui.spacer(),
            ui.text(`+${hidden} older`, {
              role: "caption",
              foreground: "tertiary",
            }),
          ]),
        ]
        : []),
    ], { spacing: 5 }),
    status,
  };
}

async function renderUnavailable(
  ctx: WidgetLoadContext,
  error: unknown,
): Promise<void> {
  const message = error instanceof Error ? error.message : String(error);
  await ctx.log("warn", `muxa status failed: ${oneLine(message, 240)}`);
  const missing = /not found|ExecNotFound/i.test(message);
  const outdated = /does not support status --json/i.test(message);

  await ctx.render(
    ui.empty({
      icon: missing || outdated ? "terminal" : "bolt.horizontal.circle",
      title: missing
        ? "muxa CLI not found"
        : outdated
        ? "Update muxa CLI"
        : "muxa is unavailable",
      subtitle: missing
        ? "Install muxa or set MUXA_BIN, then refresh this widget."
        : outdated
        ? "This widget needs a muxa build that supports status --json."
        : "Make sure muxad is running and the socket setting is correct.",
    }),
    {
      status: { label: "Offline", tooltip: "muxa status is unavailable" },
      cacheTtlMs: 5_000,
      sensitive: false,
    },
  );
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  try {
    const socket = typeof ctx.settings.socket === "string"
      ? ctx.settings.socket.trim()
      : "";
    const args = socket
      ? ["--socket", socket, "status", "--json"]
      : ["status", "--json"];
    let result = await ctx.exec.run({
      command: "muxa",
      args,
      parse: "json",
      timeoutMs: 4_000,
      sensitive: true,
    });
    if (result.exitCode !== 0) {
      // The daemon can briefly hit the CLI's IPC deadline during a burst of
      // hook traffic. One short retry prevents a transient miss from replacing
      // a useful menu-bar snapshot with an offline state.
      await new Promise((resolve) => setTimeout(resolve, 250));
      result = await ctx.exec.run({
        command: "muxa",
        args,
        parse: "json",
        timeoutMs: 4_000,
        sensitive: true,
      });
    }
    if (result.exitCode !== 0) {
      if (
        /unexpected argument ['\"]--json['\"]|unknown option.*--json/i.test(
          result.stderr,
        )
      ) {
        throw new Error("muxa CLI does not support status --json");
      }
      throw new Error(`muxa exited with code ${result.exitCode}`);
    }

    const snapshot = parseStatus(result.json);
    const live = prepareStatusView(ctx, snapshot);
    const fallback = prepareStatusView(
      ctx,
      redactedCacheStatus(snapshot),
      true,
    );
    await ctx.render(
      live.root,
      {
        status: live.status,
        cacheRoot: fallback.root,
        cacheTtlMs: 5_000,
        sensitive: true,
      },
    );
    runtimeState.hasRendered = true;
  } catch (error) {
    if (runtimeState.hasRendered) {
      const message = error instanceof Error ? error.message : String(error);
      await ctx.log(
        "warn",
        `muxa refresh kept last good render: ${oneLine(message, 240)}`,
      );
      return;
    }
    await renderUnavailable(ctx, error);
  }
}

export default barshelf.widget({ load });
