# R10 — Landing page (barshelf.jiun.dev)

## Deliverable
Static, self-contained landing page for BarShelf, deployable to GitHub Pages / any static host.

## Files (owned scope: `site/**`)
- `site/index.html` — single-file landing page. All CSS inline in `<head>`; no external CDN/JS/font requests. Fonts = `system-ui` stack.
- `site/icon-512.png` — copied from `assets/media/icon-512.png` (source untouched), referenced relatively.

## Sections
1. Sticky header + nav (Features / Execution / Widgets / Install / GitHub / Download).
2. Hero — app icon, "BarShelf", tagline "Your menu bar, finally organized.", Download button → releases/latest, GitHub link, fact badges, a CSS-only popover mock (screenshot placeholder comment beside it).
3. Values (4 cards): One icon many widgets / CLI is the API / Native not web / Three ways to build.
4. Three execution layers: exec / workflow / script, each with a flow line + isolation note.
5. Widget gallery table: hello, aas Usage, OTPeek, Recent Files, Script Clock (layer + description).
6. Install (3 steps): release zip (notarized double-click), Homebrew cask, mbk CLI + requirements note + `<!-- 스크린샷 자리 -->` placeholder block.
7. Footer: Product / Documentation / Project + License MIT © Jiun Bae.

## Facts used (verified from README.md + Casks/barshelf.rb)
- GitHub org/repo: `Open330/barshelf`. Download: https://github.com/Open330/barshelf/releases/latest
- Homebrew: `brew tap Open330/barshelf https://github.com/Open330/barshelf` then `brew install --cask Open330/barshelf/barshelf`
- macOS 13+ (Ventura), Apple Silicon (arm64). Developer ID signed + Apple-notarized (double-click, no Gatekeeper dance).
- Zero runtime dependencies (Deno optional, script-only). 161 tests. MIT © Jiun Bae.
- Docs links point to GitHub blob/main/docs/* (site is standalone, docs live in repo).

## Design
- Palette from icon: deep teal (#071b21–#1f5361), mint green (#4fcf9c / #74e3b4 / #92ecc6), cream (#f2ecda). CSS variables.
- Dark theme default; light mode via `prefers-color-scheme` (cream canvas, teal accents).
- Responsive grids collapse at 900/860/820/780/720/520px. Reduced-motion respected.
- Accessibility: skip link, semantic landmarks, `:focus-visible`, alt text on icon (decorative icons `alt=""`/`aria-hidden`), table with `<caption>`/`scope`, screenshot placeholder as `role="img"`.

## Validation
`python3 -c "import html.parser; html.parser.HTMLParser().feed(open('site/index.html').read())"` → `html ok`.
Browser not run (unavailable) — markup well-formedness only.

## Notes / TODO for later
- Replace CSS popover mock + `.shot` placeholder with real screenshots (comments mark spots).
- `barshelf://install` deep link and `mbk` are documented but not linked as live buttons.
- No commit made (per instructions).
