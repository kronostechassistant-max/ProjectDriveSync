import Foundation

// Compare, choices, clash protection and data-safety scenarios (V1.25). Each starts from empty folders.
setvbuf(stdout, nil, _IONBF, 0)
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1])
try? fm.removeItem(at: base)
// Optional: put location B on another drive, e.g. an exFAT disk image.
let baseB = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : base
var A = base, B = base, T = base
var pair: SyncPair!
var failures = 0, passes = 0
func check(_ c: Bool, _ m: String) { print((c ? "  PASS " : "  FAIL ") + m); if c { passes += 1 } else { failures += 1 } }
func fresh(_ n: String) {
    print("== \(n)")
    let r = base.appendingPathComponent(n.replacingOccurrences(of: "/", with: "-"))
    A = r.appendingPathComponent("A/Proj"); B = baseB.appendingPathComponent("\(n.prefix(3).trimmingCharacters(in: .whitespaces))-B/Proj"); T = r.appendingPathComponent("Trash")
    for d in [A, B, T] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }
    guard case .success(let p) = PairStore.makePair(pathA: A.path, pathB: B.path, existing: []) else { fatalError() }
    pair = p
}
func w(_ d: URL, _ n: String, _ s: String, _ ago: Double) {
    let u = d.appendingPathComponent(n)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! s.write(to: u, atomically: false, encoding: .utf8)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -ago)], ofItemAtPath: u.path)
}
func rm(_ d: URL, _ n: String) { try! fm.removeItem(at: d.appendingPathComponent(n)) }
func rd(_ d: URL, _ n: String) -> String? { try? String(contentsOf: d.appendingPathComponent(n), encoding: .utf8) }
func ex(_ d: URL, _ n: String) -> Bool { fm.fileExists(atPath: d.appendingPathComponent(n).path) }
var lastLog: [String] = []
func eng() -> SyncEngine { let e = SyncEngine(pair: pair, logDirectory: nil, log: { lastLog.append($0.text) }, progress: { _ in }); e.trashOverride = T; return e }
@discardableResult func doSync() -> PlanSummary { let e = eng(); let p = try! e.prepare(); _ = try! e.execute(p); return p.summary }
func look() -> SyncPlan { try! eng().prepare(readOnly: true) }
@discardableResult func apply(_ seen: SyncPlan, _ d: [String: Decision], limit: Set<String>? = nil) -> (PlanSummary, SyncResult) {
    var r = SyncEngine.review(of: seen)
    for i in seen.items { r.decisions[i.id] = i.suggested }
    for (k, v) in d { r.decisions[k] = v }
    r.limit = limit
    let e = eng(); let p = try! e.prepare(review: r); return (p.summary, try! e.execute(p))
}
func kind(_ p: SyncPlan, _ id: String) -> DiffKind? { p.items.first { $0.id == id }?.kind }
func snapshot(_ d: URL) -> [String] {
    var o: [String] = []
    for case let u as URL in fm.enumerator(at: d, includingPropertiesForKeys: nil)! {
        let a = try! fm.attributesOfItem(atPath: u.path)
        o.append("\(u.path)|\(a[.size]!)|\((a[.modificationDate] as! Date).timeIntervalSince1970)")
    }
    return o.sorted()
}
func trashed(_ text: String) -> Bool { ((try? fm.contentsOfDirectory(atPath: T.path)) ?? []).contains { rd(T, $0) == text } }
func noLeftovers() -> Bool { !(snapshot(A) + snapshot(B)).contains { $0.contains(".pds-") } }

fresh("1 compare touches nothing")
w(A, "a.txt", "x", 9000); w(A, ".pds-tmp-zzz", "partial", 10); w(A, "sub/.pds-hold-b.txt", "parked", 10); w(B, "c.txt", "y", 9000)
var before = snapshot(A) + snapshot(B)
var p = look()
check(before == snapshot(A) + snapshot(B), "nothing on either drive changed, including leftovers")
check(p.items.count >= 3, "still reports differences")

fresh("2 every kind is recognised")
for n in ["same", "delB", "delA", "editA", "editB", "clash", "delChanged"] { w(A, n + ".txt", "base " + n, 9000) }
w(A, "dir/in.txt", "in", 9000); doSync()
check(look().items.allSatisfy { $0.kind == .unchanged }, "all unchanged after a sync")
rm(B, "delB.txt"); rm(A, "delA.txt"); w(A, "editA.txt", "A!", 500); w(B, "editB.txt", "B!", 500)
w(A, "clash.txt", "clash from A", 500); w(B, "clash.txt", "clash from B!", 400); rm(B, "delChanged.txt"); w(A, "delChanged.txt", "more", 300)
w(A, "newA.txt", "n", 200); w(B, "newdir/n.txt", "n", 200); rm(A, "dir")
p = look()
check(kind(p, "f:same.txt") == .unchanged, "unchanged")
check(kind(p, "f:delb.txt") == .deleted && kind(p, "f:dela.txt") == .deleted, "deleted on either drive")
check(kind(p, "f:edita.txt") == .edited && kind(p, "f:editb.txt") == .edited, "edited on either drive")
check(kind(p, "f:clash.txt") == .clash, "clash")
check(kind(p, "f:delchanged.txt") == .deletedButChanged, "deleted but changed")
check(kind(p, "f:newa.txt") == .added && kind(p, "d:newdir") == .added, "new file and folder")
check(kind(p, "d:dir") == .deleted && kind(p, "f:dir/in.txt") == .deleted, "deleted folder")

