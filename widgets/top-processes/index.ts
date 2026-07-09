import { barshelf, ui, type UINode, type WidgetLoadContext } from "barshelf";

interface ProcessUsage {
  name: string;
  cpu: number;
}

function displayName(command: string): string {
  const base = command.split("/").filter(Boolean).pop() ?? command;
  return base.length > 28 ? `${base.slice(0, 25)}...` : base;
}

function toneFor(cpu: number): string {
  if (cpu >= 50) {
    return "danger";
  }
  if (cpu >= 20) {
    return "warning";
  }
  return "accent";
}

function parseProcesses(output: string): ProcessUsage[] {
  return output
    .split(/\r?\n/)
    .slice(1)
    .map((line) => line.trim())
    .map((line) => {
      const match = line.match(/^(.*?)\s+([0-9]+(?:\.[0-9]+)?)$/);
      if (!match) {
        return null;
      }
      return {
        name: displayName(match[1].trim()),
        cpu: Number(match[2]),
      };
    })
    .filter((item): item is ProcessUsage => item !== null && item.cpu > 0)
    .slice(0, 5);
}

function processRow(item: ProcessUsage, index: number): UINode {
  const tone = toneFor(item.cpu);
  const cpu = `${item.cpu.toFixed(1)}%`;
  return ui.card([
    ui.hstack([
      ui.text(`#${index + 1}`, {
        role: "caption",
        foreground: "secondary",
        monospacedDigit: true,
      }),
      ui.text(item.name, { lineLimit: 1 }),
      ui.spacer(),
      ui.badge(cpu, { tone }),
    ], { spacing: 6 }),
    ui.progress(Math.min(item.cpu / 100, 1), { tint: tone }),
  ], { id: `process-${index}-${item.name}`, tone, spacing: 5, padding: 7 });
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  const result = await ctx.exec.run({
    command: "/bin/ps",
    args: ["-axo", "comm,%cpu", "-r"],
    parse: "text",
    timeoutMs: 5_000,
  });
  const processes = parseProcesses(result.stdout);
  const top = processes[0];

  if (!top) {
    await ctx.render(
      ui.empty({
        icon: "cpu",
        title: "No active processes",
        subtitle: "CPU usage is idle.",
      }),
      { status: { label: "Idle", tooltip: "No CPU-heavy processes" } },
    );
    return;
  }

  const total = processes.reduce((sum, item) => sum + item.cpu, 0);
  const topTone = toneFor(top.cpu);
  await ctx.render(
    ui.vstack([
      ui.header("Top Processes", {
        icon: "cpu.fill",
        badge: `${processes.length} active`,
        badgeTone: "accent",
      }),
      ui.metricCard("Peak CPU", `${top.cpu.toFixed(1)}%`, {
        icon: "flame.fill",
        tone: topTone,
        caption: top.name,
        progress: Math.min(top.cpu / 100, 1),
        progressLabel: top.name,
      }),
      ui.hstack([
        ui.stat("Top total", `${total.toFixed(1)}%`, { icon: "sum", tone: "accent" }),
        ui.stat("Samples", processes.length, { icon: "list.number", tone: "neutral" }),
      ], { spacing: 6 }),
      ui.list(processes.map(processRow), { spacing: 6 }),
    ], { spacing: 8 }),
    {
      status: {
        label: `${top.cpu.toFixed(0)}%`,
        tooltip: `${top.name}: ${top.cpu.toFixed(1)}% CPU`,
      },
      cacheTtlMs: 120_000,
    },
  );
}

export default barshelf.widget({ load });
