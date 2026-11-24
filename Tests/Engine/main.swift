import Foundation

setvbuf(stdout, nil, _IONBF, 0)
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1])
try? fm.removeItem(at: base)
let A = base.appendingPathComponent("A/General Projects")
let B = base.appendingPathComponent("B/General Projects")
let trash = base.appendingPathComponent("Trash")
try! fm.createDirectory(at: A, withIntermediateDirectories: true)
try! fm.createDirectory(at: B, withIntermediateDirectories: true)

var failures = 0
func check(_ cond: Bool, _ msg: String) {
    print((cond ? "  PASS " : "  FAIL ") + msg)
    if !cond { failures += 1 }
}

var clock = Date().addingTimeInterval(-100_000)
func tick() -> Date { clock = clock.addingTimeInterval(60); return clock }

func write(_ root: URL, _ rel: String, _ text: String, mtime: Date? = nil) {
    let u = root.appendingPathComponent(rel)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! text.write(to: u, atomically: false, encoding: .utf8)
    try! fm.setAttributes([.modificationDate: mtime ?? tick()], ofItemAtPath: u.path)
}
func read(_ root: URL, _ rel: String) -> String? { try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) }
func exists(_ root: URL, _ rel: String) -> Bool { fm.fileExists(atPath: root.appendingPathComponent(rel).path) }
func listing(_ root: URL) -> [String] {
    var out: [String] = []
    let en = fm.enumerator(atPath: root.path)!
    while let p = en.nextObject() as? String { out.append(p) }
    return out.sorted()
}

let pair = SyncPair(id: UUID(), name: "General Projects", pathA: A.path, pathB: B.path, created: Date(), lastSync: nil)
var progressEvents = 0
var maxRate = 0.0

@discardableResult
func sync(_ title: String, printLog: Bool = false) -> (PlanSummary, SyncResult) {
    print("== \(title)")
    let engine = SyncEngine(pair: pair, logDirectory: nil, log: { e in
        if printLog || e.level == .error { print("     log: \(e.text)") }
    }, progress: { p in progressEvents += 1; maxRate = max(maxRate, p.bytesPerSecond) })
    engine.trashOverride = trash
    let plan = try! engine.prepare()
    let result = try! engine.execute(plan)
    check(result.errors == 0, "no errors (\(result.errors))")
    // After every sync both sides must be identical (excluding hidden files)
    check(listing(A).filter { !$0.contains("/.") && !$0.hasPrefix(".") } == listing(B).filter { !$0.contains("/.") && !$0.hasPrefix(".") }, "A and B have identical structure")
    return (plan.summary, result)
}

// 1. First sync / merge
write(A, "report.docx", "r1")
write(A, "Clients/Acme/proposal.docx", "p1")
write(B, "Notes/todo.txt", "t1")
write(B, "Empty Folder/.keep-hidden", "x")
var (s, r) = sync("1 first sync (merge)", printLog: true)
check(s.mergeMode && s.needsConfirmation, "merge mode + confirmation requested")
check(read(A, "report.docx") == "r1" && read(B, "report.docx") == "r1", "report keeps its name in both")
check(!exists(A, "report_past.docx"), "no _past yet (only one version)")
check(read(A, "Notes/todo.txt") == "t1", "B-only file copied to A")
check(exists(A, "Empty Folder"), "empty folder created")
let structName = r.structureFileName ?? ""
check(structName.hasPrefix("General Projects, file structure - ") && exists(A, structName) && exists(B, structName), "structure file in both: \(structName)")
print(read(A, structName) ?? "")

// 2. No changes
(s, r) = sync("2 nothing changed")
check(s.isNoop && !s.mergeMode, "noop, trusted")

// 3. Edit on A
write(A, "report.docx", "r2")
(s, _) = sync("3 edit on A")
check(read(B, "report.docx") == "r2" && read(B, "report_past.docx") == "r1", "B: updated=r2 past=r1")
check(read(A, "report_past.docx") == "r1", "A: past=r1")