fresh("3 defaults through Apply equal a normal sync")
w(A, "e.txt", "1", 9000); w(A, "d.txt", "d", 9000); doSync()
w(B, "e.txt", "22", 500); rm(A, "d.txt"); w(A, "n/new.txt", "n", 400)
apply(look(), [:])
check(rd(A, "e.txt") == "22" && rd(A, "e_past.txt") == "1" && !ex(B, "d.txt") && rd(B, "n/new.txt") == "n", "edit, delete and add carried over")
check(look().items.allSatisfy { $0.kind == .unchanged }, "then all unchanged"); check(noLeftovers(), "no leftovers")

fresh("4 deleted item: restore, skip, then delete")
w(A, "a.txt", "a", 9000); w(A, "b.txt", "b", 9000); doSync(); rm(B, "a.txt"); rm(B, "b.txt")
apply(look(), ["f:a.txt": .copyAcross, "f:b.txt": .skip])
check(rd(B, "a.txt") == "a", "restored"); check(rd(A, "b.txt") == "b" && !ex(B, "b.txt"), "skipped item untouched")
check(kind(look(), "f:b.txt") == .deleted && kind(look(), "f:a.txt") == .unchanged, "skipped is still a deletion next time")
apply(look(), ["f:b.txt": .deleteBoth]); check(!ex(A, "b.txt") && trashed("b"), "deleted from both, in Trash")

fresh("5 new item: delete or skip")
w(A, "k.txt", "k", 9000); doSync(); w(A, "n1.txt", "n1", 100); w(B, "n2.txt", "n2", 100)
apply(look(), ["f:n1.txt": .deleteBoth, "f:n2.txt": .skip])
check(!ex(A, "n1.txt") && !ex(B, "n1.txt") && trashed("n1"), "new file deleted to Trash")
check(ex(B, "n2.txt") && !ex(A, "n2.txt") && kind(look(), "f:n2.txt") == .added, "skipped new file still new")

fresh("6 keep the older version, and it sticks")
w(A, "r.txt", "old", 9000); doSync(); w(B, "r.txt", "newer edit", 500)
apply(look(), ["f:r.txt": .keepA])
check(rd(A, "r.txt") == "old" && rd(B, "r.txt") == "old" && rd(A, "r_past.txt") == "newer edit" && rd(B, "r_past.txt") == "newer edit", "older is current, newer is _past")
check(look().items.allSatisfy { $0.kind == .unchanged }, "nothing to do next time")
doSync(); doSync(); check(rd(A, "r.txt") == "old" && rd(B, "r_past.txt") == "newer edit", "survives later syncs")
w(A, "r.txt", "third", 10); doSync(); check(rd(B, "r.txt") == "third" && rd(B, "r_past.txt") == "old", "later edit works normally")
fresh("6b editing the demoted _past brings it back")
w(A, "r.txt", "old", 9000); doSync(); w(B, "r.txt", "newer", 500); apply(look(), ["f:r.txt": .keepA])
w(A, "r_past.txt", "edited past", 10); doSync(); check(rd(B, "r.txt") == "edited past" && rd(B, "r_past.txt") == "old", "swap")
fresh("6c deleting a document with a demoted _past")
w(A, "r.txt", "old", 9000); doSync(); w(B, "r.txt", "newer", 500); apply(look(), ["f:r.txt": .keepA]); rm(B, "r.txt")
check(kind(look(), "f:r.txt") == .deleted, "seen as deleted"); doSync(); check(!ex(A, "r.txt") && !ex(A, "r_past.txt") && !ex(B, "r_past.txt"), "all versions trashed")

