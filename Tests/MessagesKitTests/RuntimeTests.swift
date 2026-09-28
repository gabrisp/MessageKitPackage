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
}
