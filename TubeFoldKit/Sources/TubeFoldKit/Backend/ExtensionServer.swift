import Foundation
import Network
import os

/// The tiny localhost HTTP shim for the Chrome extension — the only HTTP
/// surface TubeFold has. `NWListener` + a minimal HTTP/1.1
/// request parser / response writer — zero dependencies.
///
/// Contract (verified against TubeFold/extension `background.js`):
/// - `GET /health` — liveness (`apiVersion` + `backendFeatures` map)
/// - `POST /api/v1/summaries` — summarize this tab
/// - `POST /api/v1/watch-activity` — report watched video
/// - `GET /api/v1/videos/by-youtube-id/{id}` — popup state lookup
/// - `POST /api/v1/videos/{id}/publish-telegraph` — popup action
/// plus the wider library/settings surface (list/delete/regenerate, watch
/// suggestion + dismiss, extension-status, usage) for compatibility.
/// CORS for `chrome-extension://*`, bound to 127.0.0.1 only, optional bearer
/// token. Error JSON shape: `{"error": {code, message}}`.
public actor ExtensionServer {
    public static let defaultPort: UInt16 = 43821

    private let backend: TubeFoldBackend
    private let port: UInt16
    private let apiToken: String?
    private let allowedOrigins: [String]
    private var listener: NWListener?
    private let logger = Logger(subsystem: "app.tubefold", category: "extension-server")

    public init(
        backend: TubeFoldBackend,
        port: UInt16 = ExtensionServer.defaultPort,
        apiToken: String? = ProcessInfo.processInfo.environment["TUBEFOLD_API_TOKEN"],
        allowedOrigins: [String] = ["chrome-extension://*", "null"]
    ) {
        self.backend = backend
        self.port = port
        self.apiToken = apiToken
        self.allowedOrigins = allowedOrigins
    }

    public func start() throws {
        guard listener == nil else { return }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Bind to loopback only — never reachable from the network.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handle(connection: connection) }
        }
        listener.start(queue: DispatchQueue(label: "app.tubefold.extension-server"))
        self.listener = listener
        logger.info("Extension server listening on 127.0.0.1:\(self.port)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) async {
        connection.start(queue: DispatchQueue(label: "app.tubefold.extension-conn"))
        defer { connection.cancel() }
        do {
            let request = try await HTTPRequest.read(from: connection, maxBodyBytes: 64 * 1024)
            let response = await route(request)
            try? await response.write(to: connection, origin: request.headers["origin"], allowedOrigins: allowedOrigins)
        } catch {
            logger.debug("Connection error: \(error)")
        }
    }

    // MARK: - Routing

    func route(_ request: HTTPRequest) async -> HTTPResponse {
        if let origin = request.headers["origin"], origin.hasPrefix("chrome-extension://") {
            await backend.noteExtensionSeen()
        }

        if request.method == "OPTIONS" {
            return HTTPResponse(status: 204)
        }

        if let token = apiToken, !token.isEmpty, request.path != "/health" {
            guard request.headers["authorization"] == "Bearer \(token)" else {
                return .error(status: 401, code: "unauthorized", message: "Invalid local API token.")
            }
        }

        do {
            return try await dispatch(request)
        } catch let error as BackendAPIError {
            return .error(status: error.httpStatus, code: error.code, message: error.message)
        } catch {
            return .error(status: 500, code: "internal_error", message: "\(error)")
        }
    }

    private func dispatch(_ request: HTTPRequest) async throws -> HTTPResponse {
        let path = request.path
        switch (request.method, path) {
        case ("GET", "/health"):
            return try .json(backend.healthPayload())

        case ("GET", "/api/v1/videos"):
            return try .json(["videos": await backend.listVideoPayloads()])

        case ("GET", "/api/v1/usage"):
            return try .json(await backend.usagePayload())

        case ("GET", "/api/v1/extension-status"):
            return try .json(await backend.extensionStatusPayload())

        case ("GET", "/api/v1/watch-activity"):
            let suggestion = try await backend.watchSuggestionPayload()
            return try .json(["suggestion": suggestion ?? NSNull()])

        case ("GET", "/api/v1/provider-setup"):
            return try .json(backend.providerSetupPayload())

        case ("POST", "/api/v1/summaries"):
            let body = try request.jsonBody()
            let outcome = try await backend.createSummary(
                rawURL: string(body, "url") ?? string(body, "canonicalURL") ?? "",
                rawVideoID: string(body, "videoId"),
                title: string(body, "title"),
                channelName: string(body, "channelName"),
                durationSeconds: double(body, "durationSeconds"),
                currentTimeSeconds: double(body, "currentTimeSeconds"),
                thumbnailURL: string(body, "thumbnailURL"),
                source: string(body, "source") ?? "chrome-extension"
            )
            return try .json(
                ["jobId": outcome.jobID as Any, "videoId": outcome.videoID, "status": outcome.status],
                status: outcome.status == "queued" ? 202 : 200
            )

        case ("POST", "/api/v1/watch-activity"):
            let body = try request.jsonBody()
            try await backend.recordWatchActivity(
                rawURL: string(body, "url") ?? string(body, "canonicalURL") ?? "",
                rawVideoID: string(body, "videoId"),
                title: string(body, "title"),
                channelName: string(body, "channelName"),
                thumbnailURL: string(body, "thumbnailURL"),
                durationSeconds: double(body, "durationSeconds")
            )
            return try .json(["status": "recorded"])

        case ("POST", "/api/v1/watch-activity/dismiss"):
            let body = try request.jsonBody()
            try await backend.dismissWatchActivity(
                rawVideoID: string(body, "youtubeVideoID") ?? string(body, "videoId") ?? ""
            )
            return try .json(["status": "dismissed"])

        case ("POST", "/api/v1/reset"):
            let removed = try await backend.resetAllData()
            return try .json(["status": "reset", "removed": removed])

        case ("POST", "/api/v1/provider-setup/select"):
            let body = try request.jsonBody()
            return try .json(backend.selectProvider(string(body, "provider") ?? ""))

        case ("POST", "/api/v1/provider-setup/complete"):
            return try .json(backend.completeProviderSetup())

        case ("POST", "/api/v1/provider-setup/output-language"):
            let body = try request.jsonBody()
            return try .json(backend.saveOutputLanguage(string(body, "outputLanguage")))

        default:
            break
        }

        if request.method == "POST", path.hasPrefix("/api/v1/provider-setup/") {
            let parts = path.dropFirst("/api/v1/provider-setup/".count).split(separator: "/")
            if parts.count == 2, ["codex", "claude"].contains(String(parts[0])) {
                let providerID = String(parts[0])
                switch parts[1] {
                case "detect":
                    let body = (try? request.jsonBody()) ?? [:]
                    return try .json(await backend.detectProviderInstallation(
                        providerID: providerID, path: string(body, "path")
                    ))
                case "test":
                    let body = (try? request.jsonBody()) ?? [:]
                    return try .json(await backend.testProviderConnection(
                        providerID: providerID, path: string(body, "path")
                    ))
                case "model":
                    let body = try request.jsonBody()
                    return try .json(backend.saveModelSettings(
                        providerID: providerID,
                        model: string(body, "model"),
                        reasoningEffort: string(body, "reasoningEffort")
                    ))
                default:
                    break
                }
            }
        }

        if request.method == "GET",
           let videoID = request.pathParameter(prefix: "/api/v1/videos/by-youtube-id/") {
            return try .json(await backend.videoLookupPayload(youtubeVideoID: videoID))
        }
        if request.method == "GET", let jobID = request.pathParameter(prefix: "/api/v1/jobs/") {
            return try .json(await backend.jobPayload(jobID: jobID))
        }
        if request.method == "POST",
           let videoID = request.pathParameter(prefix: "/api/v1/videos/", suffix: "/regenerate") {
            let outcome = try await backend.regenerate(videoID: videoID)
            return try .json(
                ["jobId": outcome.jobID as Any, "videoId": outcome.videoID, "status": "queued"],
                status: 202
            )
        }
        if request.method == "POST",
           let videoID = request.pathParameter(prefix: "/api/v1/videos/", suffix: "/publish-telegraph") {
            let result = try await backend.publishTelegraph(videoID: videoID)
            return try .json(["url": result.url, "status": result.status])
        }
        if request.method == "DELETE", let videoID = request.pathParameter(prefix: "/api/v1/videos/") {
            try await backend.deleteVideo(videoID: videoID)
            return try .json(["status": "deleted", "videoId": videoID])
        }

        return .error(status: 404, code: "not_found", message: "Endpoint was not found.")
    }

    private func string(_ body: [String: Any], _ key: String) -> String? {
        if let value = body[key] as? String { return value }
        if body[key] is NSNull || body[key] == nil { return nil }
        return "\(body[key]!)"
    }

    private func double(_ body: [String: Any], _ key: String) -> Double? {
        if let value = body[key] as? Double { return value }
        if let value = body[key] as? Int { return Double(value) }
        if let value = body[key] as? String { return Double(value) }
        return nil
    }
}

