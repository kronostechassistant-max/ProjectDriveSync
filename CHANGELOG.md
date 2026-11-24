# Project Drive Sync — Journal

To release a new version: raise `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `ProjectDriveSync.xcodeproj/project.xcproj`, add an entry below, then run `./build-and-install.sh`. The app reads its version number from the build settings, so the window and logs update on their own.

---

## Version 1.0 (build 1) — 3 November 2026

First release. Built 2–3 November 2026 by Kronos Technologies with Claude Code.

### What it does
- Syncs two folders that have the same name, usually on external drives. A sync runs only when you press **Sync Pair**; there is no background watching.
- Keeps two versions of every file. The newest keeps its plain name (`report.docx`) and the previous one becomes `report_past.docx`, in the same folder.
- Writes a file map, "[folder name], file structure - YYYYMMDD, HHMM.txt", into both folders after each sync.
- Detects new and deleted files and folders using a hidden record in each folder, so a new folder isn't deleted and a deleted one isn't brought back.
  - The first sync of a pair only merges and never deletes.
  - Removed items go to the drive's Trash.
- Shows a progress bar with live transfer speed, time remaining and item count. Cancel is safe.
- Shows a pair list with availability and last-synced times. The drop-down updates when drives are connected or ejected, and **Check Pairs** refreshes it on demand.
- Has a log that refreshes every 50 entries and shows the latest 12. Full logs go to `~/Library/Logs/ProjectDriveSync/`.

### Decisions made for this version
- If you delete the current file on one side and the other side is unchanged, every version of that document is deleted on both sides. If you delete only the `_past` file, it is copied back.
- A file already named `…_past` that has no current partner keeps its name.
- If one pick is a whole drive, a folder with the other side's name is created on that drive. If both picks are whole drives, each gets a new folder named "Untitled, Synced Folder".
- Before a large deletion (25 items or more, or 20% of files) or a first merge with changes, the app asks you to confirm.
- Version matching allows 2 seconds of clock difference, plus a 1-hour daylight-saving shift for FAT32 drives.

### Testing
- 17 headless engine scenarios, all passing.
- An independent data-loss review found 7 bugs, all fixed before release.
- An end-to-end sync through the app (123 files) succeeded.
- 3 November 2026: the owner tested it on their own drives and it worked as intended, so v1.0 is approved.

### Known limits
- Runs only on Apple Silicon Macs with macOS 27.2 or later. A build for Intel Macs and macOS 14 or later is possible.
- Ad-hoc signed, not notarized. On another Mac you may need System Settings → Privacy & Security → **Open Anyway**.
- Pairs are saved per user account and don't travel with the app.
- There's no way to edit a pair. If a synced folder is renamed or moved, remove the pair and create it again.