fresh("7 clash: never touched by Sync, then each choice")
func clash() { for n in ["a", "b", "k", "s"] { w(A, n + ".txt", "base" + n, 9000) }; doSync(); for n in ["a", "b", "k", "s"] { w(A, n + ".txt", "from A " + n, 600); w(B, n + ".txt", "from B! " + n, 500) } }
clash(); var s = doSync(); check(s.clashes == 4 && s.needsConfirmation, "flagged"); doSync()
check(rd(A, "a.txt") == "from A a" && rd(B, "a.txt") == "from B! a" && !ex(A, "a_past.txt"), "both edits untouched after two syncs")
apply(look(), ["f:a.txt": .keepA, "f:b.txt": .keepB, "f:k.txt": .keepBoth])
check(rd(B, "a.txt") == "from A a" && rd(A, "a_past.txt") == "from B! a", "keep A (older) wins, B's edit is _past on both")
check(rd(A, "b.txt") == "from B! b" && rd(B, "b_past.txt") == "from A b", "keep B")
check(rd(A, "k.txt") == "from B! k" && rd(B, "k.txt") == "from B! k", "keep both: newer keeps the name")
let kb = try! fm.contentsOfDirectory(atPath: A.path).first { $0.hasPrefix("k (") } ?? ""
check(rd(A, kb) == "from A k" && rd(B, kb) == "from A k", "keep both: other saved as \(kb)")
check(rd(A, "s.txt") == "from A s" && kind(look(), "f:s.txt") == .clash, "unchosen clash still waiting")
check(look().items.filter { $0.kind != .unchanged }.count == 1, "everything else settled"); check(noLeftovers(), "no leftovers")
fresh("7b clash then another edit loses nothing")
w(A, "r.txt", "base", 9000); doSync(); w(A, "r.txt", "A edit", 600); w(B, "r.txt", "B edit!", 500); doSync(); w(A, "r.txt", "third edit", 100); doSync()
check(rd(A, "r.txt") == "third edit" && rd(B, "r.txt") == "B edit!", "v1.0 loss case: both kept"); check(!trashed("A edit") && !trashed("B edit!"), "nothing in Trash")
fresh("7c same edit on both is not a clash")
w(A, "r.txt", "base", 9000); doSync(); w(A, "r.txt", "same!", 600); w(B, "r.txt", "same!", 500)
check(kind(look(), "f:r.txt") == .edited, "identical contents"); doSync(); check(kind(look(), "f:r.txt") == .unchanged, "settled")
fresh("7d one drive simply a version ahead")
w(A, "r.txt", "v1", 9000); doSync(); w(A, "r.txt", "v2", 700); w(B, "r.txt", "v3", 500)
try! fm.copyItem(at: A.appendingPathComponent("r.txt"), to: B.appendingPathComponent("r_past.txt"))
check(kind(look(), "f:r.txt") == .edited, "not a clash when one was built on the other")

fresh("8 edit made during a sync is never trashed (v1.0 bug)")
w(A, "r.txt", "base", 9000); for i in 0..<20 { w(A, "f\(i).txt", "x", 9000) }; doSync()
var e = eng(); p = try! e.prepare(); w(A, "r.txt", "edit during sync", 100); _ = try! e.execute(p)
rm(B, "r.txt"); s = doSync()
check(s.deletions == 0 && rd(A, "r.txt") == "edit during sync" && rd(B, "r.txt") == "edit during sync", "kept and restored")

fresh("9 stale comparison is held back")
for n in ["a", "b", "c"] { w(A, n + ".txt", n, 9000) }; doSync(); rm(B, "a.txt"); w(A, "b.txt", "b2", 500)
p = look(); w(A, "a.txt", "a edited after looking", 50); w(A, "new.txt", "new after looking", 50); w(B, "b.txt", "b on B after", 40)
let (s9, _) = apply(p, [:])
check(s9.heldBack == 3, "three held back (\(s9.heldBack))")
check(rd(A, "a.txt") == "a edited after looking" && !ex(B, "new.txt") && rd(B, "b.txt") == "b on B after" && rd(A, "b.txt") == "b2", "nothing acted on")
p = look(); check(kind(p, "f:a.txt") == .deletedButChanged && kind(p, "f:new.txt") == .added && kind(p, "f:b.txt") == .clash, "seen correctly next time")
fresh("9b synced after looking: Apply refuses")
w(A, "a.txt", "a", 9000); doSync(); p = look(); doSync()
var r9 = SyncEngine.review(of: p); r9.decisions["f:a.txt"] = .skip
check((try? eng().prepare(review: r9)) == nil, "refused")

fresh("10 do this now touches one item only")
for n in ["a", "b"] { w(A, n + ".txt", n, 9000) }; doSync(); w(A, "a.txt", "a2", 500); w(A, "b.txt", "b2", 500); w(A, "x/y/n.txt", "n", 400); rm(B, "b.txt")
apply(look(), [:], limit: ["f:a.txt"]); check(rd(B, "a.txt") == "a2" && !ex(B, "b.txt") && !ex(B, "x"), "only a.txt")
apply(look(), [:], limit: ["f:x/y/n.txt"]); check(rd(B, "x/y/n.txt") == "n", "parent folders created as needed")
check(kind(look(), "f:b.txt") == .deletedButChanged, "the rest still waiting")