// MARK: - Minimal HTTP/1.1

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    /// Header names lowercased.
    public let headers: [String: String]
    public let body: Data

    /// `{prefix}{value}` or `{prefix}{value}{suffix}` single-segment matcher.
    func pathParameter(prefix: String, suffix: String = "") -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let value = path.dropFirst(prefix.count).dropLast(suffix.count)
        guard !value.isEmpty, !value.contains("/") else { return nil }
        return value.removingPercentEncoding ?? String(value)
    }

    func jsonBody() throws -> [String: Any] {
        guard headers["content-type"]?.contains("application/json") == true else {
            throw BackendAPIError.badRequest(
                code: "invalid_content_type",
                message: "Content-Type must be application/json."
            )
        }
        guard !body.isEmpty else {
            throw BackendAPIError.badRequest(
                code: "invalid_request_body",
                message: "Request body is empty or too large."
            )
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: body),
              let object = parsed as? [String: Any] else {
            throw BackendAPIError.badRequest(code: "invalid_json", message: "Request body is not valid JSON.")
        }
        return object
    }

    /// Read one request from the connection: headers up to CRLFCRLF, then
    /// `Content-Length` bytes of body.
    static func read(from connection: NWConnection, maxBodyBytes: Int) async throws -> HTTPRequest {
        var buffer = Data()
        let headerEnd = Data("\r\n\r\n".utf8)

        while buffer.range(of: headerEnd) == nil {
            guard buffer.count < 64 * 1024 else {
                throw URLError(.dataLengthExceedsMaximum)
            }
            let chunk = try await receive(connection)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
        }
        guard let headerRange = buffer.range(of: headerEnd) else {
            throw URLError(.badServerResponse)
        }

        let head = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { throw URLError(.badServerResponse) }
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 2 else { throw URLError(.badServerResponse) }
        let method = requestLine[0].uppercased()
        let target = requestLine[1]
        let path = String(target.split(separator: "?", maxSplits: 1)[0])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        var body = Data(buffer[headerRange.upperBound...])
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        guard contentLength <= maxBodyBytes else {
            throw URLError(.dataLengthExceedsMaximum)
        }
        while body.count < contentLength {
            let chunk = try await receive(connection)
            guard !chunk.isEmpty else { break }
            body.append(chunk)
        }

        return HTTPRequest(
            method: method,
            path: path.removingPercentEncoding ?? path,
            headers: headers,
            body: body.prefix(contentLength)
        )
    }

    private static func receive(_ connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if isComplete {
                    continuation.resume(returning: Data())
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }
}

