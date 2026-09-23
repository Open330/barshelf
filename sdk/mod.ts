export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonValue[] | {
  [key: string]: JsonValue;
};
export type RpcId = number | string;

export type LoadReason = "install" | "open" | "manual" | "timer" | "interval";
export type Appearance = "light" | "dark";

export interface WidgetLoadParams {
  widgetId: string;
  reason: LoadReason;
  now: number;
  locale: string;
  appearance: Appearance;
  settings: Record<string, unknown>;
  lastRenderRevision?: number | null;
  /** @internal Opaque host token acknowledged when the load handler returns. */
  loadGeneration?: string;
}

export interface WidgetActionParams {
  actionId: string;
  payload?: unknown;
  now: number;
}

export interface WidgetTimerParams {
  id: string;
  now: number;
}

export interface RenderStatus {
  label?: string;
  tooltip?: string;
  /**
   * Text the menu bar draws before `label` — "CPU" in "CPU 23%", or the top
   * row when the widget's status item is stacked.
   *
   * Supplied per render rather than fixed in the manifest, because a widget
   * whose metric the user chooses cannot know at authoring time whether it
   * will be showing CPU or memory. The user can still override it.
   */
  prefix?: string;
  /**
   * SF Symbol for this render, overriding the manifest's `statusItem.icon`.
   *
   * A manifest field cannot follow a value. This is what lets a battery widget
   * move between `battery.25` and `battery.100`, or a network one between
   * signal strengths.
   */
  icon?: string;
  /**
   * Colour for this render: `accent`, `good`, `warning`, `danger` or
   * `secondary` — the same vocabulary the view layer uses.
   *
   * Leave it off for the menu bar's own colour. That also keeps the item a
   * template image, which follows a light or dark bar and inverts while the
   * item is held open; a fixed colour does neither.
   */
  tint?: "accent" | "good" | "warning" | "danger" | "secondary";
  /** Up to two compact, independently active menu-bar readings. */
  metrics?: StatusMetric[];
  /** Per-render defaults. User settings override these, then manifest defaults. */
  presentation?: MenuBarPresentation;
}

export type StatusMetricFormat =
  | "decimal"
  | "percent"
  | "bytes"
  | "bytesPerSecond";
export type MetricPrecision = 0 | 1 | 2 | 3;
/** `automatic`, `monochrome`, or a semantic tint such as `warning`. */
export type MenuBarColor = "automatic" | "monochrome" | StatusMetricTint;
export type StatusMetricTint =
  | "accent"
  | "good"
  | "warning"
  | "danger"
  | "secondary";

export interface MenuBarMetricOverride {
  label?: string;
  hidden?: boolean;
  tint?: StatusMetricTint;
}

/**
 * Sparse menu-bar presentation defaults. The host resolves every field in
 * user preference → render status → manifest order, so omit fields you do not
 * own. `color` is `automatic`, `monochrome`, or a semantic tint.
 */
export interface MenuBarPresentation {
  showValues?: boolean;
  showUnits?: boolean;
  precision?: MetricPrecision;
  color?: MenuBarColor;
  /** Text column width in points (32–120) for `width: "fixed"`. */
  valueWidth?: number;
  metricOrder?: string[];
  metricOverrides?: Record<string, MenuBarMetricOverride>;
  /**
   * `auto` (default) reserves room for `digits` integer digits so a reading
   * going from 9 to 10 does not change the item's width; `fixed` uses
   * `valueWidth`; `fit` follows the text.
   */
  width?: "auto" | "fixed" | "fit";
  /** Integer digits `width: "auto"` reserves, 1–6 (default 2). */
  digits?: number;
  /** Block alignment of the label and value rows. */
  alignment?: "leading" | "center" | "trailing";
  /**
   * Where a short number sits in its reserved digits: `right` (default)
   * keeps the last digit and unit still; `left` starts it where the label does.
   */
  numberAlignment?: "right" | "left";
  weight?: "regular" | "medium" | "semibold" | "bold";
  size?: "small" | "regular" | "large";
}

export interface StatusMetric {
  /** Stable id for ordering and per-metric preferences. */
  id?: string;
  /** Short visible label, such as "↓" or "Disk". */
  label?: string;
  /** Visible reading. It may be empty when `active` is used as an activity dot. */
  value?: string;
  /** Machine-readable value. Null means the metric is currently unknown. */
  number?: number | null;
  /** Defaults to `decimal` for a numeric metric. */
  format?: StatusMetricFormat;
  /** Optional unit appended to a decimal metric. */
  unit?: string;
  /** Per-metric decimal places (0 through 3). */
  precision?: MetricPrecision;
  tint?: StatusMetricTint;
  active?: boolean;
  /** Spoken description when the compact presentation hides the value. */
  accessibilityLabel?: string;
}