fresh("11 folder choices")
for n in ["d1/a.txt", "d1/s/b.txt", "d2/a.txt", "d3/a.txt", "d3/b.txt"] { w(A, n, n, 9000) }; doSync()
for d in ["d1", "d2", "d3"] { rm(B, d) }
apply(look(), ["d:d1": .copyAcross, "d:d1/s": .copyAcross, "f:d1/a.txt": .copyAcross, "f:d1/s/b.txt": .copyAcross, "d:d2": .skip, "f:d2/a.txt": .skip, "f:d3/b.txt": .skip])
check(rd(B, "d1/s/b.txt") == "d1/s/b.txt", "folder restored"); check(ex(A, "d2/a.txt") && !ex(B, "d2"), "folder skipped on both drives")
check(!ex(A, "d3/a.txt") && ex(A, "d3/b.txt") && !ex(B, "d3"), "folder kept for the skipped file inside, not recreated")
check(kind(look(), "d:d2") == .deleted && kind(look(), "f:d3/b.txt") == .deleted, "still pending")
doSync(); check(!ex(A, "d2") && !ex(A, "d3"), "a normal sync then removes them")
w(A, "nd/in/x.txt", "x", 100); p = look()
apply(p, ["d:nd": .deleteBoth, "d:nd/in": .deleteBoth, "f:nd/in/x.txt": .deleteBoth]); check(!ex(A, "nd") && !ex(B, "nd"), "new folder deleted")
w(A, "nf/x.txt", "x", 100); w(A, "nf/.secret", "hidden", 100); p = look()
apply(p, ["d:nf": .deleteBoth, "f:nf/x.txt": .deleteBoth]); check(ex(A, "nf/.secret"), "folder with hidden files is not removed")

fresh("12 unreadable folder: nothing deleted, nothing invented")
w(A, "d/a.txt", "a", 9000); w(A, "z.txt", "z", 9000); doSync(); rm(B, "z.txt")
try! fm.setAttributes([.posixPermissions: 0], ofItemAtPath: B.appendingPathComponent("d").path)
let cantRead = (try? fm.contentsOfDirectory(atPath: B.appendingPathComponent("d").path)) == nil
if !cantRead { print("  (skipped: this drive has no permissions)") } else {
p = look(); apply(p, ["f:z.txt": .deleteBoth, "f:d/a.txt": .deleteBoth])
try! fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: B.appendingPathComponent("d").path)
check(rd(A, "d/a.txt") == "a" && rd(B, "d/a.txt") == "a" && rd(A, "z.txt") == "z", "nothing deleted while something can't be read")
check(kind(look(), "f:z.txt") == .deleted, "deletion still remembered")
}

fresh("13 merge: three different versions are not silently reduced")
w(A, "r.txt", "A cur", 500); w(A, "r_past.txt", "A past!", 900); w(B, "r.txt", "B cur!!", 400); w(B, "r_past.txt", "B past!!!", 800)
p = look(); check(kind(p, "f:r.txt") == .clash, "needs a choice"); doSync()
check(rd(A, "r.txt") == "A cur" && rd(B, "r_past.txt") == "B past!!!", "untouched")
w(A, "q.txt", "x", 10); fresh("13b merge: two versions, newest current"); w(A, "q.txt", "older", 900); w(B, "q.txt", "newer!", 100); doSync()
check(rd(A, "q.txt") == "newer!" && rd(B, "q_past.txt") == "older", "as in v1.0")

fresh("14 a v1.0 sync record still works")
w(A, "r.txt", "r", 9000); doSync()
for d in [A, B] { let f = try! fm.contentsOfDirectory(atPath: d.path).first { $0.hasPrefix(".projectdrivesync-") }!
    var j = try! JSONSerialization.jsonObject(with: Data(contentsOf: d.appendingPathComponent(f))) as! [String: Any]; j["demoted"] = nil; j["pasts"] = nil
    try! JSONSerialization.data(withJSONObject: j).write(to: d.appendingPathComponent(f)) }
rm(A, "r.txt"); s = doSync(); check(!s.mergeMode && ex(B, "r.txt"), "record read; a deletion from a 1.0 record waits to be confirmed")
apply(look(), ["f:r.txt": .deleteBoth]); check(!ex(B, "r.txt"), "then it is carried over")

fresh("15 any deletion is shown first")
for i in 0..<200 { w(A, "f\(i).txt", "x\(i)", 9000) }; doSync(); rm(A, "f3.txt")
func asks() -> Bool { let e = eng(); let p = try! e.prepare(); e.releaseLocks(); return p.summary.needsConfirmation }
check(asks(), "one deletion among 200 asks"); doSync(); w(A, "f5.txt", "edit", 10)
check(!asks(), "an ordinary edit doesn't ask")

fresh("16 each drive's map lists that drive")
w(A, "a.txt", "a", 9000); doSync(); w(B, "only-b.txt", "b", 100); apply(look(), ["f:only-b.txt": .skip])
func map(_ d: URL) -> String { rd(d, (try! fm.contentsOfDirectory(atPath: d.path)).first { $0.contains("file structure") }!)! }
check(map(B).contains("only-b.txt") && !map(A).contains("only-b.txt"), "maps differ while an item is skipped")

fresh("17 cancel part-way loses nothing")
for i in 0..<6 { w(A, "c\(i).txt", "base\(i)", 9000) }; doSync()
for i in 0..<6 { w(A, "c\(i).txt", "new \(i)", 500) }; rm(A, "c5.txt")
var c = 0; var holder: SyncEngine?
let ce = SyncEngine(pair: pair, logDirectory: nil, log: { _ in }, progress: { if $0.phase.hasPrefix("Copying") { c += 1; if c == 2 { holder?.cancel() } } }); ce.trashOverride = T; holder = ce
p = try! ce.prepare(); _ = try? ce.execute(p); doSync()
check((0..<5).allSatisfy { rd(B, "c\($0).txt") == "new \($0)" && rd(B, "c\($0)_past.txt") == "base\($0)" } && !ex(B, "c5.txt"), "next sync completes it")

