import Foundation
import Observation

/// The comparison on screen: what was found, and what the user has chosen so far. Nothing here touches files.
@Observable
final class Comparison {
    enum Filter: String, CaseIterable, Identifiable {
        case changes = "Changes", review = "Review", all = "All"
        var id: String { rawValue }
    }

    struct Row: Identifiable {
        let item: DiffItem
        let depth: Int
        let hasChildren: Bool
        let changesInside: Int
        var id: String { item.id }
    }

    struct Totals {
        var copies = 0, bytes: Int64 = 0, trash = 0, choose = 0, skipped = 0, blocked = 0
        var trashNames: [String] = []
        var actions: Int { copies + trash + other }
        var other = 0
    }

    let pair: SyncPair
    let summary: PlanSummary
    let labels: (a: String, b: String)
    let baseReview: Review
    let made = Date()
    /// Why Sync opened this instead of running straight away (empty when the user pressed Compare).
    let notice: String

    let items: [String: DiffItem]
    private let children: [String: [DiffItem]]
    private let changesInside: [String: Int]
    private let reviewInside: [String: Int]
    let changeCount: Int
    let reviewCount: Int

    private(set) var decisions: [String: Decision] = [:]
    var filter: Filter { didSet { rebuild() } }
    var search = "" { didSet { rebuild() } }
    private var expanded: Set<String> = []
    var selection: Set<String> = []
    private(set) var rows: [Row] = []
    private(set) var totals = Totals()

    init(pair: SyncPair, plan: SyncPlan, notice: String = "", keeping old: Comparison? = nil) {
        self.pair = pair
        self.summary = plan.summary
        self.labels = Place.labels(pair)
        self.baseReview = SyncEngine.review(of: plan)
        self.notice = notice
        var byID: [String: DiffItem] = [:], kids: [String: [DiffItem]] = [:], inside: [String: Int] = [:], rev: [String: Int] = [:]
        for item in plan.items {
            byID[item.id] = item
            kids[item.parentKey, default: []].append(item)
            guard item.kind.isChange else { continue }
            for a in Naming.ancestors(of: item.key) {
                inside[a, default: 0] += 1
                if item.kind.needsReview { rev[a, default: 0] += 1 }
            }
        }
        for k in kids.keys {
            kids[k]!.sort { x, y in
                x.isFolder != y.isFolder ? x.isFolder : x.name.localizedStandardCompare(y.name) == .orderedAscending
            }
        }
        items = byID
        children = kids
        changesInside = inside
        reviewInside = rev
        changeCount = plan.items.filter { $0.kind.isChange }.count
        reviewCount = plan.items.filter { $0.kind.needsReview }.count
        filter = old?.filter ?? .changes
        if let old {
            // Keep choices for items that still look the same.
            for (id, d) in old.decisions where byID[id]?.kind == old.items[id]?.kind && byID[id]?.allowed.contains(d) == true
                && byID[id]?.a == old.items[id]?.a && byID[id]?.b == old.items[id]?.b { decisions[id] = d }
            search = old.search
            expanded = old.expanded
        } else {
            // Open the folders that contain changes (unless there are very many).
            let open = plan.items.filter { $0.isFolder && (inside[$0.key] ?? 0) > 0 }
            if changeCount <= 400 { expanded = Set(open.map(\.id)) }
        }
        rebuild()
        recount()
    }

    // MARK: Choices

    func decision(_ item: DiffItem) -> Decision { decisions[item.id] ?? item.suggested }

    /// A clash with no choice made yet.
    func isUnchosen(_ item: DiffItem) -> Bool { item.kind == .clash && decisions[item.id] == nil }

    var hasChoices: Bool { !decisions.isEmpty }

