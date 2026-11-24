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
    /// The same file read twice from the same drive.
    static let exactTolerance: TimeInterval = 0.01
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
            let logical = join(String(stem.dropLast(suffix.count)), ext)
            // Only a name this app would give it: "a.txt_past" is not the previous version of "a.txt".
            if key(name(logical: logical, role: .past)) == key(fileName) { return (logical, .past) }
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

    /// Same size and date. The engine's `same` also handles FAT32 drives.
    func sameVersion(as other: FileVariant) -> Bool {
        size == other.size && Self.sameTime(mtime, other.mtime)
    }

    func matches(_ stamp: VersionStamp, within tolerance: TimeInterval = SyncConstants.timeTolerance) -> Bool {
        size == stamp.size && abs(mtime.timeIntervalSince(stamp.mtime)) <= tolerance
    }

    static func sameTime(_ a: Date, _ b: Date) -> Bool {
        abs(a.timeIntervalSince(b)) <= SyncConstants.timeTolerance
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
    /// Documents with a file still parked by an interrupted sync (seen by a read-only check).
    var parkedKeys: Set<String> = []
    /// Keys that must be left alone on both drives, and why (aliases, two names that differ only in case).
    var leaveAlone: [String: String] = [:]
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
    /// A _past version the user chose to keep behind an older current one, although its date is newer.
    var demoted: [String: VersionStamp]? = nil
    /// The _past version at the last sync. Missing in records written by 1.0.
    var pasts: [String: VersionStamp]? = nil
    /// Location B's own dates, only where they differ from `files` / `pasts` (FAT32 after a clock change).
    var filesB: [String: VersionStamp]? = nil
    var pastsB: [String: VersionStamp]? = nil

    func stamp(_ key: String, _ side: Side) -> VersionStamp? { (side == .b ? filesB?[key] : nil) ?? files[key] }
    func past(_ key: String, _ side: Side) -> VersionStamp? { (side == .b ? pastsB?[key] : nil) ?? pasts?[key] }
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
    /// Everything with the same group is deleted together or not at all.
    var group = ""
    /// These must still be missing, otherwise it wasn't deleted after all.
    var mustBeAbsent: [Absent] = []
    struct Absent: Sendable { var side: Side; var parentKey: String; var parentRel: String; var name: String }
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
    var clashes = 0
    var skipped = 0
    var heldBack = 0
    var keepBoth = 0
    /// Deletions seen through a record written by 1.0.
    var toConfirm = 0
    var unreadable = 0
    var deletionsPaused = false
    var totalDocuments = 0

    var deletions: Int { filesToDelete + foldersToDelete }
    var isNoop: Bool { foldersToCreate == 0 && filesToCopy == 0 && versionUpdates == 0 && deletions == 0 && keepBoth == 0 }

    /// Show the comparison before running: first sync, any deletion, any clash, or many old versions retired.
    var needsConfirmation: Bool {
        if mergeMode && !isNoop { return true }
        if deletions > 0 || clashes > 0 || toConfirm > 0 || displacedVersions >= 25 { return true }
        return displacedVersions >= 5 && displacedVersions * 5 >= max(totalDocuments, 1)
    }

    var lines: [String] {
        var l: [String] = []
        if mergeMode {
            l.append("First sync for this pair (or the last-sync records didn't match): safe merge mode. No document or folder will be deleted.")
        }
        if foldersToCreate > 0 { l.append("\(foldersToCreate) folder(s) will be created.") }
        if filesToCopy > 0 { l.append("\(filesToCopy) file copies, \(Fmt.bytes(bytesToCopy)) total.") }
        if displacedVersions > 0 { l.append("\(displacedVersions) older version(s) beyond the newest and _past will go to the Trash.") }
        if deletions > 0 {
            l.append("\(filesToDelete) document(s) and \(foldersToDelete) folder(s) that were deleted in one location since the last sync will be moved to the Trash in the other.")
        }
        if keptChanged > 0 { l.append("\(keptChanged) item(s) deleted in one location but changed in the other will be kept and restored.") }
        if clashes > 0 { l.append("\(clashes) document(s) need your choice (edited on both drives, or replaced by an older copy). They are left alone until you choose.") }
        if keepBoth > 0 { l.append("\(keepBoth) document(s) will be kept as two separate files.") }
        if skipped > 0 { l.append("\(skipped) item(s) skipped this time.") }
        if heldBack > 0 { l.append("\(heldBack) item(s) changed after you looked, so they are held back. Compare again to see them.") }
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
    var keepBoths: [KeepBothOp] = []
    var items: [DiffItem] = []
    /// Newer versions the user chose to put behind an older current one (document key -> stamp).
    var demote: [String: VersionStamp] = [:]
    /// Such choices made earlier.
    var demoted: [String: VersionStamp] = [:]
    /// "Do this now" touches only some items.
    var partial = false
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
    /// Deletions that were planned but held back.
    var kept = 0
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

    deinit {
        try? logHandle?.close()
        releaseLocks()
    }

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

    func scan(_ side: Side, readOnly: Bool = false) throws -> SideScan {
        let rootURL = root(side)
        guard PairStore.isDirectory(rootURL.path) else { throw SyncError.locationMissing(rootURL.path) }
        var result = SideScan(root: rootURL)
        try walk(dir: rootURL, rel: "", depth: 0, rootName: rootURL.lastPathComponent, readOnly: readOnly, into: &result)
        return result
    }

    private func walk(dir: URL, rel: String, depth: Int, rootName: String, readOnly: Bool, into result: inout SideScan) throws {
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
            if readOnly {
                if name.hasPrefix(SyncConstants.holdPrefix) {
                    var original = name
                    while original.hasPrefix(SyncConstants.holdPrefix) { original.removeFirst(SyncConstants.holdPrefix.count) }
                    result.parkedKeys.insert(Naming.joinPath(Naming.key(rel), Naming.key(Naming.parse(original).logical)))
                }
                continue
            }
            if name.hasPrefix(SyncConstants.tempPrefix) {
                Self.unlock(item)
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
                let why = "It is an alias (symbolic link) on one drive."
                result.leaveAlone[Naming.key(childRel)] = why
                result.leaveAlone[Naming.joinPath(Naming.key(rel), Naming.key(Naming.parse(name).logical))] = why
                continue
            }
            let isDir = values.isDirectory == true
            let isPackage = isDir && values.isPackage == true
            if isDir && !isPackage {
                if let other = result.folders[Naming.key(childRel)] {
                    result.leaveAlone[Naming.key(childRel)] = "Two folders differ only in capital letters or accents (\(other)). Rename one."
                    result.skipped.append(childRel + " (same name as \(other))")
                    continue
                }
                result.folders[Naming.key(childRel)] = childRel
                try walk(dir: item, rel: childRel, depth: depth + 1, rootName: rootName, readOnly: readOnly, into: &result)
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
            if let other = result.files[key]!.variants.first(where: { $0.role == role }) {
                result.leaveAlone[key] = "Two files differ only in capital letters or accents (\(other.fileName) and \(name)). Rename one."
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

    /// Written to temporary files on both drives first, so a drive that can't be written leaves both old records.
    private func writeStates(_ state: SyncState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        var temps: [(URL, URL)] = []
        defer { for (t, _) in temps where fm.fileExists(atPath: t.path) { try? fm.removeItem(at: t) } }
        for side in Side.allCases {
            let tmp = root(side).appendingPathComponent(SyncConstants.tempPrefix + UUID().uuidString)
            temps.append((tmp, stateURL(side)))
            try data.write(to: tmp)
        }
        for (tmp, final) in temps {
            guard rename(tmp.path, final.path) == 0 else { throw posixFailure("save", final) }
        }
    }

    // MARK: - One sync at a time, on the drives it started with

    private var lockHandles: [Int32] = []
    private var devices: [dev_t?] = [nil, nil]

    private func device(_ side: Side) -> dev_t? {
        var st = stat()
        return stat(root(side).path, &st) == 0 ? st.st_dev : nil
    }

    private func takeLocks() throws {
        guard lockHandles.isEmpty else { return }
        for side in Side.allCases {
            let path = root(side).appendingPathComponent(".projectdrivesync.lock").path
            let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o666)
            guard fd >= 0 else { continue }  // e.g. a read-only drive: the sync itself will say so
            _ = fchmod(fd, 0o666)
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let busy = errno == EWOULDBLOCK
                close(fd)
                if busy { throw SyncError.failed("Another copy of Project Drive Sync is using \(root(side).path). Try again when it has finished.") }
                continue
            }
            lockHandles.append(fd)
        }
    }

    /// Called when a run ends, or when a prepared plan won't be carried out.
    func releaseLocks() {
        for fd in lockHandles { close(fd) }
        lockHandles = []
    }

    private static func unlock(_ url: URL) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        let locks = UInt32(UF_IMMUTABLE | UF_APPEND)
        if st.st_flags & locks != 0 { _ = lchflags(url.path, st.st_flags & ~locks) }
    }

    /// FAT32 keeps local time, so a daylight-saving change moves its dates by an hour.
    var fatOverride: Bool?
    private var sameCache: [String: Bool] = [:]
    private var fileSystems: [String]?
    private func drives() -> [String] {
        if let known = fileSystems { return known }
        let found = Side.allCases.map { side -> String in
            var fs = statfs()
            guard statfs(root(side).path, &fs) == 0 else { return "" }
            return withUnsafeBytes(of: fs.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        fileSystems = found
        return found
    }
    private func usesFAT() -> Bool { fatOverride ?? drives().contains("msdos") }
    private func exactDates() -> Bool { drives().allSatisfy { $0 == "apfs" } }

    /// The same version on two drives. Exactly an hour apart counts only on FAT32, and only if the contents match.
    private func same(_ x: FileVariant, _ sx: Side, _ y: FileVariant, _ sy: Side) -> Bool {
        guard x.size == y.size else { return false }
        let dt = abs(x.mtime.timeIntervalSince(y.mtime))
        if sx == sy { return dt <= SyncConstants.timeTolerance && contentsMatch(x, sx, y, sy) }
        if dt <= SyncConstants.exactTolerance { return true }
        if dt <= SyncConstants.timeTolerance {
            // Coarse drives round dates. Nearly equal is only equal if the last sync said so or the contents match.
            if x.isPackage || y.isPackage { return true }
            // Without a full record, rounding can't be told from a real difference, except between two exact drives.
            guard let record = sameRecord, record.pasts != nil else { return exactDates() ? contentsMatch(x, sx, y, sy) : true }
            let key = Self.documentKey(x.relPath)
            if trustedKeys.contains(key) { return true }
            func both(_ a: VersionStamp?, _ b: VersionStamp?) -> Bool {
                guard let a, let b else { return false }
                return x.matches(a, within: SyncConstants.exactTolerance) && y.matches(b, within: SyncConstants.exactTolerance)
            }
            if both(record.stamp(key, sx), record.stamp(key, sy)) || both(record.past(key, sx), record.past(key, sy)) { return true }
            return contentsMatch(x, sx, y, sy)
        }
        guard usesFAT(), abs(dt - 3600) <= SyncConstants.timeTolerance else { return false }
        return contentsMatch(x, sx, y, sy)
    }

    /// The last sync's record, and documents this run has just copied: both settle whether dates that differ only
    /// by a drive's rounding are the same.
    private var sameRecord: SyncState?
    private var trustedKeys: Set<String> = []

    static func documentKey(_ rel: String) -> String {
        Naming.joinPath(Naming.key(Naming.parent(of: rel)), Naming.key(Naming.parse(Naming.lastComponent(rel)).logical))
    }

    private func contentsMatch(_ x: FileVariant, _ sx: Side, _ y: FileVariant, _ sy: Side) -> Bool {
        let k = "\(sx.rawValue)|\(x.relPath)|\(x.mtime.timeIntervalSince1970)|\(sy.rawValue)|\(y.relPath)|\(y.mtime.timeIntervalSince1970)"
        if let known = sameCache[k] { return known }
        let result = sameContents(url(sx, x.relPath), url(sy, y.relPath), limit: .max)
        sameCache[k] = result
        return result
    }

    // MARK: - Prepare (scan + plan)

    /// `readOnly` only looks: nothing on either drive is touched.
    func prepare(readOnly: Bool = false, review: Review? = nil) throws -> SyncPlan {
        progress = SyncProgress()
        for side in Side.allCases {
            guard PairStore.isDirectory(root(side).path) else { throw SyncError.locationMissing(root(side).path) }
            devices[side.rawValue] = device(side)
        }
        if !readOnly { try takeLocks() }
        setPhase("Scanning location A…", indeterminate: true)
        log("Scanning A: \(root(.a).path)")
        let scanA = try scan(.a, readOnly: readOnly)
        try checkCancel()
        setPhase("Scanning location B…", indeterminate: true)
        log("Scanning B: \(root(.b).path)")
        let scanB = try scan(.b, readOnly: readOnly)
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
        if let review, review.syncID != trusted?.syncID {
            throw SyncError.failed("This pair was synced after you compared it, so nothing was changed. Compare again.")
        }
        var plan = buildPlan(scans: [scanA, scanB], state: trusted, review: review,
                             demoted: (stateB?.demoted ?? [:]).merging(stateA?.demoted ?? [:]) { $1 },
                             anyRecord: stateA != nil || stateB != nil)
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

    private func groupVersions(_ instances: [(side: Side, variant: FileVariant)], demoted: VersionStamp? = nil, demotedIsKnown: Bool = true) -> [Version] {
        var versions: [Version] = []
        for inst in instances.sorted(by: { $0.variant.mtime > $1.variant.mtime }) {
            if let i = versions.firstIndex(where: { same($0.rep, $0.instances[0].side, inst.variant, inst.side) }) {
                versions[i].instances.append(inst)
            } else {
                versions.append(Version(rep: inst.variant, instances: [inst]))
            }
        }
        versions.sort { $0.rep.mtime != $1.rep.mtime ? $0.rep.mtime > $1.rep.mtime : $0.rep.size > $1.rep.size }
        if let demoted {
            // The user put this version behind an older one; it stays behind while it is only a _past file.
            let isDemoted: (Version) -> Bool = { v in
                v.rep.matches(demoted) && v.instances.allSatisfy { $0.variant.role == .past }
            }
            let behind = versions.filter(isDemoted), rest = versions.filter { !isDemoted($0) }
            // Until a sync has fully recorded it, it stays directly behind the current version so it can't be retired.
            versions = demotedIsKnown || rest.isEmpty ? rest + behind : [rest[0]] + behind + rest.dropFirst()
        }
        return versions
    }

    /// Decides what every document and folder needs, and why. The comparison tree and the sync are both
    /// built from this one result, so they can't disagree.
    func buildPlan(scans: [SideScan], state: SyncState?, review: Review? = nil, demoted: [String: VersionStamp] = [:],
                   anyRecord: Bool = false) -> SyncPlan {
        var plan = SyncPlan(scans: scans, oldState: state)
        plan.partial = review?.limit != nil
        plan.demoted = demoted
        let oldFormat = state != nil && state?.pasts == nil   // written by 1.0
        // 1.0 kept one date for both drives; now each drive's own date is recorded.
        let recordTolerance = oldFormat ? SyncConstants.timeTolerance : SyncConstants.exactTolerance
        sameRecord = state
        let leaveAlone = scans[0].leaveAlone.merging(scans[1].leaveAlone) { a, _ in a }
        plan.summary.mergeMode = (state == nil)
        plan.summary.unreadable = scans.reduce(0) { $0 + $1.unreadable.count }
        // If anything couldn't be read, a missing item might just be unreadable: delete nothing this time.
        let canDelete = plan.summary.unreadable == 0
        if state != nil && !canDelete {
            plan.summary.deletionsPaused = true
            plan.notes.append("Some items couldn't be read (see errors), so nothing is deleted this time. Fix the problem and sync again.")
        }
        let stateFolders = Set(state?.folders ?? [])
        let unreadableKeys = Set(scans.flatMap(\.unreadable).map(Naming.key))
        var conflictKeys = Set<String>()
        let parked = scans[0].parkedKeys.union(scans[1].parkedKeys)
        let labels = Place.labels(pair)
        func label(_ s: Side) -> String { s == .a ? labels.a : labels.b }
        func underUnreadable(_ key: String) -> Bool {
            !unreadableKeys.isEmpty && (unreadableKeys.contains(key) || Naming.ancestors(of: key).contains { unreadableKeys.contains($0) })
        }
        func leftAlone(_ key: String) -> String? {
            if leaveAlone.isEmpty { return nil }
            return leaveAlone[key] ?? Naming.ancestors(of: key).lazy.compactMap { leaveAlone[$0] }.first
        }
        func insideConflict(_ key: String) -> Bool { Naming.ancestors(of: key).contains { conflictKeys.contains($0) } }
        /// The user's choice if it is one this item allows, otherwise the suggestion.
        func choice(_ id: String, _ suggested: Decision, _ allowed: [Decision]) -> Decision {
            if let limit = review?.limit, !limit.contains(id) { return .skip }
            guard let review else { return suggested }
            guard let d = review.decisions[id] else { return .skip }
            return allowed.contains(d) ? d : .skip
        }
        func info(_ f: LogicalFile?) -> SideInfo? {
            guard let f else { return nil }
            let c = Self.current(f)
            let past = f.variants.filter { $0.role == .past && $0.relPath != c.relPath }.max { $0.mtime < $1.mtime }
            return SideInfo(relPath: c.relPath, size: c.size, mtime: c.mtime, isPackage: c.isPackage,
                            pastRelPath: past?.relPath, pastMtime: past?.mtime)
        }

        // ---- Files ----
        let allFileKeys = Set(scans[0].files.keys).union(scans[1].files.keys)
        plan.summary.totalDocuments = allFileKeys.count
        var deletedFileKeys = Set<String>()
        /// Documents whose plan copies something to a side (that side needs the parent folders).
        var copiesTo: [String: Set<Side>] = [:]
        var pendingFileDeletes: [(key: String, side: Side, variants: [FileVariant])] = []
        var mustBeAbsent: [String: [DeleteOp.Absent]] = [:]
        var claimedNames = Set<String>()

        for key in allFileKeys.sorted() {
            let fa = scans[0].files[key], fb = scans[1].files[key]
            let lf = (fa ?? fb)!
            let id = DiffItem.fileID(key)
            let shownPath = Naming.joinPath(lf.parentRel, lf.logicalName)
            var item = DiffItem(id: id, key: key, parentKey: lf.parentKey, name: Naming.lastComponent(Self.current(lf).relPath),
                                isFolder: false, kind: .unchanged, side: nil, a: info(fa), b: info(fb),
                                suggested: .skip, allowed: [], reason: "The same on both drives.")

            func block(_ reason: String) {
                item.kind = .blocked
                item.reason = reason
                item.allowed = []
                item.suggested = .skip
                plan.items.append(item)
                plan.notes.append("Skipped \"\(shownPath)\": \(reason)")
            }
            // A file whose name (or its _past name) matches a folder in either location.
            let pastName = Naming.name(logical: lf.logicalName, role: .past)
            let clashingFolders = [key, Naming.joinPath(lf.parentKey, Naming.key(pastName))]
                .filter { scans[0].folders[$0] != nil || scans[1].folders[$0] != nil }
            if !clashingFolders.isEmpty {
                conflictKeys.insert(key)
                plan.summary.conflicts += 1
                block("A folder has the same name as this file (or its _past name). Rename one of them.")
                continue
            }
            if pastName.utf8.count > 255 {
                conflictKeys.insert(key)
                plan.summary.conflicts += 1
                block("The name is too long to add \"_past\". Shorten it.")
                continue
            }
            if insideConflict(key) { plan.summary.conflicts += 1; block("The folder it is in has the same name as a file or package on the other drive. Rename one."); continue }
            if let why = leftAlone(key) { plan.summary.conflicts += 1; block(why); continue }
            if underUnreadable(key) { block("It, or the folder it is in, couldn't be read on one drive."); continue }
            if parked.contains(key) { block("An interrupted sync left this document half renamed. Press Sync Pair to restore it."); continue }

            if let review {
                if let limit = review.limit, !limit.contains(id) { continue }
                if review.fingerprints[key] != Fingerprint.document(fa, fb) {
                    plan.summary.heldBack += 1
                    plan.notes.append("Held back \"\(shownPath)\": it changed after you compared.")
                    continue
                }
            }

            var instances: [(side: Side, variant: FileVariant)] = []
            for v in fa?.variants ?? [] { instances.append((.a, v)) }
            for v in fb?.variants ?? [] { instances.append((.b, v)) }
            var versions = groupVersions(instances, demoted: demoted[key],
                                         demotedIsKnown: demoted[key].map { d in state?.pasts?[key].map { $0.size == d.size && FileVariant.sameTime($0.mtime, d.mtime) } ?? false } ?? true)
            let stamp = state?.files[key]

            // Versions holding work that was never fully synced. None of these goes to the Trash unless the user
            // chose exactly that and was shown its name.
            func unsynced(_ v: FileVariant, _ side: Side) -> Bool {
                guard let state, let st = state.stamp(key, side) else { return true }
                if v.matches(st, within: recordTolerance) { return false }
                if state.pasts != nil { return state.past(key, side).map { !v.matches($0, within: recordTolerance) } ?? true }
                // 1.0 didn't record _past versions: an older-dated one is taken as known.
                return v.role == .updated || v.mtime.timeIntervalSince(st.mtime) > SyncConstants.timeTolerance
            }
            let fresh = versions.filter { v in v.instances.allSatisfy { unsynced($0.variant, $0.side) } }
            func matchesRecord(_ v: FileVariant, _ side: Side) -> Bool { state?.stamp(key, side).map { v.matches($0, within: recordTolerance) } ?? false }
            let lone = !((fa?.variants ?? []) + (fb?.variants ?? [])).contains { $0.role == .updated }
            var sameContent = false

            // ---- What happened?
            if let fa, let fb {
                let ca = Self.current(fa), cb = Self.current(fb)
                let hasA = Self.hasCurrent(fa), hasB = Self.hasCurrent(fb)
                if hasA != hasB {
                    // One drive has only the _past file left.
                    let present: Side = hasA ? .a : .b
                    let keep = hasA ? ca : cb, rest = hasA ? fb : fa
                    // A deletion leaves only _past files that both drives already had. Anything else is a rename,
                    // an unfinished sync or an edit.
                    let kept = hasA ? fa : fb
                    let leftOnlyKnownPast = stamp != nil && fresh.isEmpty && rest.variants.allSatisfy { r in
                        !matchesRecord(r, present.other) && kept.variants.contains { $0.role == .past && same($0, present, r, present.other) }
                    }
                    item.side = present
                    if stamp != nil, matchesRecord(keep, present), leftOnlyKnownPast {
                        item.kind = .deleted
                        item.reason = "Deleted on \(label(present.other)) (only its _past file is left) and unchanged on \(label(present)) since the last sync."
                        item.suggested = canDelete && !oldFormat ? .deleteBoth : .skip
                    } else if stamp != nil {
                        item.kind = .deletedButChanged
                        item.reason = "\(label(present.other)) has no current file, only a _past one that is a rename or has other changes. Nothing is deleted; the newest becomes current on both."
                        item.suggested = .copyAcross
                    } else {
                        item.kind = .onlyHere
                        item.reason = "\(label(present.other)) has only a _past file, and there is no sync record to say why."
                        item.suggested = .copyAcross
                    }
                    item.allowed = [.copyAcross, .deleteBoth, .skip]
                } else if same(ca, .a, cb, .b) {
                    item.kind = .tidy
                    item.reason = versions[0].instances.contains { $0.side == .a && $0.variant == ca }
                        ? "The current files match. Only the _past files need lining up."
                        : "A _past file is newer than the current one, so the names will swap."
                    item.suggested = .tidy
                    item.allowed = [.tidy, .keepA, .keepB, .skip]
                } else {
                    let aFollowsB = fa.variants.contains { $0.role == .past && same($0, .a, cb, .b) }
                    let bFollowsA = fb.variants.contains { $0.role == .past && same($0, .b, ca, .a) }
                    let newer: Side = ca.mtime >= cb.mtime ? .a : .b
                    let changedA = stamp.map { _ in !matchesRecord(ca, .a) }, changedB = stamp.map { _ in !matchesRecord(cb, .b) }
                    item.allowed = [.keepA, .keepB, .keepBoth, .skip]
                    if aFollowsB != bFollowsA, changedA != false, changedB != false {
                        item.side = aFollowsB ? .a : .b
                        item.kind = .edited
                        item.reason = "\(label(item.side!)) has an edit made after the version on \(label(item.side!.other))."
                        item.suggested = item.side == .a ? .keepA : .keepB
                    } else if let changedA, let changedB, !(changedA && changedB) {
                        item.side = changedA ? .a : (changedB ? .b : newer)
                        if item.side == newer {
                            item.kind = .edited
                            item.reason = "Edited on \(label(newer)) since the last sync; unchanged on \(label(newer.other))."
                            item.suggested = newer == .a ? .keepA : .keepB
                        } else {
                            item.kind = .olderCopy
                            item.reason = "Changed on \(label(item.side!)) since the last sync, but its date is older than the copy on \(label(newer)). Choose which to use."
                            item.suggested = .skip
                        }
                    } else if state == nil && !anyRecord && versions.count <= 2 && !lone {
                        item.kind = .differs
                        item.side = newer
                        item.reason = "Different on each drive, with no sync record. The newer one becomes current and the other is kept as _past."
                        item.suggested = newer == .a ? .keepA : .keepB
                    } else if sameContents(url(.a, ca.relPath), url(.b, cb.relPath)) {
                        sameContent = true
                        item.kind = .edited
                        item.side = newer
                        item.allowed = [.keepA, .keepB, .skip]
                        item.reason = "The contents are the same on both drives; only the dates differ."
                        item.suggested = newer == .a ? .keepA : .keepB
                    } else {
                        item.kind = .clash
                        item.reason = stamp == nil ? "Different on each drive, and there is no record of which follows which."
                                                   : "Edited on both drives since the last sync. Each has changes the other doesn't."
                        item.suggested = .skip
                    }
                }
            } else {
                let present: Side = fa != nil ? .a : .b
                item.side = present
                item.allowed = [.copyAcross, .deleteBoth, .skip]
                if stamp != nil {
                    if matchesRecord(Self.current(lf), present) && fresh.isEmpty {
                        item.kind = .deleted
                        item.suggested = canDelete && !oldFormat ? .deleteBoth : .skip
                        item.reason = "Deleted on \(label(present.other)) and unchanged on \(label(present)) since the last sync."
                    } else {
                        item.kind = .deletedButChanged
                        item.suggested = .copyAcross
                        item.reason = "Deleted on \(label(present.other)), but edited on \(label(present)) since the last sync, so it is restored."
                    }
                } else if state != nil {
                    item.kind = .added
                    item.suggested = .copyAcross
                    item.reason = "New on \(label(present)) since the last sync."
                } else {
                    item.kind = .onlyHere
                    item.suggested = .copyAcross
                    item.reason = "Only on \(label(present)). There is no sync record, so the app can't tell whether it is new or was deleted elsewhere."
                }
            }
            if oldFormat && item.kind == .deleted {
                item.reason += " The last sync was made by version 1.0, so please confirm deletions this once."
            }
            // Each drive has an edit the other lacks, somewhere among name and name_past.
            if stamp != nil, fa != nil, fb != nil, [.edited, .tidy].contains(item.kind), !sameContent {
                let onlyA = fresh.contains { $0.instances.allSatisfy { $0.side == .a } }
                let onlyB = fresh.contains { $0.instances.allSatisfy { $0.side == .b } }
                let follows = item.kind == .edited && fresh.allSatisfy { v in
                    v.instances.contains { $0.variant == Self.current(fa!) && $0.side == .a || $0.variant == Self.current(fb!) && $0.side == .b }
                }
                if onlyA && onlyB && !follows {
                    item.kind = .clash
                    item.suggested = .skip
                    item.allowed.removeAll { $0 == .tidy }
                    item.reason = "Both drives have edits the other doesn't, counting the _past files."
                }
            }
            if !canDelete {
                item.allowed.removeAll { $0 == .deleteBoth }
                if item.kind == .deleted { item.reason += " Deletions are paused because some items couldn't be read." }
            }

            // ---- What to do about it
            /// The order of versions a choice asks for: first = current, second = _past, the rest go to the Trash.
            func ordered(_ d: Decision) -> [Version] {
                guard d == .keepA || d == .keepB, let fa, let fb else { return versions }
                let (mine, theirs): (Side, Side) = d == .keepA ? (.a, .b) : (.b, .a)
                let win = Self.current(d == .keepA ? fa : fb), lose = Self.current(d == .keepA ? fb : fa)
                func index(_ v: FileVariant, _ side: Side, in list: [Version]) -> Int? {
                    list.firstIndex { $0.instances.contains { $0.side == side && $0.variant == v } }
                }
                var rest = versions
                var out = [rest.remove(at: index(win, mine, in: rest)!)]
                if let li = index(lose, theirs, in: rest) {
                    if sameContent {
                        rest.remove(at: li)   // the same contents twice: one is enough
                    } else if unsynced(lose, theirs) {
                        out.append(rest.remove(at: li))
                    } else if let f = rest.firstIndex(where: { v in fresh.contains { $0.rep == v.rep && $0.instances[0].side == v.instances[0].side } }) {
                        out.append(rest.remove(at: f))   // an edit that was never synced comes before a version that was
                    } else {
                        out.append(rest.remove(at: li))
                    }
                } else if let p = Self.past(d == .keepA ? fa : fb), let pi = index(p, mine, in: rest) {
                    out.append(rest.remove(at: pi))   // same current file: "use A" means A's _past
                }
                return out + rest
            }
            func operations(_ list: [Version]) -> [FileOp] {
                let name = Naming.parse(list[0].rep.fileName).logical
                return Side.allCases.compactMap { side in
                    makeOp(side: side, file: lf, logicalName: name,
                           local: scans[side.rawValue].files[key]?.variants ?? [], versions: list, lone: lone)
                }
            }
            /// Names of never-synced versions a choice would send to the Trash.
            func retires(_ d: Decision) -> [String] {
                guard [.keepA, .keepB, .tidy, .copyAcross].contains(d) else { return [] }
                let list = ordered(d), group = operations(list)
                let kept = list.prefix(lone ? 1 : 2)
                var names = Set<String>()
                for op in group {
                    for v in op.displaced {
                        guard let version = versions.first(where: { $0.instances.contains { $0.side == op.side && $0.variant == v } }) else { continue }
                        let staysSomewhere = kept.contains { k in k.instances.contains { $0.side == op.side && $0.variant == v } }
                        let duplicate = sameContent && !list.contains { $0.instances.contains { $0.side == op.side && $0.variant == v } }
                        if !staysSomewhere && !duplicate && version.instances.allSatisfy({ unsynced($0.variant, $0.side) }) {
                            names.insert("\(v.relPath) (\(label(op.side)))")
                        }
                    }
                }
                return names.sorted()
            }
            for d in item.allowed {
                let names = retires(d)
                if !names.isEmpty { item.retires[d.rawValue] = names }
            }
            if item.retires[item.suggested.rawValue] != nil {
                item.kind = .clash
                item.reason += " There are more separate versions than name and name_past can hold, so some would go to the Trash. Choose, or rename one to keep it."
                item.suggested = .skip
            }
            if item.retires[Decision.tidy.rawValue] != nil { item.allowed.removeAll { $0 == .tidy } }
            if item.kind == .tidy && operations(versions).isEmpty {
                item.kind = .unchanged
                item.side = nil
                item.suggested = .skip
                item.allowed = []
                item.reason = "The same on both drives."
                plan.items.append(item)
                plan.summary.unchanged += 1
                continue
            }
            let decision = choice(id, item.suggested, item.allowed)
            plan.items.append(item)

            switch decision {
            case .skip:
                if oldFormat && item.kind == .deleted { plan.summary.toConfirm += 1 }
                if item.kind == .clash || item.kind == .olderCopy { plan.summary.clashes += 1 } else { plan.summary.skipped += 1 }
                continue
            case .deleteBoth:
                deletedFileKeys.insert(key)
                if let fa { pendingFileDeletes.append((key, .a, fa.variants)) }
                if let fb { pendingFileDeletes.append((key, .b, fb.variants)) }
                // It must still be missing where it was missing when this was decided.
                for side in Side.allCases {
                    let f = side == .a ? fa : fb
                    var names: [String] = []
                    if f == nil { names = [lf.logicalName, pastName] } else if !lone && !Self.hasCurrent(f!) { names = [lf.logicalName] }
                    // Only names that belong to this document ("X_past" can be the previous version of "X").
                    for n in names where Naming.joinPath(lf.parentKey, Naming.key(Naming.parse(n).logical)) == key {
                        mustBeAbsent[key, default: []].append(.init(side: side, parentKey: lf.parentKey, parentRel: lf.parentRel, name: n))
                    }
                }
                continue
            case .keepBoth:
                guard let fa, let fb else { continue }
                let ca = Self.current(fa), cb = Self.current(fb)
                let loserSide: Side = ca.mtime >= cb.mtime ? .b : .a
                let (winner, loser) = loserSide == .b ? (ca, cb) : (cb, ca)
                let (stem, ext) = Naming.split(loser.fileName)
                let place = Place.fileSafe(label(loserSide))
                var newName = "", n = 1
                repeat {
                    newName = Naming.join(n == 1 ? "\(stem) (\(place))" : "\(stem) (\(place) \(n))", ext)
                    n += 1
                } while takenName(newName, in: lf.parentKey, scans: scans, claimed: claimedNames) && n < 1000
                guard Naming.name(logical: newName, role: .past).utf8.count <= 255, n < 1000 else {
                    plan.summary.skipped += 1
                    plan.notes.append("Skipped \"\(shownPath)\": its name is too long to keep both.")
                    continue
                }
                claimedNames.insert(Naming.joinPath(lf.parentKey, Naming.key(newName)))
                plan.keepBoths.append(KeepBothOp(key: key, parentKey: lf.parentKey, parentRel: lf.parentRel,
                                                 loserSide: loserSide, loser: loser, winner: winner, newName: newName))
                plan.summary.keepBoth += 1
                plan.summary.filesToCopy += 2
                plan.summary.bytesToCopy += loser.size + winner.size
                continue
            case .keepA, .keepB:
                // The chosen file becomes current, whatever the dates.
                versions = ordered(decision)
                if versions.count > 1, versions[1].rep.mtime > versions[0].rep.mtime {
                    plan.demote[key] = VersionStamp(size: versions[1].rep.size, mtime: versions[1].rep.mtime)
                }
            case .copyAcross, .tidy:
                if item.kind == .deletedButChanged {
                    plan.summary.keptChanged += 1
                    plan.notes.append("Kept \"\(shownPath)\": \(item.reason)")
                }
            }

            let group = operations(versions)
            if group.isEmpty { plan.summary.unchanged += 1; continue }
            for op in group {
                for slot in op.slots {
                    guard case .remote(let v) = slot.source else { continue }
                    plan.summary.filesToCopy += 1
                    plan.summary.bytesToCopy += v.size
                    copiesTo[key, default: []].insert(op.side)
                }
                plan.summary.displacedVersions += op.displaced.count
            }
            plan.summary.versionUpdates += 1
            plan.fileGroups.append(group)
        }

        // ---- Folders ----
        let allFolderKeys = Set(scans[0].folders.keys).union(scans[1].folders.keys)
        func presence(_ key: String) -> Int { (scans[0].folders[key] != nil ? 1 : 0) | (scans[1].folders[key] != nil ? 2 : 0) }

        // Folders that still hold something that isn't being deleted, and folders a copy needs.
        var holdsSurvivor = Set<String>()
        var needed: [Side: Set<String>] = [.a: [], .b: []]
        for key in allFileKeys {
            if !deletedFileKeys.contains(key) { holdsSurvivor.formUnion(Naming.ancestors(of: key)) }
            for side in copiesTo[key] ?? [] { needed[side]!.formUnion(Naming.ancestors(of: key)) }
        }
        func create(_ key: String, on target: Side) {
            plan.folderCreates.append(FolderCreate(target: target, key: key, parentKey: Naming.parent(of: key),
                                                   sourceRel: scans[target.other.rawValue].folders[key]!,
                                                   depth: key.filter { $0 == "/" }.count))
            needed[target]!.formUnion(Naming.ancestors(of: key))
        }
        var deletedFolders: [String: Side] = [:]
        // Deepest first, so a parent knows what became of everything inside it.
        for key in allFolderKeys.sorted(by: { a, b in
            let da = a.filter { $0 == "/" }.count, db = b.filter { $0 == "/" }.count
            return da != db ? da > db : a < b
        }) {
            let here = presence(key)
            let id = DiffItem.folderID(key)
            let rel = scans[0].folders[key] ?? scans[1].folders[key]!
            var item = DiffItem(id: id, key: key, parentKey: Naming.parent(of: key), name: Naming.lastComponent(rel), isFolder: true,
                                kind: .unchanged, side: nil, a: nil, b: nil, suggested: .skip, allowed: [], reason: "On both drives.")
            if let r = scans[0].folders[key] { item.a = SideInfo(relPath: r, size: 0, mtime: .distantPast, isPackage: false) }
            if let r = scans[1].folders[key] { item.b = SideInfo(relPath: r, size: 0, mtime: .distantPast, isPackage: false) }
            if here == 3 { plan.items.append(item); holdsSurvivor.formUnion(Naming.ancestors(of: key)); continue }

            let present: Side = here == 1 ? .a : .b
            item.side = present
            if conflictKeys.contains(key) || insideConflict(key) || leftAlone(key) != nil || underUnreadable(key) {
                item.kind = .blocked
                item.reason = leftAlone(key) ?? (underUnreadable(key) ? "It couldn't be read on one drive." : "A file or package has the same name as this folder, or one it is in.")
                plan.items.append(item)
                holdsSurvivor.formUnion(Naming.ancestors(of: key))
                continue
            }
            let wasSynced = stateFolders.contains(key)
            item.allowed = canDelete ? [.copyAcross, .deleteBoth, .skip] : [.copyAcross, .skip]
            if wasSynced {
                item.kind = .deleted
                item.suggested = canDelete ? .deleteBoth : .skip
                item.reason = "Deleted on \(label(present.other)) since the last sync."
            } else {
                item.kind = state == nil ? .onlyHere : .added
                item.suggested = .copyAcross
                item.reason = state == nil ? "Only on \(label(present)). There is no sync record to say why." : "New on \(label(present)) since the last sync."
            }
            let changedSinceReview = review.map { $0.folders[key] != here } ?? false
            let decision = changedSinceReview ? .skip : choice(id, item.suggested, item.allowed)
            let mustExist = needed[present.other]!.contains(key)
            if decision == .deleteBoth && !holdsSurvivor.contains(key) && canDelete {
                deletedFolders[key] = present
            } else {
                holdsSurvivor.formUnion(Naming.ancestors(of: key))
                if mustExist || decision == .copyAcross {
                    create(key, on: present.other)
                    if wasSynced {
                        if review == nil { item.kind = .deletedButChanged }
                        item.suggested = .copyAcross
                        item.reason = "Deleted on \(label(present.other)), but it holds new or changed items on \(label(present)), so it is restored."
                        plan.summary.keptChanged += 1
                        plan.notes.append("Kept folder \"\(rel)\": \(item.reason)")
                    }
                } else if decision == .deleteBoth {
                    // Something inside is being skipped, so the folder has to stay.
                    item.suggested = .skip
                } else if review?.limit == nil {
                    plan.summary.skipped += 1
                }
            }
            plan.items.append(item)
        }
        plan.folderCreates.sort { $0.depth != $1.depth ? $0.depth < $1.depth : $0.key < $1.key }
        plan.summary.foldersToCreate = plan.folderCreates.count

        func coveredByFolderDelete(_ key: String, _ side: Side) -> Bool {
            Naming.ancestors(of: key).contains { deletedFolders[$0] == side }
        }
        for (key, side) in deletedFolders.sorted(by: { $0.key < $1.key }) where !coveredByFolderDelete(key, side) {
            let scan = scans[side.rawValue]
            var op = DeleteOp(side: side, relPath: scan.folders[key]!, isFolder: true)
            for (fk, lf) in scan.files where fk.hasPrefix(key + "/") {
                for v in lf.variants { op.expectedFiles[v.relPath] = v }
            }
            op.expectedFolders = Set(scan.folders.keys.filter { $0 == key || $0.hasPrefix(key + "/") })
            op.group = "d:" + key
            op.mustBeAbsent = [.init(side: side.other, parentKey: Naming.parent(of: key), parentRel: Naming.parent(of: op.relPath),
                                     name: Naming.lastComponent(op.relPath))]
            plan.deletes.append(op)
        }
        for d in pendingFileDeletes where !coveredByFolderDelete(d.key, d.side) {
            for v in d.variants {
                plan.deletes.append(DeleteOp(side: d.side, relPath: v.relPath, isFolder: false, expectedFiles: [v.relPath: v],
                                             group: "f:" + d.key, mustBeAbsent: mustBeAbsent[d.key] ?? []))
            }
        }
        plan.summary.filesToDelete = deletedFileKeys.count
        plan.summary.foldersToDelete = deletedFolders.count
        return plan
    }

    /// True when a new file can't use this name: it, its _past name, or the document it would join exists.
    private func takenName(_ name: String, in parentKey: String, scans: [SideScan], claimed: Set<String>) -> Bool {
        let key = Naming.joinPath(parentKey, Naming.key(Naming.parse(name).logical))
        let full = Naming.joinPath(parentKey, Naming.key(name))
        return claimed.contains(full) || scans.contains { $0.files[key] != nil || $0.folders[full] != nil || $0.folders[key] != nil }
    }

    /// Everything needed to check, at Apply, that the drives still look the way the user saw them.
    static func review(of plan: SyncPlan) -> Review {
        var r = Review(syncID: plan.oldState?.syncID)
        for item in plan.items { r.decisions[item.id] = item.suggested }
        let a = plan.scans[0], b = plan.scans[1]
        for key in Set(a.files.keys).union(b.files.keys) { r.fingerprints[key] = Fingerprint.document(a.files[key], b.files[key]) }
        for key in Set(a.folders.keys).union(b.folders.keys) {
            r.folders[key] = (a.folders[key] != nil ? 1 : 0) | (b.folders[key] != nil ? 2 : 0)
        }
        return r
    }

    private func makeOp(side: Side, file: LogicalFile, logicalName: String, local: [FileVariant], versions: [Version], lone: Bool) -> FileOp? {
        var desired: [(VersionRole, Version)] = [(.updated, versions[0])]
        if lone {
            // Only "_past" files exist (e.g. a document genuinely named "Notes_past.pdf"): leave its name alone.
            desired = [(.past, versions[0])]
        } else if versions.count > 1 {
            desired.append((.past, versions[1]))
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
        defer { releaseLocks() }
        var result = SyncResult(completed: false, lastSync: nil, errors: plan.summary.unreadable, copied: 0, bytesCopied: 0, trashed: 0)
        try ensureRootsAvailable()
        // Remember "keep the older version" choices before acting on them, so stopping half-way doesn't undo them.
        if !plan.demote.isEmpty, var early = plan.oldState {
            early.demoted = (early.demoted ?? [:]).merging(plan.demote) { _, new in new }
            try writeStates(early)
        }

        // Free-space check per destination.
        for side in Side.allCases {
            var needed = plan.fileGroups.joined().filter { $0.side == side }.reduce(Int64(0)) { $0 + $1.bytesToCopy }
            for k in plan.keepBoths { needed += k.loserSide == side ? k.winner.size : k.loser.size }
            guard needed > 0 else { continue }
            let values = try? root(side).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            var available = values?.volumeAvailableCapacityForImportantUsage ?? 0
            if available <= 0, let plain = values?.volumeAvailableCapacity { available = Int64(plain) }
            if available > 0 && needed + 50_000_000 > available {
                throw SyncError.insufficientSpace("Not enough space in location \(side.label): need \(Fmt.bytes(needed)), only \(Fmt.bytes(available)) free.")
            }
        }

        let items = plan.folderCreates.count + plan.fileGroups.count + plan.keepBoths.count + plan.deletes.count
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
        var failedSources: [FileVariant] = []
        func noteFailure(_ group: [FileOp]) {
            for op in group { for slot in op.slots { if case .remote(let v) = slot.source { failedSources.append(v) } } }
        }
        for group in plan.fileGroups {
            try checkCancel()
            var temps: [[URL?]] = group.map { $0.slots.map { _ in nil } }
            // The plan may be minutes old (e.g. the confirmation dialog sat open). If any file involved
            // changed since, leave this document alone; the next sync handles it with fresh information.
            if let changed = firstChangedVariant(in: group) {
                result.errors += 1
                noteFailure(group)
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
                // A file saved while it was being copied gives a mixed copy: check again before using it.
                if let changed = firstChangedVariant(in: group) {
                    throw SyncError.failed("\(changed) changed while it was being copied. Nothing was replaced; sync again.")
                }
                for (i, op) in group.enumerated() {
                    for (j, slot) in op.slots.enumerated() {
                        guard case .remote(let v) = slot.source, let tmp = temps[i][j] else { continue }
                        guard currentStats(tmp)?.size == v.size else {
                            throw SyncError.failed("The copy of \(v.relPath) is incomplete. Nothing was replaced; sync again.")
                        }
                    }
                }
                // 2b. Arrange each side: retire old versions, rename, move copies into place.
                for (i, op) in group.enumerated() {
                    let dirRel = parentRel(op.side, parentKey: op.parentKey, fallback: op.sourceParentRel)
                    result.trashed += try arrange(op, dirRel: dirRel, temps: temps[i])
                }
                trustedKeys.insert(group[0].key)
            } catch SyncError.cancelled {
                for t in temps.joined().compactMap({ $0 }) { try? fm.removeItem(at: t) }
                throw SyncError.cancelled
            } catch {
                for t in temps.joined().compactMap({ $0 }) where fm.fileExists(atPath: t.path) { try? fm.removeItem(at: t) }
                result.errors += 1
                noteFailure(group)
                let name = Naming.joinPath(group[0].sourceParentRel, group[0].logicalName)
                log("Failed on \(name): \(error.localizedDescription)", .error)
                try ensureRootsAvailable()
            }
            finishItem()
        }

        // 2c. Documents kept as two separate files
        for k in plan.keepBoths {
            try checkCancel()
            progress.currentItem = k.loser.relPath
            do {
                try keepBoth(k, dir: { self.url($0, parentRel($0, parentKey: k.parentKey, fallback: k.parentRel)) }, result: &result)
            } catch SyncError.cancelled {
                throw SyncError.cancelled
            } catch {
                result.errors += 1
                failedSources += [k.loser, k.winner]
                log("Failed on \(k.loser.relPath): \(error.localizedDescription)", .error)
                try ensureRootsAvailable()
            }
            finishItem()
        }

        // 3. Deletions carried over from the other location (to Trash, recoverable)
        setPhase("Removing deleted items…", indeterminate: false)
        var groups: [[DeleteOp]] = []
        for d in plan.deletes {
            if let last = groups.last, last[0].group == d.group { groups[groups.count - 1].append(d) } else { groups.append([d]) }
        }
        for group in groups {
            try checkCancel()
            let d0 = group[0]
            progress.currentItem = d0.relPath
            try ensureRootsAvailable()
            var reason = group.lazy.compactMap { self.deletionBlocker($0) }.first
            if reason == nil, group.contains(where: { $0.expectedFiles.values.contains { e in failedSources.contains { $0.sameVersion(as: e) } } }) {
                reason = "it may have been renamed or moved, and copying it under its new name failed"
            }
            for a in d0.mustBeAbsent where reason == nil {
                let there = url(a.side, parentRel(a.side, parentKey: a.parentKey, fallback: a.parentRel)).appendingPathComponent(a.name)
                var st = stat()
                if lstat(there.path, &st) == 0 { reason = "it is back on the other drive" }
            }
            if let reason {
                result.kept += 1
                log("\(sideName(d0.side)) Kept \(d0.relPath) (not moved to Trash): \(reason).", .warning)
                finishItem(group.count)
                continue
            }
            var moved: [(from: URL, inTrash: URL)] = []
            for d in group {
                do {
                    let from = url(d.side, d.relPath)
                    if let t = try moveToTrash(from, side: d.side) { moved.append((from, t)) }
                    result.trashed += 1
                    log("\(sideName(d.side)) Moved to Trash \(d.isFolder ? "folder " : "")\(d.relPath)")
                } catch {
                    result.errors += 1
                    log("\(sideName(d.side)) Could not remove \(d.relPath): \(error.localizedDescription)", .error)
                    // All of a document's versions go together or not at all.
                    for m in moved where !fm.fileExists(atPath: m.from.path) {
                        if (try? fm.moveItem(at: m.inTrash, to: m.from)) != nil { result.trashed -= 1 }
                    }
                    try ensureRootsAvailable()
                    break
                }
            }
            finishItem(group.count)
        }

        // 4. Verify, write last-sync record and the file-structure map.
        try checkCancel()
        setPhase("Verifying and writing file map…", indeterminate: true)
        try ensureRootsAvailable()
        let finalA = try scan(.a), finalB = try scan(.b)
        try ensureRootsAvailable()
        let now = Date()
        var files: [String: VersionStamp] = [:]
        var demoted: [String: VersionStamp] = [:]
        var pasts: [String: VersionStamp] = [:], filesB: [String: VersionStamp] = [:], pastsB: [String: VersionStamp] = [:]
        var mismatched = 0
        for key in Set(finalA.files.keys).union(finalB.files.keys) {
            // Only a document that really is the same on both drives counts as synced. Anything skipped,
            // failed, or edited during the sync keeps its earlier record, so the next check still sees it.
            if let fa = finalA.files[key], let fb = finalB.files[key],
               finalA.leaveAlone[key] == nil, finalB.leaveAlone[key] == nil,
               Self.hasCurrent(fa) == Self.hasCurrent(fb), same(Self.current(fa), .a, Self.current(fb), .b) {
                let ca = Self.current(fa), cb = Self.current(fb)
                files[key] = VersionStamp(size: ca.size, mtime: ca.mtime)
                if ca.mtime != cb.mtime { filesB[key] = VersionStamp(size: cb.size, mtime: cb.mtime) }
                let pa = Self.past(fa), pb = Self.past(fb)
                if let pa, let pb, same(pa, .a, pb, .b) {
                    pasts[key] = VersionStamp(size: pa.size, mtime: pa.mtime)
                    if pa.mtime != pb.mtime { pastsB[key] = VersionStamp(size: pb.size, mtime: pb.mtime) }
                } else if let old = plan.oldState?.pasts?[key] {
                    pasts[key] = old
                    pastsB[key] = plan.oldState?.pastsB?[key]
                }
                if let d = plan.demote[key] ?? plan.demoted[key],
                   (fa.variants + fb.variants).contains(where: { $0.role == .past && $0.matches(d) }) { demoted[key] = d }
            } else {
                mismatched += 1
                if let old = plan.oldState?.files[key] {
                    files[key] = old
                    filesB[key] = plan.oldState?.filesB?[key]
                    if plan.oldState?.pasts == nil, let only = finalA.files[key] ?? finalB.files[key], let p = Self.past(only),
                       p.mtime.timeIntervalSince(old.mtime) <= SyncConstants.timeTolerance {
                        pasts[key] = VersionStamp(size: p.size, mtime: p.mtime)   // 1.0 didn't record these
                    }
                }
                if let old = plan.oldState?.pasts?[key] { pasts[key] = old; pastsB[key] = plan.oldState?.pastsB?[key] }
                if let old = plan.demote[key] ?? plan.demoted[key] { demoted[key] = old }
            }
        }
        var folders = Set(finalA.folders.keys).intersection(finalB.folders.keys)
        let oneSidedFolders = Set(finalA.folders.keys).symmetricDifference(finalB.folders.keys)
        folders.formUnion(oneSidedFolders.intersection(plan.oldState?.folders ?? []))
        if mismatched > 0 || !oneSidedFolders.isEmpty {
            log("\(mismatched) document(s) and \(oneSidedFolders.count) folder(s) still differ between A and B (skipped, waiting for your choice, or failed).", .warning)
        }

        let state = SyncState(pairID: pair.id, syncID: UUID(), lastSync: now, files: files, folders: folders.sorted(),
                              demoted: demoted.isEmpty ? nil : demoted, pasts: pasts,
                              filesB: filesB.isEmpty ? nil : filesB, pastsB: pastsB.isEmpty ? nil : pastsB)
        do { try writeStates(state) } catch {
            result.errors += 1
            log("Could not save the sync record: \(error.localizedDescription)", .error)
        }
        result.structureFileName = writeStructureFiles(scans: [finalA, finalB], date: now, errors: result.errors)
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
        return now.size == variant.size && abs(now.mtime.timeIntervalSince(variant.mtime)) <= SyncConstants.exactTolerance
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
        var readFailed = false
        guard let en = fm.enumerator(at: folderURL, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey, .isSymbolicLinkKey],
                                     options: [.producesRelativePathURLs], errorHandler: { _, _ in readFailed = true; return false }) else {
            return "it couldn't be read"
        }
        for case let item as URL in en {
            let name = item.lastPathComponent
            if name == ".DS_Store" || name == ".localized" || name.hasPrefix("._") || name.hasPrefix(SyncConstants.tempPrefix)
                || SyncConstants.ignoredNames.contains(name) || name.hasPrefix("~$") { continue }
            if name.hasPrefix(".") { return "it contains hidden files (\(name)) that aren't synced" }
            var inner = item.relativePath
            while inner.hasSuffix("/") { inner.removeLast() }
            let rel = Naming.joinPath(d.relPath, inner)
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
        if readFailed { return "part of it couldn't be read" }
        return nil
    }

    private func ensureRootsAvailable() throws {
        for side in Side.allCases where !PairStore.isDirectory(root(side).path) {
            throw SyncError.locationMissing(root(side).path)
        }
        // An ejected drive can leave an ordinary folder with its name behind.
        for side in Side.allCases where devices[side.rawValue] != device(side) {
            throw SyncError.locationMissing(root(side).path)
        }
    }

    /// Make one side hold exactly the planned newest + _past files. Returns how many items went to the Trash.
    private func arrange(_ op: FileOp, dirRel: String, temps: [URL?]) throws -> Int {
        let dir = url(op.side, dirRel)
        var trashed = 0

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
            if !moves.contains(where: { sameItem($0.from, target) })
                && !op.displaced.contains(where: { sameItem(url(op.side, $0.relPath), target) }) {
                throw SyncError.failed("\"\(target.lastPathComponent)\" already exists and isn't a version of this document, so nothing was changed. Rename it and sync again.")
            }
        }
        // Retire versions that are no longer the newest or second newest.
        var retired: [(from: URL, inTrash: URL)] = []
        func restore() {
            for r in retired where !fm.fileExists(atPath: r.from.path) { try? fm.moveItem(at: r.inTrash, to: r.from) }
        }
        for v in op.displaced {
            do {
                if let t = try moveToTrash(url(op.side, v.relPath), side: op.side) { retired.append((url(op.side, v.relPath), t)) }
            } catch {
                restore()
                throw error
            }
            trashed += 1
            log("\(sideName(op.side)) Old version to Trash: \(v.relPath)")
        }
        // If anything below fails, put every name back the way it was.
        var done: [(from: URL, to: URL)] = []
        func undo() {
            for m in done.reversed() where !fm.fileExists(atPath: m.from.path) { try? fm.moveItem(at: m.to, to: m.from) }
        }
        do {
        while !moves.isEmpty {
            if let i = moves.firstIndex(where: { !fm.fileExists(atPath: $0.to.path) }) {
                try fm.moveItem(at: moves[i].from, to: moves[i].to)
                done.append((moves[i].from, moves[i].to))
                log("\(sideName(op.side)) \(moves[i].label)")
                moves.remove(at: i)
            } else if let i = moves.firstIndex(where: { m in moves.contains { sameItem($0.from, m.to) } }),
                      !moves[i].from.lastPathComponent.hasPrefix(SyncConstants.holdPrefix) {
                // Two files swapping names: park one under a recoverable name first.
                let hold = dir.appendingPathComponent(SyncConstants.holdPrefix + moves[i].from.lastPathComponent)
                try fm.moveItem(at: moves[i].from, to: hold)
                done.append((moves[i].from, hold))
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
            done.append((p.from, p.to))
            log("\(sideName(op.side)) \(p.label)")
        }
        } catch {
            undo()
            restore()
            throw error
        }
        return trashed
    }

    /// Both edits survive: the newer keeps the name, the other is saved beside it on both drives.
    /// Stopping at any point leaves every edit in at least one place.
    private func keepBoth(_ k: KeepBothOp, dir: (Side) -> URL, result: inout SyncResult) throws {
        let winSide = k.loserSide.other
        let tmpOnWin = dir(winSide).appendingPathComponent(SyncConstants.tempPrefix + UUID().uuidString)
        let tmpOnLose = dir(k.loserSide).appendingPathComponent(SyncConstants.tempPrefix + UUID().uuidString)
        defer { for t in [tmpOnWin, tmpOnLose] where fm.fileExists(atPath: t.path) { try? fm.removeItem(at: t) } }
        func ready() -> Bool { unchanged(k.loser, on: k.loserSide) && unchanged(k.winner, on: winSide) }
        guard ready() else { throw SyncError.failed("it changed after you looked, so nothing was done. Compare again.") }
        try copyItem(from: url(k.loserSide, k.loser.relPath), to: tmpOnWin, expectedSize: k.loser.size)
        try copyItem(from: url(winSide, k.winner.relPath), to: tmpOnLose, expectedSize: k.winner.size)
        guard ready(), currentStats(tmpOnWin)?.size == k.loser.size, currentStats(tmpOnLose)?.size == k.winner.size else {
            throw SyncError.failed("it changed while being copied, so nothing was done. Compare again.")
        }
        let newOnLose = dir(k.loserSide).appendingPathComponent(k.newName)
        let newOnWin = dir(winSide).appendingPathComponent(k.newName)
        for u in [newOnLose, newOnWin] where fm.fileExists(atPath: u.path) {
            throw SyncError.failed("\"\(k.newName)\" already exists, so nothing was done.")
        }
        let original = url(k.loserSide, k.loser.relPath)
        // The loser is safe on the other drive before its own name is touched, and is parked under a name the
        // next scan restores if the app stops half-way.
        try fm.moveItem(at: tmpOnWin, to: newOnWin)
        let hold = original.deletingLastPathComponent().appendingPathComponent(SyncConstants.holdPrefix + original.lastPathComponent)
        do {
            try fm.moveItem(at: original, to: hold)
            do {
                try fm.moveItem(at: tmpOnLose, to: dir(k.loserSide).appendingPathComponent(k.winner.fileName))
                try fm.moveItem(at: hold, to: newOnLose)
            } catch {
                if !fm.fileExists(atPath: original.path) { try? fm.moveItem(at: hold, to: original) }
                throw error
            }
        } catch {
            if fm.fileExists(atPath: original.path), !fm.fileExists(atPath: hold.path), unchanged(k.loser, on: k.loserSide) {
                try? fm.removeItem(at: newOnWin)   // our own copy; the original is back in place
            }
            throw error
        }
        trustedKeys.insert(k.key)
        trustedKeys.insert(Naming.joinPath(k.parentKey, Naming.key(k.newName)))
        result.copied += 2
        result.bytesCopied += k.loser.size + k.winner.size
        log("Kept both: \(k.winner.relPath) and \(k.newName)")
    }

    static func hasCurrent(_ f: LogicalFile) -> Bool { f.variants.contains { $0.role == .updated } }

    /// The file under the plain name, or the newest _past when there is none.
    static func current(_ f: LogicalFile) -> FileVariant {
        f.variants.filter { $0.role == .updated }.max { $0.mtime < $1.mtime } ?? f.variants.max { $0.mtime < $1.mtime }!
    }

    static func past(_ f: LogicalFile) -> FileVariant? {
        let c = current(f)
        return f.variants.filter { $0.role == .past && $0.relPath != c.relPath }.max { $0.mtime < $1.mtime }
    }

    /// Byte-for-byte comparison, used only to tell a real clash from the same edit saved twice.
    private func sameContents(_ a: URL, _ b: URL, limit: Int64 = 64_000_000) -> Bool {
        guard let sa = currentStats(a), let sb = currentStats(b), !sa.isDir, !sb.isDir, sa.size == sb.size, sa.size <= limit,
              let ha = try? FileHandle(forReadingFrom: a), let hb = try? FileHandle(forReadingFrom: b) else { return false }
        defer { try? ha.close(); try? hb.close() }
        while true {
            guard let x = try? ha.read(upToCount: 1 << 20) ?? Data(), let y = try? hb.read(upToCount: 1 << 20) ?? Data(), x == y else { return false }
            if x.isEmpty { return true }
        }
    }

    /// Tests only: send "trashed" items here instead of the real Trash.
    var trashOverride: URL?

    @discardableResult
    private func moveToTrash(_ item: URL, side: Side) throws -> URL? {
        do {
            if let t = trashOverride {
                try fm.createDirectory(at: t, withIntermediateDirectories: true)
                let dest = t.appendingPathComponent(UUID().uuidString + "-" + item.lastPathComponent)
                try fm.moveItem(at: item, to: dest)
                return dest
            }
            var result: NSURL?
            try fm.trashItem(at: item, resultingItemURL: &result)
            return result as URL?
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
            return dest
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
        Self.unlock(dst)   // a Finder-locked file can't be renamed into place
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
        Self.unlock(dst)   // a Finder-locked file can't be renamed into place
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
    func writeStructureFiles(scans: [SideScan], date: Date, errors: Int) -> String? {
        let rootName = root(.a).lastPathComponent
        let fileName = "\(rootName)\(SyncConstants.structureMarker)\(Fmt.fileStamp(date)).txt"
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
            // Each drive's map lists what is really on that drive (they differ while something is skipped).
            let text = structureText(scan: scans[side.rawValue], rootName: rootName, date: date, errors: errors)
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
