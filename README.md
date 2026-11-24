# Digital Drive Linkages

A macOS app that keeps two folders with the same name in step, usually on external drives. It acts only when you ask: there is no background watching.

Requires macOS 14 or later. Runs on Apple Silicon and Intel Macs.

## Install
1. Download the `.zip` from **Releases** and open it.
2. Move **Digital Drive Linkages** to your Applications folder.
3. The first time you open it, macOS may block it because the app isn't notarized by Apple. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**. You may be asked once more to allow access to your drives.

To update, use **Check for Updates**, download the new version, quit the app and replace it. Your pairs are kept.

Coming from **Project Drive Sync** (the earlier name)? Quit it, install Digital Drive Linkages, then move the old app to the Trash. Your pairs carry over.

## Use
- **Create Synced Pair:** choose the same-named folder in two places.
- **Compare:** one tree shows what differs on each drive and what would happen. Looking changes nothing. Change the action on any row, then press **Apply**, or use **Do This Now** for one item.
- **Sync Pair:** carries over ordinary changes at once. If anything would be deleted, or a file was edited on both drives, it stops at the comparison first.

The newest version of a file keeps its name and the previous one becomes `name_past`. Removed items go to the Trash. Files are compared by size and date, not by contents.

## Develop
- `./run-tests.sh` runs the engine tests in a temporary folder.
- `./build-and-install.sh` builds the app and puts it on the Desktop. Add `--package` to make the release file.
- `CHANGELOG.md` is the journal.
