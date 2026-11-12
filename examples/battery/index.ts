import { barshelf, ui, type WidgetLoadContext } from "barshelf";

/** Fixed text in the app's language: Korean, else the English as written. */
type Language = "en" | "ko";

function languageOf(locale: unknown): Language {
  return typeof locale === "string" && /^ko(?:[-_]|$)/i.test(locale)
    ? "ko"
    : "en";
}

const KOREAN: Record<string, string> = {
  "Charge": "충전량",
  "Source": "전원",
  "State": "상태",
  // pmset's own words, shown as reported in English.
  "Battery": "배터리",
  "Battery Power": "배터리",
  "AC Power": "전원 어댑터",
  "Charging": "충전 중",
  "Discharging": "방전 중",
  "Charged": "충전 완료",
  "Finishing Charge": "충전 마무리 중",
  "AC Attached": "전원 연결됨",
};

function word(text: string, language: Language): string {
  return language === "ko" ? KOREAN[text] ?? text : text;
}

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
  const batteryLine =
    output.split(/\r?\n/).find((line) => line.includes("%")) ?? output;
  const percent = Number(batteryLine.match(/(\d+(?:\.\d+)?)%/)?.[1] ?? 0);
  const parts = batteryLine.split(";").map((part) => part.trim()).filter(
    Boolean,
  );
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
  const language = languageOf(ctx.locale);
  const battery = parsePmset(result.stdout);
  const tone = toneFor(battery.percent, battery.status);
  const symbol = symbolFor(battery.percent, battery.status);
  // Tone and symbol read pmset's English; only what is shown is translated.
  const source = word(battery.source, language);
  const state = word(battery.status, language);
  const caption = [source, battery.detail].filter(Boolean).join(" · ");

  await ctx.render(
    ui.vstack([
      ui.metricCard(
        word("Charge", language),
        `${Math.round(battery.percent)}%`,
        {
          icon: symbol,
          tone,
          caption,
          progress: battery.percent / 100,
          progressLabel: `${Math.round(battery.percent)}%`,
        },
      ),
      ui.hstack([
        ui.stat(word("Source", language), source, {
          icon: "powerplug.fill",
          tone: "accent",
        }),
        ui.stat(word("State", language), state, {
          icon: "waveform.path.ecg",
          tone,
        }),
      ], { spacing: 6 }),
    ], { spacing: 8 }),
    {
      status: {
        label: `${Math.round(battery.percent)}%`,
        tooltip: language === "ko"
          ? `배터리 ${Math.round(battery.percent)}% · ${state}`
          : `Battery ${Math.round(battery.percent)}% · ${battery.status}`,
      },
      cacheTtlMs: 300_000,
    },
  );
}

export default barshelf.widget({ load });
