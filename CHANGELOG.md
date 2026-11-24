# Project Drive Sync — Journal

To release a new version: raise `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `ProjectDriveSync.xcodeproj/project.xcproj`, add an entry below, then run `./build-and-install.sh`. The app reads its version number from the build settings, so the window and logs update on their own.

---

## Version 1.25 (build 2) — 24 November 2026

Built by Kronos Technologies with Claude Code. Code and releases are on GitHub.

### New
- **Compare:** one tree with a column for each drive, showing what differs, why, and what would happen. Looking changes nothing. Filter by Changes, Review or All, search, and save a report.
- **Choose per item:** copy, restore, delete from both, update, use either drive's version, keep both, or skip. Works on folders and several items at once. **Apply** runs all choices; **Do This Now** runs the selected ones. Anything headed for the Trash is listed first.
- **Review side by side:** text files show changed lines; other files show a preview. Open labelled read-only copies, or edit the originals.
- **Clash protection:** a file edited on both drives is left alone until you choose.
- **Sync Pair** now opens the comparison before any deletion, clash or first sync. "Always compare before syncing" is optional.
- **Check for Updates** (only when pressed).
- Runs on Apple Silicon and Intel, macOS 14 or later.
- Each drive's file map lists what is really on that drive.

### Fixed (present in 1.0)
- An edit made during a sync could be recorded as synced, and later go to the Trash.
- Renaming a file to or from `_past` on one drive could trash it on both.
- A half-finished update (for example a locked file) could lead to every version being trashed.
- Edits to a `_past` file, or a changed file with an older date, could be undone or trashed without asking.
- A file saved while it was being copied could leave a mixed copy.
- Aliases could count as deletions, or be written through to outside the folder.
- Names differing only in capitals, and files like `a.txt_past`, could be merged into one document.
- Edits exactly an hour apart could be missed.
- Two copies of the app could work on one pair at once; a drive swapped mid-sync wasn't noticed.

### The rule behind it
The app only retires a version that its record shows was fully synced on both drives. Anything else needs your choice, with the file named.

### Testing
- 229 checks (`run-tests.sh`), also run with one location on exFAT, FAT32 and case-sensitive APFS.
- A stress test of random edits, deletions, renames, cancels and simulated crashes: 4,000 rounds without a loss, plus shorter runs with one location on exFAT and FAT32.
- Two rounds of data-loss review by an independent reviewer (an AI agent). Findings were fixed and most became tests, except those under Known limits. The fixes after the second round were checked by the tests and the stress test, not by a third review.
- Upgrading from a pair synced by 1.0.

### Known limits
- Not tested on an Intel Mac or on macOS 14 itself.
- Not notarized: other Macs may need **Open Anyway** in Privacy & Security.
- Files are compared by size and date. Two different files with the same size and the same date (within 2 seconds on a first pairing that uses a FAT or exFAT drive) can't be told apart.
- Cancelling a first sync can undo a "use the older version" choice; no version is lost.
- Deletions are asked about the first time after upgrading from 1.0.

### Made public — 24 November 2026
- The repository (code, journal and releases) is public, so anyone can download the app and **Check for Updates** works without signing in.
- Before that, the release file was replaced: debugging information holding folder paths from the Mac that built it was removed, and so was the permission that lets other programs attach to the app. The program code and build number are the same.

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
