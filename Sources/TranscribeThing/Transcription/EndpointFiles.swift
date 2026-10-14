import Foundation

/// The user's endpoint's Files API, Gemini's as the endpoint emulates it on its own host (`<root>/upload/v1beta/files`):
/// how a video too big to go inline reaches the model. A resumable upload: one request starts it and is told where the
/// bytes go, then the file goes in pieces of `uploadChunkBytes`, the last one finishing it, and the answer names the
/// file's `uri`, which a chat request points at (`askAboutVideo`). Files expire on the endpoint by themselves after 48
/// hours: nothing here deletes them. The key goes as `x-goog-api-key`, as Gemini's API takes it, and only ever to the
/// endpoint's own host: an upload address elsewhere gets the bytes without it.
extension OpenRouterClient {
    /// One upload request's share of the file: 8 MiB, as Google's own clients send.
    static let uploadChunkBytes = 8 * 1024 * 1024

    /// What the endpoint kept: the `uri` a request points at, and its size.
    struct UploadedFile: Equatable, Sendable {
        var uri: String
        var bytes: Int
    }

    /// The endpoint's root, where its Files API is: the API base without the API's own path
    /// ("https://host/api/v1" → "https://host", "https://host/v1" → "https://host").
    static func filesRoot(apiBase: URL) -> URL? {
        guard var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false) else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/api/v1", "/v1"] where path.lowercased().hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// Uploads `file` (a video, `mimeType`) to the endpoint's Files API as `displayName`, `chunkBytes` per request.
    /// Throws the endpoint's failures as a chat request does (`VertexProxyErrorMapper`), `CancellationError` when the
    /// task is cancelled. Nothing is retried: the step it serves can go without.
    func uploadVideo(_ file: URL, displayName: String, mimeType: String = "video/mp4", apiKey: String,
                     timeout: TimeInterval = 120, chunkBytes: Int = uploadChunkBytes) async throws -> UploadedFile {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AppError.vertexProxy(.keyUnreadable) }
        guard let root = Self.filesRoot(apiBase: baseURL) else {
            throw AppError.vertexProxy(.badRequest("Couldn’t build the request."))
        }
        let size = try (FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0

        // Start: where the bytes go.
        var start = URLRequest(url: root.appendingPathComponent("upload/v1beta/files"))
        start.httpMethod = "POST"
        start.timeoutInterval = timeout
        start.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        start.setValue("resumable", forHTTPHeaderField: "X-Goog-Upload-Protocol")
        start.setValue("start", forHTTPHeaderField: "X-Goog-Upload-Command")
        start.setValue(String(size), forHTTPHeaderField: "X-Goog-Upload-Header-Content-Length")
        start.setValue(mimeType, forHTTPHeaderField: "X-Goog-Upload-Header-Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.httpBody = try JSONSerialization.data(withJSONObject: ["file": ["display_name": displayName]])
        let (startBody, started) = try await upload(start)
        guard started.statusCode == 200 else { throw Self.uploadFailure(started, body: startBody) }
        guard let address = started.value(forHTTPHeaderField: "x-goog-upload-url"),
              let uploadURL = URL(string: address), uploadURL.scheme?.lowercased() == "https" else {
            throw AppError.vertexProxy(.unavailable("Your endpoint didn’t say where to upload the video."))
        }
        let sameHost = uploadURL.host?.lowercased() == root.host?.lowercased()

        // The bytes, a piece at a time; the last piece finishes the upload.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var offset = 0
        var answer = Data()
        repeat {
            try Task.checkCancellation()
            let piece = try handle.read(upToCount: max(1, chunkBytes)) ?? Data()
            let last = offset + piece.count >= size || piece.isEmpty
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            if sameHost { request.setValue(key, forHTTPHeaderField: "x-goog-api-key") }
            request.setValue(String(offset), forHTTPHeaderField: "X-Goog-Upload-Offset")
            request.setValue(last ? "upload, finalize" : "upload", forHTTPHeaderField: "X-Goog-Upload-Command")
            request.httpBody = piece
            let (body, http) = try await upload(request)
            guard http.statusCode == 200 else { throw Self.uploadFailure(http, body: body) }
            offset += piece.count
            if last {
                answer = body
                break
            }
        } while true

        let object = (try? JSONSerialization.jsonObject(with: answer)) as? [String: Any]
        let fileObject = (object?["file"] as? [String: Any]) ?? object
        guard let uri = fileObject?["uri"] as? String, !uri.isEmpty else {
            throw AppError.vertexProxy(.unavailable("Your endpoint took the video but didn’t say where it is."))
        }
        if (fileObject?["state"] as? String)?.uppercased() == "FAILED" {
            throw AppError.vertexProxy(.unavailable("Your endpoint couldn’t read the video."))
        }
        return UploadedFile(uri: uri, bytes: offset)
    }

    /// One upload request, its failures as the endpoint's.
    private func upload(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AppError.vertexProxy(.unavailable("Your endpoint sent a response \(Brand.name) couldn’t read."))
            }
            return (data, http)
        } catch let error as URLError {
            if error.code == .cancelled || Task.isCancelled { throw CancellationError() }
            switch error.code {
            case .timedOut: throw AppError.timeout(.geminiArgon)
            case .notConnectedToInternet, .dataNotAllowed, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
                 .secureConnectionFailed:
                throw AppError.vertexProxy(.unreachable)
            default: throw AppError.vertexProxy(.unavailable(error.localizedDescription))
            }
        }
    }

    private static func uploadFailure(_ http: HTTPURLResponse, body: Data) -> AppError {
        let error = VertexProxyErrorMapper.httpError(
            status: http.statusCode, data: body,
            retryAfter: OpenRouterErrorMapper.retryAfter(http.value(forHTTPHeaderField: "Retry-After")),
            engine: .geminiArgon)
        DiagnosticLog.shared.event(.net, "endpoint.upload.http", ["status": http.statusCode, "code": error])
        return error
    }
}