export interface MenuBarMetricOptions {
  label?: string;
  format?: StatusMetricFormat;
  unit?: string;
  precision?: MetricPrecision;
  tint?: StatusMetricTint;
  active?: boolean;
  accessibilityLabel?: string;
}

export interface MenuBarTextMetricOptions {
  label?: string;
  tint?: StatusMetricTint;
  active?: boolean;
  accessibilityLabel?: string;
}

export type MenuBarStatusOptions = Omit<RenderStatus, "metrics">;

export interface RenderOptions {
  status?: RenderStatus;
  /** Redacted, non-sensitive fallback persisted for cold-start display. */
  cacheRoot?: UINode;
  nextRefreshAt?: number;
  cacheTtlMs?: number;
  sensitive?: boolean;
}

export interface RenderResult {
  revision: number;
}

export type ExecParseMode = "text" | "json" | "lines";

export interface ExecRunOptions {
  command: string;
  args: string[];
  parse?: ExecParseMode;
  timeoutMs?: number;
  sensitive?: boolean;
  env?: Record<string, string>;
}

export interface ExecResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  json?: unknown;
  durationMs: number;
}

export interface NotifyOptions {
  title: string;
  body?: string;
}

export type LogLevel = "debug" | "info" | "warn" | "error";

export interface JsonRpcErrorPayload {
  code: number;
  message: string;
  data?: unknown;
}

export class JsonRpcError extends Error {
  readonly code: number;
  readonly data?: unknown;

  constructor(payload: JsonRpcErrorPayload) {
    super(payload.message);
    this.name = "JsonRpcError";
    this.code = payload.code;
    this.data = payload.data;
  }
}

export const ProtocolErrorCode = {
  PermissionDenied: -32001,
  ExecNotFound: -32002,
  Timeout: -32003,
  QuotaExceeded: -32004,
  ProtocolError: -32005,
} as const;

export type SemanticColor = string;
export type EdgeInsets = number | {
  top?: number;
  bottom?: number;
  leading?: number;
  trailing?: number;
  horizontal?: number;
  vertical?: number;
};
export type FillOrNumber = number | "fill";

export interface Accessibility {
  label?: string;
  hint?: string;
  value?: string;
}

export interface NodeStyle {
  padding?: EdgeInsets;
  spacing?: number;
  width?: FillOrNumber;
  height?: FillOrNumber;
  minHeight?: number;
  maxHeight?: number;
  alignment?: "leading" | "center" | "trailing";
  background?: SemanticColor;
  foreground?: SemanticColor;
  [key: string]: unknown;
}

export interface UINodeBase {
  id?: string;
  type: string;
  hidden?: boolean;
  accessibility?: Accessibility;
  [key: string]: unknown;
}

export interface StackNode extends UINodeBase {
  type: "vstack" | "hstack" | "zstack";
  spacing?: number;
  children?: UINode[];
}

export interface ScrollNode extends UINodeBase {
  type: "scroll";
  axis?: "vertical" | "horizontal" | "both";
  child: UINode;
}

export interface TextNode extends UINodeBase {
  type: "text";
  text: string;
  role?: "title" | "body" | "caption" | "code" | "label";
  lineLimit?: number | null;
  truncation?: "head" | "middle" | "tail";
  monospacedDigit?: boolean;
  foreground?: SemanticColor;
}

export type ImageSourceKind =
  | "sfSymbol"
  | "fileIcon"
  | "fileThumbnail"
  | "url"
  | "brand"
  | "monogram";

export interface ImageSource {
  kind: ImageSourceKind;
  name?: string;
  path?: string;
  url?: string;
  modifiedAt?: number;
  monogram?: string;
  [key: string]: unknown;
}

export interface ImageNode extends UINodeBase {
  type: "image";
  source: ImageSource;
  size?: number;
  tint?: SemanticColor;
}

export interface ListNode extends UINodeBase {
  type: "list";
  items: UINode[];
  empty?: UINode;
  rowSpacing?: number;
  virtualized?: boolean;
  /** Enables host-local visible-text filtering for this list. */
  searchPlaceholder?: string;
}

export interface GridNode extends UINodeBase {
  type: "grid";
  items: UINode[];
  columns?: number;
  spacing?: number;
  size?: number;
}

export interface ProgressCountdown {
  from: number;
  until: number;
}

export interface TintRule {
  whenRemainingLtSeconds: number;
  tint: SemanticColor;
}

export interface ProgressNode extends UINodeBase {
  type: "progress";
  style: "linear" | "ring";
  value?: number;
  countdown?: ProgressCountdown;
  label?: string;
  labelFrom?: "remainingSeconds";
  tint?: SemanticColor;
  tintRules?: TintRule[];
  size?: number;
}

export interface ButtonNode extends UINodeBase {
  type: "button";
  title?: string;
  icon?: string;
  tooltip?: string;
  role?: "normal" | "destructive" | "cancel";
  disabled?: boolean;
  action: NodeAction;
}

