import Foundation

/// A release newer than the one running.
public struct AvailableUpdate: Equatable, Sendable {
    public let version: String
    public let url: URL

    public init(version: String, url: URL) {
        self.version = version
        self.url = url
    }
}

/// Asks GitHub whether a newer release exists, and nothing more.
///
/// This is deliberately not an auto-updater. Downloading and swapping a signed
/// bundle safely is Sparkle's job, and Sparkle brings its own update feed and
/// its own signing keys. What people actually need first is to find out that a
/// new version exists, so that is all this does: one request, a version
/// comparison, and a link.
public struct UpdateChecker: Sendable {
    /// How often the app looks on its own, after the look at launch. GitHub
    /// allows sixty unauthenticated calls an hour, so this is nowhere near
    /// anything.
    public static let automaticInterval: TimeInterval = 3 * 3600

    private let session: URLSession
    private let endpoint: URL

    public init(
        session: URLSession = .shared,
        endpoint: URL = HeadroomConstants.latestReleaseURL
    ) {
        self.session = session
        self.endpoint = endpoint
    }

    private struct Release: Decodable {
        let tagName: String?
        let htmlUrl: String?
        let draft: Bool?
        let prerelease: Bool?
    }

    /// Returns the newer release, or `nil` when there is none. Never throws:
    /// a failed update check is not something to interrupt anyone about, and
    /// GitHub answers unauthenticated callers only sixty times an hour.
    public func check(currentVersion: String) async -> AvailableUpdate? {
        if case .available(let update) = await checkResult(currentVersion: currentVersion) {
            return update
        }
        return nil
    }

    /// The same look, but telling "nothing newer" apart from "no answer" —
    /// what someone who pressed a button to ask deserves to hear.
    public func checkResult(currentVersion: String) async -> UpdateCheckResult {
        var request = URLRequest(url: endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Headroom-AI/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return .failed }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Every field is optional, so any JSON object decodes — a proxy's
        // error page sent with a 200 included. A release without a readable
        // tag and link is no answer, not "nothing newer".
        guard let release = try? decoder.decode(Release.self, from: data),
              let tag = release.tagName,
              !Self.components(Self.number(from: tag)).isEmpty,
              let link = release.htmlUrl.flatMap(URL.init(string:))
        else { return .failed }
        // A draft or a prerelease is an answer — just not one to act on.
        guard release.draft != true,
              release.prerelease != true,
              Self.isNewer(tag, than: currentVersion)
        else { return .upToDate }

        return .available(AvailableUpdate(version: Self.number(from: tag), url: link))
    }

    /// Strips a leading "v" and anything that is not part of the number.
    static func number(from tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Compares dotted version numbers component by component, as numbers.
    /// Comparing them as text would put 1.10 before 1.9, and missing components
    /// count as zero so that 1.1 and 1.1.0 are the same version rather than an
    /// endless upgrade prompt.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(number(from: candidate))
        let right = components(number(from: current))
        guard !left.isEmpty else { return false }

        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        let numbers = parts.map { part -> Int? in
            Int(part.prefix(while: \.isNumber))
        }
        // A version we cannot read is not a version we should act on.
        guard !numbers.contains(where: { $0 == nil }) else { return [] }
        return numbers.compactMap { $0 }
    }
}
