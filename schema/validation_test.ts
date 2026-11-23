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
    json("./uinode-0.1.json"),
  ]);
  for (const schema of schemas) ajv.addSchema(schema);
  return ajv;
}

async function* fixturePaths(directory: string): AsyncGenerator<string> {
  for await (const entry of Deno.readDir(new URL(directory, import.meta.url))) {
    const path = `${directory}${entry.name}`;
    if (entry.isDirectory) {
      yield* fixturePaths(`${path}/`);
    } else if (entry.isFile && (entry.name === "widget.json" || entry.name === "workflow.json")) {
      yield path;
    }
  }
}

Deno.test("JSON Schemas compile and validate all widget and example fixtures and the registry", async () => {
  const ajv = await validator();
  const base = "https://barshelf.jiun.dev/schema/";
  const widget = ajv.getSchema(`${base}widget-0.1.json`);
  const workflow = ajv.getSchema(`${base}workflow-0.1.json`);
  const registry = ajv.getSchema(`${base}registry-0.1.json`);
  assert(widget && workflow && registry, "missing widget, workflow, or registry validator");

  const fixtures: Array<[string, Validate]> = [["../registry/index.json", registry]];
  for (const directory of ["../widgets/", "../examples/"]) {
    for await (const path of fixturePaths(directory)) {
      fixtures.push([path, path.endsWith("/widget.json") ? widget : workflow]);
    }
  }
  const failures: string[] = [];
  for (const [path, validate] of fixtures) {
    if (!validate(await json(path))) {
      failures.push(`${path}: ${ajv.errorsText(validate.errors)}`);
    }
  }
  assert(failures.length === 0, failures.sort().join("\n"));
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

Deno.test("JSON Schemas preserve constraints on storage, workflow sources, and list transforms", async () => {
  const ajv = await validator();
  const widget = ajv.getSchema("https://barshelf.jiun.dev/schema/widget-0.1.json")!;
  const workflow = ajv.getSchema("https://barshelf.jiun.dev/schema/workflow-0.1.json")!;
  const manifest = await json("../widgets/network/widget.json") as Record<string, unknown>;
  for (const storage of [true, false, { maxBytes: 1024 }]) {
    assert(
      widget({ ...manifest, permissions: { storage } }),
      `storage ${JSON.stringify(storage)}: ${ajv.errorsText(widget.errors)}`,
    );
  }
  for (const storage of ["true", { maxBytes: -1 }]) {
    assert(
      !widget({ ...manifest, permissions: { storage } }),
      `invalid storage permission accepted: ${JSON.stringify(storage)}`,
    );
  }

  const flow = { schemaVersion: 1, sources: {}, view: { type: "text", text: "Ready" } };
  assert(workflow(flow), ajv.errorsText(workflow.errors));
  assert(!workflow({ ...flow, sources: { run: { use: "exec" } } }), "exec source without options accepted");
  assert(!workflow({ ...flow, sources: { other: { use: "unknown", with: {} } } }), "unknown source accepted");
  assert(!workflow({
    ...flow,
    transforms: { limited: { use: "limit", from: "sources.items", with: [1] } },
  }), "list transform with array options accepted");
});

Deno.test("JSON Schemas accept sparkline, progress segments, quitApp and the processes group", async () => {
  const ajv = await validator();
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
  const processes: { count: number | string } = { count: 5 };
  flow.sources = { top: { use: "system", with: { metrics: ["processes"], processes } } };
  for (const count of [1, 5, 10, "${settings.count}"]) {
    processes.count = count;
    assert(workflow(flow), `processes count ${count}: ${ajv.errorsText(workflow.errors)}`);
  }
  for (const count of [0, 11, 1.5, "5", "${settings.count} rows"]) {
    processes.count = count;
    assert(!workflow(flow), `invalid processes count accepted: ${JSON.stringify(count)}`);
  }
});
import AjvModule from "npm:ajv@8";
import addFormatsModule from "npm:ajv-formats@2";