    func set(_ d: Decision, for id: String) {
        guard let item = items[id] else { return }
        if item.allowed.contains(d) { decisions[id] = d }
        if item.isFolder {
            let prefix = item.key + "/"
            for child in items.values where child.key.hasPrefix(prefix) && child.allowed.contains(d) { decisions[child.id] = d }
        }
        if d != .deleteBoth {
            // A folder can't be deleted while something inside it stays.
            for key in Naming.ancestors(of: item.key) {
                guard let folder = items[DiffItem.folderID(key)], !folder.allowed.isEmpty else { continue }
                let now = decision(folder)
                if d == .copyAcross, now != .copyAcross { decisions[folder.id] = .copyAcross }
                else if now == .deleteBoth { decisions[folder.id] = .skip }
            }
        }
        recount()
    }

    func set(_ d: Decision, for ids: Set<String>) { for id in ids { set(d, for: id) } }

    func reset() { decisions = [:]; recount() }

    /// Choices every one of these items (or, for a folder, its contents) allows.
    func allowed(for ids: Set<String>) -> [Decision] {
        var result: Set<Decision>?
        for id in ids {
            guard let item = items[id] else { continue }
            var here = Set(item.allowed)
            if item.isFolder && here.isEmpty {
                let prefix = item.key + "/"
                for c in items.values where c.key.hasPrefix(prefix) { here.formUnion(c.allowed) }
            }
            result = result.map { $0.intersection(here) } ?? here
        }
        let found = result ?? []
        return Decision.allCases.filter { found.contains($0) }
    }

    /// The item, everything inside it, for "Do This Now".
    func scope(_ ids: Set<String>) -> Set<String> {
        var out = ids
        for id in ids {
            guard let item = items[id], item.isFolder else { continue }
            let prefix = item.key + "/"
            for c in items.values where c.key.hasPrefix(prefix) { out.insert(c.id) }
        }
        return out
    }

    func review(limit: Set<String>? = nil) -> Review {
        var r = baseReview
        for item in items.values { r.decisions[item.id] = decision(item) }
        r.limit = limit
        return r
    }

    func totals(limit: Set<String>? = nil) -> Totals {
        var t = Totals()
        for item in items.values where item.kind.isChange {
            if let limit, !limit.contains(item.id) { continue }
            if item.kind == .blocked { t.blocked += 1; continue }
            if isUnchosen(item) { t.choose += 1; continue }
            let sa = item.a?.size ?? 0, sb = item.b?.size ?? 0
            switch decision(item) {
            case .skip: if !item.isFolder { t.skipped += 1 }
            case .deleteBoth:
                if item.isFolder {
                    t.other += 1
                    t.trashNames.append((item.a ?? item.b)!.relPath + "/")
                } else {
                    t.trash += 1
                    t.trashNames.append((item.a ?? item.b)!.relPath)
                }
            case .copyAcross: if item.isFolder { t.other += 1 } else { t.copies += 1; t.bytes += max(sa, sb) }
            case .keepA: t.copies += 1; t.bytes += sa
            case .keepB: t.copies += 1; t.bytes += sb
            case .keepBoth: t.copies += 1; t.bytes += sa + sb
            case .tidy: t.other += 1
            }
        }
        t.trashNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return t
    }

    private func recount() { totals = totals() }