// 4. Edit on B → third version retired
write(B, "report.docx", "r3")
sync("4 edit on B")
check(read(A, "report.docx") == "r3" && read(A, "report_past.docx") == "r2", "A: updated=r3 past=r2")

// 5. Both edited: a clash is left alone until the user chooses (V1.25)
write(A, "report.docx", "r4-A")
write(B, "report.docx", "r4-B-newer")
(s, _) = sync("5 both edited")
check(s.clashes == 1 && s.needsConfirmation, "clash flagged and shown first")
check(read(A, "report.docx") == "r4-A" && read(B, "report.docx") == "r4-B-newer", "neither edit touched")
(s, _) = sync("5b still a clash")
check(s.clashes == 1, "clash remembered")
do {
    let e = SyncEngine(pair: pair, logDirectory: nil, log: { _ in }, progress: { _ in }); e.trashOverride = trash
    var review = SyncEngine.review(of: try! e.prepare(readOnly: true)); review.decisions["f:report.docx"] = .keepB
    _ = try! e.execute(try! e.prepare(review: review))
}
check(read(A, "report.docx") == "r4-B-newer" && read(A, "report_past.docx") == "r4-A", "chose B: newest=B, past=A's edit")
check(read(B, "report_past.docx") == "r4-A", "B past = A's edit")

// 6. Delete file on B → removed from A
try! fm.removeItem(at: B.appendingPathComponent("Notes/todo.txt"))
(s, _) = sync("6 delete file on B")
check(s.filesToDelete == 1, "1 deletion planned")
check(!exists(A, "Notes/todo.txt"), "deleted from A")

// 7. Delete folder on B, but A changed a file inside it meanwhile → keep + restore
write(A, "Clients/Acme/proposal.docx", "p2")
try! fm.removeItem(at: B.appendingPathComponent("Clients"))
(s, _) = sync("7 folder deleted on B, but changed on A")
check(s.keptChanged >= 1 && s.foldersToDelete == 0, "kept, not deleted")
check(read(B, "Clients/Acme/proposal.docx") == "p2", "restored to B")

// 8. New folder on B with OLD timestamps → must be copied, not deleted
write(B, "Archive 2019/old.txt", "ancient", mtime: Date(timeIntervalSince1970: 1_500_000_000))
try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_500_000_000)], ofItemAtPath: B.appendingPathComponent("Archive 2019").path)
(s, _) = sync("8 new folder with old dates")
check(s.deletions == 0, "nothing deleted")
check(read(A, "Archive 2019/old.txt") == "ancient", "old-dated new folder copied to A")
let m = (try? fm.attributesOfItem(atPath: A.appendingPathComponent("Archive 2019/old.txt").path)[.modificationDate]) as? Date
check(m.map { abs($0.timeIntervalSince1970 - 1_500_000_000) < 2 } ?? false, "modification date preserved on copy")

// 9. Delete an untouched folder on A → removed from B
try! fm.removeItem(at: A.appendingPathComponent("Archive 2019"))
(s, _) = sync("9 delete folder on A")
check(s.foldersToDelete == 1 && !exists(B, "Archive 2019"), "folder removed from B")

// 10. User edits the _past file (past becomes newest) → names swap
write(A, "report_past.docx", "r5-edited-past")
sync("10 edited the _past file")
check(read(A, "report.docx") == "r5-edited-past" && read(A, "report_past.docx") == "r4-B-newer", "swap handled")
check(!listing(A).contains { $0.contains(".pds-") }, "no temp/hold files left")

// 11. Sync record missing on one side → safe merge, no deletions
try! fm.removeItem(at: B.appendingPathComponent("report.docx"))
try! fm.removeItem(at: B.appendingPathComponent("report_past.docx"))
for f in try! fm.contentsOfDirectory(atPath: B.path) where f.hasPrefix(".projectdrivesync-") {
    try! fm.removeItem(at: B.appendingPathComponent(f))
}
(s, _) = sync("11 replaced drive (no record on B)")
check(s.mergeMode && s.deletions == 0, "merge mode, no deletions")
check(read(B, "report.docx") == "r5-edited-past", "restored instead of deleted")

