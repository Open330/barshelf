function assert(condition: unknown, message = "assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

async function json(path: string): Promise<unknown> {
  return JSON.parse(await Deno.readTextFile(new URL(path, import.meta.url)));
}

interface Validate {
  (value: unknown): boolean;
  errors?: unknown;
}

interface AjvLike {
  addSchema(schema: unknown): void;
  getSchema(id: string): Validate | undefined;
  errorsText(errors: unknown): string;
}

async function validator(): Promise<AjvLike> {
  const Ajv = AjvModule as unknown as new (
    options: { allErrors: boolean; strict: boolean },
  ) => AjvLike;
  const addFormats = addFormatsModule as unknown as (instance: AjvLike) => void;
  const ajv = new Ajv({ allErrors: true, strict: false });
  addFormats(ajv);
  const schemas = await Promise.all([
    json("./widget-0.1.json"),
    json("./workflow-0.1.json"),
    json("./registry-0.1.json"),
  ]);
  for (const schema of schemas) ajv.addSchema(schema);
  return ajv;
}

Deno.test("JSON Schemas compile and validate bundled manifest, workflow, and registry documents", async () => {
  const ajv = await validator();
  const [networkManifest, networkWorkflow, systemManifest, systemWorkflow, sensorsManifest, sensorsWorkflow, registry] = await Promise.all([
    json("../widgets/network/widget.json"),
    json("../widgets/network/workflow.json"),
    json("../widgets/system/widget.json"),
    json("../widgets/system/workflow.json"),
    json("../widgets/sensors/widget.json"),
    json("../widgets/sensors/workflow.json"),
    json("../registry/index.json"),
  ]);
  for (const [id, value] of [
    ["https://barshelf.jiun.dev/schema/widget-0.1.json", networkManifest],
    ["https://barshelf.jiun.dev/schema/workflow-0.1.json", networkWorkflow],
    ["https://barshelf.jiun.dev/schema/widget-0.1.json", systemManifest],
    ["https://barshelf.jiun.dev/schema/workflow-0.1.json", systemWorkflow],
    ["https://barshelf.jiun.dev/schema/widget-0.1.json", sensorsManifest],
    ["https://barshelf.jiun.dev/schema/workflow-0.1.json", sensorsWorkflow],
    ["https://barshelf.jiun.dev/schema/registry-0.1.json", registry],
  ] as const) {
    const validate = ajv.getSchema(id);
    assert(validate, `missing validator ${id}`);
    assert(validate(value), `${id}: ${ajv.errorsText(validate.errors)}`);
  }
});

Deno.test("JSON Schemas reject invalid menu-bar presentation values", async () => {
  const ajv = await validator();
  const widget = ajv.getSchema("https://barshelf.jiun.dev/schema/widget-0.1.json")!;
  const workflow = ajv.getSchema("https://barshelf.jiun.dev/schema/workflow-0.1.json")!;
  const validWidget = await json("../widgets/network/widget.json") as Record<string, unknown>;
  const validWorkflow = await json("../widgets/network/workflow.json") as Record<string, unknown>;
  assert(widget(validWidget), `network widget baseline: ${ajv.errorsText(widget.errors)}`);
  assert(workflow(validWorkflow), `network workflow baseline: ${ajv.errorsText(workflow.errors)}`);

  const widthOutOfRange = structuredClone(validWidget);
  widthOutOfRange.statusItem = { mode: "text", presentation: { valueWidth: 121 } };
  assert(!widget(widthOutOfRange), "widget schema accepted out-of-range width");

  const presentationPrecisionOutOfRange = structuredClone(validWorkflow);
  presentationPrecisionOutOfRange.status = { presentation: { precision: 4 } };
  assert(!workflow(presentationPrecisionOutOfRange), "workflow schema accepted out-of-range precision");

  const metricPrecisionOutOfRange = structuredClone(validWorkflow);
  metricPrecisionOutOfRange.status = {
    metrics: [{ id: "cpu", number: 12, format: "percent", precision: 4 }],
  };
  assert(!workflow(metricPrecisionOutOfRange), "workflow schema accepted out-of-range metric precision");
});
Deno.test("JSON Schemas accept sparkline, progress segments, quitApp and the processes group", async () => {
  const ajv = await validator();
  ajv.addSchema(await json("./uinode-0.1.json"));
  const node = ajv.getSchema("https://barshelf.jiun.dev/schema/uinode-0.1.json")!;
  const widget = ajv.getSchema("https://barshelf.jiun.dev/schema/widget-0.1.json")!;
  const workflow = ajv.getSchema("https://barshelf.jiun.dev/schema/workflow-0.1.json")!;

  const sparkline = { type: "sparkline", values: [3, 5, 4], min: 0, max: 10, tint: "accent", height: 40 };
  assert(node(sparkline), `sparkline: ${ajv.errorsText(node.errors)}`);
  assert(node({ type: "sparkline", values: "${storage.history}" }), "templated sparkline values");
  assert(!node({ type: "sparkline" }), "sparkline without values accepted");

  const stacked = {
    type: "progress",
    style: "linear",
    segments: [{ value: 0.3, tint: "accent", label: "User" }, { value: 0.1, label: "System" }],
  };
  assert(node(stacked), `segments: ${ajv.errorsText(node.errors)}`);

  const quit = { type: "button", title: "Quit", action: { type: "quitApp", value: "com.apple.TextEdit" } };
  assert(node(quit), `quitApp: ${ajv.errorsText(node.errors)}`);
  assert(node({ ...quit, action: { type: "quitApp", value: 4242 } }), "quitApp by pid");

  const manifest = structuredClone(await json("../widgets/system/widget.json")) as Record<string, unknown>;
  manifest.permissions = { system: ["cpu", "processes"], quitApps: true };
  assert(widget(manifest), `quitApps/processes permission: ${ajv.errorsText(widget.errors)}`);

  const flow = structuredClone(await json("../widgets/system/workflow.json")) as Record<string, unknown>;
  flow.sources = { top: { use: "system", with: { metrics: ["processes"], processes: { count: 5 } } } };
  assert(workflow(flow), `processes source: ${ajv.errorsText(workflow.errors)}`);
  flow.sources = { top: { use: "system", with: { metrics: ["processes"], processes: { count: 11 } } } };
  assert(!workflow(flow), "processes count above 10 accepted");
});
import AjvModule from "npm:ajv@8";
import addFormatsModule from "npm:ajv-formats@2";
