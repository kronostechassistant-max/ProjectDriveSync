import Foundation

// MARK: - What the user can choose for one item

nonisolated enum Decision: String, Sendable, Codable, CaseIterable {
    /// Leave both drives exactly as they are this time.
    case skip
    /// Copy (or restore) an item that is on one drive to the other.
    case copyAcross
    /// Move every version on both drives to the Trash.
    case deleteBoth
    /// Make A's (or B's) file the current one on both drives; the other becomes _past.
    case keepA, keepB
    /// Keep the newer under its name and save the other beside it under a new name.
    case keepBoth
    /// Currents already match; only _past files need lining up.
    case tidy
}

nonisolated enum DiffKind: Sendable, Equatable {
    case unchanged
    case added              // on one drive, not there at the last sync
    case deleted            // was synced, untouched, now gone from the other drive
    case deletedButChanged  // gone from one drive but edited on the other
    case edited             // one drive has an edit the other doesn't
    case clash              // both drives have edits the other doesn't
    case olderCopy          // one drive changed, but to something with an older date
    case onlyHere           // on one drive, and there is no sync record to say why
    case differs            // different on each drive, and there is no sync record
    case tidy               // current files match; _past files don't
    case blocked            // can't be synced (name problem, unreadable)

    var isChange: Bool { self != .unchanged }
    var needsReview: Bool { self == .clash || self == .olderCopy || self == .blocked }
}

nonisolated struct SideInfo: Sendable, Equatable {
    var relPath: String
    var size: Int64
    var mtime: Date
    var isPackage: Bool
    var pastRelPath: String?
    var pastMtime: Date?
}

/// One row of the comparison tree.
nonisolated struct DiffItem: Sendable, Identifiable {
    var id: String          // "f:" or "d:" + key
    var key: String
    var parentKey: String
    var name: String
    var isFolder: Bool
    var kind: DiffKind
    /// The drive that has the item (added/deleted/only here) or the edit (edited).
    var side: Side?
    var a: SideInfo?
    var b: SideInfo?
    var suggested: Decision
    var allowed: [Decision]
    var reason: String

    static func fileID(_ key: String) -> String { "f:" + key }
    static func folderID(_ key: String) -> String { "d:" + key }
}

// MARK: - What the user reviewed

/// Sent with Apply. Anything on disk that no longer looks the way the user saw it is held back.
nonisolated struct Review: Sendable {
    var syncID: UUID?
    var decisions: [String: Decision] = [:]   // item id -> choice
    var fingerprints: [String: String] = [:]  // document key -> what both drives looked like
    var folders: [String: Int] = [:]          // folder key -> bit 1 = on A, bit 2 = on B
    /// "Do this now": only these item ids are acted on.
    var limit: Set<String>? = nil
}

/// Two files with the same name that both deserve to stay.
nonisolated struct KeepBothOp: Sendable {
    var key: String
    var parentKey: String
    var parentRel: String
    var loserSide: Side
    var loser: FileVariant
    var winner: FileVariant
    var newName: String
}

nonisolated enum Fingerprint {
    static func document(_ a: LogicalFile?, _ b: LogicalFile?) -> String {
        func part(_ f: LogicalFile?) -> String {
            (f?.variants ?? []).map { "\($0.relPath)|\($0.size)|\(Int64(($0.mtime.timeIntervalSince1970 * 1000).rounded()))" }
                .sorted().joined(separator: "\n")
        }
        return part(a) + "\n--\n" + part(b)
    }
}

/// "This Mac" or the drive's name.
nonisolated enum Place {
    static func name(_ path: String) -> String {
        let parts = path.split(separator: "/")
        if parts.count >= 2 && parts[0] == "Volumes" { return String(parts[1]) }
        return "This Mac"
    }

    /// Short labels for a pair, always different from each other.
    static func labels(_ pair: SyncPair) -> (a: String, b: String) {
        let a = name(pair.pathA), b = name(pair.pathB)
        return a.lowercased() == b.lowercased() ? ("\(a) (A)", "\(b) (B)") : (a, b)
    }

    static func fileSafe(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
    }
}

// MARK: - Line differences for text files

nonisolated struct DiffLine: Sendable, Identifiable {
    enum Mark: Sendable { case same, changed, missing }
    let id: Int
    var left: String
    var right: String
    var leftMark: Mark
    var rightMark: Mark
}

nonisolated enum TextDiff {
    static let maxBytes = 1_000_000
    static let maxLines = 5_000

    /// nil when the file isn't plain text (or is too large to show).
    static func text(_ url: URL) -> String? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= maxBytes,
              let data = try? Data(contentsOf: url), !data.contains(0) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func lines(_ left: String, _ right: String) -> [DiffLine]? {
        func split(_ s: String) -> [String] { s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") }
        let l = split(left), r = split(right)
        guard l.count <= maxLines, r.count <= maxLines else { return nil }
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in r.difference(from: l) {
            switch change {
            case .remove(let o, _, _): removed.insert(o)
            case .insert(let o, _, _): inserted.insert(o)
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0
        while i < l.count || j < r.count {
            let dl = i < l.count && removed.contains(i), dr = j < r.count && inserted.contains(j)
            if dl && dr {
                out.append(DiffLine(id: out.count, left: l[i], right: r[j], leftMark: .changed, rightMark: .changed)); i += 1; j += 1
            } else if dl {
                out.append(DiffLine(id: out.count, left: l[i], right: "", leftMark: .changed, rightMark: .missing)); i += 1
            } else if dr {
                out.append(DiffLine(id: out.count, left: "", right: r[j], leftMark: .missing, rightMark: .changed)); j += 1
            } else {
                out.append(DiffLine(id: out.count, left: i < l.count ? l[i] : "", right: j < r.count ? r[j] : "", leftMark: .same, rightMark: .same)); i += 1; j += 1
            }
        }
        return out
    }
}
