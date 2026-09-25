#!/usr/bin/env python3
"""Generates the landing site's widget pages from the registry.

    python3 scripts/build-widget-pages.py <site-dir>

Writes `<site-dir>/widgets/index.html` (every registry entry),
`<site-dir>/widgets/<slug>/index.html` for each widget with enough to say, and
`<site-dir>/sitemap.xml`. The Pages workflow runs it after staging `site/`.

A widget gets its own page only when it has a real preview render and either a
README or a substantial registry description. The rest stay on the index page
under an anchor: a page that only repeats one sentence is thin content, and a
pile of those counts against the whole site in search. Adding a preview and a
README to a widget is all it takes to give it a page.

Everything comes from `registry/index.json`, `widgets/<slug>/`, and
`assets/widget-previews/`, so the pages cannot drift from what ships.
"""
from __future__ import annotations

import html
import json
import pathlib
import re
import shutil
import sys
from urllib.parse import quote

ROOT = pathlib.Path(__file__).resolve().parent.parent
SITE_URL = "https://barshelf.jiun.dev"
REPO_URL = "https://github.com/Open330/barshelf"
BUNDLED_PREFIX = f"{REPO_URL}/tree/main/widgets/"
PREVIEWS = ROOT / "assets" / "widget-previews"

MIN_README_WORDS = 80
MIN_DESCRIPTION_WORDS = 30

# Preview files named before the widget ids settled.
PREVIEW_ALIASES = {"aas-usage": "aas", "otpeek": "otp", "recent-files-grid": "files"}

# Search-facing titles for widgets whose names are not what people type.
TITLES = {
    "aas-usage": "Claude Code and Codex usage in the macOS menu bar",
    "otpeek": "OTP codes in the macOS menu bar",
    "developer-inbox": "GitHub review requests and notifications in the macOS menu bar",
    "sensors": "Mac temperatures, fans and power in the menu bar",
    "system": "CPU, memory and disk in the macOS menu bar",
    "muxa-watch": "Watch coding agents from the macOS menu bar",
    "codex-reset": "Will Codex reset? A quota reset forecast in the macOS menu bar",
    "github-status": "GitHub status in the macOS menu bar",
    "network": "Network speed and local IP in the macOS menu bar",
    "exchange": "USD to KRW exchange rate in the macOS menu bar",
    "stock": "Stock prices in the macOS menu bar",
    "battery-meter": "Battery percentage in the macOS menu bar",
    "now-playing": "Now playing from Music or Spotify in the macOS menu bar",
    "weather": "Weather in the macOS menu bar",
}

# Widgets that live in another repository have no README here. Say what the
# companion tool is, in words taken from that tool's own README.
INTROS = {
    "aas-usage": (
        "[aas](https://github.com/Open330/aas) lets you use several Claude Code, Codex and other "
        "coding-agent accounts side by side. This widget runs `aas usage --json` and shows every "
        "account's 5-hour and 7-day quota — used, left, and when it resets — in the BarShelf popover.\n\n"
        "Install aas first:\n\n```\nbrew install open330/tap/aas\n```"
    ),
    "otpeek": (
        "[OTPeek](https://github.com/jiunbae/otpeek) is a cross-platform OTP authenticator with a "
        "shared Rust core and a CLI. This widget shows the codes in your OTPeek vault with a countdown, "
        "so a 2FA code is one click away in the menu bar."
    ),
    "muxa-watch": (
        "[Muxa](https://github.com/Open330/muxa) watches the Claude Code, Codex and Gemini CLI sessions "
        "you already run in tmux and tells you which one needs you. This widget puts that list in the "
        "BarShelf popover, one row per agent."
    ),
}

# Registry categories as visitors should read them. "Demo" is a gallery shelf
# name; docs/widgets/README.md calls the same widgets "Everyday".
CATEGORY_LABELS = {"Demo": "Everyday"}


def category_of(widget: dict) -> str:
    category = widget.get("category") or "Other"
    return CATEGORY_LABELS.get(category, category)