export interface SectionNode extends UINodeBase {
  type: "section";
  title?: string;
  children?: UINode[];
}

export interface CardNode extends UINodeBase {
  type: "card";
  children?: UINode[];
  spacing?: number;
  tone?: SemanticColor;
  tint?: SemanticColor;
}

export interface BadgeNode extends UINodeBase {
  type: "badge";
  text: string;
  tone?: SemanticColor;
  tint?: SemanticColor;
}

export interface BannerNode extends UINodeBase {
  type: "banner";
  text: string;
  title?: string;
  tone?: SemanticColor;
}

export interface EmptyNode extends UINodeBase {
  type: "empty";
  icon?: string | ImageSource;
  title?: string;
  subtitle?: string;
}

export interface DividerNode extends UINodeBase {
  type: "divider";
}

export interface SpacerNode extends UINodeBase {
  type: "spacer";
  minLength?: number;
}

export interface NoneNode extends UINodeBase {
  type: "none";
}

export type EventAction = { type: "event"; id: string; payload?: unknown };
export type CopyTextAction = {
  type: "copyText";
  value: string;
  toast?: string;
  clearAfterSec?: number;
};
export type OpenURLAction = { type: "openURL"; url: string };
export type OpenFileAction = { type: "openFile"; path: string };
export type RevealFileAction = { type: "revealFile"; path: string };
export type RunAction = {
  type: "run";
  command: string[];
  thenRefresh?: boolean;
};
export type RefreshAction = { type: "refresh" };
export type NodeAction =
  | EventAction
  | CopyTextAction
  | OpenURLAction
  | OpenFileAction
  | RevealFileAction
  | RunAction
  | RefreshAction;

export type UINode =
  | StackNode
  | ScrollNode
  | TextNode
  | ImageNode
  | ListNode
  | GridNode
  | ProgressNode
  | ButtonNode
  | SectionNode
  | CardNode
  | BadgeNode
  | BannerNode
  | EmptyNode
  | DividerNode
  | SpacerNode
  | NoneNode;

type NodeOptions<T extends UINodeBase> =
  & Omit<Partial<T>, "type">
  & Record<string, unknown>;
type StackOptions = Omit<NodeOptions<StackNode>, "children">;
type TextOptions = Omit<NodeOptions<TextNode>, "text">;
type ImageOptions = Omit<NodeOptions<ImageNode>, "source">;
type ListOptions = Omit<NodeOptions<ListNode>, "items">;
type GridOptions = Omit<NodeOptions<GridNode>, "items">;
type ProgressOptions = Omit<NodeOptions<ProgressNode>, "style"> & {
  style?: "linear" | "ring";
};
type ButtonOptions = Omit<NodeOptions<ButtonNode>, "action" | "icon"> & {
  icon?: string;
};
type SectionOptions = Omit<NodeOptions<SectionNode>, "children" | "title">;
type CardOptions = Omit<NodeOptions<CardNode>, "children">;
type BadgeOptions = Omit<NodeOptions<BadgeNode>, "text">;
type BannerOptions = Omit<NodeOptions<BannerNode>, "text">;
type EmptyOptions = NodeOptions<EmptyNode>;
type DividerOptions = NodeOptions<DividerNode>;
type SpacerOptions = NodeOptions<SpacerNode>;

export interface HeaderOptions extends StackOptions {
  icon?: string | ImageSource;
  iconSize?: number;
  subtitle?: string;
  badge?: string;
  badgeTone?: SemanticColor;
  tint?: SemanticColor;
}

export interface StatOptions extends CardOptions {
  icon?: string | ImageSource;
  caption?: string;
  tone?: SemanticColor;
  valueTone?: SemanticColor;
}

export interface MeterRowOptions extends StackOptions {
  valueText?: string;
  tint?: SemanticColor;
}

export interface MetricCardOptions extends CardOptions {
  icon?: string | ImageSource;
  caption?: string;
  badge?: string;
  badgeTone?: SemanticColor;
  tone?: SemanticColor;
  progress?: number;
  progressLabel?: string;
  progressTint?: SemanticColor;
}

function compact<T extends Record<string, unknown>>(value: T): T {
  const out: Record<string, unknown> = {};
  for (const [key, item] of Object.entries(value)) {
    if (item !== undefined) {
      out[key] = item;
    }
  }
  return out as T;
}

function sfSymbol(name: string): ImageSource {
  return { kind: "sfSymbol", name };
}

function imageSource(source: string | ImageSource): ImageSource {
  return typeof source === "string" ? sfSymbol(source) : source;
}

function clamp01(value: number): number {
  if (!Number.isFinite(value)) {
    return 0;
  }
  return Math.min(Math.max(value, 0), 1);
}

