import Foundation
import Testing
@testable import MessagesKit

/// Un hub de mentira: responde a `messages` con una campaña, tras un pequeño retraso.
final class StubHub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var requests = 0
    private static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.requests += 1 }
        let response = MessagesResponse(campaigns: [Campaign(name: "x", appIds: ["test"])], etag: UUID().uuidString)
        let body = String(decoding: (try? JSONEncoder.messages.encode(response)) ?? Data(), as: UTF8.self)
        let envelope = try! JSONSerialization.data(withJSONObject: ["responseStatusCode": 200, "responseBody": body])
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: envelope)
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}

/// Lo que la app «dice» que es el usuario (cambia a mitad del test).
nonisolated(unsafe) var testIsPro = false

@Suite("Runtime", .serialized)
@MainActor
struct RuntimeTests {
    @Test("Refrescos forzados a la vez no se quedan colgados y vuelven a pedir", .timeLimit(.minutes(1)))
    func concurrentForcedRefresh() async throws {
        HubClient.testProtocolClasses = [StubHub.self]
        defer { HubClient.testProtocolClasses = nil }
        StubHub.requests = 0
        let runtime = MessagesRuntime(presenter: MessagePresenter())
        runtime.configure(.init(
            appId: "test-\(UUID().uuidString)", endpoint: URL(string: "https://hub.invalid/v1")!,
            projectId: "p", publicKey: "k", userId: { "u" }
        ))
        defer { runtime.resetLocalState() }
        // Lo que hacía una app Pro al arrancar: el refresh del arranque en marcha y, encima, dos más.
        try await Task.sleep(for: .milliseconds(50))
        async let a: Void = runtime.refresh(force: true)
        async let b: Void = runtime.refresh(force: true)
        _ = await (a, b)
        await runtime.refresh(force: true)
        #expect(runtime.lastSync?.ok == true)
        #expect(StubHub.requests >= 2, "Con force se vuelve a pedir (\(StubHub.requests) peticiones)")
    }

    @Test("La audiencia se mira en el momento, sin pedir nada al hub: al hacerse Pro deja de tocar")
    func audienceMatchesNow() async throws {
        HubClient.testProtocolClasses = [StubHub.self]
        defer { HubClient.testProtocolClasses = nil }
        testIsPro = false
        let runtime = MessagesRuntime(presenter: MessagePresenter())
        runtime.configure(.init(
            appId: "test-\(UUID().uuidString)", endpoint: URL(string: "https://hub.invalid/v1")!,
            projectId: "p", publicKey: "k", userId: { "u" }, attributes: { ["isPro": testIsPro] }
        ))
        defer { runtime.resetLocalState() }
        var forFree = Campaign(name: "Hazte Pro", appIds: ["test"])
        forFree.audience = Audience(rules: .condition(.init(attr: "isPro", op: .neq, value: true)))
        #expect(await runtime.matchesNow(forFree))
        testIsPro = true
        #expect(await !runtime.matchesNow(forFree), "Pro: ya no le toca, sin refresh")
        // Sin reglas ni porcentaje: siempre (no hace falta mirar nada).
        #expect(await runtime.matchesNow(Campaign(name: "Para todos", appIds: ["test"])))
        // Solo desarrollo: los tests no son una build de desarrollo de una app.
        var devOnly = Campaign(name: "Dev", appIds: ["test"])
        devOnly.audience.developmentOnly = true
        _ = await runtime.matchesNow(devOnly)
    }
}
