import Foundation
import Darwin

// MARK: - Constants & naming

nonisolated enum SyncConstants {
    /// Hidden per-pair record of the last sync, stored in the root of both folders.
    static let stateFilePrefix = ".projectdrivesync-"
    /// Partial copies (safe to delete if left behind).
    static let tempPrefix = ".pds-tmp-"
    /// A user's file parked mid-rename (always restored, never deleted).
    static let holdPrefix = ".pds-hold-"
    static let pastSuffix = "_past"
    /// Timestamps closer than this are "the same" (FAT/exFAT drives store times coarsely).
    static let timeTolerance: TimeInterval = 2.0
    static let structureMarker = ", file structure - "
    /// Used only when a drive has no Trash (e.g. some network shares). Never synced.
    static let removedFolderName = "ProjectDriveSync Removed Items"
    static let ignoredNames: Set<String> = [
        "Thumbs.db", "desktop.ini", "$RECYCLE.BIN", "System Volume Information", "Icon\r",
    ]
}

/// `.updated` is the newest version and keeps the plain name ("report.docx");
/// `.past` is the previous version ("report_past.docx").
nonisolated enum VersionRole: String, Sendable, Codable {
    case updated, past
}

nonisolated enum Naming {
    /// Splits "report.docx" into ("report", "docx"). Only a short alphanumeric tail counts as an
    /// extension, so "Version 2.0 Final" stays whole.
    static func split(_ name: String) -> (stem: String, ext: String) {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        let ext = String(name[name.index(after: dot)...])
        guard (1...12).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              ext.contains(where: { $0.isLetter }) else {
            return (name, "")
        }
        return (String(name[..<dot]), ext)
    }

    static func join(_ stem: String, _ ext: String) -> String { ext.isEmpty ? stem : stem + "." + ext }

    /// "report_past.docx" -> ("report.docx", .past); "report.docx" -> ("report.docx", .updated)
    static func parse(_ fileName: String) -> (logical: String, role: VersionRole) {
        let (stem, ext) = split(fileName)
        let suffix = SyncConstants.pastSuffix
        // Case-insensitive, like the drives themselves: "Plan_Past.docx" is the previous version.
        if stem.count > suffix.count && stem.lowercased().hasSuffix(suffix) {
            return (join(String(stem.dropLast(suffix.count)), ext), .past)
        }
        return (fileName, .updated)
    }

    /// ("report.docx", .past) -> "report_past.docx"
    static func name(logical: String, role: VersionRole) -> String {
        let (stem, ext) = split(logical)
        switch role {
        case .updated: return logical
        case .past: return join(stem + SyncConstants.pastSuffix, ext)
        }
    }

    /// Comparison key: Unicode-normalised and case-insensitive (Mac and exFAT drives are case-insensitive).
    static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    static func joinPath(_ dir: String, _ name: String) -> String { dir.isEmpty ? name : dir + "/" + name }

    static func parent(of relPath: String) -> String {
        guard let slash = relPath.lastIndex(of: "/") else { return "" }
        return String(relPath[..<slash])
    }

    static func lastComponent(_ relPath: String) -> String {
        guard let slash = relPath.lastIndex(of: "/") else { return relPath }
        return String(relPath[relPath.index(after: slash)...])
    }

    /// Proper ancestors of "a/b/c" -> ["a", "a/b"]
    static func ancestors(of key: String) -> [String] {
        var result: [String] = []
        var current = ""
        let parts = key.split(separator: "/", omittingEmptySubsequences: false)
        for part in parts.dropLast() {
            current = current.isEmpty ? String(part) : current + "/" + part
            result.append(current)
        }
        return result
    }
}

// MARK: - Scan model

nonisolated enum Side: Int, Sendable, CaseIterable {
    case a = 0, b = 1
    var other: Side { self == .a ? .b : .a }
    var label: String { self == .a ? "A" : "B" }
}

/// One physical file (or package such as an .rtfd) that is a version of a logical document.
nonisolated struct FileVariant: Sendable, Hashable {
    var relPath: String
    var role: VersionRole
    var size: Int64
    var mtime: Date
    var isPackage: Bool

    var fileName: String { Naming.lastComponent(relPath) }

    func sameVersion(as other: FileVariant) -> Bool {
        size == other.size && Self.sameTime(mtime, other.mtime)
    }

    func matches(_ stamp: VersionStamp) -> Bool {
        size == stamp.size && Self.sameTime(mtime, stamp.mtime)
    }

    /// Equal within 2 s, or exactly one hour apart: FAT32 drives store local time, so a daylight-saving
    /// change shifts every file on them by an hour.
    static func sameTime(_ a: Date, _ b: Date) -> Bool {
        let d = abs(a.timeIntervalSince(b))
        return d <= SyncConstants.timeTolerance || abs(d - 3600) <= SyncConstants.timeTolerance
    }
}

/// A document regardless of suffix: "Clients/report.docx" groups report.docx and report_past.docx.
nonisolated struct LogicalFile: Sendable {
    var key: String
    var parentKey: String
    var parentRel: String
    var logicalName: String
    var variants: [FileVariant]
}

nonisolated struct SideScan: Sendable {
    var root: URL
    var files: [String: LogicalFile] = [:]
    /// folder key -> actual relative path on this side
    var folders: [String: String] = [:]
    var skipped: [String] = []
    /// Folders that could not be read. While any exist, nothing is deleted anywhere.
    var unreadable: [String] = []
    var recovered: [String] = []
    var totalBytes: Int64 = 0
    var fileCount = 0
}

// MARK: - Persistent last-sync record

nonisolated struct VersionStamp: Codable, Sendable {
    var size: Int64
    var mtime: Date
}

nonisolated struct SyncState: Codable, Sendable {
    var pairID: UUID
    var syncID: UUID
    var lastSync: Date
    /// logical file key -> newest version at the last sync
    var files: [String: VersionStamp]
    var folders: [String]
}

// MARK: - Plan model

nonisolated enum SlotSource: Sendable {
    case local(FileVariant)   // already on this side
    case remote(FileVariant)  // must be copied from the other side
}

nonisolated struct Slot: Sendable {
    var role: VersionRole
    var source: SlotSource
}

/// Everything needed to make one side hold exactly: name (newest) + name_past (second newest).
nonisolated struct FileOp: Sendable {
    var side: Side
    var key: String
    var parentKey: String
    var sourceParentRel: String
    var logicalName: String
    var slots: [Slot]
    var displaced: [FileVariant]   // older versions no longer needed -> Trash
    var bytesToCopy: Int64 {
        slots.reduce(0) { total, slot in
            if case .remote(let v) = slot.source { return total + v.size }
            return total
        }
    }
}

nonisolated struct FolderCreate: Sendable {
    var target: Side
    var key: String
    var parentKey: String
    var sourceRel: String
    var depth: Int
}

nonisolated struct DeleteOp: Sendable {
    var side: Side
    var relPath: String
    var isFolder: Bool
    /// What the plan saw: the file itself, or every file inside the folder (by relative path).
    var expectedFiles: [String: FileVariant] = [:]
    /// For folders: every subfolder the plan saw (lower-cased keys).
    var expectedFolders: Set<String> = []
}