function stack(
  type: "vstack" | "hstack" | "zstack",
  children: UINode[] = [],
  options: StackOptions = {},
): StackNode {
  return compact({ ...options, type, children }) as StackNode;
}

export const action = {
  event(id: string, payload?: unknown): EventAction {
    return compact({ type: "event", id, payload }) as EventAction;
  },

  copyText(
    value: string,
    options: Omit<CopyTextAction, "type" | "value"> = {},
  ): CopyTextAction {
    return compact({ ...options, type: "copyText", value }) as CopyTextAction;
  },

  openURL(url: string): OpenURLAction {
    return { type: "openURL", url };
  },

  openFile(path: string): OpenFileAction {
    return { type: "openFile", path };
  },

  revealFile(path: string): RevealFileAction {
    return { type: "revealFile", path };
  },

  run(
    command: string[],
    options: Omit<RunAction, "type" | "command"> = {},
  ): RunAction {
    return compact({ ...options, type: "run", command }) as RunAction;
  },

  refresh(): RefreshAction {
    return { type: "refresh" };
  },
};

export const ui = {
  action,

  vstack(children: UINode[] = [], options: StackOptions = {}): StackNode {
    return stack("vstack", children, options);
  },

  hstack(children: UINode[] = [], options: StackOptions = {}): StackNode {
    return stack("hstack", children, options);
  },

  zstack(children: UINode[] = [], options: StackOptions = {}): StackNode {
    return stack("zstack", children, options);
  },

  scroll(
    child: UINode,
    options: Omit<NodeOptions<ScrollNode>, "child"> = {},
  ): ScrollNode {
    return compact({ ...options, type: "scroll", child }) as ScrollNode;
  },

  text(text: string, options: TextOptions = {}): TextNode {
    return compact({ ...options, type: "text", text }) as TextNode;
  },

  image(source: string | ImageSource, options: ImageOptions = {}): ImageNode {
    return compact({
      ...options,
      type: "image",
      source: imageSource(source),
    }) as ImageNode;
  },

  list(items: UINode[] = [], options: ListOptions = {}): ListNode {
    return compact({ ...options, type: "list", items }) as ListNode;
  },

  grid(items: UINode[] = [], options: GridOptions = {}): GridNode {
    return compact({ ...options, type: "grid", items }) as GridNode;
  },

  section(
    title: string | undefined,
    children: UINode[] = [],
    options: SectionOptions = {},
  ): SectionNode {
    return compact({
      ...options,
      type: "section",
      title,
      children,
    }) as SectionNode;
  },

  card(children: UINode[] = [], options: CardOptions = {}): CardNode {
    return compact({ ...options, type: "card", children }) as CardNode;
  },

  header(title: string, options: HeaderOptions = {}): StackNode {
    const {
      icon,
      iconSize = 16,
      subtitle,
      badge,
      badgeTone = "neutral",
      tint = "accent",
      ...rest
    } = options;
    const row = stack("hstack", [
      ...(icon === undefined ? [] : [ui.image(icon, { size: iconSize, tint })]),
      ui.text(title, { role: "title", lineLimit: 1 }),
      ui.spacer(),
      ...(badge === undefined ? [] : [ui.badge(badge, { tone: badgeTone })]),
    ], { spacing: rest.spacing ?? 6 });

    if (subtitle === undefined || subtitle.length === 0) {
      return compact({
        ...rest,
        type: "hstack",
        spacing: rest.spacing ?? 6,
        children: row.children,
      }) as StackNode;
    }
    return stack("vstack", [
      row,
      ui.text(subtitle, {
        role: "caption",
        foreground: "secondary",
        lineLimit: 1,
      }),
    ], { ...rest, spacing: 2 });
  },

  stat(
    label: string,
    value: string | number,
    options: StatOptions = {},
  ): CardNode {
    const {
      icon,
      caption,
      tone = "accent",
      valueTone,
      ...rest
    } = options;
    return ui.card([
      ui.hstack([
        ...(icon === undefined
          ? []
          : [ui.image(icon, { size: 13, tint: tone })]),
        ui.text(label, {
          role: "caption",
          foreground: "secondary",
          lineLimit: 1,
        }),
      ], { spacing: 4 }),
      ui.text(String(value), {
        role: "title",
        monospacedDigit: true,
        foreground: valueTone,
        lineLimit: 1,
      }),
      ...(caption === undefined ? [] : [
        ui.text(caption, {
          role: "caption",
          foreground: "secondary",
          lineLimit: 1,
        }),
      ]),
    ], { ...rest, tone, spacing: rest.spacing ?? 3 });
  },

  meterRow(
    label: string,
    value: number,
    options: MeterRowOptions = {},
  ): StackNode {
    const {
      valueText = `${Math.round(clamp01(value) * 100)}%`,
      tint = "accent",
      ...rest
    } = options;
    return ui.vstack([
      ui.hstack([
        ui.text(label, {
          role: "caption",
          foreground: "secondary",
          lineLimit: 1,
        }),
        ui.spacer(),
        ui.text(valueText, {
          role: "caption",
          monospacedDigit: true,
          lineLimit: 1,
        }),
      ], { spacing: 6 }),
      ui.progress(clamp01(value), { tint }),
    ], { ...rest, spacing: rest.spacing ?? 4 });
  },

  metricCard(
    title: string,
    value: string | number,
    options: MetricCardOptions = {},
  ): CardNode {
    const {
      icon,
      caption,
      badge,
      badgeTone = "neutral",
      tone = "accent",
      progress,
      progressLabel,
      progressTint,
      ...rest
    } = options;
    return ui.card([
      ui.header(title, { icon, badge, badgeTone, tint: tone }),
      ui.text(String(value), {
        role: "title",
        monospacedDigit: true,
        lineLimit: 1,
      }),
      ...(caption === undefined ? [] : [
        ui.text(caption, {
          role: "caption",
          foreground: "secondary",
          lineLimit: 1,
        }),
      ]),
      ...(progress === undefined ? [] : [
        ui.progress(clamp01(progress), {
          label: progressLabel,
          tint: progressTint ?? tone,
        }),
      ]),
    ], { ...rest, tone, spacing: rest.spacing ?? 6 });
  },

  progress(
    valueOrOptions: number | ProgressOptions = {},
    options: ProgressOptions = {},
  ): ProgressNode {
    const node = typeof valueOrOptions === "number"
      ? { ...options, value: valueOrOptions }
      : valueOrOptions;
    return compact({
      ...node,
      type: "progress",
      style: node.style ?? "linear",
    }) as ProgressNode;
  },

  button(
    title: string | undefined,
    buttonAction: NodeAction,
    options: ButtonOptions = {},
  ): ButtonNode {
    const { icon, ...rest } = options;
    return compact({
      ...rest,
      type: "button",
      title,
      icon,
      action: buttonAction,
    }) as ButtonNode;
  },

  badge(text: string, options: BadgeOptions = {}): BadgeNode {
    return compact({ ...options, type: "badge", text }) as BadgeNode;
  },

  banner(text: string, options: BannerOptions = {}): BannerNode {
    return compact({ ...options, type: "banner", text }) as BannerNode;
  },

  empty(options: EmptyOptions = {}): EmptyNode {
    return compact({ ...options, type: "empty" }) as EmptyNode;
  },

  divider(options: DividerOptions = {}): DividerNode {
    return compact({ ...options, type: "divider" }) as DividerNode;
  },

  spacer(minLength?: number, options: SpacerOptions = {}): SpacerNode {
    return compact({ ...options, type: "spacer", minLength }) as SpacerNode;
  },

  none(): NoneNode {
    return { type: "none" };
  },
};

