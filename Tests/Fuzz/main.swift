import Foundation

// Random use, cancels and crashes. Arguments: folder, rounds, seed. Rules checked after every run:
//  1. An edit that was never fully synced is still on A or B (never only in the Trash).
//  2. A current file nobody deleted, renamed or replaced is still on A or B.
//  3. After choices are made, everything settles (nothing is stuck).
setvbuf(stdout, nil, _IONBF, 0)
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let A = base.appendingPathComponent("A/Proj"), B = (ProcessInfo.processInfo.environment["PDS_FUZZ_B"].map { URL(fileURLWithPath: $0) } ?? base).appendingPathComponent("B/Proj"), T = base.appendingPathComponent("Trash")
let pair = SyncPair(id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "Proj", pathA: A.path, pathB: B.path, created: Date(), lastSync: nil)
func eng(_ log: @escaping @Sendable (LogEntry) -> Void = { _ in }) -> SyncEngine {
    let e = SyncEngine(pair: pair, logDirectory: nil, log: log, progress: { _ in }); e.trashOverride = T; return e
}

struct Saved: Codable { var d: [String: Decision] }
/// Child process: run one sync and die abruptly at the nth action.
if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "--crash" {
    let n = Int(CommandLine.arguments[3])!
    let choices = (try? JSONDecoder().decode(Saved.self, from: Data(CommandLine.arguments[4].utf8)))?.d ?? [:]
    nonisolated(unsafe) var armed = false, count = 0
    let e = eng { _ in if armed { count += 1; if count >= n { _exit(9) } } }
    var r = SyncEngine.review(of: try! eng().prepare(readOnly: true))
    for (k, v) in choices { r.decisions[k] = v }
    if let p = try? e.prepare(review: r) { armed = true; _ = try? e.execute(p) }
    exit(0)
}

