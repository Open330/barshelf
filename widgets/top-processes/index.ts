import { barshelf, ui, type UINode, type WidgetLoadContext } from "barshelf";

/** The app's language, set at the start of each load. */
let language: "en" | "ko" = "en";

/** Fixed text: Korean when the app is in Korean, else the English. */
function t(english: string, korean: string): string {
  return language === "ko" ? korean : english;
}

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
  language = typeof ctx.locale === "string" && /^ko(?:[-_]|$)/i.test(ctx.locale)
    ? "ko"
    : "en";
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
        title: t("No active processes", "활성 프로세스 없음"),
        subtitle: t("CPU usage is idle.", "CPU가 거의 쉬고 있습니다."),
      }),
      {
        status: {
          label: t("Idle", "유휴"),
          tooltip: t("No CPU-heavy processes", "CPU를 많이 쓰는 프로세스 없음"),
        },
      },
    );
    return;
  }

  const total = processes.reduce((sum, item) => sum + item.cpu, 0);
  const topTone = toneFor(top.cpu);
  await ctx.render(
    ui.vstack([
      ui.metricCard(t("Peak CPU", "최고 CPU"), `${top.cpu.toFixed(1)}%`, {
        icon: "flame.fill",
        tone: topTone,
        caption: top.name,
        progress: Math.min(top.cpu / 100, 1),
        progressLabel: top.name,
      }),
      ui.hstack([
        ui.stat(t("Top total", "상위 합계"), `${total.toFixed(1)}%`, {
          icon: "sum",
          tone: "accent",
        }),
        ui.stat(t("Samples", "표본 수"), processes.length, {
          icon: "list.number",
          tone: "neutral",
        }),
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