const menuBarIdPattern = /^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$/;
const statusMetricFormats: readonly StatusMetricFormat[] = [
  "decimal",
  "percent",
  "bytes",
  "bytesPerSecond",
];
const statusMetricTints: readonly StatusMetricTint[] = [
  "accent",
  "good",
  "warning",
  "danger",
  "secondary",
];
const menuBarColors: readonly MenuBarColor[] = [
  "automatic",
  "monochrome",
  "accent",
  "good",
  "warning",
  "danger",
  "secondary",
];

function menuBarError(message: string): never {
  throw new TypeError(`barshelf.menuBar: ${message}`);
}

function validateMenuBarId(id: string, field = "metric id"): void {
  if (typeof id !== "string" || !menuBarIdPattern.test(id)) {
    menuBarError(
      `${field} must be a stable id (letters/digits followed by letters, digits, ., _, or -; max 100 characters)`,
    );
  }
}

function validatePrecision(precision: unknown, field = "precision"): void {
  if (
    precision !== undefined &&
    (typeof precision !== "number" || !Number.isInteger(precision) ||
      precision < 0 || precision > 3)
  ) {
    menuBarError(`${field} must be an integer from 0 through 3`);
  }
}

function validateMetric(metric: StatusMetric): void {
  if (!metric || typeof metric !== "object") {
    menuBarError("each metric must be an object");
  }
  if (metric.id !== undefined) validateMenuBarId(metric.id);
  if (metric.value !== undefined && typeof metric.value !== "string") {
    menuBarError("text metric value must be a string");
  }
  if (
    metric.number !== undefined &&
    metric.number !== null &&
    (typeof metric.number !== "number" || !Number.isFinite(metric.number))
  ) {
    menuBarError("numeric metric value must be a finite number or null");
  }
  if (
    metric.format !== undefined &&
    !statusMetricFormats.includes(metric.format)
  ) {
    menuBarError("format must be decimal, percent, bytes, or bytesPerSecond");
  }
  validatePrecision(metric.precision, "metric precision");
  if (metric.tint !== undefined && !statusMetricTints.includes(metric.tint)) {
    menuBarError("metric tint must be accent, good, warning, danger, or secondary");
  }
}