nonisolated struct PlanSummary: Sendable {
    var pairName = ""
    var mergeMode = false
    var foldersToCreate = 0
    var filesToCopy = 0
    var bytesToCopy: Int64 = 0
    var versionUpdates = 0
    var displacedVersions = 0
    var filesToDelete = 0
    var foldersToDelete = 0
    var unchanged = 0
    var keptChanged = 0
    var conflicts = 0
    var unreadable = 0
    var deletionsPaused = false
    var totalDocuments = 0

    var deletions: Int { filesToDelete + foldersToDelete }
    var isNoop: Bool { foldersToCreate == 0 && filesToCopy == 0 && versionUpdates == 0 && deletions == 0 }

    /// Ask before running when it's the first sync of a pair, or when lots would be deleted.
    var needsConfirmation: Bool {
        if mergeMode && !isNoop { return true }
        if deletions >= 25 || displacedVersions >= 25 { return true }
        let docs = max(totalDocuments, 1)
        return (deletions > 0 && deletions * 5 >= docs) || (displacedVersions > 0 && displacedVersions * 5 >= docs)
    }

    var lines: [String] {
        var l: [String] = []
        if mergeMode {
            l.append("First sync for this pair (or the last-sync records didn't match): safe merge mode. Nothing will be deleted. Both folders end up with everything from either one.")
        }
        if foldersToCreate > 0 { l.append("\(foldersToCreate) folder(s) will be created.") }
        if filesToCopy > 0 { l.append("\(filesToCopy) file copies, \(Fmt.bytes(bytesToCopy)) total.") }
        if displacedVersions > 0 { l.append("\(displacedVersions) older version(s) beyond the newest and _past will go to the Trash.") }
        if deletions > 0 {
            l.append("\(filesToDelete) document(s) and \(foldersToDelete) folder(s) that were deleted in one location since the last sync will be moved to the Trash in the other.")
        }
        if keptChanged > 0 { l.append("\(keptChanged) item(s) deleted in one location but changed in the other will be kept and restored.") }
        if conflicts > 0 { l.append("\(conflicts) item(s) will be skipped because of a name problem (see log).") }
        if unreadable > 0 { l.append("\(unreadable) item(s) couldn't be read\(deletionsPaused ? ", so no deletions will be carried over this time" : "").") }
        l.append("\(unchanged) document(s) are already up to date.")
        return l
    }
}

nonisolated struct SyncPlan: Sendable {
    var scans: [SideScan]
    var oldState: SyncState?
    var folderCreates: [FolderCreate] = []
    var fileGroups: [[FileOp]] = []
    var deletes: [DeleteOp] = []
    var summary = PlanSummary()
    var notes: [String] = []
}

nonisolated struct SyncResult: Sendable {
    var completed: Bool
    var lastSync: Date?
    var errors: Int
    var copied: Int
    var bytesCopied: Int64
    var trashed: Int
    var structureFileName: String?
}

nonisolated enum SyncError: LocalizedError, Sendable {
    case cancelled
    case locationMissing(String)
    case insufficientSpace(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Sync cancelled."
        case .locationMissing(let s): return "Location not available: \(s)"
        case .insufficientSpace(let s): return s
        case .failed(let s): return s
        }
    }
}

// MARK: - Progress & log

nonisolated struct LogEntry: Sendable, Identifiable {
    enum Level: Sendable { case info, success, warning, error }
    let id = UUID()
    let time: Date
    let level: Level
    let text: String
}

nonisolated struct SyncProgress: Sendable {
    var phase: String = ""
    var fraction: Double? = nil        // nil = indeterminate (scanning)
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var itemsDone = 0
    var itemsTotal = 0
    var bytesPerSecond: Double = 0
    var secondsRemaining: Double? = nil
    var currentItem = ""
}

// MARK: - Engine