KIND_LABELS = {
    "exec": "Command (exec)",
    "workflow": "Workflow (no code)",
    "script": "TypeScript script",
}


def slug_of(widget: dict) -> str:
    return widget["id"].rsplit(".", 1)[-1]


def preview_of(slug: str) -> pathlib.Path | None:
    path = PREVIEWS / f"tile-{PREVIEW_ALIASES.get(slug, slug)}.png"
    return path if path.exists() else None


def readme_of(slug: str) -> str:
    path = ROOT / "widgets" / slug / "README.md"
    return path.read_text() if path.exists() else ""


def manifest_of(slug: str) -> dict:
    path = ROOT / "widgets" / slug / "widget.json"
    return json.loads(path.read_text()) if path.exists() else {}


def has_page(widget: dict) -> bool:
    slug = slug_of(widget)
    if preview_of(slug) is None:
        return False
    return (len(readme_of(slug).split()) >= MIN_README_WORDS
            or len(widget["description"].split()) >= MIN_DESCRIPTION_WORDS)


def is_bundled(widget: dict) -> bool:
    return widget.get("install", {}).get("url", "").startswith(BUNDLED_PREFIX)


# --- Markdown ----------------------------------------------------------------
# Widget READMEs use a small subset: headings, paragraphs, lists, tables,
# fenced code, inline code, links, bold and italics. Anything else renders as
# plain text.

def inline(text: str, base: str) -> str:
    parts = re.split(r"(`[^`]+`)", text)
    out = []
    for part in parts:
        if part.startswith("`") and part.endswith("`") and len(part) > 1:
            out.append(f"<code>{html.escape(part[1:-1])}</code>")
            continue
        part = html.escape(part, quote=False)
        part = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", part)
        part = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<em>\1</em>", part)

        def link(m: re.Match) -> str:
            href = html.unescape(m.group(2))
            if not re.match(r"^[a-z]+:|^#", href):
                href = f"{base}/{href}"
            return f'<a href="{html.escape(href)}" rel="noopener">{m.group(1)}</a>'

        out.append(re.sub(r"\[([^\]]+)\]\(([^)\s]+)\)", link, part))
    return "".join(out)


def markdown(source: str, base: str) -> str:
    lines = source.splitlines()
    out: list[str] = []
    para: list[str] = []
    items: list[str] = []
    list_tag = ""
    i = 0

    def flush() -> None:
        nonlocal list_tag
        if para:
            out.append(f"<p>{inline(' '.join(para), base)}</p>")
            para.clear()
        if items:
            out.append(f"<{list_tag}>" + "".join(f"<li>{inline(t, base)}</li>" for t in items) + f"</{list_tag}>")
            items.clear()
            list_tag = ""

    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped.startswith("```"):
            flush()
            code = []
            i += 1
            while i < len(lines) and not lines[i].strip().startswith("```"):
                code.append(lines[i])
                i += 1
            out.append(f"<pre><code>{html.escape(chr(10).join(code))}</code></pre>")
        elif stripped.startswith("|"):
            flush()
            rows = []
            while i < len(lines) and lines[i].strip().startswith("|"):
                cells = [c.strip() for c in lines[i].strip().strip("|").split("|")]
                if not all(re.fullmatch(r":?-+:?", c) for c in cells):
                    rows.append(cells)
                i += 1
            i -= 1
            head, *rest = rows
            out.append("<table><thead><tr>" + "".join(f"<th>{inline(c, base)}</th>" for c in head)
                       + "</tr></thead><tbody>"
                       + "".join("<tr>" + "".join(f"<td>{inline(c, base)}</td>" for c in r) + "</tr>" for r in rest)
                       + "</tbody></table>")
        elif m := re.match(r"^(#{1,6})\s+(.*)", stripped):
            flush()
            level = len(m.group(1))
            if level > 1:  # the page renders its own h1
                tag = "h2" if level == 2 else "h3"
                out.append(f"<{tag}>{inline(m.group(2), base)}</{tag}>")
        elif m := re.match(r"^([-*]|\d+\.)\s+(.*)", stripped):
            if para:
                flush()
            tag = "ol" if m.group(1)[0].isdigit() else "ul"
            if items and tag != list_tag:
                flush()
            list_tag = tag
            items.append(m.group(2))
        elif not stripped:
            flush()
        elif items and line.startswith((" ", "\t")):
            items[-1] += " " + stripped
        elif stripped.startswith(("![", "<")):
            flush()  # images and raw HTML have no place in the page body
        else:
            if items:
                flush()
            para.append(stripped)
        i += 1
    flush()
    return "\n".join(out)