function validatePresentation(presentation: MenuBarPresentation): void {
  validatePrecision(presentation.precision);
  if (
    presentation.valueWidth !== undefined &&
    (!Number.isFinite(presentation.valueWidth) || presentation.valueWidth < 32 ||
      presentation.valueWidth > 120)
  ) {
    menuBarError("valueWidth must be a finite number from 32 through 120");
  }
  if (presentation.color !== undefined && !menuBarColors.includes(presentation.color)) {
    menuBarError("color must be automatic, monochrome, or a semantic tint");
  }
  if (
    presentation.digits !== undefined &&
    (!Number.isInteger(presentation.digits) || presentation.digits < 1 || presentation.digits > 6)
  ) {
    menuBarError("digits must be an integer from 1 through 6");
  }
  const oneOf = (value: unknown, allowed: string[], name: string) => {
    if (value !== undefined && !allowed.includes(value as string)) {
      menuBarError(`${name} must be one of ${allowed.join(", ")}`);
    }
  };
  oneOf(presentation.width, ["auto", "fixed", "fit"], "width");
  oneOf(presentation.alignment, ["leading", "center", "trailing"], "alignment");
  oneOf(presentation.weight, ["regular", "medium", "semibold", "bold"], "weight");
  oneOf(presentation.size, ["small", "regular", "large"], "size");
  oneOf(presentation.numberAlignment, ["right", "left"], "numberAlignment");

  const order = presentation.metricOrder;
  if (order !== undefined) {
    if (!Array.isArray(order)) menuBarError("metricOrder must be an array of metric ids");
    const ids = new Set<string>();
    for (const id of order) {
      validateMenuBarId(id, "metricOrder id");
      if (ids.has(id)) menuBarError(`metricOrder contains duplicate id ${id}`);
      ids.add(id);
    }
  }

  if (presentation.metricOverrides !== undefined) {
    for (const [id, override] of Object.entries(presentation.metricOverrides)) {
      validateMenuBarId(id, "metricOverrides id");
      if (!override || typeof override !== "object") {
        menuBarError(`metricOverrides.${id} must be an object`);
      }
      if (override.tint !== undefined && !statusMetricTints.includes(override.tint)) {
        menuBarError(`metricOverrides.${id}.tint must be a semantic metric tint`);
      }
    }
  }
}

/**
 * Typed builders for a script widget's compact menu-bar status.
 * Numeric values use SI (base-1000) byte units, percentages are 0–100, and
 * null represents an unknown reading. User menu-bar preferences override
 * render defaults, which override manifest defaults.
 */
export const menuBar = {
  metric(
    id: string,
    number: number | null,
    options: MenuBarMetricOptions = {},
  ): StatusMetric {
    validateMenuBarId(id);
    if (number !== null && (typeof number !== "number" || !Number.isFinite(number))) {
      menuBarError("numeric metric value must be a finite number or null");
    }
    const metric: StatusMetric = {
      id,
      number,
      format: options.format ?? "decimal",
      ...options,
    };
    validateMetric(metric);
    return metric;
  },

  text(
    id: string,
    value: string,
    options: MenuBarTextMetricOptions = {},
  ): StatusMetric {
    validateMenuBarId(id);
    if (typeof value !== "string") menuBarError("text metric value must be a string");
    const metric: StatusMetric = { id, value, ...options };
    validateMetric(metric);
    return metric;
  },

  status(
    metrics: StatusMetric[] = [],
    options: MenuBarStatusOptions = {},
  ): RenderStatus {
    if (!Array.isArray(metrics) || metrics.length > 2) {
      menuBarError("status accepts at most two metrics");
    }
    const ids = new Set<string>();
    for (const metric of metrics) {
      validateMetric(metric);
      if (metric.id !== undefined) {
        if (ids.has(metric.id)) menuBarError(`status contains duplicate metric id ${metric.id}`);
        ids.add(metric.id);
      }
    }
    if (options.presentation !== undefined) {
      validatePresentation(options.presentation);
    }
    return { ...options, metrics: [...metrics] };
  },
};

type Awaitable<T> = T | Promise<T>;

export interface WidgetRuntimeContext {
  render: typeof render;
  exec: typeof exec;
  storage: typeof storage;
  secret: typeof secret;
  timer: typeof timer;
  notify: typeof notify;
  log: typeof log;
  ui: typeof ui;
  menuBar: typeof menuBar;
  barshelf: typeof barshelf;
  bsf: typeof bsf;
  reload: () => Promise<void>;
}

export type WidgetLoadContext = WidgetLoadParams & WidgetRuntimeContext;
export type WidgetActionContext = WidgetActionParams & WidgetRuntimeContext;
export type WidgetTimerContext = WidgetTimerParams & WidgetRuntimeContext;

