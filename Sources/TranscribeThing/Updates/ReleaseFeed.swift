import Foundation

// MARK: - Releases

/// One published release, as the update checker keeps it.
struct Release: Codable, Equatable, Sendable, Identifiable {
    var version: AppVersion
    /// The Git tag as published ("v0.3.0").
    var tag: String
    /// GitHub's release title, when it says more than the tag.
    var title: String?
    /// Markdown, as written on GitHub (possibly auto-generated).
    var notes: String
    var publishedAt: Date?
    /// The release's page on GitHub.
    var pageURL: URL
    var assets: [ReleaseAsset]

    var id: String { tag }

    /// The zip "Update Now" installs: `transcribe-thing-<version>.zip`, else the release's only zip.
    var installableAsset: ReleaseAsset? {
        let names = Set(["\(ReleaseAsset.namePrefix)\(version).zip",
                         "\(ReleaseAsset.namePrefix)\(tag.hasPrefix("v") ? String(tag.dropFirst()) : tag).zip"])
        if let named = assets.first(where: { names.contains($0.name) }) { return named }
        let zips = assets.filter { $0.name.lowercased().hasSuffix(".zip") }
        return zips.count == 1 ? zips[0] : nil
    }
}

struct ReleaseAsset: Codable, Equatable, Sendable {
    static let namePrefix = "transcribe-thing-"

    var name: String
    var url: URL
    /// Bytes, as GitHub reports it.
    var size: Int64
}

extension AppVersion: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let version = AppVersion(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a version: \(text)")
        }
        self = version
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

// MARK: - GitHub's format

/// GET /repos/{owner}/{repo}/releases, reduced to what the app shows and installs.
enum GitHubReleases {
    private struct Wire: Decodable {
        var tag_name: String
        var name: String?
        var body: String?
        var draft: Bool?
        var prerelease: Bool?
        var published_at: String?
        var html_url: URL?
        var assets: [WireAsset]?
    }

    private struct WireAsset: Decodable {
        var name: String
        var browser_download_url: URL
        var size: Int64?
    }

    /// Drafts, prereleases and tags that aren't versions are skipped; newest version first.
    static func decode(_ data: Data) throws -> [Release] {
        let wire = try JSONDecoder().decode([Wire].self, from: data)
        let releases = wire.compactMap { item -> Release? in
            guard item.draft != true, item.prerelease != true,
                  let version = AppVersion(item.tag_name), !version.isPrerelease
            else { return nil }
            let title = item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let meaningfulTitle = title.flatMap { name -> String? in
                guard !name.isEmpty, AppVersion(name) != version,
                      name.caseInsensitiveCompare("transcribe-thing \(version)") != .orderedSame,
                      name.caseInsensitiveCompare("transcribe-thing \(item.tag_name)") != .orderedSame
                else { return nil }
                return name
            }
            return Release(
                version: version, tag: item.tag_name, title: meaningfulTitle,
                notes: item.body ?? "",
                publishedAt: item.published_at.flatMap(parseDate),
                pageURL: item.html_url ?? Brand.releasesPage.appendingPathComponent("tag/\(item.tag_name)"),
                assets: (item.assets ?? []).map {
                    ReleaseAsset(name: $0.name, url: $0.browser_download_url, size: $0.size ?? 0)
                })
        }
        return sorted(releases)
    }

    /// Newest version first; one entry per version (the first seen wins).
    static func sorted(_ releases: [Release]) -> [Release] {
        var seen: Set<AppVersion> = []
        return releases.sorted { $0.version > $1.version }.filter { seen.insert($0.version).inserted }
    }

    private static func parseDate(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}

// MARK: - Cache

/// What the last successful check saw, kept on disk so the changelog shows offline and between launches.
struct UpdateFeedCache: Codable, Equatable, Sendable {
    var feedURL: URL
    var releases: [Release]
    var etag: String?
    var lastChecked: Date

    static func load(from url: URL) -> UpdateFeedCache? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(UpdateFeedCache.self, from: data)
    }

    func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}

// MARK: - Checking

enum UpdateCheckError: Error, Equatable, Sendable {
    case offline
    /// GitHub's unauthenticated limit (60 requests an hour per address).
    case rateLimited
    case notFound
    case http(Int)
    case unreadable(String)
    case failed(String)

    /// The reason line under "Couldn’t check for updates".
    var message: String {
        switch self {
        case .offline: "You’re offline. Connect to the internet and try again."
        case .rateLimited: "GitHub is limiting requests from your network right now. Try again in a while."
        case .notFound: "GitHub couldn’t find \(Brand.name)’s releases."
        case .http(let status): "GitHub answered with an error (HTTP \(status)). Try again later."
        case .unreadable: "GitHub’s answer couldn’t be read."
        case .failed(let detail): detail
        }
    }
}

/// Reads the release feed: GitHub's REST API (with ETag revalidation), or a file:// feed for QA.
struct UpdateFeedClient: Sendable {
    enum Result: Equatable, Sendable {
        case releases([Release], etag: String?)
        /// 304: the cached releases are still current.
        case notModified
    }

    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let timeout: TimeInterval = 15

    var feedURL: URL
    var userAgent: String
    var transport: Transport

    init(feedURL: URL, userAgent: String, transport: @escaping Transport = UpdateFeedClient.liveTransport) {
        self.feedURL = feedURL
        self.userAgent = userAgent
        self.transport = transport
    }

    /// The real feed, or TT_UPDATE_FEED_URL (file:// or https) when set.
    static func live(version: AppVersion?) -> UpdateFeedClient {
        UpdateFeedClient(feedURL: feedOverride ?? Brand.releasesFeed,
                         userAgent: "transcribe-thing/\(version?.description ?? "dev")")
    }

    static var feedOverride: URL? {
        guard let raw = ProcessInfo.processInfo.environment["TT_UPDATE_FEED_URL"], !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    static let liveTransport: Transport = { request in
        if let url = request.url, url.isFileURL {
            let data = try Data(contentsOf: url)
            return (data, URLResponse(url: url, mimeType: "application/json", expectedContentLength: data.count,
                                      textEncodingName: nil))
        }
        return try await URLSession.updates.data(for: request)
    }

    func request(etag: String?) -> URLRequest {
        var request = URLRequest(url: feedURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.timeout)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        return request
    }

    /// `etag` from the cache revalidates it: an unchanged feed answers 304 (free of GitHub's rate limit).
    func fetch(etag: String?) async throws(UpdateCheckError) -> Result {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request(etag: etag))
        } catch let error as URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff,
                 .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut:
                throw .offline
            default:
                throw .failed(error.localizedDescription)
            }
        } catch {
            throw .failed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200: break
            case 304: return .notModified
            case 404: throw .notFound
            case 429: throw .rateLimited
            case 403 where http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0": throw .rateLimited
            default: throw .http(http.statusCode)
            }
        }
        do {
            let releases = try GitHubReleases.decode(data)
            let tag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            return .releases(releases, etag: tag)
        } catch {
            throw .unreadable(String(describing: error))
        }
    }
}

extension URLSession {
    /// Update checks and downloads: no shared cookies or cache.
    static let updates: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = UpdateFeedClient.timeout
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()
}
