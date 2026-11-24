import Foundation

// The choices behind the comparison tree, and version checking.
setvbuf(stdout, nil, _IONBF, 0)
let fm = FileManager.default
let base = URL(fileURLWithPath: CommandLine.arguments[1])
let A = base.appendingPathComponent("A/Proj"), B = base.appendingPathComponent("B/Proj"), T = base.appendingPathComponent("Trash")
for d in [A, B, T] { try! fm.createDirectory(at: d, withIntermediateDirectories: true) }
var failures = 0
func check(_ c: Bool, _ m: String) { print((c ? "  PASS " : "  FAIL ") + m); if !c { failures += 1 } }
func w(_ d: URL, _ n: String, _ s: String, _ ago: Double) {
    let u = d.appendingPathComponent(n)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! s.write(to: u, atomically: false, encoding: .utf8)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -ago)], ofItemAtPath: u.path)
}
func ex(_ d: URL, _ n: String) -> Bool { fm.fileExists(atPath: d.appendingPathComponent(n).path) }
guard case .success(let pair) = PairStore.makePair(pathA: A.path, pathB: B.path, existing: []) else { fatalError() }
func eng() -> SyncEngine { let e = SyncEngine(pair: pair, logDirectory: nil, log: { _ in }, progress: { _ in }); e.trashOverride = T; return e }
for n in ["top.txt", "gone/a.txt", "gone/in/b.txt", "keep/c.txt"] { w(A, n, "base", 9000) }
do { let e = eng(); _ = try! e.execute(try! e.prepare()) }
try! fm.removeItem(at: B.appendingPathComponent("gone")); w(A, "top.txt", "from A", 500); w(B, "top.txt", "from B!", 400); w(B, "fresh/n.txt", "n", 100)
let c = Comparison(pair: pair, plan: try! eng().prepare(readOnly: true))

print("== tree and choices")
check(c.labels.a != c.labels.b, "column names differ"); check(c.reviewCount == 1 && c.totals.choose == 1, "one to review, one to choose")
check(!c.rows.contains { $0.item.name == "c.txt" }, "unchanged files hidden under Changes"); c.filter = .all; check(c.rows.contains { $0.item.name == "keep" }, "shown under All"); c.filter = .changes
check(c.totals.trashNames.count == 4, "2 files + 2 folders would go to the Trash (\(c.totals.trashNames.count))")
c.set(.skip, for: "f:gone/in/b.txt")
check(c.decision(c.items["d:gone/in"]!) == .skip && c.decision(c.items["d:gone"]!) == .skip, "folders around a skipped file are no longer deleted")
check(c.decision(c.items["f:gone/a.txt"]!) == .deleteBoth, "its neighbour is unaffected")
c.set(.copyAcross, for: "d:gone"); check(c.decision(c.items["f:gone/in/b.txt"]!) == .copyAcross, "restoring a folder restores what is inside")
c.reset(); c.set(.deleteBoth, for: "d:gone"); c.set(.copyAcross, for: "f:gone/in/b.txt")
check(c.decision(c.items["d:gone"]!) == .copyAcross, "restoring one file restores the folders it needs")
check(c.allowed(for: ["f:gone/a.txt", "f:fresh/n.txt"]) == [.skip, .copyAcross, .deleteBoth], "shared choices for several items")
check(c.scope(["d:fresh"]).contains("f:fresh/n.txt"), "Do This Now on a folder includes its contents")
c.search = "n.txt"; check(c.rows.map(\.item.name).contains("n.txt") && !c.rows.map(\.item.name).contains("top.txt"), "search"); c.search = ""
check(c.report().contains("not chosen yet"), "report says a clash is undecided")
print("== the same choices carried out")
c.reset(); c.set(.copyAcross, for: "f:gone/in/b.txt")
do { let e = eng(); _ = try! e.execute(try! e.prepare(review: c.review())) }
check(ex(B, "gone/in/b.txt") && !ex(B, "gone/a.txt") && !ex(A, "gone/a.txt") && ex(A, "fresh/n.txt"), "drives match the tree")
check((try? String(contentsOf: A.appendingPathComponent("top.txt"), encoding: .utf8)) == "from A", "the undecided clash is untouched")

print("== versions")
func rel(_ v: String, _ b: Int?) -> UpdateChecker.Release { .init(version: v, build: b, page: URL(string: "https://github.com/x")!) }
check(UpdateChecker.isNewer(rel("1.5", 3), than: "1.25", build: 2), "build 3 is newer than build 2")
check(!UpdateChecker.isNewer(rel("1.25", 2), than: "1.25", build: 2) && !UpdateChecker.isNewer(rel("1.0", 1), than: "1.25", build: 2), "same or older is not an update")
check(UpdateChecker.isNewer(rel("1.5", nil), than: "1.25", build: 2) && !UpdateChecker.isNewer(rel("1.0", nil), than: "1.25", build: 2), "without a build number: 1.5 > 1.25 > 1.0")
let json = #"{"tag_name":"v1.5","html_url":"https://github.com/o/r/releases/tag/v1.5","assets":[{"name":"DigitalDriveLinkages-1.5-build3.zip"}]}"#
let r = UpdateChecker.parse(Data(json.utf8)); check(r?.version == "1.5" && r?.build == 3, "reads a GitHub release")
check(UpdateChecker.parse(Data(json.replacingOccurrences(of: "https://github.com", with: "http://evil.example").utf8)) == nil, "refuses a link that isn't GitHub")

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