# --- Pages -------------------------------------------------------------------

CSS = """
:root{--ink:#111315;--muted:#676d72;--paper:#f5f3ef;--panel:#fff;--line:rgba(17,19,21,.12);
--accent:#d85f4b;--max:1040px;--font:-apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;
--mono:ui-monospace,"SF Mono",Menlo,Consolas,monospace;color-scheme:light}
*{box-sizing:border-box}
body{margin:0;background:var(--paper);color:var(--ink);font-family:var(--font);line-height:1.6;-webkit-font-smoothing:antialiased}
a{color:inherit}
img{display:block;max-width:100%;height:auto}
:focus-visible{outline:2px solid var(--accent);outline-offset:3px}
.wrap{width:min(var(--max),calc(100% - 32px));margin:0 auto}
.nav{position:sticky;top:0;z-index:5;background:rgba(245,243,239,.92);backdrop-filter:blur(12px);border-bottom:1px solid var(--line)}
.nav-inner{display:flex;align-items:center;gap:18px;min-height:60px}
.brand{display:flex;align-items:center;gap:10px;font-weight:700;text-decoration:none}
.brand img{width:28px;height:28px;border-radius:7px}
.nav a.link{color:var(--muted);text-decoration:none;font-size:15px}
.spacer{flex:1}
.btn{display:inline-flex;align-items:center;min-height:44px;padding:0 18px;border-radius:10px;font-weight:600;text-decoration:none;border:1px solid transparent}
.btn.dark{background:var(--ink);color:#fff}
.btn.line{border-color:rgba(17,19,21,.22)}
.crumbs{margin:28px 0 0;font-size:14px;color:var(--muted)}
.crumbs a{text-decoration:none}
h1{font-size:clamp(34px,5vw,52px);line-height:1.05;margin:14px 0 12px;letter-spacing:0}
h2{font-size:24px;margin:40px 0 10px}
h3{font-size:18px;margin:28px 0 8px}
.lead{font-size:clamp(17px,2vw,20px);color:#2c3033;max-width:720px;margin:0}
.head{display:grid;grid-template-columns:1.1fr .9fr;gap:40px;align-items:start;padding-bottom:12px}
.shot{background:var(--panel);border:1px solid var(--line);border-radius:18px;padding:18px}
.facts{display:grid;grid-template-columns:max-content 1fr;gap:8px 18px;margin:24px 0 0;font-size:15px}
.facts dt{color:var(--muted)}
.facts dd{margin:0;overflow-wrap:anywhere}
.head>*{min-width:0}
.actions{display:flex;flex-wrap:wrap;gap:12px;margin-top:26px}
.body{max-width:760px}
code{font-family:var(--mono);font-size:.92em;background:rgba(17,19,21,.06);padding:1px 5px;border-radius:5px}
pre{background:#111315;color:#f1efe9;padding:16px 18px;border-radius:12px;overflow-x:auto}
pre code{background:none;padding:0;color:inherit}
.body table{border-collapse:collapse;width:100%;font-size:15px;margin:14px 0;display:block;overflow-x:auto}
.body th,.body td{border-bottom:1px solid var(--line);padding:8px 10px;text-align:left;vertical-align:top}
.body th{color:var(--muted);font-weight:600}
.grid{columns:3 280px;column-gap:16px;margin:18px 0 8px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:16px;padding:18px;display:flex;flex-direction:column;gap:10px;scroll-margin-top:80px;break-inside:avoid;margin:0 0 16px}
.card h3{margin:0;font-size:18px}
.card p{margin:0;color:#2c3033;font-size:15px}
.card .meta{color:var(--muted);font-size:13px}
.card .more{margin-top:auto;font-weight:600;font-size:14px}
.card img{border-radius:10px;border:1px solid var(--line)}
footer{margin-top:72px;border-top:1px solid var(--line);padding:28px 0 40px;color:var(--muted);font-size:14px}
footer .wrap{display:flex;flex-wrap:wrap;gap:18px;align-items:center}
footer a{text-decoration:none}
@media (max-width:820px){.head{grid-template-columns:1fr}.nav a.link{display:none}}
"""


