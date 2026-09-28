import Foundation

// Lo que viaja entre la app y las funciones del hub. Espejo en `functions/shared/src/protocol.ts`.

/// Lo que la app sabe hacer. El hub solo sirve campañas que caben aquí.
public struct Capabilities: Sendable, Hashable, Codable {
    public var routes: [String]
    public var actions: [String]
    public var blocksVersion: Int
    public var schemaVersion: Int

    public init(routes: [String], actions: [String], blocksVersion: Int = messagesBlocksVersion, schemaVersion: Int = messagesSchemaVersion) {
        self.routes = routes; self.actions = actions
        self.blocksVersion = blocksVersion; self.schemaVersion = schemaVersion
    }
}

/// Cuerpo de la función `messages`.
public struct MessagesRequest: Sendable, Codable {
    public var appId: String
    public var publicKey: String
    public var userId: String
    public var locale: String
    public var attributes: [String: JSONValue]
    public var capabilities: Capabilities
    /// La `etag` de la última respuesta; si nada ha cambiado vuelve `notModified: true`.
    public var etag: String?
    public var sdkVersion: String
}

/// Respuesta de la función `messages`.
public struct MessagesResponse: Sendable, Codable {
    /// Ya filtradas por audiencia, calendario, frecuencia y capacidades, con su idioma resuelto.
    public var campaigns: [Campaign]
    public var dailyCap: Int
    public var serverTime: Date
    public var etag: String
    public var ttlSeconds: Double
    public var notModified: Bool

    public init(campaigns: [Campaign] = [], dailyCap: Int = 0, serverTime: Date = .now, etag: String = "", ttlSeconds: Double = 300, notModified: Bool = false) {
        self.campaigns = campaigns; self.dailyCap = dailyCap; self.serverTime = serverTime
        self.etag = etag; self.ttlSeconds = ttlSeconds; self.notModified = notModified
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        campaigns = c.value(.campaigns, default: [])
        dailyCap = c.value(.dailyCap, default: 0)
        serverTime = c.value(.serverTime, default: .now)
        etag = c.value(.etag, default: "")
        ttlSeconds = c.value(.ttlSeconds, default: 300)
        notModified = c.value(.notModified, default: false)
    }
}

/// Qué pasó con una campaña.
public enum ImpressionEvent: String, Sendable, Hashable, Codable, CaseIterable {
    case shown, dismissed, clicked, action
    case pushSent = "push_sent"
    case pushOpened = "push_opened"
}

public struct Impression: Sendable, Hashable, Codable, Identifiable {
    /// Id del evento, generado en el dispositivo: así reintentar no duplica.
    public var id: String
    public var campaignId: String
    public var event: ImpressionEvent
    public var actionId: String?
    public var at: Date

    public init(id: String = UUID().uuidString.lowercased(), campaignId: String, event: ImpressionEvent, actionId: String? = nil, at: Date = .now) {
        self.id = id; self.campaignId = campaignId; self.event = event; self.actionId = actionId; self.at = at
    }
}

/// Cuerpo de la función `events`.
public struct EventsRequest: Sendable, Codable {
    public var appId: String
    public var publicKey: String
    public var userId: String
    public var events: [Impression]
}

/// Cuerpo de la función `devices`: registra el token de avisos y los topics.
public struct DeviceRequest: Sendable, Codable {
    public var appId: String
    public var publicKey: String
    public var userId: String
    /// Token APNs en hex.
    public var token: String
    /// `true` en builds de desarrollo (APNs sandbox). TestFlight y App Store: `false`.
    public var sandbox: Bool
    public var attributes: [String: JSONValue]
}
