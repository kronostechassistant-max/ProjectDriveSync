import Foundation

/// A "married" pair of folders that are kept in sync with each other.
nonisolated struct SyncPair: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var pathA: String
    var pathB: String
    var created: Date
    var lastSync: Date?

    var urlA: URL { URL(fileURLWithPath: pathA, isDirectory: true) }
    var urlB: URL { URL(fileURLWithPath: pathB, isDirectory: true) }
}

nonisolated enum PairStatus: Sendable, Equatable {
    case available, missingA, missingB, missingBoth

    var isAvailable: Bool { self == .available }

    var label: String {
        switch self {
        case .available: return "Both locations available"
        case .missingA: return "Location A not found"
        case .missingB: return "Location B not found"
        case .missingBoth: return "Neither location found"
        }
    }
}

/// The folder keeps the app's first name so saved pairs carry over.
/// Saved list of pairs: ~/Library/Application Support/ProjectDriveSync/pairs.json
nonisolated enum PairStore {
    static var directory: URL {
        #if DEBUG
        if let test = ProcessInfo.processInfo.environment["PDS_DATA"] { return URL(fileURLWithPath: test, isDirectory: true) }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ProjectDriveSync", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("pairs.json") }

    static func load() -> [SyncPair] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([SyncPair].self, from: data)) ?? []
    }

    static func save(_ pairs: [SyncPair]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(pairs).write(to: fileURL, options: .atomic)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    static func status(of pair: SyncPair) -> PairStatus {
        switch (isDirectory(pair.pathA), isDirectory(pair.pathB)) {
        case (true, true): return .available
        case (false, true): return .missingA
        case (true, false): return .missingB
        case (false, false): return .missingBoth
        }
    }

    /// Validates two folder paths for a new pair. Returns the pair, or a user-facing error message.
    static func makePair(pathA rawA: String, pathB rawB: String, existing: [SyncPair]) -> Result<SyncPair, PairError> {
        let a = normalize(rawA), b = normalize(rawB)
        guard !a.isEmpty, !b.isEmpty else { return .failure(.init("Choose both locations.")) }
        guard isDirectory(a) else { return .failure(.init("Location A is not an existing folder:\n\(a)")) }
        guard isDirectory(b) else { return .failure(.init("Location B is not an existing folder:\n\(b)")) }
        let la = a.lowercased(), lb = b.lowercased()
        guard la != lb else { return .failure(.init("Location A and B are the same folder.")) }
        if la.hasPrefix(lb + "/") || lb.hasPrefix(la + "/") {
            return .failure(.init("One location is inside the other. Pick two separate folders."))
        }
        if a == "/" || b == "/" || a.hasPrefix("/Volumes/") && a.split(separator: "/").count == 2
            || b.hasPrefix("/Volumes/") && b.split(separator: "/").count == 2 {
            return .failure(.init("Pick a folder (for example \"Photos\"), not a whole drive."))
        }
        let nameA = (a as NSString).lastPathComponent, nameB = (b as NSString).lastPathComponent
        guard nameA.precomposedStringWithCanonicalMapping.lowercased()
                == nameB.precomposedStringWithCanonicalMapping.lowercased() else {
            return .failure(.init("Both folders must have the same name.\nA is \"\(nameA)\", B is \"\(nameB)\"."))
        }
        if existing.contains(where: { Set([$0.pathA.lowercased(), $0.pathB.lowercased()]) == Set([la, lb]) }) {
            return .failure(.init("These two folders are already a pair."))
        }
        return .success(SyncPair(id: UUID(), name: nameA, pathA: a, pathB: b, created: Date(), lastSync: nil))
    }

    static let untitledFolderName = "Untitled, Synced Folder"

    /// True for a whole drive (a volume's top level), e.g. "/Volumes/My Drive".
    static func isDriveRoot(_ path: String) -> Bool {
        let url = URL(fileURLWithPath: normalize(path), isDirectory: true).resolvingSymlinksInPath()
        if url.path == "/" { return true }
        let values = try? url.resourceValues(forKeys: [.isVolumeKey])
        return values?.isVolume == true
    }

    /// The folders a pair will actually use after resolving whole-drive picks:
    /// - one side is a folder, the other a whole drive: use/create the same-named folder on that drive;
    /// - both are whole drives: use/create "Untitled, Synced Folder" on each.
    nonisolated struct ResolvedPicks: Sendable, Equatable {
        var pathA: String
        var pathB: String
        var toCreate: [String]
    }

    static func resolve(pathA rawA: String, pathB rawB: String) -> ResolvedPicks? {
        let a = normalize(rawA), b = normalize(rawB)
        guard !a.isEmpty, !b.isEmpty, isDirectory(a), isDirectory(b) else { return nil }
        func inside(_ parent: String, _ name: String) -> String { (parent as NSString).appendingPathComponent(name) }
        var ra = a, rb = b
        switch (isDriveRoot(a), isDriveRoot(b)) {
        case (true, true):
            ra = inside(a, untitledFolderName)
            rb = inside(b, untitledFolderName)
        case (true, false):
            ra = inside(a, (b as NSString).lastPathComponent)
        case (false, true):
            rb = inside(b, (a as NSString).lastPathComponent)
        case (false, false):
            break
        }
        return ResolvedPicks(pathA: ra, pathB: rb, toCreate: [ra, rb].filter { !isDirectory($0) })
    }

    static func normalize(_ path: String) -> String {
        var p = ((path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }
}

nonisolated struct PairError: Error, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
}

/// Shared formatting helpers.
nonisolated enum Fmt {
    /// Version from the app bundle (MARKETING_VERSION), e.g. "1.0". See CHANGELOG.md.
    static let appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    /// "YYYYMMDD, HHMM" used in the file-structure text file name.
    static func fileStamp(_ date: Date) -> String { formatter("yyyyMMdd, HHmm").string(from: date) }
    static func display(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm").string(from: date) }
    static func time(_ date: Date) -> String { formatter("HH:mm:ss").string(from: date) }
    static func full(_ date: Date) -> String { formatter("yyyy-MM-dd HH:mm:ss").string(from: date) }
    static func logFileStamp(_ date: Date) -> String { formatter("yyyyMMdd-HHmmss").string(from: date) }

    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond)) + "/s"
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}
