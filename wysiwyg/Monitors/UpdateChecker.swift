import Foundation

/// Checks our GitHub Releases for a newer tag. Dependency-free on purpose:
/// plain HTTPS + JSON, silent on failure/offline. No Sparkle, no daemons.
struct UpdateChecker {
    static let repo = "blessingmwiti/wysiwyg"

    enum Result: Equatable {
        case upToDate
        case available(version: String, url: String)
        case unknown // never checked, offline, or no releases yet
    }

    func check(currentVersion: String) async -> Result {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else {
            return .unknown
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return .unknown }
            let rel = try JSONDecoder().decode(Release.self, from: data)
            let latest = Self.normalized(rel.tag_name)
            guard !latest.isEmpty else { return .unknown }
            return Self.isNewer(latest, than: Self.normalized(currentVersion))
                ? .available(version: latest, url: rel.html_url)
                : .upToDate
        } catch {
            return .unknown
        }
    }

    private struct Release: Decodable {
        var tag_name: String
        var html_url: String
    }

    /// "v1.2.3" -> "1.2.3"
    static func normalized(_ v: String) -> String {
        var s = v.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        return s
    }

    /// Numeric component-wise compare, so 1.10 > 1.9. Ignores suffixes ("-beta").
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(separator: ".").map { Int(String($0.prefix(while: { $0.isNumber }))) ?? 0 }
        }
        let l = parts(latest), c = parts(current)
        for i in 0..<max(l.count, c.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < c.count ? c[i] : 0
            if a != b { return a > b }
        }
        return false
    }
}
