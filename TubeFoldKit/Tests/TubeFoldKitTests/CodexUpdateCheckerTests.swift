import Foundation
import Testing

@testable import TubeFoldKit

@Suite struct CodexUpdateCheckerTests {
    @Test func normalizesCLIAndReleaseVersions() {
        #expect(CodexUpdateChecker.normalizedVersion("codex-cli 0.143.0") == "0.143.0")
        #expect(CodexUpdateChecker.normalizedVersion("rust-v0.144.1") == "0.144.1")
        #expect(CodexUpdateChecker.normalizedVersion("unknown") == nil)
    }

    @Test func comparesSemanticVersionsNumerically() {
        #expect(CodexUpdateChecker.isNewer("0.144.1", than: "0.143.0"))
        #expect(!CodexUpdateChecker.isNewer("0.143.0", than: "0.143.0"))
        #expect(!CodexUpdateChecker.isNewer("0.142.9", than: "0.143.0"))
        #expect(CodexUpdateChecker.isNewer("1.0", than: "0.999.999"))
    }

    @Test func decodesLatestStableRelease() async throws {
        let transport: CodexUpdateChecker.Transport = { request in
            let data = Data(#"{"tag_name":"rust-v0.144.1"}"#.utf8)
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            return (data, response)
        }

        let result = await CodexUpdateChecker.check(
            installedVersion: "codex-cli 0.143.0",
            transport: transport
        )

        #expect(result == CodexUpdateCheck(
            installedVersion: "0.143.0",
            latestVersion: "0.144.1"
        ))
        #expect(result?.updateAvailable == true)
    }
}
