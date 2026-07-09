import { barshelf, ui, type WidgetLoadContext } from "barshelf";

interface BatteryState {
  percent: number;
  source: string;
  status: string;
  detail: string;
}

function titleCase(value: string): string {
  return value.replace(/\b\w/g, (ch) => ch.toUpperCase());
}

function toneFor(percent: number, status: string): string {
  if (/charging|charged|ac attached/i.test(status)) {
    return "good";
  }
  if (percent <= 20) {
    return "danger";
  }
  if (percent <= 45) {
    return "warning";
  }
  return "good";
}

function symbolFor(percent: number, status: string): string {
  if (/charging|ac attached/i.test(status)) {
    return "bolt.fill";
  }
  if (percent <= 15) {
    return "battery.0percent";
  }
  if (percent <= 35) {
    return "battery.25percent";
  }
  if (percent <= 60) {
    return "battery.50percent";
  }
  if (percent <= 85) {
    return "battery.75percent";
  }
  return "battery.100percent";
}

function parsePmset(output: string): BatteryState {
  const source = output.match(/Now drawing from '([^']+)'/)?.[1] ?? "Battery";
  const batteryLine = output.split(/\r?\n/).find((line) => line.includes("%")) ?? output;
  const percent = Number(batteryLine.match(/(\d+(?:\.\d+)?)%/)?.[1] ?? 0);
  const parts = batteryLine.split(";").map((part) => part.trim()).filter(Boolean);
  const status = parts[1] ?? source;
  const detail = (parts[2] ?? "")
    .replace(/\s*present:\s*(true|false).*/i, "")
    .trim();
  return {
    percent: Math.min(Math.max(percent, 0), 100),
    source,
    status: titleCase(status),
    detail,
  };
}

async function load(ctx: WidgetLoadContext): Promise<void> {
  const result = await ctx.exec.run({
    command: "/usr/bin/pmset",
    args: ["-g", "batt"],
    parse: "text",
    timeoutMs: 5_000,
  });
  const battery = parsePmset(result.stdout);
  const tone = toneFor(battery.percent, battery.status);
  const symbol = symbolFor(battery.percent, battery.status);
  const caption = [battery.source, battery.detail].filter(Boolean).join(" · ");

  await ctx.render(
    ui.vstack([
      ui.header("Battery", {
        icon: symbol,
        badge: battery.status,
        badgeTone: tone,
        tint: tone,
      }),
      ui.metricCard("Charge", `${Math.round(battery.percent)}%`, {
        icon: symbol,
        tone,
        caption,
        progress: battery.percent / 100,
        progressLabel: `${Math.round(battery.percent)}%`,
      }),
      ui.hstack([
        ui.stat("Source", battery.source, { icon: "powerplug.fill", tone: "accent" }),
        ui.stat("State", battery.status, { icon: "waveform.path.ecg", tone }),
      ], { spacing: 6 }),
    ], { spacing: 8 }),
    {
      status: {
        label: `${Math.round(battery.percent)}%`,
        tooltip: `Battery ${Math.round(battery.percent)}% · ${battery.status}`,
      },
      cacheTtlMs: 300_000,
    },
  );
}

export default barshelf.widget({ load });
