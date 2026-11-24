import SwiftUI
import AppKit

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Digital Drive Linkages", id: "main") {
            ContentView(model: AppModel.shared)
        }
        .defaultSize(width: 820, height: 780)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppModel.shared.checkForUpdates() }
            }
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillFinishLaunching(_ notification: Notification) { ReviewFiles.clear() }

    #if DEBUG
    /// Debug builds only: PDS_SNAPSHOT=/path.png writes a picture of the window (used to check layout).
    func applicationDidFinishLaunching(_ notification: Notification) {
        let env = ProcessInfo.processInfo.environment
        if env["PDS_AUTOSYNC"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { AppModel.shared.startSync() } }
        if env["PDS_AUTOCOMPARE"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { AppModel.shared.startCompare() } }
        if let id = env["PDS_SELECT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { AppModel.shared.comparison?.selection = [id] }
        }
        if env["PDS_REVIEW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let c = AppModel.shared.comparison, let id = c.selection.first, let item = c.items[id] {
                    AppModel.shared.reviewing = item
                }
            }
        }
        if env["PDS_APPLY"] != nil { DispatchQueue.main.asyncAfter(deadline: .now() + 3) { AppModel.shared.apply() } }
        guard let path = ProcessInfo.processInfo.environment["PDS_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["PDS_SNAPSHOT_DELAY"] ?? "2") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let main = NSApp.windows.first(where: { $0.isVisible }), let view = (main.attachedSheet ?? main).contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isBusy, !AppModel.shared.isComparing else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "A sync is still running"
        alert.informativeText = "If you quit now the sync stops safely. Half-copied files are cleaned up and the next sync carries on from where this one stopped."
        alert.addButton(withTitle: "Keep Syncing")
        alert.addButton(withTitle: "Quit Anyway")
        if alert.runModal() == .alertSecondButtonReturn {
            AppModel.shared.cancelSync()
            return .terminateNow
        }
        return .terminateCancel
    }
}
