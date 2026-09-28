import Foundation

/// Lo que se guarda en disco por app: la última respuesta del hub (para funcionar sin red),
/// la frecuencia local y las impresiones pendientes de enviar.
struct PersistedState: Codable, Sendable {
    var campaigns: [Campaign] = []
    var etag: String?
    var dailyCap: Int = 0
    var fetchedAt: Date?
    var ttlSeconds: Double = 300
    var history: [String: ImpressionHistory] = [:]
    var pendingEvents: [Impression] = []
    /// Campañas forzadas ("Enviar a un usuario", push) que aún no han salido.
    var forced: [Campaign] = []
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
