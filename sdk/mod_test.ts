import {
  barshelf,
  menuBar,
  type MenuBarPresentation,
  type StatusMetric,
} from "./mod.ts";

function assert(condition: unknown, message = "assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown): void {
  assert(JSON.stringify(actual) === JSON.stringify(expected),
    `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

function assertThrows(run: () => unknown, contains: string): void {
  try {
    run();
  } catch (error) {
    assert(error instanceof TypeError, "expected TypeError");
    assert(error.message.includes(contains), `missing ${contains}: ${error.message}`);
    return;
  }
  throw new Error("expected function to throw");
}

Deno.test("menuBar builds numeric and textual metrics with stable ids", () => {
  assert(barshelf.menuBar === menuBar, "menuBar should be available from barshelf");
  const cpu = menuBar.metric("cpu", 23.4, {
    label: "CPU",
    format: "percent",
    precision: 1,
  });
  const power = menuBar.metric("power", null, { label: "Power", unit: "W" });
  const state = menuBar.text("thermal-state", "Nominal", { label: "Thermal" });

  assertEquals(cpu, {
    id: "cpu", number: 23.4, format: "percent", label: "CPU", precision: 1,
  });
  assertEquals(power, {
    id: "power", number: null, format: "decimal", label: "Power", unit: "W",
  });
  assertEquals(state, { id: "thermal-state", value: "Nominal", label: "Thermal" });
});

Deno.test("menuBar status keeps sparse render presentation defaults", () => {
  const presentation: MenuBarPresentation = {
    showValues: true,
    showUnits: false,
    precision: 2,
    color: "monochrome",
    valueWidth: 72,
    metricOrder: ["ram", "cpu"],
    metricOverrides: { ram: { label: "Memory", tint: "accent" } },
  };
  const status = menuBar.status([
    menuBar.metric("cpu", 23, { format: "percent" }),
    menuBar.metric("ram", 12_800_000_000, { format: "bytes" }),
  ], { prefix: "System", presentation });

  assertEquals(status.prefix, "System");
  assertEquals(status.presentation, presentation);
  assertEquals(status.metrics?.map((metric) => metric.id), ["cpu", "ram"]);
});

Deno.test("menuBar rejects invalid numeric and presentation inputs", () => {
  assertThrows(() => menuBar.metric("cpu", Number.NaN), "finite number");
  assertThrows(() => menuBar.metric("cpu", Infinity), "finite number");
  assertThrows(() => menuBar.metric("not a stable id", 1), "stable id");
  assertThrows(() => menuBar.status([
    menuBar.metric("cpu", 1),
    menuBar.metric("ram", 2),
    menuBar.metric("power", 3),
  ]), "at most two");
  assertThrows(() => menuBar.status([
    menuBar.metric("cpu", 1),
    menuBar.metric("cpu", 2),
  ]), "duplicate metric id");
  assertThrows(() => menuBar.status([], { presentation: { precision: 4 } as unknown as MenuBarPresentation }), "0 through 3");
  assertThrows(() => menuBar.status([], { presentation: { valueWidth: 121 } }), "32 through 120");
  assertThrows(() => menuBar.status([], { presentation: { color: "blue" } as unknown as MenuBarPresentation }), "semantic tint");
  assertThrows(() => menuBar.status([], { presentation: { metricOrder: ["cpu", "cpu"] } }), "duplicate id");

  const invalid: StatusMetric = { id: "cpu", number: Infinity };
  assertThrows(() => menuBar.status([invalid]), "finite number");
});
