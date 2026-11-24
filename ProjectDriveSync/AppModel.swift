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

    var comparison: Comparison?
    /// True while only looking (nothing is being changed).
    var isComparing = false
    var errorMessage: String?
    /// The file open in the side-by-side review.
    var reviewing: DiffItem?
    var update: UpdateAlert?
    var isCheckingUpdate = false

    struct UpdateAlert: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        let page: URL?
    }

    @ObservationIgnored private var fullLog: [LogEntry] = []
    @ObservationIgnored private var unflushed = 0
    @ObservationIgnored private var engine: SyncEngine?
    /// Open the comparison again after this run ("Do This Now", or items were held back).
    @ObservationIgnored private var compareAfter: Comparison?
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
        "\(Place.name(pair.pathA)) ⇄ \(Place.name(pair.pathB))"
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: Compare and sync

    private func makeEngine(_ pair: SyncPair, logging: Bool) -> SyncEngine {
        SyncEngine(
            pair: pair,
            logDirectory: logging ? Self.logDirectory : nil,
            log: { [weak self] entry in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.receive(entry) } }
            },
            progress: { [weak self] p in
                DispatchQueue.main.async { MainActor.assumeIsolated { if self?.isBusy == true { self?.progress = p } } }
            })
    }

    private func begin(_ phase: String, _ pair: SyncPair, logging: Bool) -> SyncEngine {
        isBusy = true
        progress = SyncProgress(phase: phase)
        let engine = makeEngine(pair, logging: logging)
        self.engine = engine
        if logging { lastLogFile = engine.logFileURL }
        return engine
    }

    private func availablePair() -> SyncPair? {
        refreshAvailability(manual: false)
        if let pair = selectedPair { return pair }
        errorMessage = "Choose an available pair first. Both of its locations must be connected."
        return nil
    }

    /// Only looks. Nothing on either drive is changed.
    func startCompare() {
        guard !isBusy, let pair = availablePair() else { return }
        compare(pair, keeping: nil)
    }

    func refreshComparison() {
        guard !isBusy, let c = comparison else { return }
        compare(c.pair, keeping: c)
    }

    private func compare(_ pair: SyncPair, keeping old: Comparison?) {
        let engine = begin("Comparing…", pair, logging: false)
        isComparing = true
        Task.detached {
            do {
                let plan = try engine.prepare(readOnly: true)
                await MainActor.run {
                    let c = Comparison(pair: pair, plan: plan, keeping: old)
                    self.comparison = c
                    self.addLog("Compared \(pair.name): \(c.changeCount) difference(s). Nothing was changed.", .success)
                    self.endBusy()
                    self.progress = nil
                }
            } catch {
                await MainActor.run { self.finish(error: error) }
            }
        }
    }

    func closeComparison() {
        guard !isBusy else { return }
        comparison = nil
    }

    func startSync() {
        guard !isBusy, let pair = availablePair() else { return }
        if UserDefaults.standard.bool(forKey: Self.compareFirstKey) { compare(pair, keeping: nil); return }
        let engine = begin("Preparing…", pair, logging: true)
        addLog("Sync started: \(pair.name) (\(route(for: pair)))")
        flushLog()
        Task.detached {
            do {
                let plan = try engine.prepare()
                await MainActor.run { self.planReady(plan, engine: engine, pair: pair) }
            } catch {
                await MainActor.run { self.finish(error: error) }
            }
        }
    }

    static let compareFirstKey = "alwaysCompareFirst"

    private func planReady(_ plan: SyncPlan, engine: SyncEngine, pair: SyncPair) {
        for line in plan.summary.lines { addLog("Plan: \(line)") }
        flushLog()
        guard plan.summary.needsConfirmation else { run(plan, engine: engine, pair: pair); return }
        let s = plan.summary
        var why: [String] = []
        if s.mergeMode { why.append("there is no matching record of an earlier sync, so nothing is treated as deleted") }
        if s.deletions > 0 { why.append("something would be deleted") }
        if s.clashes > 0 { why.append("a file was edited on both drives") }
        if why.isEmpty { why.append("many old versions would go to the Trash") }
        addLog("Sync paused for review. Nothing has been changed.", .warning)
        comparison = Comparison(pair: pair, plan: plan,
                                notice: "Sync paused here because " + why.joined(separator: ", and ") + ". Check the choices, then press Apply.")
        progress = nil
        endBusy()
    }

    /// Carries out the choices in the comparison. `limit` = "Do This Now" for those items only.
    func apply(limit: Set<String>? = nil) {
        guard !isBusy, let c = comparison else { return }
        refreshAvailability(manual: false)
        guard statuses[c.pair.id]?.isAvailable == true else {
            errorMessage = "One of the two locations isn't connected any more. Nothing was changed."
            return
        }
        let review = c.review(limit: limit)
        let engine = begin("Checking again…", c.pair, logging: true)
        addLog(limit == nil ? "Applying choices: \(c.pair.name) (\(route(for: c.pair)))" : "Doing selected item(s) now: \(c.pair.name)")
        flushLog()
        compareAfter = limit == nil ? nil : c
        if limit == nil { comparison = nil }
        Task.detached {
            do {
                let plan = try engine.prepare(review: review)
                await MainActor.run {
                    for line in plan.summary.lines { self.addLog("Plan: \(line)") }
                    if plan.summary.heldBack > 0 { self.compareAfter = c }
                    self.run(plan, engine: engine, pair: c.pair)
                }
            } catch {
                await MainActor.run {
                    self.comparison = c
                    self.finish(error: error)
                }
            }
        }
    }

    private func run(_ plan: SyncPlan, engine: SyncEngine, pair: SyncPair) {
        Task.detached {
            do {
                let result = try engine.execute(plan)
                await MainActor.run { self.finish(result, plan: plan, pair: pair) }
            } catch {
                await MainActor.run { self.finish(error: error) }
            }
        }
    }

    func cancelSync() { engine?.cancel() }

    private func endBusy() {
        isBusy = false
        isComparing = false
        engine?.releaseLocks()
        engine = nil
        flushLog()
        refreshAvailability(manual: false)
    }

    private func finish(_ result: SyncResult, plan: SyncPlan, pair: SyncPair) {
        if !plan.partial, let date = result.lastSync, let i = pairs.firstIndex(where: { $0.id == pair.id }) {
            pairs[i].lastSync = date
            try? PairStore.save(pairs)
        }
        let summary = "Copied \(result.copied) file(s) (\(Fmt.bytes(result.bytesCopied))), \(result.trashed) item(s) to Trash."
        let left = plan.summary.skipped + plan.summary.clashes + plan.summary.heldBack
        if result.errors > 0 {
            addLog("Sync finished with \(result.errors) error(s). \(summary) Problem items were left as they were; run Sync again after fixing them.", .error)
        } else if plan.partial {
            addLog("Done. \(summary)", .success)
        } else if left > 0 {
            addLog("Sync complete. \(summary) \(left) item(s) left as they were.", .warning)
        } else {
            addLog("Sync complete. \(summary)", .success)
        }
        endBusy()
        if let c = compareAfter {
            compareAfter = nil
            compare(pair, keeping: c)
        }
    }

    private func finish(error: Error) {
        if case SyncError.cancelled = error {
            addLog(isComparing ? "Comparison cancelled. Nothing was changed."
                               : "Cancelled. Partial copies were removed. Press Sync Pair to finish later; nothing is lost.", .warning)
            progress?.phase = "Cancelled"
        } else {
            addLog("Stopped: \(error.localizedDescription)", .error)
            progress?.phase = "Stopped"
            errorMessage = error.localizedDescription
        }
        // What is on screen may be out of date after a run that stopped part-way.
        if compareAfter != nil && !isComparing { comparison = nil }
        compareAfter = nil
        endBusy()
    }

    // MARK: Updates (only when asked)

    func checkForUpdates() {
        guard !isCheckingUpdate else { return }
        isCheckingUpdate = true
        Task {
            let outcome = await UpdateChecker.check()
            isCheckingUpdate = false
            switch outcome {
            case .upToDate:
                update = UpdateAlert(title: "You're up to date", message: "Version \(Fmt.appVersion) is the latest release.", page: nil)
            case .available(let r):
                update = UpdateAlert(title: "Version \(r.version) is available",
                                     message: "You have version \(Fmt.appVersion). The download page opens in your browser; quit this app before replacing it.", page: r.page)
            case .noRelease:
                update = UpdateAlert(title: "No release found", message: "There is no public release to compare with yet.", page: nil)
            case .failed(let why):
                update = UpdateAlert(title: "Couldn't check for updates", message: why, page: nil)
            }
        }
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