fresh("18 text differences")
let d = TextDiff.lines("a\nb\nc", "a\nB\nc\nd")!
check(d.count == 4 && d[0].leftMark == .same && d[1].leftMark == .changed && d[1].right == "B" && d[3].leftMark == .missing, "aligned lines")

fresh("19 packages: clash and keep both")
func pkg(_ r: URL, _ t: String, _ ago: Double) { try! fm.createDirectory(at: r.appendingPathComponent("L.rtfd"), withIntermediateDirectories: true); w(r, "L.rtfd/TXT.rtf", t, ago)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -ago)], ofItemAtPath: r.appendingPathComponent("L.rtfd").path) }
pkg(A, "base", 9000); doSync(); pkg(A, "from A", 600); pkg(B, "from B!", 500)
check(kind(look(), "f:l.rtfd") == .clash, "package clash"); apply(look(), ["f:l.rtfd": .keepBoth])
let lk = try! fm.contentsOfDirectory(atPath: A.path).first { $0.hasPrefix("L (") } ?? "none"
check(rd(A, "L.rtfd/TXT.rtf") == "from B!" && rd(B, lk + "/TXT.rtf") == "from A" && rd(A, lk + "/TXT.rtf") == "from A", "both packages on both drives (\(lk))")

// ---- Cases proven by the independent review ----
func mv(_ d: URL, _ a: String, _ b: String) { try! fm.moveItem(at: d.appendingPathComponent(a), to: d.appendingPathComponent(b)) }
func lock(_ u: URL, _ on: Bool) { try! fm.setAttributes([.immutable: on], ofItemAtPath: u.path) }
func settled() -> Bool { look().items.allSatisfy { $0.kind == .unchanged } }
func trashEmpty() -> Bool { ((try? fm.contentsOfDirectory(atPath: T.path)) ?? []).isEmpty }
func v12() { w(A, "r.txt", "v1", 9000); doSync(); w(A, "r.txt", "v2", 8000); doSync() }

fresh("R1 renaming to or from _past is not a deletion")
w(A, "r.txt", "precious", 9000); w(A, "Notes_past.pdf", "notes", 9000); doSync(); mv(B, "r.txt", "r_past.txt"); mv(A, "Notes_past.pdf", "Notes.pdf"); s = doSync()
check(s.deletions == 0 && trashEmpty() && rd(A, "r.txt") == "precious" && rd(B, "r.txt") == "precious", "r.txt safe on both")
check(rd(A, "Notes.pdf") == "notes" && rd(B, "Notes.pdf") == "notes", "rename carried over"); check(settled(), "settled")

fresh("R2 half-finished update is not a deletion")
w(A, "r.txt", "base", 9000); doSync(); mv(B, "r.txt", "r_past.txt"); w(B, "r_past.txt", "B replacement", 9500); s = doSync()
check(s.deletions == 0 && trashEmpty() && rd(A, "r.txt") == "base", "nothing trashed")
fresh("R2b locked file: copies over, unlocked, nothing left behind")
w(A, "r.txt", "v1", 9000); doSync(); w(A, "r.txt", "v2", 500); lock(A.appendingPathComponent("r.txt"), true); doSync()
check(rd(B, "r.txt") == "v2" && rd(B, "r_past.txt") == "v1" && noLeftovers(), "synced"); lock(A.appendingPathComponent("r.txt"), false); check(settled(), "settled")
fresh("R2c a placement that can't happen is rolled back")
w(A, "r.txt", "v1", 9000); doSync(); w(A, "r.txt", "v2", 500)
var re = eng()
let sub = SyncEngine(pair: pair, logDirectory: nil, log: { if $0.text.contains("Renamed r.txt") { try! "in the way".write(to: B.appendingPathComponent("r.txt"), atomically: false, encoding: .utf8) } }, progress: { _ in }); sub.trashOverride = T
p = try! sub.prepare(); let rr = try! sub.execute(p)
check(rr.errors == 1 && rd(B, "r.txt") == "in the way" && rd(B, "r_past.txt") == "v1" && rd(A, "r.txt") == "v2", "every file still there"); check(noLeftovers(), "no leftovers")

fresh("R3 unsynced _past edits are never retired silently")
v12(); w(A, "r.txt", "v3", 200); w(B, "r_past.txt", "B edit of past", 100); doSync()
check(rd(B, "r_past.txt") == "B edit of past" && rd(A, "r.txt") == "v3" && !trashed("B edit of past"), "edit on one, _past edit on the other: left alone")
fresh("R3b"); v12(); w(A, "r.txt", "v3", 200); w(A, "r_past.txt", "A edit of past", 100); doSync(); check(rd(A, "r_past.txt") == "A edit of past" && !trashed("A edit of past"), "both on one drive")
fresh("R3c"); v12(); w(A, "r_past.txt", "past on A", 200); w(B, "r_past.txt", "past on B!", 100); doSync()
check(rd(A, "r_past.txt") == "past on A" && rd(B, "r_past.txt") == "past on B!" && rd(A, "r.txt") == "v2" && trashEmpty(), "different _past edits")
mv(A, "r_past.txt", "r other.txt"); doSync(); check(ex(B, "r other.txt"), "renaming one clears it"); doSync(); check(settled(), "settled")
fresh("R4 _past edited while the current is deleted elsewhere"); v12(); w(A, "r_past.txt", "my new edit", 100); rm(B, "r.txt"); s = doSync(); check(s.deletions == 0 && !trashed("my new edit"), "not treated as a deletion")

