import Foundation

/// Parámetros de una ruta: siempre texto, para que la app decida cómo interpretarlos.
public typealias RouteParams = [String: String]

/// Lo que hace un botón (o tocar un banner, o abrir un push).
///
/// En JSON va aplanado: `{ "type": "route", "name": "paywall", "params": {}, "thenDismiss": true }`.
public struct MessageAction: Sendable, Hashable, Codable {
    public var kind: Kind
    /// Si el mensaje se cierra tras la acción. `nil` usa el valor por defecto del tipo.
    public var thenDismiss: Bool?
    /// Nombre con el que se registra la pulsación en impresiones y analítica.
    public var trackAs: String?

    public enum Kind: Sendable, Hashable {
        case dismiss
        case route(name: String, params: RouteParams)
        case deepLink(url: String)
        case openURL(url: String, inApp: Bool)
        case requestReview
        case requestPushPermission
        case share(text: String?, url: String?)
        case copy(text: String, toast: String?)
        case openCampaign(campaignId: String)
        case track(event: String, properties: [String: JSONValue])
        case custom(name: String, payload: JSONValue)
        /// Compra dentro de la app con la hoja de Apple. Con RevenueCat: `offering` + `packageId`
        /// (lo resuelve el manejador de `Messages.register(purchase:)`); sin él, StoreKit con `productId`.
        case purchase(productId: String?, offering: String?, packageId: String?)
        /// Una acción que esta versión no conoce. Se conserva para no perderla al reescribir.
        case unknown(type: String, raw: JSONValue)
    }

    public init(_ kind: Kind, thenDismiss: Bool? = nil, trackAs: String? = nil) {
        self.kind = kind
        self.thenDismiss = thenDismiss
        self.trackAs = trackAs
    }

    public static let dismiss = MessageAction(.dismiss)
    public static func route(_ name: String, _ params: RouteParams = [:]) -> MessageAction {
        MessageAction(.route(name: name, params: params))
    }

    /// El `type` del JSON.
    public var type: String {
        switch kind {
        case .dismiss: "dismiss"
        case .route: "route"
        case .deepLink: "deepLink"
        case .openURL: "openURL"
        case .requestReview: "requestReview"
        case .requestPushPermission: "requestPushPermission"
        case .share: "share"
        case .copy: "copy"
        case .openCampaign: "openCampaign"
        case .track: "track"
        case .custom: "custom"
        case .purchase: "purchase"
        case .unknown(let type, _): type
        }
    }

    public static let allTypes = [
        "dismiss", "route", "deepLink", "openURL", "requestReview", "requestPushPermission",
        "share", "copy", "openCampaign", "track", "custom", "purchase",
    ]

    /// Si tras la acción se cierra el mensaje (explícito o por defecto del tipo).
    public var dismisses: Bool {
        if case .dismiss = kind { return true }
        if let thenDismiss { return thenDismiss }
        switch kind {
        case .copy, .track, .share, .unknown: return false
        default: return true
        }
    }

    /// Identificador estable para impresiones: `trackAs` o el tipo con su destino.
    public var trackingId: String {
        if let trackAs, !trackAs.isEmpty { return trackAs }
        switch kind {
        case .route(let name, _): return "route:\(name)"
        case .custom(let name, _): return "custom:\(name)"
        case .purchase(let product, let offering, let package): return "purchase:\(package ?? product ?? offering ?? "")"
        case .openCampaign(let id): return "openCampaign:\(id)"
        case .track(let event, _): return "track:\(event)"
        default: return type
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case type, name, params, url, inApp, text, toast, campaignId, event, properties, payload, thenDismiss, trackAs
        case productId, offering, package
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let type: String = c.value(.type, default: "dismiss")
        thenDismiss = c.optional(.thenDismiss)
        trackAs = c.optional(.trackAs)
        switch type {
        case "dismiss": kind = .dismiss
        case "route":
            let raw: [String: JSONValue] = c.value(.params, default: [:])
            kind = .route(name: c.value(.name, default: ""), params: raw.compactMapValues(\.stringValue))
        case "deepLink": kind = .deepLink(url: c.value(.url, default: ""))
        case "openURL": kind = .openURL(url: c.value(.url, default: ""), inApp: c.value(.inApp, default: true))
        case "requestReview": kind = .requestReview
        case "requestPushPermission": kind = .requestPushPermission
        case "share": kind = .share(text: c.optional(.text), url: c.optional(.url))
        case "copy": kind = .copy(text: c.value(.text, default: ""), toast: c.optional(.toast))
        case "openCampaign": kind = .openCampaign(campaignId: c.value(.campaignId, default: ""))
        case "track": kind = .track(event: c.value(.event, default: ""), properties: c.value(.properties, default: [:]))
        case "custom": kind = .custom(name: c.value(.name, default: ""), payload: c.value(.payload, default: .null))
        case "purchase": kind = .purchase(productId: c.optional(.productId), offering: c.optional(.offering), packageId: c.optional(.package))
        default: kind = .unknown(type: type, raw: (try? JSONValue(from: decoder)) ?? .null)
        }
    }

    public func encode(to encoder: Encoder) throws {
        if case .unknown(_, let raw) = kind {
            try raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(thenDismiss, forKey: .thenDismiss)
        try c.encodeIfPresent(trackAs, forKey: .trackAs)
        switch kind {
        case .dismiss, .requestReview, .requestPushPermission, .unknown: break
        case .route(let name, let params):
            try c.encode(name, forKey: .name)
            if !params.isEmpty { try c.encode(params, forKey: .params) }
        case .deepLink(let url): try c.encode(url, forKey: .url)
        case .openURL(let url, let inApp):
            try c.encode(url, forKey: .url)
            try c.encode(inApp, forKey: .inApp)
        case .share(let text, let url):
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(url, forKey: .url)
        case .copy(let text, let toast):
            try c.encode(text, forKey: .text)
            try c.encodeIfPresent(toast, forKey: .toast)
        case .openCampaign(let id): try c.encode(id, forKey: .campaignId)
        case .track(let event, let properties):
            try c.encode(event, forKey: .event)
            if !properties.isEmpty { try c.encode(properties, forKey: .properties) }
        case .custom(let name, let payload):
            try c.encode(name, forKey: .name)
            if payload != .null { try c.encode(payload, forKey: .payload) }
        case .purchase(let productId, let offering, let packageId):
            try c.encodeIfPresent(productId, forKey: .productId)
            try c.encodeIfPresent(offering, forKey: .offering)
            try c.encodeIfPresent(packageId, forKey: .package)
        }
    }
}