def plain(text: str) -> str:
    return re.sub(r"[`*]", "", text).strip()


def summary(text: str, limit: int = 160) -> str:
    text = plain(text)
    if len(text) <= limit:
        return text
    cut = text[:limit].rsplit(" ", 1)[0].rstrip(",;:—- ")
    return cut + "…"


def document(*, title: str, description: str, path: str, image: str,
             body: str, breadcrumbs: list[tuple[str, str]]) -> str:
    url = f"{SITE_URL}{path}"
    crumbs_ld = json.dumps({
        "@context": "https://schema.org",
        "@type": "BreadcrumbList",
        "itemListElement": [
            {"@type": "ListItem", "position": n, "name": name, "item": f"{SITE_URL}{href}"}
            for n, (name, href) in enumerate(breadcrumbs, 1)
        ],
    }, ensure_ascii=False)
    e = html.escape
    return f"""<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>{e(title)}</title>
  <meta name="description" content="{e(description)}" />
  <link rel="canonical" href="{url}" />
  <meta property="og:type" content="website" />
  <meta property="og:title" content="{e(title)}" />
  <meta property="og:description" content="{e(description)}" />
  <meta property="og:url" content="{url}" />
  <meta property="og:image" content="{image}" />
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:title" content="{e(title)}" />
  <meta name="twitter:description" content="{e(description)}" />
  <meta name="twitter:image" content="{image}" />
  <meta name="theme-color" content="#111315" />
  <link rel="icon" href="/icon-512.png" />
  <script type="application/ld+json">{crumbs_ld}</script>
  <style>{CSS}</style>
</head>
<body>
  <header class="nav">
    <div class="wrap nav-inner">
      <a class="brand" href="/"><img src="/icon-512.png" alt="" />BarShelf</a>
      <a class="link" href="/widgets/">Widgets</a>
      <a class="link" href="{REPO_URL}/blob/main/docs/WIDGET-SPEC.md" rel="noopener">Build a widget</a>
      <span class="spacer"></span>
      <a class="btn dark" href="{REPO_URL}/releases/latest" rel="noopener">Download</a>
    </div>
  </header>
  <main class="wrap">
{body}
  </main>
  <footer>
    <div class="wrap">
      <a class="brand" href="/"><img src="/icon-512.png" alt="" />BarShelf</a>
      <a href="/widgets/">Widgets</a>
      <a href="{REPO_URL}" rel="noopener">GitHub</a>
      <a href="{REPO_URL}/blob/main/docs/GETTING-STARTED.md" rel="noopener">Docs</a>
      <a href="{REPO_URL}/blob/main/docs/PRIVACY.md" rel="noopener">Privacy</a>
      <span class="spacer"></span>
      <span>MIT © Jiun Bae</span>
    </div>
  </footer>
</body>
</html>
"""


def permissions_of(widget: dict) -> str:
    perms = widget.get("permissions") or {}
    parts = []
    for key, value in perms.items():
        if value is True:
            parts.append(key)
        elif isinstance(value, list) and value:
            parts.append(f"{key}: " + ", ".join(f"<code>{html.escape(str(v))}</code>" for v in value))
    return "; ".join(parts) if parts else "None"