fresh("R5 an hour apart is a different version"); w(A, "db.dat", "1111", 9000); doSync(); w(A, "db.dat", "2222", 9000 - 3600); doSync(); check(rd(B, "db.dat") == "2222", "edit synced")
w(A, "c.dat", "0000", 9000); doSync(); w(A, "c.dat", "AAAA", 5000); w(B, "c.dat", "BBBB", 1400); check(kind(look(), "f:c.dat") == .clash, "clash seen")
fresh("R5b FAT32 daylight saving"); w(A, "f.txt", "same", 9000); doSync(); w(B, "f.txt", "same", 9000 - 3600)
func fatLook() -> SyncPlan { let e = eng(); e.fatOverride = true; return try! e.prepare(readOnly: true) }
check(kind(fatLook(), "f:f.txt") == .unchanged, "same contents, shifted an hour"); w(B, "f.txt", "diff", 9000 - 3600); check(kind(fatLook(), "f:f.txt") != .unchanged, "different contents are not hidden")

fresh("R6 aliases are not deletions and are never written through")
w(A, "Photos/p.jpg", "p", 9000); w(A, "r.txt", "r", 9000); doSync()
let outside = A.deletingLastPathComponent().appendingPathComponent("outside"); try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
try! fm.moveItem(at: A.appendingPathComponent("Photos"), to: outside.appendingPathComponent("Photos")); try! fm.moveItem(at: A.appendingPathComponent("r.txt"), to: outside.appendingPathComponent("r.txt"))
try! fm.createSymbolicLink(at: A.appendingPathComponent("Photos"), withDestinationURL: outside.appendingPathComponent("Photos")); try! fm.createSymbolicLink(at: A.appendingPathComponent("r.txt"), withDestinationURL: outside.appendingPathComponent("r.txt"))
w(B, "Photos/new.jpg", "n", 100); doSync()
check(rd(B, "Photos/p.jpg") == "p" && rd(B, "r.txt") == "r", "nothing deleted"); check(!fm.fileExists(atPath: outside.appendingPathComponent("Photos/new.jpg").path), "nothing written outside the folder")
check(kind(look(), "f:r.txt") == .blocked, "shown as left alone")

fresh("R7 a change with an older date is a choice, not undone")
w(A, "r.txt", "base", -86400); doSync(); w(B, "r.txt", "edit one", 200); s = doSync(); check(s.clashes == 1 && rd(B, "r.txt") == "edit one" && rd(A, "r.txt") == "base", "asked")
w(B, "r.txt", "edit two!", 100); doSync(); check(rd(B, "r.txt") == "edit two!" && trashEmpty(), "second edit kept too"); apply(look(), ["f:r.txt": .keepB]); check(rd(A, "r.txt") == "edit two!" && rd(A, "r_past.txt") == "base", "chosen"); doSync(); check(rd(A, "r.txt") == "edit two!" && settled(), "and it sticks")

fresh("R8 a.txt_past is its own document"); w(A, "a.txt", "a1", 9000); w(A, "a_past.txt", "a0", 9500); w(A, "a.txt_past", "my other file", 9000); doSync(); w(A, "a.txt", "a2", 100); doSync()
check(rd(A, "a.txt_past") == "my other file" && rd(B, "a.txt_past") == "my other file" && rd(B, "a_past.txt") == "a1", "kept")

fresh("R9 put back while waiting: not deleted"); w(A, "r.txt", "r", 9000); w(A, "d/x.txt", "x", 9000); doSync(); rm(B, "r.txt"); rm(B, "d")
re = eng(); p = try! re.prepare(); w(B, "r.txt", "r", 9000); w(B, "d/x.txt", "x", 9000); _ = try! re.execute(p); doSync()
check(rd(A, "r.txt") == "r" && rd(B, "r.txt") == "r" && rd(A, "d/x.txt") == "x" && rd(B, "d/x.txt") == "x", "still on both")

fresh("R10 keeping the older survives a cancel"); w(A, "r.txt", "old", 9000); w(A, "z.txt", "z", 9000); doSync(); w(B, "r.txt", "newer", 500); w(B, "z.txt", "z2", 400); 
var rv = SyncEngine.review(of: look()); rv.decisions["f:r.txt"] = .keepA
var hold10: SyncEngine?; let c10 = SyncEngine(pair: pair, logDirectory: nil, log: { if $0.text.contains("r_past.txt") && $0.text.contains("[A]") || $0.text.contains("Copied newest r.txt") { hold10?.cancel() } }, progress: { _ in }); c10.trashOverride = T; hold10 = c10
let cp = try! c10.prepare(review: rv); var didCancel = false; do { _ = try c10.execute(cp) } catch { didCancel = true }
doSync(); check(didCancel && rd(A, "r.txt") == "old" && rd(B, "r.txt") == "old" && rd(A, "r_past.txt") == "newer", "older still current after cancel and another sync")