export interface WidgetHandlers {
  load?: (ctx: WidgetLoadContext) => Awaitable<void>;
  action?: (
    ctx: WidgetActionContext,
    event: WidgetActionParams,
  ) => Awaitable<void>;
  timer?: (
    ctx: WidgetTimerContext,
    event: WidgetTimerParams,
  ) => Awaitable<void>;
}

export interface WidgetRegistration {
  handlers: WidgetHandlers;
}

interface PendingRequest<T = unknown> {
  resolve: (value: T) => void;
  reject: (reason: unknown) => void;
}

interface JsonRpcResponse {
  jsonrpc: "2.0";
  id: RpcId | null;
  result?: unknown;
  error?: JsonRpcErrorPayload;
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
let nextRequestId = 1;
let writeQueue: Promise<void> = Promise.resolve();
let notificationQueue: Promise<void> = Promise.resolve();
const pending = new Map<string, PendingRequest>();

let handlers: WidgetHandlers | undefined;
let lastLoadParams: WidgetLoadParams | undefined;
let activeLoadGeneration: string | undefined;
let readLoopStarted = false;

function pendingKey(id: RpcId): string {
  return String(id);
}

function writeStdout(line: string): Promise<void> {
  const bytes = encoder.encode(line);
  const job = writeQueue.then(async () => {
    await Deno.stdout.write(bytes);
  });
  writeQueue = job.catch(() => {});
  return job;
}

function writeStderr(message: string): void {
  void Deno.stderr.write(encoder.encode(`${message}\n`));
}

async function sendRequest<T>(method: string, params?: unknown): Promise<T> {
  const id = nextRequestId++;
  const message = compact({
    jsonrpc: "2.0",
    id,
    method,
    params,
  });

  const promise = new Promise<T>((resolve, reject) => {
    pending.set(pendingKey(id), {
      resolve: resolve as (value: unknown) => void,
      reject,
    });
  });

  try {
    await writeStdout(`${JSON.stringify(message)}\n`);
  } catch (error) {
    pending.delete(pendingKey(id));
    throw error;
  }

  return promise;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function handleResponse(response: JsonRpcResponse): void {
  if (response.id === null) {
    writeStderr("barshelf sdk: response with null id ignored");
    return;
  }

  const request = pending.get(pendingKey(response.id));
  if (!request) {
    writeStderr(
      `barshelf sdk: response for unknown id ${String(response.id)} ignored`,
    );
    return;
  }

  pending.delete(pendingKey(response.id));

  if (response.error) {
    request.reject(new JsonRpcError(response.error));
  } else {
    request.resolve(response.result);
  }
}

function makeContext<T extends object>(params: T): T & WidgetRuntimeContext {
  return Object.assign({}, params, {
    render,
    exec,
    storage,
    secret,
    timer,
    notify,
    log,
    ui,
    menuBar,
    barshelf,
    bsf,
    reload: async () => {
      if (!handlers?.load || !lastLoadParams) {
        return;
      }
      await handlers.load(makeContext(lastLoadParams));
    },
  });
}

function reportHandlerError(method: string, error: unknown): void {
  const message = error instanceof Error
    ? `${error.name}: ${error.message}`
    : String(error);
  void log("error", `${method} handler failed: ${message}`).catch(() => {
    writeStderr(`barshelf sdk: ${method} handler failed: ${message}`);
  });
}

function dispatchNotification(method: string, params: unknown): void {
  // Lifecycle handlers are serialized. Besides keeping widget state
  // deterministic, this prevents an action/timer handler from racing a load
  // and attributing its render to the wrong refresh generation.
  notificationQueue = notificationQueue.then(async () => {
    if (!handlers) {
      writeStderr(
        `barshelf sdk: received ${method} before barshelf.widget registration`,
      );
      return;
    }

    try {
      if (method === "widget.load") {
        lastLoadParams = params as WidgetLoadParams;
        const generation = lastLoadParams.loadGeneration;
        const previousGeneration = activeLoadGeneration;
        let loadError: string | undefined;
        activeLoadGeneration = generation;
        try {
          await handlers.load?.(makeContext(lastLoadParams));
        } catch (error) {
          loadError = error instanceof Error
            ? `${error.name}: ${error.message}`
            : String(error);
          throw error;
        } finally {
          activeLoadGeneration = previousGeneration;
          if (generation) {
            await sendRequest("host.load.complete", {
              generation,
              error: loadError,
            });
          }
        }
        return;
      }

      if (method === "widget.action") {
        const event = params as WidgetActionParams;
        await handlers.action?.(makeContext(event), event);
        return;
      }

      if (method === "widget.timer") {
        const event = params as WidgetTimerParams;
        await handlers.timer?.(makeContext(event), event);
        return;
      }

      writeStderr(`barshelf sdk: unknown notification ${method}`);
    } catch (error) {
      reportHandlerError(method, error);
    }
  });
}

function handleLine(line: string): void {
  let message: unknown;
  try {
    message = JSON.parse(line);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    writeStderr(`barshelf sdk: invalid JSON-RPC line: ${detail}`);
    return;
  }

  if (!isRecord(message)) {
    writeStderr("barshelf sdk: non-object JSON-RPC message ignored");
    return;
  }

  if (("result" in message || "error" in message) && "id" in message) {
    handleResponse(message as unknown as JsonRpcResponse);
    return;
  }

  if (typeof message.method === "string") {
    dispatchNotification(message.method, message.params);
    return;
  }

  writeStderr(
    "barshelf sdk: JSON-RPC message without method/result/error ignored",
  );
}

async function readLoop(): Promise<void> {
  const reader = Deno.stdin.readable.getReader();
  let buffer = "";

  try {
    while (true) {
      const { value, done } = await reader.read();
      if (done) {
        break;
      }

      buffer += decoder.decode(value, { stream: true });

      while (true) {
        const newlineIndex = buffer.indexOf("\n");
        if (newlineIndex === -1) {
          break;
        }

        const rawLine = buffer.slice(0, newlineIndex);
        buffer = buffer.slice(newlineIndex + 1);
        const line = rawLine.endsWith("\r") ? rawLine.slice(0, -1) : rawLine;
        if (line.trim().length > 0) {
          handleLine(line);
        }
      }
    }

    const trailing = buffer + decoder.decode();
    const line = trailing.endsWith("\r") ? trailing.slice(0, -1) : trailing;
    if (line.trim().length > 0) {
      handleLine(line);
    }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    writeStderr(`barshelf sdk: stdin read failed: ${message}`);
  } finally {
    reader.releaseLock();
    const error = new JsonRpcError({
      code: ProtocolErrorCode.ProtocolError,
      message: "JSON-RPC input closed",
    });
    for (const request of pending.values()) {
      request.reject(error);
    }
    pending.clear();
  }
}

function startReadLoop(): void {
  if (readLoopStarted) {
    return;
  }
  readLoopStarted = true;
  void readLoop();
}

export async function render(
  root: UINode,
  options: RenderOptions = {},
): Promise<RenderResult> {
  return await sendRequest<RenderResult>("host.render", {
    root,
    cacheRoot: options.cacheRoot,
    status: options.status,
    nextRefreshAt: options.nextRefreshAt,
    cacheTtlMs: options.cacheTtlMs,
    sensitive: options.sensitive,
    loadGeneration: activeLoadGeneration,
  });
}

export const exec = {
  async run(options: ExecRunOptions): Promise<ExecResult> {
    return await sendRequest<ExecResult>("host.exec.run", {
      command: options.command,
      args: options.args,
      parse: options.parse,
      timeoutMs: options.timeoutMs,
      sensitive: options.sensitive,
      env: options.env,
    });
  },
};

export const storage = {
  async get<T = unknown>(key: string): Promise<T | null> {
    return await sendRequest<T | null>("host.storage.get", { key });
  },

  async set<T = unknown>(key: string, value: T): Promise<void> {
    await sendRequest("host.storage.set", { key, value });
  },

  async delete(key: string): Promise<void> {
    await sendRequest("host.storage.delete", { key });
  },

  async list(prefix?: string): Promise<string[]> {
    return await sendRequest<string[]>("host.storage.list", { prefix });
  },
};

export const secret = {
  async get(key: string): Promise<string | null> {
    return await sendRequest<string | null>("host.secret.get", { key });
  },

  async set(key: string, value: string): Promise<void> {
    await sendRequest("host.secret.set", { key, value });
  },
};

export const timer = {
  async once(id: string, atMs: number): Promise<void> {
    await sendRequest("host.timer.once", { id, atMs });
  },

  async after(id: string, delayMs: number): Promise<void> {
    await sendRequest("host.timer.after", { id, delayMs });
  },

  async every(id: string, intervalMs: number): Promise<void> {
    await sendRequest("host.timer.every", { id, intervalMs });
  },

  async clear(id: string): Promise<void> {
    await sendRequest("host.timer.clear", { id });
  },
};

export const notify = {
  async show(options: NotifyOptions): Promise<void> {
    await sendRequest("host.notify.show", options);
  },
};

export async function log(level: LogLevel, message: string): Promise<void> {
  await sendRequest("host.log", { level, message });
}

function widget(newHandlers: WidgetHandlers): WidgetRegistration {
  handlers = newHandlers;
  startReadLoop();
  return { handlers: newHandlers };
}

export const barshelf = {
  widget,
  render,
  menuBar,
  exec,
  storage,
  secret,
  timer,
  notify,
  log,
};

export const bsf = barshelf;

export default barshelf;