// 12. Package (rtfd) + big file with progress
let pkg = A.appendingPathComponent("Letter.rtfd")
try! fm.createDirectory(at: pkg, withIntermediateDirectories: true)
write(A, "Letter.rtfd/TXT.rtf", "{\\rtf1 hi}")
let big = A.appendingPathComponent("Video.mov")
fm.createFile(atPath: big.path, contents: Data(count: 80_000_000))
try! fm.setAttributes([.modificationDate: tick()], ofItemAtPath: big.path)
progressEvents = 0
(s, r) = sync("12 package + 80 MB file")
check(exists(B, "Letter.rtfd/TXT.rtf"), "package copied as one unit and renamed")
check(!exists(B, "Letter.rtfd/TXT_past.rtf"), "package contents untouched")
check(r.bytesCopied >= 80_000_000, "bytes counted: \(r.bytesCopied)")
check(progressEvents > 3, "progress events: \(progressEvents), max rate \(Int(maxRate / 1_000_000)) MB/s")

// 13. Rename a file on A (looks like delete + new)
try! fm.moveItem(at: A.appendingPathComponent("Clients/Acme/proposal.docx"), to: A.appendingPathComponent("Clients/Acme/proposal-final.docx"))
try? fm.removeItem(at: A.appendingPathComponent("Clients/Acme/proposal_past.docx"))
sync("13 rename on A")
check(exists(B, "Clients/Acme/proposal-final.docx") && !exists(B, "Clients/Acme/proposal.docx"), "rename carried over")

// 14. Mass deletion triggers confirmation
for i in 0..<30 { write(A, "Bulk/file\(i).txt", "\(i)") }
sync("14a add 30 files")
try! fm.removeItem(at: B.appendingPathComponent("Bulk"))
let engine = SyncEngine(pair: pair, logDirectory: nil, log: { _ in }, progress: { _ in })
let plan = try! engine.prepare()
engine.releaseLocks()
print("== 14b delete 30 on B")
check(plan.summary.needsConfirmation && plan.summary.foldersToDelete == 1 && plan.summary.filesToDelete == 30, "confirmation required for mass delete")
print(plan.summary.lines.map { "     " + $0 }.joined(separator: "\n"))

// 15. Lone "_past" document keeps its name
write(A, "Minutes_past.pdf", "real doc named _past")
sync("15 lone _past file")
check(read(A, "Minutes_past.pdf") == "real doc named _past" && read(B, "Minutes_past.pdf") == "real doc named _past" && !exists(A, "Minutes.pdf"), "not renamed, copied as-is")

// 16. Delete the current file on B (its _past remains) -> whole document deleted both sides
write(A, "Spec.docx", "s1"); sync("16a add")
write(A, "Spec.docx", "s2"); sync("16b edit")
check(read(B, "Spec_past.docx") == "s1", "past exists before delete")
try! fm.removeItem(at: B.appendingPathComponent("Spec.docx"))
(s, _) = sync("16c delete current on B")
check(s.filesToDelete == 1, "planned as a document deletion")
check(!exists(A, "Spec.docx") && !exists(A, "Spec_past.docx") && !exists(B, "Spec_past.docx"), "all versions trashed")

// 17. Delete only the _past on B -> restored (harmless)
write(A, "Plan.docx", "p1"); sync("17a"); write(A, "Plan.docx", "p2"); sync("17b")
try! fm.removeItem(at: B.appendingPathComponent("Plan_past.docx"))
sync("17c delete only _past on B")
check(read(B, "Plan_past.docx") == "p1" && read(B, "Plan.docx") == "p2", "past restored, current intact")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
