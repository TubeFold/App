import Foundation

struct CodexUpdateCheck: Sendable, Equatable {
    let installedVersion: String
    let latestVersion: String

    var updateAvailable: Bool {
        CodexUpdateChecker.isNewer(latestVersion, than: installedVersion)
    }
}

enum CodexUpdateChecker {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private struct Release: Decodable {
        let tagName: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
        }
    }

    private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/openai/codex/releases/latest"
    )!

    static func check(
        installedVersion: String,
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) async -> CodexUpdateCheck? {
        guard let installed = normalizedVersion(installedVersion) else { return nil }

        var request = URLRequest(url: latestReleaseURL, timeoutInterval: 5)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("TubeFold", forHTTPHeaderField: "User-Agent")

        guard let (data, response) = try? await transport(request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let release = try? JSONDecoder().decode(Release.self, from: data),
              let latest = normalizedVersion(release.tagName)
        else {
            return nil
        }

        return CodexUpdateCheck(installedVersion: installed, latestVersion: latest)
    }

    static func normalizedVersion(_ value: String) -> String? {
        value
            .split(whereSeparator: { !$0.isNumber && $0 != "." })
            .map(String.init)
            .first(where: { versionComponents($0) != nil })
    }

    static func isNewer(_ candidate: String, than installed: String) -> Bool {
        guard let candidateParts = versionComponents(candidate),
              let installedParts = versionComponents(installed)
        else {
            return false
        }

        let count = max(candidateParts.count, installedParts.count)
        for index in 0 ..< count {
            let candidatePart = index < candidateParts.count ? candidateParts[index] : 0
            let installedPart = index < installedParts.count ? installedParts[index] : 0
            if candidatePart != installedPart {
                return candidatePart > installedPart
            }
        }
        return false
    }

    private static func versionComponents(_ value: String) -> [Int]? {
        let pieces = value.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count >= 2,
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return nil
        }
        return pieces.compactMap { Int($0) }
    }
}
