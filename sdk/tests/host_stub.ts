// Stands in for the `barshelf` module when a bundled script widget runs
// under `deno test`: the real builders (`ui`, `menuBar`), with every host
// call recorded in `host` instead of going over stdio.
//
//   deno test --import-map=sdk/tests/import_map.json sdk/tests/
import * as sdk from "../mod.ts";
import type {
  ExecRunOptions,
  RenderOptions,
  UINode,
  WidgetHandlers,
  WidgetRuntimeContext,
} from "../mod.ts";

export * from "../mod.ts";

export interface ExecCall {
  command: string;
  args?: string[];
}

export const host = {
  renders: [] as { root: UINode; options: RenderOptions }[],
  storage: new Map<string, unknown>(),
  notifications: [] as { title: string; body?: string }[],
  execCalls: [] as ExecCall[],
  /** Answers `exec.run`; throw to fail the command. */
  exec: (
    _call: ExecCall,
  ): { stdout: string; exitCode?: number; json?: unknown } => {
    throw new Error("no exec answer set");
  },
  reset(): void {
    this.renders = [];
    this.storage = new Map();
    this.notifications = [];
    this.execCalls = [];
    this.exec = () => {
      throw new Error("no exec answer set");
    };
  },
  get lastRender(): { root: UINode; options: RenderOptions } {
    const last = this.renders.at(-1);
    if (!last) throw new Error("nothing rendered");
    return last;
  },
};

const render: typeof sdk.render = async (root, options = {}) => {
  host.renders.push({ root, options });
  return { revision: host.renders.length };
};

const exec: typeof sdk.exec = {
  async run(options: ExecRunOptions) {
    const call = { command: options.command, args: options.args };
    host.execCalls.push(call);
    const answer = host.exec(call);
    return {
      stdout: answer.stdout,
      stderr: "",
      exitCode: answer.exitCode ?? 0,
      json: answer.json,
      durationMs: 1,
    };
  },
};

const storage: typeof sdk.storage = {
  async get<T = unknown>(key: string): Promise<T | null> {
    return (host.storage.get(key) as T | undefined) ?? null;
  },
  async set<T = unknown>(key: string, value: T): Promise<void> {
    host.storage.set(key, structuredClone(value));
  },
  async delete(key: string): Promise<void> {
    host.storage.delete(key);
  },
  async list(): Promise<string[]> {
    return [...host.storage.keys()];
  },
};

const timer: typeof sdk.timer = {
  async once(_id: string, _atMs: number): Promise<void> {},
  async after(_id: string, _delayMs: number): Promise<void> {},
  async every(_id: string, _intervalMs: number): Promise<void> {},
  async clear(_id: string): Promise<void> {},
};

const notify: typeof sdk.notify = {
  async show(notification) {
    host.notifications.push(notification);
  },
};

const log: typeof sdk.log = async () => {};

export const barshelf = {
  ...sdk.barshelf,
  widget: (handlers: WidgetHandlers) => ({ handlers }),
  render,
  exec,
  storage,
  timer,
  notify,
  log,
};

export const bsf = barshelf;
export default barshelf;

/** The context a load, action or timer handler receives. */
export function context<T extends object>(params: T): T & WidgetRuntimeContext {
  return {
    ...params,
    render,
    exec,
    storage,
    secret: sdk.secret,
    timer,
    notify,
    log,
    ui: sdk.ui,
    menuBar: sdk.menuBar,
    barshelf,
    bsf: barshelf,
    reload: async () => {},
  };
}

/** Delivers an action the way the host does: context and event. */
export async function sendAction(
  handlers: WidgetHandlers,
  actionId: string,
  now: number,
  payload?: unknown,
): Promise<void> {
  const event = { actionId, now, payload };
  await handlers.action!(context(event), event);
}

/** Fires a timer the way the host does: context and event. */
export async function fireTimer(
  handlers: WidgetHandlers,
  id: string,
  now: number,
): Promise<void> {
  const event = { id, now };
  await handlers.timer!(context(event), event);
}

/** Every string in a rendered tree (text, titles, labels, actions…). */
export function strings(value: unknown): string[] {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.flatMap(strings);
  if (value !== null && typeof value === "object") {
    return Object.values(value).flatMap(strings);
  }
  return [];
}