public struct HTTPResponse: Sendable {
    public let status: Int
    public let body: Data
    public let contentType: String

    public init(status: Int, body: Data = Data(), contentType: String = "application/json; charset=utf-8") {
        self.status = status
        self.body = body
        self.contentType = contentType
    }

    static func json(_ payload: [String: Any], status: Int = 200) throws -> HTTPResponse {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.withoutEscapingSlashes])
        return HTTPResponse(status: status, body: data)
    }

    static func error(status: Int, code: String, message: String) -> HTTPResponse {
        let payload: [String: Any] = ["error": ["code": code, "message": message]]
        return (try? json(payload, status: status)) ?? HTTPResponse(status: status)
    }

    private static let statusTexts: [Int: String] = [
        200: "OK", 202: "Accepted", 204: "No Content",
        400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
        409: "Conflict", 415: "Unsupported Media Type",
        500: "Internal Server Error", 502: "Bad Gateway",
    ]

    func write(to connection: NWConnection, origin: String?, allowedOrigins: [String]) async throws {
        var head = "HTTP/1.1 \(status) \(Self.statusTexts[status] ?? "OK")\r\n"
        head += "Content-Type: \(contentType)\r\n"
        if status != 204 {
            head += "Content-Length: \(body.count)\r\n"
        }
        if let origin, Self.originAllowed(origin, allowedOrigins: allowedOrigins) {
            head += "Access-Control-Allow-Origin: \(origin)\r\n"
            head += "Vary: Origin\r\n"
        }
        head += "Access-Control-Allow-Methods: GET,POST,DELETE,OPTIONS\r\n"
        head += "Access-Control-Allow-Headers: Authorization,Content-Type\r\n"
        head += "Connection: close\r\n\r\n"

        var payload = Data(head.utf8)
        if status != 204 {
            payload.append(body)
        }
        try await send(payload, over: connection)
    }

    static func originAllowed(_ origin: String, allowedOrigins: [String]) -> Bool {
        allowedOrigins.contains("*")
            || allowedOrigins.contains(origin)
            || (allowedOrigins.contains("chrome-extension://*") && origin.hasPrefix("chrome-extension://"))
    }

    private func send(_ data: Data, over connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }
}