/// Runs on a background thread. All mutable state is touched only by that thread, except
/// `cancelled`, which is lock protected.
nonisolated final class SyncEngine: @unchecked Sendable {
    let pair: SyncPair
    let roots: [URL]
    let logFileURL: URL?

    private let fm = FileManager()
    private let lock = NSLock()
    private var cancelled = false
    private let logSink: @Sendable (LogEntry) -> Void
    private let progressSink: @Sendable (SyncProgress) -> Void
    private var logHandle: FileHandle?

    private var progress = SyncProgress()
    private var lastEmit = Date.distantPast
    private var rateSampleTime = Date()
    private var rateSampleBytes: Int64 = 0
    private var smoothedRate: Double = 0
    private var weightDone: Double = 0
    private var weightTotal: Double = 0
    private let opWeight: Double = 256 * 1024   // non-copy work counts like copying 256 KB

    init(pair: SyncPair,
         logDirectory: URL?,
         log: @escaping @Sendable (LogEntry) -> Void,
         progress: @escaping @Sendable (SyncProgress) -> Void) {
        self.pair = pair
        self.roots = [pair.urlA, pair.urlB]
        self.logSink = log
        self.progressSink = progress
        if let dir = logDirectory {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safeName = pair.name.replacingOccurrences(of: "/", with: "-")
            let url = dir.appendingPathComponent("\(safeName) \(Fmt.logFileStamp(Date())).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            if let data = "Project Drive Sync \(Fmt.appVersion)\n".data(using: .utf8) { try? logHandle?.write(contentsOf: data) }
            logFileURL = url
        } else {
            logFileURL = nil
        }
    }

    deinit { try? logHandle?.close() }

    // MARK: Cancellation

    func cancel() { lock.lock(); cancelled = true; lock.unlock() }

    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    private func checkCancel() throws { if isCancelled { throw SyncError.cancelled } }

    // MARK: Logging

    func log(_ text: String, _ level: LogEntry.Level = .info) {
        let entry = LogEntry(time: Date(), level: level, text: text)
        let tag: String
        switch level {
        case .info: tag = "    "
        case .success: tag = "OK  "
        case .warning: tag = "WARN"
        case .error: tag = "ERR "
        }
        if let data = "\(Fmt.full(entry.time)) \(tag) \(text)\n".data(using: .utf8) {
            try? logHandle?.write(contentsOf: data)
        }
        logSink(entry)
    }

    private func root(_ side: Side) -> URL { roots[side.rawValue] }

    private func url(_ side: Side, _ rel: String) -> URL {
        rel.isEmpty ? root(side) : root(side).appendingPathComponent(rel)
    }

    private func sideName(_ side: Side) -> String { "[\(side.label)]" }

    // MARK: Progress

    private func setPhase(_ phase: String, indeterminate: Bool) {
        progress.phase = phase
        progress.fraction = indeterminate ? nil : (weightTotal > 0 ? min(1, weightDone / weightTotal) : 0)
        emit(force: true)
    }

    fileprivate func addCopiedBytes(_ n: Int64) {
        guard n > 0 else { return }
        progress.bytesDone += n
        weightDone += Double(n)
        emit()
    }

    private func finishItem(_ count: Int = 1) {
        progress.itemsDone += count
        weightDone += opWeight * Double(count)
        emit()
    }

    private func emit(force: Bool = false) {
        let now = Date()
        let dt = now.timeIntervalSince(rateSampleTime)
        if dt >= 0.5 {
            let instant = Double(progress.bytesDone - rateSampleBytes) / dt
            smoothedRate = smoothedRate == 0 ? instant : 0.35 * instant + 0.65 * smoothedRate
            rateSampleTime = now
            rateSampleBytes = progress.bytesDone
        }
        guard force || now.timeIntervalSince(lastEmit) >= 0.1 else { return }
        lastEmit = now
        if progress.fraction != nil, weightTotal > 0 { progress.fraction = min(1, weightDone / weightTotal) }
        progress.bytesPerSecond = smoothedRate
        let remainingBytes = Double(max(0, progress.bytesTotal - progress.bytesDone))
        progress.secondsRemaining = (smoothedRate > 1024 && remainingBytes > 0) ? remainingBytes / smoothedRate : nil
        progressSink(progress)
    }

    // MARK: - Scanning

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .contentModificationDateKey, .fileSizeKey,
    ]

    private func shouldIgnore(_ name: String, depth: Int, rootName: String) -> Bool {
        if name.hasPrefix(".") || name.hasPrefix("~$") { return true }
        if SyncConstants.ignoredNames.contains(name) { return true }
        if depth == 0 {
            if name == SyncConstants.removedFolderName { return true }
            if Self.isStructureFileName(name, rootName: rootName) { return true }
        }
        return false
    }

    static func isStructureFileName(_ name: String, rootName: String) -> Bool {
        let k = Naming.key(name)
        return k.hasPrefix(Naming.key(rootName + SyncConstants.structureMarker)) && k.hasSuffix(".txt")
    }

    func scan(_ side: Side) throws -> SideScan {
        let rootURL = root(side)
        guard PairStore.isDirectory(rootURL.path) else { throw SyncError.locationMissing(rootURL.path) }
        var result = SideScan(root: rootURL)
        try walk(dir: rootURL, rel: "", depth: 0, rootName: rootURL.lastPathComponent, into: &result)
        return result
    }

    private func walk(dir: URL, rel: String, depth: Int, rootName: String, into result: inout SideScan) throws {
        try checkCancel()
        var items: [URL]
        do {
            items = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.resourceKeys, options: [])
        } catch {
            if depth == 0 { throw error }
            log("Could not read folder \(rel): \(error.localizedDescription)", .error)
            result.unreadable.append(rel)
            return
        }

        // Clean up after an interrupted sync: drop partial copies, restore parked files.
        var touched = false
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(SyncConstants.tempPrefix) {
                try? fm.removeItem(at: item)
                touched = true
            } else if name.hasPrefix(SyncConstants.holdPrefix) {
                var original = String(name.dropFirst(SyncConstants.holdPrefix.count))
                while original.hasPrefix(SyncConstants.holdPrefix) { original.removeFirst(SyncConstants.holdPrefix.count) }
                // Put it back under a free name of the same document so it rejoins its versions
                // (the newest-by-date rule then sorts out which is newest and which is _past).
                let logical = Naming.parse(original).logical
                let candidates = [original, logical, Naming.name(logical: logical, role: .updated),
                                  Naming.name(logical: logical, role: .past)]
                    + (2...20).map { n -> String in let (st, ex) = Naming.split(logical); return Naming.join("\(st) (recovered \(n))", ex) }
                if let free = candidates.first(where: { !fm.fileExists(atPath: dir.appendingPathComponent($0).path) }) {
                    do {
                        try fm.moveItem(at: item, to: dir.appendingPathComponent(free))
                        result.recovered.append(Naming.joinPath(rel, free))
                        touched = true
                    } catch {
                        log("Could not restore parked file \(Naming.joinPath(rel, name)): \(error.localizedDescription)", .error)
                        result.unreadable.append(rel)
                    }
                } else {
                    log("Could not restore parked file \(Naming.joinPath(rel, name)): no free name", .error)
                    result.unreadable.append(rel)
                }
            }
        }
        if touched {
            items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: Self.resourceKeys, options: [])) ?? items
        }

        for item in items {
            let name = item.lastPathComponent
            if shouldIgnore(name, depth: depth, rootName: rootName) { continue }
            let childRel = Naming.joinPath(rel, name)
            guard let values = try? item.resourceValues(forKeys: Set(Self.resourceKeys)) else {
                log("Could not read \(childRel)", .error)
                result.unreadable.append(childRel)
                continue
            }
            if values.isSymbolicLink == true {
                result.skipped.append(childRel + " (alias/symlink)")
                continue
            }
            let isDir = values.isDirectory == true
            let isPackage = isDir && values.isPackage == true
            if isDir && !isPackage {
                result.folders[Naming.key(childRel)] = childRel
                try walk(dir: item, rel: childRel, depth: depth + 1, rootName: rootName, into: &result)
                continue
            }
            var size = Int64(values.fileSize ?? 0)
            var mtime = values.contentModificationDate ?? .distantPast
            if isPackage { (size, mtime) = packageStats(item, fallback: mtime) }
            let (logical, role) = Naming.parse(name)
            let parentKey = Naming.key(rel)
            let key = Naming.joinPath(parentKey, Naming.key(logical))
            let variant = FileVariant(relPath: childRel, role: role, size: size, mtime: mtime, isPackage: isPackage)
            if result.files[key] == nil {
                result.files[key] = LogicalFile(key: key, parentKey: parentKey, parentRel: rel, logicalName: logical, variants: [])
            }
            result.files[key]!.variants.append(variant)
            result.totalBytes += size
            result.fileCount += 1
        }
    }

    /// A package (e.g. .rtfd, .app) is treated as one file: total size, newest inner timestamp.
    private func packageStats(_ url: URL, fallback: Date) -> (Int64, Date) {
        var size: Int64 = 0
        var newest = fallback
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isSymbolicLinkKey]
        if let en = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: []) {
            for case let child as URL in en {
                let v = try? child.resourceValues(forKeys: keys)
                if v?.isSymbolicLink == true { continue }  // link times aren't kept by every copier
                size += Int64(v?.fileSize ?? 0)
                if let m = v?.contentModificationDate, m > newest { newest = m }
            }
        }
        return (size, newest)
    }

    // MARK: - State file

    private func stateURL(_ side: Side) -> URL {
        root(side).appendingPathComponent("\(SyncConstants.stateFilePrefix)\(pair.id.uuidString).json")
    }

    private func loadState(_ side: Side) -> SyncState? {
        guard let data = try? Data(contentsOf: stateURL(side)) else { return nil }
        return try? JSONDecoder().decode(SyncState.self, from: data)
    }

    private func writeState(_ state: SyncState, _ side: Side) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(state).write(to: stateURL(side), options: .atomic)
    }

    // MARK: - Prepare (scan + plan)

    func prepare() throws -> SyncPlan {
        progress = SyncProgress()
        setPhase("Scanning location A…", indeterminate: true)
        log("Scanning A: \(root(.a).path)")
        let scanA = try scan(.a)
        try checkCancel()
        setPhase("Scanning location B…", indeterminate: true)
        log("Scanning B: \(root(.b).path)")
        let scanB = try scan(.b)
        for (side, s) in [(Side.a, scanA), (Side.b, scanB)] {
            log("\(sideName(side)) \(s.folders.count) folders, \(s.fileCount) files, \(Fmt.bytes(s.totalBytes))")
            for r in s.recovered { log("\(sideName(side)) Restored a file left over from an interrupted sync: \(r)", .warning) }
            for item in s.skipped.prefix(20) { log("\(sideName(side)) Skipped: \(item)", .warning) }
            if s.skipped.count > 20 { log("\(sideName(side)) …and \(s.skipped.count - 20) more skipped", .warning) }
            for item in s.unreadable.prefix(20) { log("\(sideName(side)) Could not read: \(item)", .error) }
        }

        let stateA = loadState(.a), stateB = loadState(.b)
        var trusted: SyncState? = nil
        if let sa = stateA, let sb = stateB, sa.pairID == pair.id, sb.pairID == pair.id, sa.syncID == sb.syncID {
            trusted = sa
            log("Last sync record found (\(Fmt.display(sa.lastSync))). Deletions since then will be carried over.")
        } else if stateA == nil && stateB == nil {
            log("No previous sync record: first sync, safe merge mode (nothing will be deleted).", .warning)
        } else {
            log("Last-sync records in A and B don't match (a location was replaced, or a sync was interrupted). Using safe merge mode: nothing will be deleted.", .warning)
        }

        setPhase("Planning…", indeterminate: true)
        var plan = buildPlan(scans: [scanA, scanB], state: trusted)
        plan.summary.pairName = pair.name
        for note in plan.notes.prefix(30) { log(note, .warning) }
        if plan.notes.count > 30 { log("…and \(plan.notes.count - 30) more notes (see full log)", .warning) }
        for note in plan.notes.dropFirst(30) {
            if let data = "  \(note)\n".data(using: .utf8) { try? logHandle?.write(contentsOf: data) }
        }
        return plan
    }

    private struct Version {
        var rep: FileVariant
        var instances: [(side: Side, variant: FileVariant)]
    }

    private func groupVersions(_ instances: [(side: Side, variant: FileVariant)]) -> [Version] {
        var versions: [Version] = []
        for inst in instances.sorted(by: { $0.variant.mtime > $1.variant.mtime }) {
            if let i = versions.firstIndex(where: { $0.rep.sameVersion(as: inst.variant) }) {
                versions[i].instances.append(inst)
            } else {
                versions.append(Version(rep: inst.variant, instances: [inst]))
            }
        }
        versions.sort { $0.rep.mtime != $1.rep.mtime ? $0.rep.mtime > $1.rep.mtime : $0.rep.size > $1.rep.size }
        return versions
    }

    func buildPlan(scans: [SideScan], state: SyncState?) -> SyncPlan {
        var plan = SyncPlan(scans: scans, oldState: state)
        plan.summary.mergeMode = (state == nil)
        plan.summary.unreadable = scans.reduce(0) { $0 + $1.unreadable.count }
        // If anything couldn't be read, a missing item might just be unreadable: delete nothing this time.
        let deletionState: SyncState? = plan.summary.unreadable == 0 ? state : nil
        if state != nil && deletionState == nil {
            plan.summary.deletionsPaused = true
            plan.notes.append("Some items couldn't be read (see errors), so no deletions are carried over this time. Fix the problem and sync again.")
        }
        let stateFolders = Set(deletionState?.folders ?? [])

        // ---- Files ----
        let allFileKeys = Set(scans[0].files.keys).union(scans[1].files.keys)
        plan.summary.totalDocuments = allFileKeys.count
        var deletedFileKeys = Set<String>()
        var pendingFileDeletes: [(key: String, side: Side, variants: [FileVariant])] = []
        var conflictKeys = Set<String>()

        for key in allFileKeys.sorted() {
            let fa = scans[0].files[key], fb = scans[1].files[key]
            let anyFile = (fa ?? fb)!
            // A file whose name (or its _past name) matches a folder in either location.
            let targetKeys = [key] + [VersionRole.past].map {
                Naming.joinPath(anyFile.parentKey, Naming.key(Naming.name(logical: anyFile.logicalName, role: $0)))
            }
            let clashingFolders = targetKeys.filter { scans[0].folders[$0] != nil || scans[1].folders[$0] != nil }
            if !clashingFolders.isEmpty {
                conflictKeys.insert(key)
                conflictKeys.formUnion(clashingFolders)
                plan.summary.conflicts += 1
                plan.notes.append("Skipped \"\(Naming.joinPath(anyFile.parentRel, anyFile.logicalName))\": a folder has the same name as this file (or its _past name). Rename one of them.")
                continue
            }
            if Naming.name(logical: anyFile.logicalName, role: .past).utf8.count > 255 {
                conflictKeys.insert(key)
                plan.summary.conflicts += 1
                plan.notes.append("Skipped \"\(Naming.joinPath(anyFile.parentRel, anyFile.logicalName))\": the name is too long to add \"_past\". Shorten it.")
                continue
            }
            var instances: [(side: Side, variant: FileVariant)] = []
            for v in fa?.variants ?? [] { instances.append((.a, v)) }
            for v in fb?.variants ?? [] { instances.append((.b, v)) }
            let versions = groupVersions(instances)
            let lf = (fa ?? fb)!

            // The current file was deleted on one side (its _past may still be there) and the other side's
            // current file is unchanged since the last sync: the document was deleted. Remove every version.
            if let fa, let fb, let stamp = deletionState?.files[key] {
                var deletedOn: Side? = nil
                for (x, fx, fy) in [(Side.a, fa, fb), (Side.b, fb, fa)] {
                    let xLostCurrent = !fx.variants.contains { $0.role == .updated }
                    let yCurrentUnchanged = fy.variants.contains { $0.role == .updated && $0.matches(stamp) }
                    let nothingNewer = (fx.variants + fy.variants).allSatisfy {
                        $0.mtime.timeIntervalSince(stamp.mtime) <= SyncConstants.timeTolerance
                    }
                    if xLostCurrent && yCurrentUnchanged && nothingNewer { deletedOn = x; break }
                }
                if let x = deletedOn {
                    deletedFileKeys.insert(key)
                    pendingFileDeletes.append((key, x.other, (x == .a ? fb : fa).variants))
                    pendingFileDeletes.append((key, x, (x == .a ? fa : fb).variants))
                    continue
                }
            }

            if fa == nil || fb == nil, let stamp = deletionState?.files[key] {
                let present: Side = fa != nil ? .a : .b
                if versions[0].rep.matches(stamp) {
                    // Synced last time, untouched since, now gone from the other side: it was deleted there.
                    deletedFileKeys.insert(key)
                    pendingFileDeletes.append((key, present, lf.variants))
                    continue
                }
                plan.summary.keptChanged += 1
                plan.notes.append("Kept \"\(Naming.joinPath(lf.parentRel, lf.logicalName))\": deleted in \(present.other.label) but changed in \(present.label) since the last sync. It will be restored to \(present.other.label).")
            }

            let logicalName = Naming.parse(versions[0].rep.fileName).logical
            var group: [FileOp] = []
            for side in Side.allCases {
                let local = scans[side.rawValue].files[key]?.variants ?? []
                if let op = makeOp(side: side, file: lf, logicalName: logicalName, local: local, versions: versions) {
                    group.append(op)
                }
            }
            if group.isEmpty {
                plan.summary.unchanged += 1
            } else {
                for op in group {
                    for slot in op.slots {
                        switch slot.source {
                        case .remote(let v):
                            plan.summary.filesToCopy += 1
                            plan.summary.bytesToCopy += v.size
                        default: break
                        }
                    }
                    plan.summary.displacedVersions += op.displaced.count
                }
                plan.summary.versionUpdates += 1
                plan.fileGroups.append(group)
            }
        }

        // ---- Folders ----
        let allFolderKeys = Set(scans[0].folders.keys).union(scans[1].folders.keys)
        var candidates: [String: Side] = [:]
        var newOneSided: [String] = []
        for key in allFolderKeys {
            let inA = scans[0].folders[key], inB = scans[1].folders[key]
            if inA != nil && inB != nil { continue }
            if conflictKeys.contains(key) { continue }
            let present: Side = inA != nil ? .a : .b
            if deletionState != nil && stateFolders.contains(key) {
                candidates[key] = present
            } else {
                newOneSided.append(key)
                plan.folderCreates.append(FolderCreate(target: present.other, key: key, parentKey: Naming.parent(of: key),
                                                       sourceRel: (inA ?? inB)!, depth: key.filter { $0 == "/" }.count))
            }
        }

        // A deleted folder is only removed if nothing new or changed lives inside it.
        var survivorAncestors = Set<String>()
        for key in allFileKeys where !deletedFileKeys.contains(key) {
            survivorAncestors.formUnion(Naming.ancestors(of: key))
        }
        for key in newOneSided { survivorAncestors.formUnion(Naming.ancestors(of: key)) }

        var deletedFolders = Set<String>()
        for (key, side) in candidates {
            if survivorAncestors.contains(key) {
                let rel = plan.scans[side.rawValue].folders[key]!
                plan.summary.keptChanged += 1
                plan.notes.append("Kept folder \"\(rel)\": deleted in \(side.other.label) but has new or changed items in \(side.label). It will be restored to \(side.other.label).")
                plan.folderCreates.append(FolderCreate(target: side.other, key: key, parentKey: Naming.parent(of: key),
                                                       sourceRel: rel, depth: key.filter { $0 == "/" }.count))
            } else {
                deletedFolders.insert(key)
            }
        }
        plan.folderCreates.sort { $0.depth != $1.depth ? $0.depth < $1.depth : $0.key < $1.key }
        plan.summary.foldersToCreate = plan.folderCreates.count

        func coveredByFolderDelete(_ key: String) -> Bool {
            Naming.ancestors(of: key).contains { deletedFolders.contains($0) }
        }
        for key in deletedFolders.sorted() where !coveredByFolderDelete(key) {
            let side = candidates[key]!
            let scan = scans[side.rawValue]
            var op = DeleteOp(side: side, relPath: scan.folders[key]!, isFolder: true)
            for (fk, lf) in scan.files where fk.hasPrefix(key + "/") {
                for v in lf.variants { op.expectedFiles[v.relPath] = v }
            }
            op.expectedFolders = Set(scan.folders.keys.filter { $0 == key || $0.hasPrefix(key + "/") })
            plan.deletes.append(op)
        }
        for d in pendingFileDeletes where !coveredByFolderDelete(d.key) {
            for v in d.variants {
                plan.deletes.append(DeleteOp(side: d.side, relPath: v.relPath, isFolder: false, expectedFiles: [v.relPath: v]))
            }
        }
        plan.summary.filesToDelete = deletedFileKeys.count
        plan.summary.foldersToDelete = deletedFolders.count
        return plan
    }

    private func makeOp(side: Side, file: LogicalFile, logicalName: String, local: [FileVariant], versions: [Version]) -> FileOp? {
        var desired: [(VersionRole, Version)] = [(.updated, versions[0])]
        if versions.count > 1 {
            desired.append((.past, versions[1]))
        } else if versions[0].instances.allSatisfy({ $0.variant.role == .past }) {
            // Only a "_past" file exists (e.g. a document genuinely named "Notes_past.pdf"): leave its name alone.
            desired = [(.past, versions[0])]
        }

        var used = Set<String>()
        var slots: [Slot] = []
        for (role, version) in desired {
            let localInstances = version.instances.filter { $0.side == side }.map(\.variant)
            if let v = localInstances.first(where: { $0.role == role && !used.contains($0.relPath) })
                ?? localInstances.first(where: { !used.contains($0.relPath) }) {
                used.insert(v.relPath)
                slots.append(Slot(role: role, source: .local(v)))
            } else {
                let remote = version.instances.filter { $0.side != side }.map(\.variant)
                let v = remote.first(where: { $0.role == .updated }) ?? remote[0]
                slots.append(Slot(role: role, source: .remote(v)))
            }
        }
        let displaced = local.filter { !used.contains($0.relPath) }
        let inPlace = slots.allSatisfy { slot in
            if case .local(let v) = slot.source { return v.role == slot.role }
            return false
        }
        if inPlace && displaced.isEmpty { return nil }
        return FileOp(side: side, key: file.key, parentKey: file.parentKey, sourceParentRel: file.parentRel,
                      logicalName: logicalName, slots: slots, displaced: displaced)
    }

    // MARK: - Execute

    func execute(_ plan: SyncPlan) throws -> SyncResult {
        var result = SyncResult(completed: false, lastSync: nil, errors: plan.summary.unreadable, copied: 0, bytesCopied: 0, trashed: 0)
        for side in Side.allCases where !PairStore.isDirectory(root(side).path) {
            throw SyncError.locationMissing(root(side).path)
        }

        // Free-space check per destination.
        for side in Side.allCases {
            let needed = plan.fileGroups.joined().filter { $0.side == side }.reduce(Int64(0)) { $0 + $1.bytesToCopy }
            guard needed > 0 else { continue }
            let values = try? root(side).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            var available = values?.volumeAvailableCapacityForImportantUsage ?? 0
            if available <= 0, let plain = values?.volumeAvailableCapacity { available = Int64(plain) }
            if available > 0 && needed + 50_000_000 > available {
                throw SyncError.insufficientSpace("Not enough space in location \(side.label): need \(Fmt.bytes(needed)), only \(Fmt.bytes(available)) free.")
            }
        }

        let items = plan.folderCreates.count + plan.fileGroups.count + plan.deletes.count
        progress = SyncProgress()
        progress.bytesTotal = plan.summary.bytesToCopy
        progress.itemsTotal = items
        weightDone = 0
        weightTotal = Double(plan.summary.bytesToCopy) + opWeight * Double(max(items, 1))
        rateSampleTime = Date(); rateSampleBytes = 0; smoothedRate = 0

        var folderMaps = [plan.scans[0].folders, plan.scans[1].folders]
        func parentRel(_ side: Side, parentKey: String, fallback: String) -> String {
            parentKey.isEmpty ? "" : (folderMaps[side.rawValue][parentKey] ?? fallback)
        }

        // 1. Folders
        setPhase("Creating folders…", indeterminate: false)
        for fc in plan.folderCreates {
            try checkCancel()
            let name = Naming.lastComponent(fc.sourceRel)
            let rel = Naming.joinPath(parentRel(fc.target, parentKey: fc.parentKey, fallback: Naming.parent(of: fc.sourceRel)), name)
            progress.currentItem = rel
            do {
                try fm.createDirectory(at: url(fc.target, rel), withIntermediateDirectories: true)
                folderMaps[fc.target.rawValue][fc.key] = rel
                log("\(sideName(fc.target)) Created folder \(rel)")
            } catch {
                result.errors += 1
                log("\(sideName(fc.target)) Could not create folder \(rel): \(error.localizedDescription)", .error)
                try ensureRootsAvailable()
            }
            finishItem()
        }

        // 2. Files (newest keeps the name, second newest -> name_past)
        setPhase("Copying files…", indeterminate: false)
        for group in plan.fileGroups {
            try checkCancel()
            var temps: [[URL?]] = group.map { $0.slots.map { _ in nil } }
            // The plan may be minutes old (e.g. the confirmation dialog sat open). If any file involved
            // changed since, leave this document alone; the next sync handles it with fresh information.
            if let changed = firstChangedVariant(in: group) {
                result.errors += 1
                log("Skipped \(changed): it changed while the sync was running. Sync again to include it.", .warning)
                finishItem()
                continue
            }
            do {
                // 2a. Copy everything needed from the other side into temp files first,
                //     before anything is renamed (sources must still be at their scanned paths).
                for (i, op) in group.enumerated() {
                    let dirRel = parentRel(op.side, parentKey: op.parentKey, fallback: op.sourceParentRel)
                    for (j, slot) in op.slots.enumerated() {
                        guard case .remote(let v) = slot.source else { continue }
                        let tmp = url(op.side, dirRel).appendingPathComponent(SyncConstants.tempPrefix + UUID().uuidString)
                        progress.currentItem = v.relPath
                        try copyItem(from: url(op.side.other, v.relPath), to: tmp, expectedSize: v.size)
                        temps[i][j] = tmp
                        result.copied += 1
                        result.bytesCopied += v.size
                    }
                }
                // 2b. Arrange each side: retire old versions, rename, move copies into place.
                for (i, op) in group.enumerated() {
                    let dirRel = parentRel(op.side, parentKey: op.parentKey, fallback: op.sourceParentRel)
                    result.trashed += try arrange(op, dirRel: dirRel, temps: temps[i])
                }
            } catch SyncError.cancelled {
                for t in temps.joined().compactMap({ $0 }) { try? fm.removeItem(at: t) }
                throw SyncError.cancelled
            } catch {
                for t in temps.joined().compactMap({ $0 }) where fm.fileExists(atPath: t.path) { try? fm.removeItem(at: t) }
                result.errors += 1
                let name = Naming.joinPath(group[0].sourceParentRel, group[0].logicalName)
                log("Failed on \(name): \(error.localizedDescription)", .error)
                try ensureRootsAvailable()
            }
            finishItem()
        }

        // 3. Deletions carried over from the other location (to Trash, recoverable)
        setPhase("Removing deleted items…", indeterminate: false)
        for d in plan.deletes {
            try checkCancel()
            progress.currentItem = d.relPath
            if let reason = deletionBlocker(d) {
                log("\(sideName(d.side)) Kept \(d.relPath) (not moved to Trash): \(reason).", .warning)
                finishItem()
                continue
            }
            do {
                try moveToTrash(url(d.side, d.relPath), side: d.side)
                result.trashed += 1
                log("\(sideName(d.side)) Moved to Trash \(d.isFolder ? "folder " : "")\(d.relPath) (deleted in \(d.side.other.label) since last sync)")
            } catch {
                result.errors += 1
                log("\(sideName(d.side)) Could not remove \(d.relPath): \(error.localizedDescription)", .error)
                try ensureRootsAvailable()
            }
            finishItem()
        }

        // 4. Verify, write last-sync record and the file-structure map.
        try checkCancel()
        setPhase("Verifying and writing file map…", indeterminate: true)
        let finalA = try scan(.a), finalB = try scan(.b)
        let now = Date()
        var files: [String: VersionStamp] = [:]
        var mismatched = 0
        for key in Set(finalA.files.keys).union(finalB.files.keys) {
            let fa = finalA.files[key], fb = finalB.files[key]
            if let fa, let fb {
                let newest = (fa.variants + fb.variants).max(by: { $0.mtime < $1.mtime })!
                files[key] = VersionStamp(size: newest.size, mtime: newest.mtime)
            } else {
                mismatched += 1
                // Keep a pending deletion pending; anything else is treated as new next time.
                if let old = plan.oldState?.files[key] { files[key] = old }
            }
        }
        var folders = Set(finalA.folders.keys).intersection(finalB.folders.keys)
        let oneSidedFolders = Set(finalA.folders.keys).symmetricDifference(finalB.folders.keys)
        folders.formUnion(oneSidedFolders.intersection(plan.oldState?.folders ?? []))
        if mismatched > 0 || !oneSidedFolders.isEmpty {
            log("\(mismatched) document(s) and \(oneSidedFolders.count) folder(s) still differ between A and B (see errors above). Run sync again after fixing.", .warning)
        }

        let state = SyncState(pairID: pair.id, syncID: UUID(), lastSync: now, files: files, folders: folders.sorted())
        for side in Side.allCases {
            do { try writeState(state, side) } catch {
                result.errors += 1
                log("\(sideName(side)) Could not save the sync record: \(error.localizedDescription)", .error)
            }
        }
        result.structureFileName = writeStructureFiles(scanA: finalA, date: now, errors: result.errors)
        result.completed = true
        result.lastSync = now
        progress.fraction = 1
        progress.currentItem = ""
        setPhase(result.errors == 0 ? "Sync complete" : "Sync finished with \(result.errors) error(s)", indeterminate: false)
        return result
    }

    /// Fresh size + date of a file or package, straight from disk.
    private func currentStats(_ url: URL) -> (size: Int64, mtime: Date, isDir: Bool)? {
        let fresh = URL(fileURLWithPath: url.path)
        guard let v = try? fresh.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { return nil }
        let mtime = v.contentModificationDate ?? .distantPast
        if v.isDirectory == true {
            let (size, newest) = packageStats(fresh, fallback: mtime)
            return (size, newest, true)
        }
        return (Int64(v.fileSize ?? 0), mtime, false)
    }

    private func unchanged(_ variant: FileVariant, on side: Side) -> Bool {
        guard let now = currentStats(url(side, variant.relPath)) else { return false }
        return now.size == variant.size && abs(now.mtime.timeIntervalSince(variant.mtime)) <= SyncConstants.timeTolerance
    }

    private func firstChangedVariant(in group: [FileOp]) -> String? {
        for op in group {
            for slot in op.slots {
                switch slot.source {
                case .local(let v): if !unchanged(v, on: op.side) { return v.relPath }
                case .remote(let v): if !unchanged(v, on: op.side.other) { return v.relPath }
                }
            }
            for v in op.displaced where !unchanged(v, on: op.side) { return v.relPath }
        }
        return nil
    }

    /// Why a planned deletion must not happen now (nil = safe to move to the Trash).
    private func deletionBlocker(_ d: DeleteOp) -> String? {
        if !d.isFolder {
            guard let v = d.expectedFiles[d.relPath] else { return "nothing recorded for it" }
            return unchanged(v, on: d.side) ? nil : "it changed after the sync was planned"
        }
        let folderURL = url(d.side, d.relPath)
        let rootPath = root(d.side).path
        guard let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey], options: []) else {
            return "it couldn't be read"
        }
        for case let item as URL in en {
            let name = item.lastPathComponent
            if name == ".DS_Store" || name == ".localized" || name.hasPrefix("._") || name.hasPrefix(SyncConstants.tempPrefix)
                || SyncConstants.ignoredNames.contains(name) || name.hasPrefix("~$") { continue }
            if name.hasPrefix(".") { return "it contains hidden files (\(name)) that aren't synced" }
            guard item.path.hasPrefix(rootPath + "/") else { return "unexpected path" }
            let rel = String(item.path.dropFirst(rootPath.count + 1))
            let v = try? item.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey])
            if v?.isSymbolicLink == true { return "it contains an alias/symlink (\(name))" }
            if v?.isDirectory == true && v?.isPackage != true {
                if !d.expectedFolders.contains(Naming.key(rel)) { return "a new folder appeared inside it (\(name))" }
                continue
            }
            if v?.isPackage == true { en.skipDescendants() }
            guard let expected = d.expectedFiles[rel] else { return "a new item appeared inside it (\(name))" }
            if !unchanged(expected, on: d.side) { return "\(name) inside it changed" }
        }
        return nil
    }

    private func ensureRootsAvailable() throws {
        for side in Side.allCases where !PairStore.isDirectory(root(side).path) {
            throw SyncError.locationMissing(root(side).path)
        }
    }

    /// Make one side hold exactly the planned newest + _past files. Returns how many items went to the Trash.
    private func arrange(_ op: FileOp, dirRel: String, temps: [URL?]) throws -> Int {
        let dir = url(op.side, dirRel)
        var trashed = 0

        // Retire versions that are no longer the newest or second newest.
        for v in op.displaced {
            try moveToTrash(url(op.side, v.relPath), side: op.side)
            trashed += 1
            log("\(sideName(op.side)) Old version to Trash: \(v.relPath)")
        }

        // Local renames (e.g. report.docx -> report_past.docx when a newer report.docx arrives).
        var moves: [(from: URL, to: URL, label: String)] = []
        var placements: [(from: URL, to: URL, label: String)] = []
        for (j, slot) in op.slots.enumerated() {
            let finalURL = dir.appendingPathComponent(Naming.name(logical: op.logicalName, role: slot.role))
            switch slot.source {
            case .local(let v):
                if v.role == slot.role { continue }  // already in place
                moves.append((url(op.side, v.relPath), finalURL, "Renamed \(v.fileName) → \(finalURL.lastPathComponent)"))
            case .remote(let v):
                guard let tmp = temps[j] else { throw SyncError.failed("Missing copy of \(v.relPath)") }
                let verb = slot.role == .updated ? "Copied newest" : "Copied previous"
                placements.append((tmp, finalURL, "\(verb) \(Naming.joinPath(dirRel, finalURL.lastPathComponent))"))
            }
        }
        func sameItem(_ a: URL, _ b: URL) -> Bool { Naming.key(a.path) == Naming.key(b.path) }
        // Anything sitting at a target name that this document doesn't own is left alone: stop instead.
        for target in (moves.map(\.to) + placements.map(\.to)) where fm.fileExists(atPath: target.path) {
            if !moves.contains(where: { sameItem($0.from, target) }) {
                throw SyncError.failed("\"\(target.lastPathComponent)\" already exists and isn't a version of this document, so nothing was changed. Rename it and sync again.")
            }
        }
        while !moves.isEmpty {
            try checkCancel()
            if let i = moves.firstIndex(where: { !fm.fileExists(atPath: $0.to.path) }) {
                try fm.moveItem(at: moves[i].from, to: moves[i].to)
                log("\(sideName(op.side)) \(moves[i].label)")
                moves.remove(at: i)
            } else if let i = moves.firstIndex(where: { m in moves.contains { sameItem($0.from, m.to) } }),
                      !moves[i].from.lastPathComponent.hasPrefix(SyncConstants.holdPrefix) {
                // Two files swapping names: park one under a recoverable name first.
                let hold = dir.appendingPathComponent(SyncConstants.holdPrefix + moves[i].from.lastPathComponent)
                try fm.moveItem(at: moves[i].from, to: hold)
                moves[i].from = hold
            } else {
                throw SyncError.failed("Couldn't rename versions in \(dirRel.isEmpty ? "the main folder" : dirRel): a name is taken.")
            }
        }
        for p in placements {
            if fm.fileExists(atPath: p.to.path) {
                throw SyncError.failed("\"\(p.to.lastPathComponent)\" appeared during the sync; left untouched.")
            }
            try fm.moveItem(at: p.from, to: p.to)
            log("\(sideName(op.side)) \(p.label)")
        }
        return trashed
    }

    /// Tests only: send "trashed" items here instead of the real Trash.
    var trashOverride: URL?

    private func moveToTrash(_ item: URL, side: Side) throws {
        do {
            if let t = trashOverride {
                try fm.createDirectory(at: t, withIntermediateDirectories: true)
                try fm.moveItem(at: item, to: t.appendingPathComponent(UUID().uuidString + "-" + item.lastPathComponent))
                return
            }
            try fm.trashItem(at: item, resultingItemURL: nil)
        } catch {
            // No Trash on this drive: keep it in a visible, never-synced folder instead of deleting it.
            let bin = root(side).appendingPathComponent(SyncConstants.removedFolderName)
                .appendingPathComponent(Fmt.logFileStamp(Date()))
            try fm.createDirectory(at: bin, withIntermediateDirectories: true)
            var dest = bin.appendingPathComponent(item.lastPathComponent)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let (stem, ext) = Naming.split(item.lastPathComponent)
                dest = bin.appendingPathComponent(Naming.join("\(stem) \(n)", ext))
                n += 1
            }
            try fm.moveItem(at: item, to: dest)
            log("\(sideName(side)) No Trash on this drive; moved to \(SyncConstants.removedFolderName) instead.", .warning)
        }
    }

    // MARK: - Copying with live progress

    private func copyItem(from src: URL, to dst: URL, expectedSize: Int64) throws {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: src.path, isDirectory: &isDir) else {
            throw SyncError.failed("Source disappeared: \(src.path)")
        }
        if isDir.boolValue {
            do { try copyDirectory(src, dst) } catch { try? fm.removeItem(at: dst); throw error }
        } else {
            try copyRegularFile(src, dst)
        }
    }

    private func copyDirectory(_ src: URL, _ dst: URL) throws {
        try fm.createDirectory(at: dst, withIntermediateDirectories: false)
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            try checkCancel()
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            let type = (try fm.attributesOfItem(atPath: s.path))[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                try fm.createSymbolicLink(atPath: d.path, withDestinationPath: try fm.destinationOfSymbolicLink(atPath: s.path))
            } else if type == .typeDirectory {
                try copyDirectory(s, d)
            } else {
                try copyRegularFile(s, d)
            }
        }
        _ = copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_METADATA))
        copyModificationDate(from: src, to: dst)
    }

    /// Copies one file in 4 MB chunks so progress and speed update continuously, then copies
    /// metadata (Finder tags, extended attributes, permissions) with the system copier and keeps the
    /// original modification date — that date is what decides "newest" on the next sync.
    private func copyRegularFile(_ src: URL, _ dst: URL) throws {
        let input = open(src.path, O_RDONLY)
        guard input >= 0 else { throw posixFailure("open", src) }
        defer { close(input) }
        let output = open(dst.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard output >= 0 else { throw posixFailure("create", dst) }
        // Bypass the RAM cache so the speed shown is the drive's real speed.
        _ = fcntl(input, F_NOCACHE, 1)
        _ = fcntl(output, F_NOCACHE, 1)

        let chunk = 4 * 1024 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: chunk, alignment: 4096)
        defer { buffer.deallocate() }
        var failure: Error? = nil
        copyLoop: while true {
            if isCancelled { failure = SyncError.cancelled; break }
            let n = read(input, buffer, chunk)
            if n == 0 { break }
            if n < 0 {
                if errno == EINTR { continue }
                failure = posixFailure("read", src); break
            }
            var written = 0
            while written < n {
                let w = write(output, buffer + written, n - written)
                if w < 0 {
                    if errno == EINTR { continue }
                    failure = posixFailure("write", dst); break copyLoop
                }
                written += w
            }
            addCopiedBytes(Int64(n))
        }
        if failure == nil && fsync(output) != 0 { failure = posixFailure("flush", dst) }
        if close(output) != 0 && failure == nil { failure = posixFailure("close", dst) }
        if let failure {
            try? fm.removeItem(at: dst)
            throw failure
        }
        // Best effort: some drives (exFAT, network) can't store every kind of metadata.
        _ = copyfile(src.path, dst.path, nil, copyfile_flags_t(COPYFILE_METADATA))
        copyModificationDate(from: src, to: dst)
    }

    private func posixFailure(_ action: String, _ url: URL) -> Error {
        let code = errno
        if code == ENOSPC { return SyncError.insufficientSpace("The drive is full (while writing \(url.lastPathComponent)).") }
        return SyncError.failed("Could not \(action) \(url.path): \(String(cString: strerror(code)))")
    }

    private func copyModificationDate(from src: URL, to dst: URL) {
        if let m = (try? src.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate {
            try? fm.setAttributes([.modificationDate: m], ofItemAtPath: dst.path)
        }
    }

    // MARK: - File structure text file

    @discardableResult
    func writeStructureFiles(scanA: SideScan, date: Date, errors: Int) -> String? {
        let rootName = root(.a).lastPathComponent
        let fileName = "\(rootName)\(SyncConstants.structureMarker)\(Fmt.fileStamp(date)).txt"
        let text = structureText(scan: scanA, rootName: rootName, date: date, errors: errors)
        var wrote = false
        for side in Side.allCases {
            let r = root(side)
            let sideRootName = r.lastPathComponent
            if let existing = try? fm.contentsOfDirectory(atPath: r.path) {
                for name in existing where Self.isStructureFileName(name, rootName: sideRootName) {
                    // Only replace maps this app wrote (recognised by their first line).
                    let old = r.appendingPathComponent(name)
                    let head = (try? FileHandle(forReadingFrom: old)).flatMap { h -> String? in
                        defer { try? h.close() }
                        return (try? h.read(upToCount: 1024)).map { String(decoding: $0, as: UTF8.self) }
                    } ?? ""
                    if head.components(separatedBy: "\n").first?.hasSuffix(" — file structure") == true {
                        try? fm.removeItem(at: old)
                    }
                }
            }
            do {
                try text.write(to: r.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
                wrote = true
            } catch {
                log("\(sideName(side)) Could not write the file structure text file: \(error.localizedDescription)", .error)
            }
        }
        if wrote { log("File map written: \(fileName)", .success) }
        return wrote ? fileName : nil
    }

    private final class TreeNode {
        var folders: [String: TreeNode] = [:]
        var files: [FileVariant] = []
    }

    func structureText(scan: SideScan, rootName: String, date: Date, errors: Int) -> String {
        let tree = TreeNode()
        func node(for rel: String) -> TreeNode {
            var n = tree
            guard !rel.isEmpty else { return n }
            for part in rel.split(separator: "/") {
                let name = String(part)
                if n.folders[name] == nil { n.folders[name] = TreeNode() }
                n = n.folders[name]!
            }
            return n
        }
        for rel in scan.folders.values { _ = node(for: rel) }
        for lf in scan.files.values { node(for: lf.parentRel).files.append(contentsOf: lf.variants) }

        var lines: [String] = [
            "\(rootName) — file structure",
            "Last synced:  \(Fmt.display(date))",
            "Location A:   \(root(.a).path)",
            "Location B:   \(root(.b).path)",
            "Contents:     \(scan.folders.count) folders · \(scan.files.count) documents (\(scan.fileCount) files) · \(Fmt.bytes(scan.totalBytes))",
        ]
        if errors > 0 { lines.append("Note:         this sync finished with \(errors) error(s). See the app's log.") }
        lines += [
            "Key:          name = newest version · name_past = previous version",
            "",
            "\(rootName)/",
        ]
        func render(_ n: TreeNode, prefix: String) {
            let folderNames = n.folders.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            let files = n.files.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            let total = folderNames.count + files.count
            var index = 0
            for name in folderNames {
                index += 1
                let last = index == total
                lines.append(prefix + (last ? "└── " : "├── ") + name + "/")
                render(n.folders[name]!, prefix: prefix + (last ? "    " : "│   "))
            }
            for f in files {
                index += 1
                let last = index == total
                lines.append(prefix + (last ? "└── " : "├── ") + f.fileName
                             + "   [\(Fmt.bytes(f.size)), \(Fmt.display(f.mtime))]")
            }
        }
        render(tree, prefix: "")
        return lines.joined(separator: "\n") + "\n"
    }
}