    // MARK: Tree

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) || !search.isEmpty }

    func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
        rebuild()
    }

    func expandAll(_ open: Bool) {
        expanded = open ? Set(items.values.filter(\.isFolder).map(\.id)) : []
        rebuild()
    }

    private func shows(_ item: DiffItem) -> Bool {
        switch filter {
        case .all: return true
        case .changes: return item.kind.isChange || (item.isFolder && (changesInside[item.key] ?? 0) > 0)
        case .review: return item.kind.needsReview || (item.isFolder && (reviewInside[item.key] ?? 0) > 0)
        }
    }

    private func rebuild() {
        var out: [Row] = []
        var matches: Set<String>? = nil
        if !search.isEmpty {
            var found = Set<String>()
            for item in items.values where shows(item) && item.name.localizedCaseInsensitiveContains(search) {
                found.insert(item.id)
                for a in Naming.ancestors(of: item.key) { found.insert(DiffItem.folderID(a)) }
            }
            matches = found
        }
        func walk(_ parent: String, _ depth: Int) {
            for item in children[parent] ?? [] where shows(item) && (matches?.contains(item.id) ?? true) {
                let kids = item.isFolder && (children[item.key] ?? []).contains { shows($0) && (matches?.contains($0.id) ?? true) }
                out.append(Row(item: item, depth: depth, hasChildren: kids, changesInside: changesInside[item.key] ?? 0))
                if kids && isExpanded(item.id) { walk(item.key, depth + 1) }
            }
        }
        walk("", 0)
        rows = out
        let visible = Set(out.map(\.id))
        if !selection.isSubset(of: visible) { selection.formIntersection(visible) }
    }

    // MARK: Words

    func title(_ d: Decision, _ item: DiffItem?) -> String {
        let to = item?.side.map { $0 == .a ? labels.b : labels.a }
        switch d {
        case .skip: return "Skip this time"
        case .copyAcross:
            let restoring = item.map { $0.kind == .deleted || $0.kind == .deletedButChanged } ?? false
            return (restoring ? "Restore to " : "Copy to ") + (to ?? "the other drive")
        case .deleteBoth:
            guard let item else { return "Move to Trash" }
            return item.kind == .added || item.kind == .onlyHere ? "Move to Trash" : "Delete from both"
        case .keepA, .keepB:
            let mine = d == .keepA ? labels.a : labels.b, other = d == .keepA ? labels.b : labels.a
            if let item, item.kind == .edited || item.kind == .differs, item.suggested == d { return "Update \(other)" }
            return "Use \(mine)"
        case .keepBoth: return "Keep both files"
        case .tidy: return "Line up _past files"
        }
    }

    func symbol(_ d: Decision, _ item: DiffItem) -> String {
        switch d {
        case .skip: return "minus"
        case .copyAcross: return item.side == .b ? "arrow.left" : "arrow.right"
        case .deleteBoth: return "trash"
        case .keepA: return "arrow.right"
        case .keepB: return "arrow.left"
        case .keepBoth: return "plus.square.on.square"
        case .tidy: return "arrow.up.arrow.down"
        }
    }

    static func word(_ k: DiffKind) -> String {
        switch k {
        case .unchanged: return "Unchanged"
        case .added: return "New"
        case .deleted: return "Deleted"
        case .deletedButChanged: return "Deleted, but edited"
        case .edited: return "Edited"
        case .clash: return "Edited on both"
        case .onlyHere: return "On one drive only"
        case .differs: return "Different"
        case .tidy: return "_past differs"
        case .blocked: return "Can't sync"
        }
    }

    func report() -> String {
        var l = ["\(pair.name): comparison, \(Fmt.display(made))", "A: \(pair.pathA)", "B: \(pair.pathB)",
                 "Nothing had been changed when this was saved.", ""]
        let changed = items.values.filter { $0.kind.isChange }.sorted { $0.key < $1.key }
        if changed.isEmpty { l.append("Both folders are the same.") }
        for i in changed {
            let path = (i.a ?? i.b)!.relPath + (i.isFolder ? "/" : "")
            l.append("[\(Self.word(i.kind))] \(path)")
            l.append("    \(i.reason)")
            if !i.isFolder {
                if let a = i.a { l.append("    \(labels.a): \(Fmt.bytes(a.size)), \(Fmt.display(a.mtime))") }
                if let b = i.b { l.append("    \(labels.b): \(Fmt.bytes(b.size)), \(Fmt.display(b.mtime))") }
            }
            l.append("    Choice: " + (isUnchosen(i) ? "not chosen yet" : (i.kind == .blocked ? "none" : title(decision(i), i))))
        }
        return l.joined(separator: "\n") + "\n"
    }
}
