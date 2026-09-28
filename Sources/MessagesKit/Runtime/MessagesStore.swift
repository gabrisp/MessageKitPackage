import Foundation

/// Lo que se guarda en disco por app: la última respuesta del hub (para funcionar sin red),
/// la frecuencia local y las impresiones pendientes de enviar.
struct PersistedState: Codable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        campaigns = c.value(.campaigns, default: [])
        etag = c.optional(.etag)
        dailyCap = c.value(.dailyCap, default: 0)
        fetchedAt = c.optional(.fetchedAt)
        ttlSeconds = c.value(.ttlSeconds, default: 300)
        history = c.value(.history, default: [:])
        pendingEvents = c.value(.pendingEvents, default: [])
        forced = c.value(.forced, default: [])
        seenScreens = c.value(.seenScreens, default: [])
        seenEvents = c.value(.seenEvents, default: [])
    }

    var campaigns: [Campaign] = []
    var etag: String?
    var dailyCap: Int = 0
    var fetchedAt: Date?
    var ttlSeconds: Double = 300
    var history: [String: ImpressionHistory] = [:]
    var pendingEvents: [Impression] = []
    /// Campañas forzadas ("Enviar a un usuario", push) que aún no han salido.
    var forced: [Campaign] = []
    /// Pantallas y eventos que ha visto la app (para el informe del admin).
    var seenScreens: Set<String> = []
    var seenEvents: Set<String> = []
}

/// Lectura y escritura en disco fuera del hilo principal.
actor MessagesStore {
    private let url: URL

    init(appId: String) {
        let base = URL.applicationSupportDirectory.appending(path: "MessagesKit/\(appId)", directoryHint: .isDirectory)
        url = base.appending(path: "state.json")
    }

    func load() -> PersistedState {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder.messages.decode(PersistedState.self, from: data)
        else { return PersistedState() }
        return state
    }

    func save(_ state: PersistedState) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try JSONEncoder.messages.encode(state)
            try data.write(to: url, options: [.atomic])
        } catch {
            MessagesLog.error("No se pudo guardar el estado: \(error)")
        }
    }

    func erase() {
        try? FileManager.default.removeItem(at: url)
    }
}

enum MessagesLog {
    nonisolated(unsafe) static var enabled = false

    static func debug(_ message: @autoclosure () -> String) {
        if enabled { print("[MessagesKit] \(message())") }
    }

    static func error(_ message: @autoclosure () -> String) {
        print("[MessagesKit] ⚠️ \(message())")
    }
}