def install_block(widget: dict) -> str:
    url = widget.get("install", {}).get("url", "")
    if is_bundled(widget):
        return (
            "<h2>Install</h2>\n"
            "<p>Included with BarShelf. Open the popover, go to the Gallery, and add it. "
            "BarShelf asks you to approve the permissions listed above first.</p>\n"
            "<pre><code>brew install --cask open330/tap/barshelf</code></pre>"
        )
    deep_link = f"barshelf://install?url={quote(url, safe='')}"
    return (
        "<h2>Install</h2>\n"
        f"<p>With BarShelf running, <a href=\"{html.escape(deep_link)}\">install it in one click</a>, "
        "or from the terminal:</p>\n"
        f"<pre><code>barshelf install {html.escape(url)}</code></pre>\n"
        "<p>Don't have BarShelf yet?</p>\n"
        "<pre><code>brew install --cask open330/tap/barshelf</code></pre>"
    )


def widget_page(widget: dict, image_url: str) -> str:
    slug = slug_of(widget)
    name = widget["name"]
    manifest = manifest_of(slug)
    e = html.escape
    kind = manifest.get("entry", {}).get("kind") or widget.get("kind", "")
    facts = [
        ("Category", e(category_of(widget))),
        ("Type", e(KIND_LABELS.get(kind, kind or "—"))),
        ("Requires", e(widget.get("requires") or "Nothing beyond BarShelf")),
        ("Permissions", permissions_of(widget)),
    ]
    if manifest.get("statusItem"):
        facts.append(("Menu bar", "Can show its value live in the menu bar"))
    if interval := manifest.get("refresh", {}).get("interval"):
        facts.append(("Refresh", f"Every {interval} s while visible" if interval < 120
                      else f"Every {interval // 60} min while visible"))
    source = widget.get("install", {}).get("url") or widget.get("homepage", REPO_URL)
    facts.append(("Source", f'<a href="{e(source)}" rel="noopener">{e(source.replace("https://", ""))}</a>'))
    facts_html = "".join(f"<dt>{k}</dt><dd>{v}</dd>" for k, v in facts)

    readme_base = f"{REPO_URL}/blob/main/widgets/{slug}"
    # An external widget's intro reads better than its terse registry line, so
    # it leads and the registry line moves into the body.
    lead, body_md = widget["description"], readme_of(slug)
    if not body_md and slug in INTROS:
        lead, _, rest = INTROS[slug].partition("\n\n")
        body_md = widget["description"] + "\n\n" + rest
    readme = markdown(body_md, readme_base)
    headline = TITLES.get(slug)
    title = f"{headline} — {name} · BarShelf" if headline else f"{name} widget for the macOS menu bar · BarShelf"
    body = f"""    <p class="crumbs"><a href="/">BarShelf</a> › <a href="/widgets/">Widgets</a> › {e(name)}</p>
    <section class="head">
      <div>
        <h1>{e(name)}</h1>
        <p class="lead">{inline(lead, readme_base)}</p>
        <dl class="facts">{facts_html}</dl>
        <div class="actions">
          <a class="btn dark" href="#install">Install</a>
          <a class="btn line" href="{e(source)}" rel="noopener">View source</a>
        </div>
      </div>
      <div class="shot"><img src="preview.png" alt="{e(name)} widget, rendered by BarShelf" /></div>
    </section>
    <section class="body">
{readme}
      <div id="install">
{install_block(widget)}
      </div>
    </section>"""
    return document(
        title=title,
        description=summary(widget["description"]),
        path=f"/widgets/{slug}/",
        image=image_url,
        body=body,
        breadcrumbs=[("BarShelf", "/"), ("Widgets", "/widgets/"), (name, f"/widgets/{slug}/")],
    )