let rounds = Int(CommandLine.arguments[2])!
struct RNG: RandomNumberGenerator { var s: UInt64; mutating func next() -> UInt64 { s &+= 0x9E3779B97F4A7C15; var z = s; z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9; z = (z ^ (z >> 27)) &* 0x94D049BB133111EB; return z ^ (z >> 31) } }
let seed = UInt64(CommandLine.arguments[3])!
var g = RNG(s: seed)
func roll(_ n: Int) -> Int { Int.random(in: 0..<n, using: &g) }
let names = ["r.txt", "d/a.txt", "Notes_past.pdf", "q", "d/e/z.txt"]
var serial = 0, history: [String] = [], synced = Set<String>()
func pastName(_ n: String) -> String { Naming.joinPath(Naming.parent(of: n), Naming.name(logical: Naming.lastComponent(n), role: .past)) }
func put(_ d: URL, _ n: String, _ text: String, _ ago: Double) {
    let u = d.appendingPathComponent(n); try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: u, atomically: false, encoding: .utf8)
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -ago)], ofItemAtPath: u.path)
}
func contents(_ d: URL) -> [String: String] {   // relative path -> text
    var o: [String: String] = [:]
    for rel in (try? fm.subpathsOfDirectory(atPath: d.path)) ?? [] {
        let name = Naming.lastComponent(rel)
        // A parked file is the user's file waiting to be restored, so it counts as present.
        if (name.hasPrefix(".") && !name.hasPrefix(SyncConstants.holdPrefix)) || name.contains("file structure") { continue }
        if let t = try? String(contentsOf: d.appendingPathComponent(rel), encoding: .utf8) { o[rel] = t }
    }
    return o
}
var touched = Set<String>()   // documents the user deleted, renamed or replaced since they last settled
func docKey(_ rel: String) -> String { Naming.joinPath(Naming.key(Naming.parent(of: rel)), Naming.key(Naming.parse(Naming.lastComponent(rel)).logical)) }
func userAction() {
    let d = roll(2) == 0 ? A : B, n = names[roll(names.count)], target = roll(4) == 0 ? pastName(n) : n
    let ago = [Double(roll(2000) + 60), Double(roll(90000) + 60), Double(-roll(4000)), Double(3600 * roll(4) + 60)][roll(4)]
    serial += 1
    let side = d == A ? "A" : "B"
    switch roll(10) {
    case 0...4: touched.insert(docKey(target)); put(d, target, "text \(serial)" + String(repeating: "x", count: ProcessInfo.processInfo.environment["PDS_FUZZ_B"] == nil ? roll(3) : serial % 97), ago); history.append("\(side) write \(target) #\(serial) ago \(Int(ago))")
    case 5, 6: touched.insert(docKey(target)); try? fm.removeItem(at: d.appendingPathComponent(target)); history.append("\(side) rm \(target)")
    case 7:
        touched.insert(docKey(n))
        let (x, y) = roll(2) == 0 ? (n, pastName(n)) : (pastName(n), n)
        if fm.fileExists(atPath: d.appendingPathComponent(x).path) { try? fm.removeItem(at: d.appendingPathComponent(y)); try? fm.moveItem(at: d.appendingPathComponent(x), to: d.appendingPathComponent(y)); history.append("\(side) mv \(x) \(y)") }
    case 8:
        let dir = roll(2) == 0 ? "d" : "d/e"
        for x in contents(d).keys where x.hasPrefix(dir + "/") { touched.insert(docKey(x)) }
        try? fm.removeItem(at: d.appendingPathComponent(dir)); history.append("\(side) rm -r \(dir)")
    default:
        touched.insert(docKey(n))
        let x = d.appendingPathComponent(pastName(n))
        if fm.fileExists(atPath: x.path) { try? fm.removeItem(at: d.appendingPathComponent(n)); try? fm.copyItem(at: x, to: d.appendingPathComponent(n)); history.append("\(side) cp past over \(n)") }
    }
}
func fail(_ m: String) -> Never {
    print("FAIL (seed \(seed)) \(m)"); print(history.suffix(40).joined(separator: "\n"))
    print("A \(contents(A))\nB \(contents(B))"); exit(1)
}
/// Choices that never ask for anything to be deleted or retired.
func safeChoices(_ p: SyncPlan) -> [String: Decision] {
    var d: [String: Decision] = [:]
    for i in p.items where !i.isFolder && roll(2) == 0 {
        let ok = i.allowed.filter { $0 != .deleteBoth && i.retires[$0.rawValue] == nil }
        if let c = ok.randomElement(using: &g) { d[i.id] = c }
    }
    return d
}
func run() {
    let before = contents(A).merging(contents(B).map { ("B/" + $0, $1) }) { x, _ in x }
    let look = try! eng().prepare(readOnly: true)
    let choices = roll(2) == 0 ? safeChoices(look) : [:]
    var mode = "sync"
    switch roll(5) {
    case 0:
        mode = "cancel"
        nonisolated(unsafe) var e: SyncEngine!
        let at = roll(6) + 1
        nonisolated(unsafe) var c = 0
        e = eng { l in if l.text.hasPrefix("[") { c += 1; if c >= at { e.cancel() } } }
        var r = SyncEngine.review(of: look); for (k, v) in choices { r.decisions[k] = v }
        if let p = try? e.prepare(review: r) { c = 0; _ = try? e.execute(p) }
        e.releaseLocks()
    case 1:
        mode = "crash"
        let pr = Process(); pr.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        pr.arguments = [base.path, "--crash", "\(roll(6) + 1)", String(decoding: try! JSONEncoder().encode(Saved(d: choices)), as: UTF8.self)]
        pr.standardError = FileHandle.nullDevice
        try! pr.run(); pr.waitUntilExit()
    default:
        let e = eng()
        if choices.isEmpty { let p = try! e.prepare(); _ = try! e.execute(p) }
        else { var r = SyncEngine.review(of: look); for (k, v) in choices { r.decisions[k] = v }; if let p = try? e.prepare(review: r) { _ = try! e.execute(p) }; e.releaseLocks() }
    }
    history.append("-- \(mode) \(choices.map { "\($0)=\($1.rawValue)" }.sorted())  [\(look.items.filter { $0.kind.isChange }.map { "\($0.key):\($0.kind)->\($0.suggested.rawValue)" }.joined(separator: " "))]")
    let a = contents(A), b = contents(B), now = Set(a.values).union(b.values)
    for (path, text) in before where !now.contains(text) {
        let rel = path.hasPrefix("B/") ? String(path.dropFirst(2)) : path
        if !synced.contains(text) { fail("unsynced \"\(text)\" (\(path)) is gone after \(mode)") }
        if Naming.parse(Naming.lastComponent(rel)).role == .updated && !touched.contains(docKey(rel)) { fail("untouched current \"\(text)\" (\(path)) is gone after \(mode)") }
    }
    for (rel, t) in a where b[rel] == t { synced.insert(t) }   // it reached both drives
    if mode == "sync" {
        // Settled documents start afresh.
        let left = Set(((try? eng().prepare(readOnly: true))?.items ?? []).filter { $0.kind.isChange }.map(\.key))
        touched = touched.filter { left.contains($0) }
    }
}
func settle() {
    for _ in 0..<6 {
        let p = try! eng().prepare(readOnly: true)
        let open = p.items.filter { $0.kind.isChange }
        if open.isEmpty { return }
        var r = SyncEngine.review(of: p)
        for i in open where i.suggested == .skip { if let c = i.allowed.first(where: { $0 != .skip && $0 != .keepBoth }) ?? i.allowed.first(where: { $0 != .skip }) { r.decisions[i.id] = c } }
        let e = eng(); if let q = try? e.prepare(review: r) { _ = try! e.execute(q) }; e.releaseLocks()
    }
    fail("never settles: \(try! eng().prepare(readOnly: true).items.filter { $0.kind.isChange }.map { "\($0.key) \($0.kind) \($0.reason)" })")
}
for round in 0..<rounds {
    for d in [A, B, T] { try? fm.removeItem(at: d); try! fm.createDirectory(at: d, withIntermediateDirectories: true) }
    history = ["round \(round)"]; synced = []; touched = []
    for _ in 0..<roll(5) { userAction() }
    for _ in 0..<(3 + roll(8)) { for _ in 0..<(1 + roll(3)) { userAction() }; run() }
    settle()
}
print("ALL PASSED (\(rounds) rounds)")