fresh("R11 a lost record doesn't decide a clash"); w(A, "r.txt", "base", 9000); doSync(); w(A, "r.txt", "A edit", 600); w(B, "r.txt", "B edit!", 500)
for f in try! fm.contentsOfDirectory(atPath: B.path) where f.hasPrefix(".projectdrivesync-") { rm(B, f) }
s = doSync(); check(rd(A, "r.txt") == "A edit" && rd(B, "r.txt") == "B edit!" && s.clashes == 1, "still asks")

fresh("R12 nothing is deleted when a copy failed"); w(A, "r.txt", "r", 9000); doSync(); mv(A, "r.txt", "s.txt")
try! fm.setAttributes([.posixPermissions: 0], ofItemAtPath: A.appendingPathComponent("s.txt").path)
if (try? Data(contentsOf: A.appendingPathComponent("s.txt"))) == nil { doSync(); check(rd(B, "r.txt") == "r", "B keeps its copy") }
try! fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: A.appendingPathComponent("s.txt").path); doSync(); check(rd(B, "s.txt") == "r" && !ex(B, "r.txt"), "then the rename carries over")

fresh("R13 documents really named _past keep their name"); w(A, "Notes_past.pdf", "n1", 9000); w(A, "x.txt", "X doc", 9000); w(A, "x_past_past.txt", "other", 9000); doSync(); w(A, "Notes_past.pdf", "n2", 500); w(A, "x_past_past.txt", "other 2", 400); doSync(); doSync()
check(rd(B, "Notes_past.pdf") == "n2" && !ex(B, "Notes.pdf"), "edited in place"); check(rd(A, "x.txt") == "X doc" && rd(B, "x_past_past.txt") == "other 2", "neighbours untouched"); check(settled(), "settled")

fresh("R14 the same edit on both keeps the real _past"); v12(); w(A, "r.txt", "same!", 600); w(B, "r.txt", "same!", 500); doSync(); check(rd(A, "r_past.txt") == "v1" && rd(B, "r_past.txt") == "v1" && settled(), "the earlier version is kept, not a duplicate")
fresh("R15 a folder that became a package on one drive"); w(A, "X.bundle_/a.txt", "a", 9000); doSync(); rm(A, "X.bundle_"); w(A, "X.bundle_", "now a file", 500); doSync(); check(rd(B, "X.bundle_/a.txt") == "a", "contents on the other drive untouched")
fresh("R16 two copies of the app"); w(A, "a.txt", "a", 9000); re = eng(); _ = try! re.prepare(); check((try? eng().prepare()) == nil, "second one is refused"); check((try? eng().prepare(readOnly: true)) != nil, "looking is still allowed"); re.releaseLocks(); check((try? eng().prepare()) != nil, "free afterwards")

fresh("R17 names that differ only in capitals"); w(B, "ab.txt", "one", 900); doSync(); w(B, "AB.txt", "other document", 200)
if (try! fm.contentsOfDirectory(atPath: B.path)).filter({ $0.lowercased() == "ab.txt" }).count == 2 {
    w(B, "docs/a.txt", "d1", 300); w(B, "Docs/a.txt", "D2", 200); doSync(); doSync()
    check(rd(B, "ab.txt") == "one" && rd(B, "AB.txt") == "other document" && rd(B, "docs/a.txt") == "d1" && rd(B, "Docs/a.txt") == "D2" && trashEmpty(), "all left alone")
    check(kind(look(), "f:ab.txt") == .blocked, "shown as left alone")
} else { print("  (skipped: this drive ignores capitals)") }

// ---- Second review ----
fresh("S1 keep older interrupted on B"); w(A, "r.txt", "old", 9000); doSync(); w(B, "r.txt", "newer edit", 500)
let s1 = SyncEngine.review(of: look()); var s1r = s1; s1r.decisions["f:r.txt"] = .keepA
do { let e = eng(); let p = try! e.prepare(review: s1r); _ = p
    // The state a crash leaves: A done, B renamed but the older copy not yet in place, choice already recorded.
    e.releaseLocks() }
w(A, "r_past.txt", "newer edit", 500); mv(B, "r.txt", "r_past.txt")
for d in [A, B] { let f = try! fm.contentsOfDirectory(atPath: d.path).first { $0.hasPrefix(".projectdrivesync-") }!
    var st = try! JSONDecoder().decode(SyncState.self, from: Data(contentsOf: d.appendingPathComponent(f)))
    let at = try! fm.attributesOfItem(atPath: A.appendingPathComponent("r_past.txt").path)
    st.demoted = ["r.txt": VersionStamp(size: at[.size] as! Int64, mtime: at[.modificationDate] as! Date)]
    try! JSONEncoder().encode(st).write(to: d.appendingPathComponent(f)) }
