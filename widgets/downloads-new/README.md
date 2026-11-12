# Downloads

Shows what arrived in a folder (Downloads by default) since you last looked,
and the newest few files with thumbnails.

## What it shows

- The folder name and how many entries it holds (500+ past the 500 it reads).
- "3 new files since 09:12": files modified after the last time you marked
  the folder as seen. New files carry a **New** badge.
- The five newest files. Click one to open it, drag it out, or use the
  magnifying glass to reveal it in Finder.

"Last looked" moves only when you ask: **Mark as Seen** or the card's
Refresh. Opening the popup does not reset it, so a file stays new until you
have seen it. The first reading sets the starting point. Hidden files are
skipped.

## Settings

| Setting | Default | Effect |
|---|---|---|
| Folder | `~/Downloads` | Which folder to watch. |

## Permissions and refresh

The widget reads file names and dates in the chosen folder (never their
contents) and keeps one timestamp in widget storage. It watches the folder,
so the card follows new files without polling. The menu bar item shows the
number of new files. A folder that was moved or deleted is reported as such.
