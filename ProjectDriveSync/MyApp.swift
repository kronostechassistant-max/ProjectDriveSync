import SwiftUI
import AppKit

@main struct MyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Project Drive Sync", id: "main") {
            ContentView(model: AppModel.shared)
        }
        .defaultSize(width: 820, height: 780)
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    #if DEBUG
    /// Debug builds only: PDS_SNAPSHOT=/path.png writes a picture of the window (used to check layout).
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["PDS_AUTOSYNC"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { AppModel.shared.startSync() }
            Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                MainActor.assumeIsolated {
                    if AppModel.shared.pendingConfirmation != nil { AppModel.shared.confirmPendingSync() }
                }
            }
        }
        guard let path = ProcessInfo.processInfo.environment["PDS_SNAPSHOT"] else { return }
        let delay = Double(ProcessInfo.processInfo.environment["PDS_SNAPSHOT_DELAY"] ?? "2") ?? 2
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard let view = NSApp.windows.first(where: { $0.isVisible })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard AppModel.shared.isBusy else { return .terminateNow }
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
