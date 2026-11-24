import AppKit
import Observation

@Observable
final class AppModel {
    static let shared = AppModel()

    static let visibleLogLines = 12
    static let logRefreshEvery = 50

    var pairs: [SyncPair] = []
    var statuses: [UUID: PairStatus] = [:]
    var selectedPairID: UUID?
    var lastChecked: Date?

    var isBusy = false
    var progress: SyncProgress?
    var visibleLog: [LogEntry] = []
    var lastLogFile: URL?

    var pendingConfirmation: PendingSync?
    var errorMessage: String?

    struct PendingSync: Identifiable {
        let id = UUID()
        let pair: SyncPair
        let summary: PlanSummary
    }

    @ObservationIgnored private var fullLog: [LogEntry] = []
    @ObservationIgnored private var unflushed = 0
    @ObservationIgnored private var engine: SyncEngine?
    @ObservationIgnored private var pendingPlan: SyncPlan?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    static var logDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ProjectDriveSync", isDirectory: true)
    }

    var availablePairs: [SyncPair] { pairs.filter { statuses[$0.id]?.isAvailable == true } }

    var selectedPair: SyncPair? { availablePairs.first { $0.id == selectedPairID } }

    init() {
        pairs = PairStore.load()
        refreshAvailability(manual: false)
        addLog("Project Drive Sync \(Fmt.appVersion). Ready. \(availablePairs.count) of \(pairs.count) pair(s) available.")
        flushLog()

        // Keep the drop-down current when drives are plugged in or ejected. This only checks
        // whether the folders exist — no file watching, nothing syncs until you press Sync Pair.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshAvailability(manual: false) }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAvailability(manual: false) }
        })
    }

    // MARK: Pairs

    func refreshAvailability(manual: Bool) {
        for pair in pairs { statuses[pair.id] = PairStore.status(of: pair) }
        lastChecked = Date()
        if selectedPair == nil { selectedPairID = availablePairs.first?.id }
        if manual {
            addLog("Checked pairs: \(availablePairs.count) of \(pairs.count) available.")
            for pair in pairs where statuses[pair.id]?.isAvailable != true {
                addLog("\(pair.name): \(statuses[pair.id]?.label ?? "unknown")", .warning)
            }
            flushLog()
        }
    }

    /// Returns an error message, or nil on success.
    func createPair(pathA: String, pathB: String) -> String? {
        switch PairStore.makePair(pathA: pathA, pathB: pathB, existing: pairs) {
        case .failure(let e):
            return e.message
        case .success(let pair):
            pairs.append(pair)
            do { try PairStore.save(pairs) } catch { return "Could not save the pair: \(error.localizedDescription)" }
            refreshAvailability(manual: false)
            selectedPairID = pair.id
            addLog("Created pair \"\(pair.name)\" (\(route(for: pair))). Press Sync Pair to run its first sync.", .success)
            flushLog()
            return nil
        }
    }

    func removePair(_ pair: SyncPair) {
        pairs.removeAll { $0.id == pair.id }
        statuses[pair.id] = nil
        try? PairStore.save(pairs)
        refreshAvailability(manual: false)
        addLog("Removed pair \"\(pair.name)\". No files were touched.")
        flushLog()
    }

    func route(for pair: SyncPair) -> String {
        "\(Self.placeName(pair.pathA)) ⇄ \(Self.placeName(pair.pathB))"
    }

    static func placeName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count >= 2 && parts[0] == "Volumes" { return String(parts[1]) }
        return "This Mac"
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Sync

    func startSync() {
        guard !isBusy else { return }
        refreshAvailability(manual: false)
        guard let pair = selectedPair else {
            errorMessage = "Choose an available pair first. Both of its locations must be connected."
            return
        }
        isBusy = true
        progress = SyncProgress(phase: "Preparing…")
        addLog("Sync started: \(pair.name) (\(route(for: pair)))")
        flushLog()

        let engine = SyncEngine(
            pair: pair,
            logDirectory: Self.logDirectory,
            log: { [weak self] entry in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(entry) } }
            },
            progress: { [weak self] p in
                DispatchQueue.main.async { MainActor.assumeIsolated { if self?.isBusy == true { self?.progress = p } } }
            })
        self.engine = engine
        lastLogFile = engine.logFileURL

        Task.detached {
            do {
                let plan = try engine.prepare()
                await MainActor.run { self.planReady(plan, pair: pair) }
            } catch {
                await MainActor.run { self.finish(error: error) }
            }
        }
    }

    private func planReady(_ plan: SyncPlan, pair: SyncPair) {
        for line in plan.summary.lines { addLog("Plan: \(line)") }
        flushLog()
        if plan.summary.needsConfirmation {
            pendingPlan = plan
            pendingConfirmation = PendingSync(pair: pair, summary: plan.summary)
        } else {
            run(plan, pair: pair)
        }
    }

    func confirmPendingSync() {
        guard let plan = pendingPlan, let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        pendingPlan = nil
        run(plan, pair: pending.pair)
    }

    func declinePendingSync() {
        guard pendingConfirmation != nil else { return }
        pendingConfirmation = nil
        pendingPlan = nil
        addLog("Sync cancelled before making any changes.", .warning)
        finish(result: nil)
    }

    private func run(_ plan: SyncPlan, pair: SyncPair) {
        guard let engine else { return }
        Task.detached {
            do {
                let result = try engine.execute(plan)
                await MainActor.run { self.finish(result: result, pair: pair) }
            } catch {
                await MainActor.run { self.finish(error: error) }
            }
        }
    }

    func cancelSync() {
        engine?.cancel()
        if pendingConfirmation != nil { declinePendingSync() }
    }

    private func finish(result: SyncResult?, pair: SyncPair? = nil) {
        if let result, let pair, let date = result.lastSync, let i = pairs.firstIndex(where: { $0.id == pair.id }) {
            pairs[i].lastSync = date
            try? PairStore.save(pairs)
            let summary = "Copied \(result.copied) file(s) (\(Fmt.bytes(result.bytesCopied))), \(result.trashed) item(s) to Trash."
            if result.errors == 0 {
                addLog("Sync complete. \(summary)", .success)
            } else {
                addLog("Sync finished with \(result.errors) error(s). \(summary) Problem items were left as they were; run Sync again after fixing them.", .error)
            }
        }
        isBusy = false
        engine = nil
        if result == nil { progress = nil }
        flushLog()
        refreshAvailability(manual: false)
    }

    private func finish(error: Error) {
        if case SyncError.cancelled = error {
            addLog("Sync cancelled. Partial copies were removed. Press Sync Pair to finish later; nothing is lost.", .warning)
            progress?.phase = "Cancelled"
        } else {
            addLog("Sync stopped: \(error.localizedDescription)", .error)
            progress?.phase = "Stopped"
            errorMessage = error.localizedDescription
        }
        isBusy = false
        engine = nil
        pendingPlan = nil
        flushLog()
        refreshAvailability(manual: false)
    }

    // MARK: Log

    private func receive(_ entry: LogEntry) {
        append(entry)
        // Shown in batches of 50 so the list stays readable during big syncs; errors show at once.
        if unflushed >= Self.logRefreshEvery || entry.level == .error { flushLog() }
    }

    private func addLog(_ text: String, _ level: LogEntry.Level = .info) {
        append(LogEntry(time: Date(), level: level, text: text))
    }

    private func append(_ entry: LogEntry) {
        fullLog.append(entry)
        if fullLog.count > 500 { fullLog.removeFirst(fullLog.count - 500) }
        unflushed += 1
    }

    private func flushLog() {
        visibleLog = Array(fullLog.suffix(Self.visibleLogLines))
        unflushed = 0
    }

    func openFullLog() {
        if let url = lastLogFile, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            try? FileManager.default.createDirectory(at: Self.logDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(Self.logDirectory)
        }
    }
}