s = doSync(); check(s.deletions == 0 && trashEmpty(), "nothing deleted"); doSync(); check(rd(B, "r.txt") != nil && (rd(B, "r_past.txt") == "newer edit" || rd(B, "r.txt") == "newer edit"), "both versions kept"); check(settled(), "settled")
fresh("S2 keep older, only one drive done"); w(A, "r.txt", "p0", 9900); doSync(); w(A, "r.txt", "old", 9000); doSync(); w(A, "r.txt", "newer edit", 500)
lock(B.appendingPathComponent("r_past.txt"), true); apply(look(), ["f:r.txt": .keepB]); lock(B.appendingPathComponent("r_past.txt"), false); doSync(); doSync()
check(!(trashed("newer edit") && rd(A, "r_past.txt") != "newer edit" && rd(A, "r.txt") != "newer edit"), "the edit is still on the drives"); check(settled(), "settled")
fresh("S3 no record: a newest _past edit isn't retired"); w(A, "k.txt", "k", 9000); doSync(); w(A, "r.txt", "a1", 600); w(A, "r_past.txt", "b1", 700); w(B, "r.txt", "b1", 700); w(B, "r_past.txt", "B past edit", 100); doSync()
check(rd(B, "r_past.txt") == "B past edit" && trashEmpty(), "asked instead")
fresh("S4 a choice that retires an edit names it"); w(A, "r.txt", "A cur", 500); w(A, "r_past.txt", "A past!", 100); w(B, "r.txt", "B cur!!", 400); w(B, "r_past.txt", "B past!!!", 50); p = look()
check(p.items.first { $0.id == "f:r.txt" }!.retires["keepA"]?.isEmpty == false , "listed")
fresh("S5 reverting with the _past is asked about, not undone"); v12(); rm(B, "r.txt"); try! fm.copyItem(at: B.appendingPathComponent("r_past.txt"), to: B.appendingPathComponent("r.txt")); s = doSync()
check(rd(B, "r.txt") == "v1" && s.clashes == 1, "left as the user made it"); apply(look(), ["f:r.txt": .keepB]); check(rd(A, "r.txt") == "v1" && settled(), "and can be chosen")
fresh("S6 one stuck file doesn't stop other deletions"); w(A, "r.txt", "r", 9000); w(A, "d.txt", "dd", 9000); doSync(); w(A, "r.txt", "r2", 500); lock(B.appendingPathComponent("r.txt"), true); rm(A, "d.txt"); doSync()
check(!ex(B, "d.txt") && rd(B, "r.txt") == "r", "unrelated deletion done, locked file left"); lock(B.appendingPathComponent("r.txt"), false); doSync(); check(settled(), "settled")
fresh("S7 first pairing with different _past files is a choice, not a dead end"); w(A, "r.txt", "same", 9000); w(B, "r.txt", "same", 9000); let t7 = try! fm.attributesOfItem(atPath: A.appendingPathComponent("r.txt").path)[.modificationDate]!
try! fm.setAttributes([.modificationDate: t7], ofItemAtPath: B.appendingPathComponent("r.txt").path); w(A, "r_past.txt", "pa", 9500); w(B, "r_past.txt", "pb!", 9400); doSync(); doSync(); p = look()
check(kind(p, "f:r.txt") == .clash && trashEmpty(), "asks"); apply(p, ["f:r.txt": .keepA]); check(rd(B, "r_past.txt") == "pa" && settled(), "chosen and settled")
fresh("S8 document beside a folder named like its _past"); w(A, "Budget", "b", 9000); w(A, "Budget_past/in.txt", "in", 9000); doSync(); w(A, "Budget_past/in.txt", "in2", 100); doSync(); check(rd(B, "Budget_past/in.txt") == "in2", "the folder still syncs")
fresh("S9 a document's versions are deleted together or not at all"); v12(); rm(B, "r.txt"); lock(A.appendingPathComponent("r_past.txt"), true); doSync(); check(rd(A, "r.txt") == "v2" && rd(A, "r_past.txt") == "v1", "put back"); lock(A.appendingPathComponent("r_past.txt"), false); doSync(); check(!ex(A, "r.txt") && !ex(A, "r_past.txt"), "then deleted")
fresh("S10 same size, saved within two seconds"); w(A, "r.txt", "base", 9000); doSync(); w(A, "r.txt", "1111", 500.0); w(B, "r.txt", "2222", 499.2); check(kind(look(), "f:r.txt") == .clash, "seen as different edits")
fresh("S11 keep both survives stopping half-way"); w(A, "r.txt", "base", 9000); doSync(); w(A, "r.txt", "A edit", 600); w(B, "r.txt", "B edit!", 500); mv(A, "r.txt", ".pds-hold-r.txt"); w(B, "r (X).txt", "A edit", 600)
check(kind(look(), "f:r.txt") == .blocked, "looking explains"); doSync(); check(rd(A, "r.txt") == "A edit" && rd(B, "r.txt") == "B edit!" && rd(A, "r (X).txt") == "A edit", "restored")

print(failures == 0 ? "\nALL PASSED (\(passes))" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
