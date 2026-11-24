import Foundation

/// Looks at the latest GitHub release, only when the user asks.
nonisolated enum UpdateChecker {
    static let repository = "kronostechassistant-max/DigitalDriveLinkages"

    struct Release: Sendable {
        var version: String
        var build: Int?
        var page: URL
    }

    enum Outcome: Sendable {
        case upToDate
        case available(Release)
        case noRelease
        case failed(String)
    }

    static func check() async -> Outcome {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DigitalDriveLinkages", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 404 { return .noRelease }
            guard code == 200 else { return .failed("GitHub answered with code \(code). Try again later.") }
            guard let release = parse(data) else { return .failed("GitHub's answer couldn't be read.") }
            let mine = Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
            return isNewer(release, than: Fmt.appVersion, build: mine) ? .available(release) : .upToDate
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String, let page = (j["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https", page.host == "github.com" else { return nil }
        let names = (j["assets"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        // Release files are named "DigitalDriveLinkages-1.26-build3.zip".
        let build = names.compactMap { name -> Int? in
            guard let r = name.range(of: "-build") else { return nil }
            return Int(name[r.upperBound...].prefix { $0.isNumber })
        }.max()
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, build: build, page: page)
    }

    /// The build number always goes up, so it decides. Version names are steps like 1.0, 1.25, 1.5, so without
    /// a build number they are compared as decimals (1.5 is newer than 1.25).
    static func isNewer(_ r: Release, than version: String, build: Int?) -> Bool {
        if let theirs = r.build, let build { return theirs > build }
        return (Double(r.version) ?? 0) > (Double(version) ?? 0)
    }
}
