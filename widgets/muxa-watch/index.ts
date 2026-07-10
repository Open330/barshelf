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
  icon: string;
  rank: number;
}

const STATE_STYLE: Record<AgentState, StateStyle> = {
  error: {
    label: "Error",
    tone: "danger",
    icon: "xmark.octagon.fill",
    rank: 0,
  },
  waiting_choice: {
    label: "Choose",
    tone: "warning",
    icon: "list.bullet.rectangle",
    rank: 1,
  },
  waiting_input: {
    label: "Needs input",
    tone: "warning",
    icon: "questionmark.circle.fill",
    rank: 2,
  },
  working: { label: "Working", tone: "good", icon: "bolt.fill", rank: 3 },
  starting: { label: "Starting", tone: "accent", icon: "hourglass", rank: 4 },
  idle: { label: "Idle", tone: "neutral", icon: "pause.circle.fill", rank: 5 },
  stopped: { label: "Stopped", tone: "neutral", icon: "stop.circle", rank: 6 },
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

function agentSubtitle(agent: MuxaAgent, now: number): string {
  const parts = [kindLabel(agent.kind)];
  const project = basename(agent.cwd);
  if (project && project !== agentTitle(agent)) parts.push(project);
  if (agent.model) parts.push(agent.model);
  if (
    agent.context_used_pct !== null && Number.isFinite(agent.context_used_pct)
  ) {
    parts.push(`${agent.context_used_pct.toFixed(0)}% ctx`);
  }
  if (agent.cost_usd !== null && Number.isFinite(agent.cost_usd)) {
    parts.push(`$${agent.cost_usd.toFixed(2)}`);
  }
  parts.push(`${age(agent.last_activity_at, now)} ago`);
  return parts.join(" · ");
}

function promptFor(agent: MuxaAgent): string | null {
  const prompt = agent.last_prompt ?? agent.last_notification;
  return prompt ? oneLine(prompt) : null;
}

function agentRow(
  agent: MuxaAgent,
  index: number,
  now: number,
  showPrompts: boolean,
): UINode {
  const style = STATE_STYLE[agent.state];
  const prompt = showPrompts ? promptFor(agent) : null;
  const stateAge = age(agent.state_entered_at, now);

  return ui.card([
    ui.hstack([
      ui.image(style.icon, { size: 15, tint: style.tone }),
      ui.vstack([
        ui.text(agentTitle(agent), { role: "label", lineLimit: 1 }),
        ui.text(agentSubtitle(agent, now), {
          role: "caption",
          foreground: "secondary",
          lineLimit: 1,
        }),
      ], { spacing: 1 }),
      ui.spacer(),
      ...(prompt
        ? [
          ui.button(
            undefined,
            ui.action.copyText(prompt, { toast: "Prompt copied" }),
            {
              icon: "doc.on.doc",
              tooltip: "Copy last prompt",
            },
          ),
        ]
        : []),
      ui.badge(`${style.label} · ${stateAge}`, { tone: style.tone }),
    ], { spacing: 6 }),
    ...(prompt
      ? [
        ui.text(prompt, {
          role: "caption",
          foreground: "secondary",
          lineLimit: 2,
        }),
      ]
      : []),
  ], { id: `agent-${index}`, tone: style.tone, spacing: 5, padding: 7 });
}

function sortedAgents(agents: MuxaAgent[]): MuxaAgent[] {
  return [...agents].sort((left, right) => {
    const rank = STATE_STYLE[left.state].rank - STATE_STYLE[right.state].rank;
    if (rank !== 0) return rank;
    return Date.parse(right.last_activity_at) -
      Date.parse(left.last_activity_at);
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
    const result = await ctx.exec.run({
      command: "muxa",
      args,
      parse: "json",
      timeoutMs: 4_000,
      sensitive: true,
    });
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
    const includeStopped = booleanSetting(ctx.settings.includeStopped, false);
    const showPrompts = booleanSetting(ctx.settings.showPrompts, true);
    const maxAgents = integerSetting(ctx.settings.maxAgents, 8, 1, 20);
    const agents = sortedAgents(snapshot.agents).filter((agent) =>
      includeStopped || agent.state !== "stopped"
    );
    const active = snapshot.agents.filter((agent) =>
      agent.state !== "stopped"
    ).length;
    const working = snapshot.agents.filter((agent) =>
      agent.state === "working"
    ).length;
    const attention = snapshot.agents.filter((agent) =>
      agent.state === "waiting_input" || agent.state === "waiting_choice" ||
      agent.state === "error"
    ).length;
    const visible = agents.slice(0, maxAgents);
    const hidden = Math.max(agents.length - visible.length, 0);

    if (agents.length === 0) {
      await ctx.render(
        ui.empty({
          icon: "checkmark.circle.fill",
          title: "No active agents",
          subtitle: "Tracked agents will appear here as soon as they start.",
        }),
        {
          status: { label: "Idle", tooltip: "No active muxa agents" },
          cacheTtlMs: 5_000,
          sensitive: true,
        },
      );
      return;
    }

    await ctx.render(
      ui.vstack([
        ui.hstack([
          ui.stat("Active", active, { icon: "person.2.fill", tone: "accent" }),
          ui.stat("Working", working, {
            icon: "bolt.fill",
            tone: working > 0 ? "good" : "neutral",
          }),
          ui.stat("Needs you", attention, {
            icon: "person.crop.circle.badge.exclamationmark",
            tone: attention > 0 ? "warning" : "neutral",
          }),
        ], { spacing: 6 }),
        ui.list(
          visible.map((agent, index) =>
            agentRow(agent, index, ctx.now, showPrompts)
          ),
          {
            spacing: 6,
          },
        ),
        ...(hidden > 0
          ? [
            ui.banner(
              `${hidden} more agent${
                hidden === 1 ? "" : "s"
              } hidden by the display limit.`,
              {
                tone: "neutral",
              },
            ),
          ]
          : []),
      ], { spacing: 8 }),
      {
        status: {
          label: statusLabel(attention, working, active),
          tooltip:
            `${active} active · ${working} working · ${attention} need you`,
        },
        cacheTtlMs: 5_000,
        sensitive: true,
      },
    );
  } catch (error) {
    await renderUnavailable(ctx, error);
  }
}

export default barshelf.widget({ load });
