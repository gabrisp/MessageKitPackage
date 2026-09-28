import Foundation

public enum HubError: Error, LocalizedError, Sendable {
    case http(Int, String)
    case function(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .http(let code, let msg): "HTTP \(code): \(msg)"
        case .function(let code, let msg): "La función respondió \(code): \(msg)"
        case .decoding(let msg): "Respuesta no válida: \(msg)"
        }
    }
}

/// Habla con las funciones del hub por REST (`POST /functions/{id}/executions`).
/// Sin sesión: las funciones `messages`, `events` y `devices` son `execute: any`.
actor HubClient {
    let endpoint: URL
    let projectId: String
    private let session: URLSession
    /// Solo para tests: respuestas simuladas (un `URLProtocol`) en vez de la red.
    nonisolated(unsafe) static var testProtocolClasses: [AnyClass]?

    init(endpoint: URL, projectId: String) {
        self.endpoint = endpoint
        self.projectId = projectId
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        cfg.waitsForConnectivity = false
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        if let stubs = Self.testProtocolClasses { cfg.protocolClasses = stubs }
        session = URLSession(configuration: cfg)
    }

    /// Ejecuta una función y devuelve su respuesta decodificada.
    func call<Body: Encodable & Sendable, Response: Decodable & Sendable>(_ function: String, _ body: Body, as: Response.Type) async throws -> Response {
        let data = try await execute(function, body, async: false)
        do {
            return try JSONDecoder.messages.decode(Response.self, from: data)
        } catch {
            throw HubError.decoding(String(describing: error))
        }
    }

    /// Ejecuta una función en segundo plano (no espera a su respuesta).
    func fire<Body: Encodable & Sendable>(_ function: String, _ body: Body) async throws {
        _ = try await execute(function, body, async: true)
    }

    private struct Execution: Decodable {
        var responseStatusCode: Int?
        var responseBody: String?
        var status: String?
        var errors: String?
    }

    private func execute<Body: Encodable>(_ function: String, _ body: Body, async isAsync: Bool) async throws -> Data {
        let bodyText = String(decoding: try JSONEncoder.messages.encode(body), as: UTF8.self)
        let payload: [String: JSONValue] = [
            "body": .string(bodyText),
            "async": .bool(isAsync),
            "path": "/",
            "method": "POST",
            "headers": ["content-type": "application/json"],
        ]
        var req = URLRequest(url: endpoint.appending(path: "functions/\(function)/executions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(projectId, forHTTPHeaderField: "X-Appwrite-Project")
        req.setValue("1.8.0", forHTTPHeaderField: "X-Appwrite-Response-Format")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw HubError.http(code, String(decoding: data.prefix(300), as: UTF8.self))
        }
        if isAsync { return Data() }
        let exec = try JSONDecoder().decode(Execution.self, from: data)
        let status = exec.responseStatusCode ?? 0
        let text = exec.responseBody ?? ""
        guard (200..<300).contains(status) else {
            throw HubError.function(status, String((text.isEmpty ? (exec.errors ?? "") : text).prefix(300)))
        }
        return Data(text.utf8)
    }
}
