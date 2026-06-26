import Foundation

struct ProviderSetupService {
    private let baseURL = URL(string: "http://127.0.0.1:43821")!
    private let backend = BackendProcessController.shared

    func loadSetup() async throws -> ProviderSetupResponse {
        try await request(path: "/api/v1/provider-setup", method: "GET", body: Optional<StringRequest>.none)
    }

    func loadState() async throws -> ProviderSetupState {
        let response = try await loadSetup()
        return response.state
    }

    func selectProvider(_ provider: String) async throws -> ProviderSelectionResult {
        try await request(
            path: "/api/v1/provider-setup/select",
            method: "POST",
            body: SelectProviderRequest(provider: provider)
        )
    }

    func detect(provider: String, path: String?) async throws -> InstallationResult {
        try await request(path: "/api/v1/provider-setup/\(provider)/detect", method: "POST", body: StringRequest(path: path))
    }

    func test(provider: String, path: String?) async throws -> ConnectionTestResult {
        try await request(path: "/api/v1/provider-setup/\(provider)/test", method: "POST", body: StringRequest(path: path))
    }

    func completeSetup() async throws -> CompleteSetupResult {
        try await request(path: "/api/v1/provider-setup/complete", method: "POST", body: Optional<StringRequest>.none)
    }

    func saveModelSettings(provider: String, model: String, reasoningEffort: String) async throws -> SaveModelSettingsResult {
        try await request(
            path: "/api/v1/provider-setup/\(provider)/model",
            method: "POST",
            body: ModelSettingsRequest(model: model, reasoningEffort: reasoningEffort)
        )
    }

    func saveOutputLanguage(_ outputLanguage: String) async throws -> SaveModelSettingsResult {
        try await request(
            path: "/api/v1/provider-setup/output-language",
            method: "POST",
            body: OutputLanguageRequest(outputLanguage: outputLanguage)
        )
    }

    private func request<Response: Decodable, Body: Encodable>(
        path: String,
        method: String,
        body: Body?
    ) async throws -> Response {
        try await backend.ensureRunning()

        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ProviderSetupAPIError(message: "Invalid local API path: \(path)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 95
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw ProviderSetupAPIError(message: "TubeFold returned an invalid response.")
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? "HTTP \(httpResponse.statusCode)"
                throw ProviderSetupAPIError(message: text)
            }
            return try JSONDecoder().decode(Response.self, from: data)
        } catch let error as ProviderSetupAPIError {
            throw error
        } catch {
            throw ProviderSetupAPIError(message: "TubeFold could not talk to its local helper. Reopen the app and try again.")
        }
    }
}

struct ProviderSetupAPIError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
