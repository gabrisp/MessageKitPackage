import Foundation

/// Lo que cada app pasa a `Messages.configure(_:)`.
public struct MessagesConfiguration: Sendable {
    public var appId: String
    /// Endpoint de Appwrite del hub, p. ej. `https://appwrite.repzet.app/v1`.
    public var endpoint: URL
    public var projectId: String
    /// Clave pública de la app en el hub (no es secreta).
    public var publicKey: String
    /// El id estable del usuario (el mismo de RevenueCat y PostHog).
    public var userId: @Sendable () async -> String
    /// Atributos para la audiencia (`isPro`, `garmentCount`…). Se suman a los de serie:
    /// `language`, `locale`, `country`, `appVersion`, `build`, `platform`, `osVersion`,
    /// `installDate`, `daysSinceInstall`, `pushAuthorized`, `timezone`.
    public var attributes: @Sendable () async -> [String: any Sendable]
    public var theme: MessagesTheme
    /// Reenvía impresiones a la analítica de la app (PostHog): nombre y propiedades.
    public var analytics: (@Sendable (String, [String: any Sendable]) -> Void)?
    /// Idioma de los mensajes. `nil` = el primero preferido del sistema.
    public var language: String?
    /// Tiempo máximo esperando al hub al abrir antes de usar la caché.
    public var launchTimeout: Duration
    /// Registra en consola lo que decide el paquete.
    public var debugLogging: Bool

    public init(
        appId: String,
        endpoint: URL,
        projectId: String,
        publicKey: String,
        userId: @escaping @Sendable () async -> String,
        attributes: @escaping @Sendable () async -> [String: any Sendable] = { [:] },
        theme: MessagesTheme = .default,
        analytics: (@Sendable (String, [String: any Sendable]) -> Void)? = nil,
        language: String? = nil,
        launchTimeout: Duration = .seconds(4),
        debugLogging: Bool = false
    ) {
        self.appId = appId; self.endpoint = endpoint; self.projectId = projectId
        self.publicKey = publicKey; self.userId = userId; self.attributes = attributes
        self.theme = theme; self.analytics = analytics; self.language = language
        self.launchTimeout = launchTimeout; self.debugLogging = debugLogging
    }
}

/// Versión del paquete que se manda al hub.
public let messagesKitVersion = "0.1.0"