def index_page(widgets: list[dict], paged: set[str]) -> str:
    e = html.escape
    groups: dict[str, list[dict]] = {}
    for w in widgets:
        groups.setdefault(category_of(w), []).append(w)
    sections = []
    for category in sorted(groups):
        cards = []
        for w in sorted(groups[category], key=lambda w: w["name"].lower()):
            slug = slug_of(w)
            thumb = (f'<img src="{slug}/preview.png" alt="" loading="lazy" />' if slug in paged else "")
            link = (f'<a class="more" href="{slug}/">Details →</a>' if slug in paged else
                    f'<a class="more" href="{e(w.get("install", {}).get("url") or REPO_URL)}" rel="noopener">Source →</a>')
            requires = f'<span class="meta">Requires {e(w["requires"])}</span>' if w.get("requires") else ""
            cards.append(f'<article class="card" id="{slug}">{thumb}<h3>{e(w["name"])}</h3>'
                         f'<p>{inline(w["description"], REPO_URL)}</p>{requires}{link}</article>')
        sections.append(f'    <h2>{e(category)}</h2>\n    <div class="grid">{"".join(cards)}</div>')
    body = f"""    <p class="crumbs"><a href="/">BarShelf</a> › Widgets</p>
    <h1>BarShelf widgets</h1>
    <p class="lead">{len(widgets)} native macOS menu bar widgets, from Claude Code and Codex usage to OTP codes,
    GitHub reviews and Mac sensors. Each one runs behind the same BarShelf icon, and any command-line tool can
    become one more.</p>
    <div class="actions">
      <a class="btn dark" href="{REPO_URL}/releases/latest" rel="noopener">Download BarShelf</a>
      <a class="btn line" href="{REPO_URL}/blob/main/docs/WIDGET-SPEC.md" rel="noopener">Build your own</a>
    </div>
{chr(10).join(sections)}"""
    return document(
        title="macOS menu bar widgets — BarShelf widget gallery",
        description=summary(f"{len(widgets)} native macOS menu bar widgets for BarShelf: Claude Code and Codex "
                            "usage, OTP codes, GitHub reviews, Mac sensors, calendar, weather and more."),
        path="/widgets/",
        image=f"{SITE_URL}/shots/macos-menubar-popover-crop.jpg",
        body=body,
        breadcrumbs=[("BarShelf", "/"), ("Widgets", "/widgets/")],
    )


def sitemap(paths: list[str]) -> str:
    urls = "".join(f"  <url>\n    <loc>{SITE_URL}{p}</loc>\n  </url>\n" for p in paths)
    return ('<?xml version="1.0" encoding="UTF-8"?>\n'
            '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n' + urls + "</urlset>\n")


def build(out: pathlib.Path) -> list[str]:
    registry = json.loads((ROOT / "registry" / "index.json").read_text())
    widgets = registry.get("widgets", registry)
    paged = {slug_of(w) for w in widgets if has_page(w)}
    out_widgets = out / "widgets"
    if out_widgets.exists():
        shutil.rmtree(out_widgets)
    out_widgets.mkdir(parents=True)
    for w in widgets:
        slug = slug_of(w)
        if slug not in paged:
            continue
        page_dir = out_widgets / slug
        page_dir.mkdir()
        shutil.copyfile(preview_of(slug), page_dir / "preview.png")
        (page_dir / "index.html").write_text(
            widget_page(w, f"{SITE_URL}/widgets/{slug}/preview.png"))
    (out_widgets / "index.html").write_text(index_page(widgets, paged))
    paths = ["/", "/widgets/"] + [f"/widgets/{slug_of(w)}/" for w in widgets if slug_of(w) in paged]
    (out / "sitemap.xml").write_text(sitemap(paths))
    return paths


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    paths = build(pathlib.Path(sys.argv[1]))
    print(f"ok: {len(paths) - 2} widget pages, sitemap with {len(paths)} URLs")
    return 0


if __name__ == "__main__":
    sys.exit(main())
