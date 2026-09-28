import SwiftUI

/// La API de MessagesKit.
///
/// ```swift
/// Messages.configure(.init(appId: "myapp", endpoint: …, projectId: "your-project-id", publicKey: "…",
///                          userId: { await identity.id() }, theme: .myApp))
/// Messages.register(route: "paywall") { params in router.showPaywall() }
/// RootView().messagesLayer()
/// HomeScreen().messagePlacement("home")
/// Messages.event("task_completed")
/// ```
@MainActor
public enum Messages {
    /// El presentador compartido que usa `messagesLayer()`.
    public static let presenter = MessagePresenter()
    static let runtime = MessagesRuntime(presenter: presenter)

    // MARK: App anfitriona

    /// Configura el paquete y pide los mensajes al hub. Una vez, al arrancar.
    public static func configure(_ configuration: MessagesConfiguration) {
        runtime.configure(configuration)
    }

    /// Una pantalla u hoja propia que se puede abrir por nombre (acción `route`).
    public static func register(route name: String, _ handler: @escaping @MainActor (RouteParams) -> Void) {
        runtime.routes[name] = handler
    }

    /// Una acción propia (acción `custom`).
    public static func register(action name: String, _ handler: @escaping @MainActor (JSONValue) -> Void) {
        runtime.customActions[name] = handler
    }

    /// Cómo compra la app (acción `purchase`). Con RevenueCat:
    ///
    /// ```swift
    /// Messages.register(purchase: { req in
    ///     let offerings = try await Purchases.shared.offerings()
    ///     guard let offering = req.offering.flatMap({ offerings.offering(identifier: $0) }) ?? offerings.current,
    ///           let package = req.packageId.flatMap({ offering.package(identifier: $0) }) ?? offering.availablePackages.first
    ///     else { return .failed }
    ///     return try await Purchases.shared.purchase(package: package).userCancelled ? .cancelled : .purchased
    /// })
    /// ```
    ///
    /// Sin manejador, la acción compra `productId` directamente con StoreKit (la hoja de Apple).
    public static func register(purchase handler: @escaping @MainActor (PurchaseRequest) async throws -> PurchaseOutcome) {
        runtime.purchaseHandler = handler
    }

    /// Disparador de evento. Se puede llamar desde el wrapper de analítica para reenviarlos todos.
    public static func event(_ name: String) {
        runtime.noteEvent(name)
        runtime.fire(.event(name))
    }

    /// Silencio durante flujos críticos (onboarding, compra, grabando…). Lo que toque salir espera.
    public static func suppress(_ suppressed: Bool) {
        presenter.isSuppressed = suppressed
    }

    /// Vuelve a pedir los mensajes (p. ej. tras hacerse Pro o terminar el onboarding).
    /// Devuelve cómo ha ido (también en `Messages.lastSync`).
    @discardableResult
    public static func refresh() async -> SyncStatus? {
        await runtime.refresh(force: true)
        return runtime.lastSync
    }

    /// La última petición al hub: cuándo, con qué `userId`, cuántas campañas o qué error.
    public static var lastSync: SyncStatus? { runtime.lastSync }

    /// Si cambia el usuario (login/logout), para que la siguiente petición use el nuevo id.
    public static func userDidChange() {
        runtime.invalidateUser()
        Task { await runtime.refresh(force: true) }
    }

    /// Envía ya las impresiones pendientes.
    public static func flush() async {
        await runtime.flush()
    }

    // MARK: Avisos

    /// Pásale el token de `didRegisterForRemoteNotificationsWithDeviceToken`.
    /// `sandbox: nil` lo detecta (desarrollo = sandbox; TestFlight y App Store = producción).
    public static func registerDeviceToken(_ token: Data, sandbox: Bool? = nil) {
        runtime.registerDeviceToken(token, sandbox: sandbox)
    }

    /// Pásale el `userInfo` de un aviso abierto. Devuelve `true` si era de MessagesKit.
    @discardableResult
    public static func handleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        runtime.handleNotification(userInfo)
    }

    /// Pásale los avisos silenciosos (`didReceiveRemoteNotification`). Si el hub avisa de
    /// cambios, pide los mensajes y lo nuevo sale sin reabrir la app. `true` si era de MessagesKit.
    @discardableResult
    public static func didReceiveRemoteNotification(_ userInfo: [AnyHashable: Any]) async -> Bool {
        guard MessagesRuntime.isRefreshSignal(userInfo) else { return false }
        await runtime.refreshFromSignal()
        return true
    }

    /// Pásale los avisos que llegan con la app abierta (`willPresent`). Si es un aviso de
    /// MessagesKit (cambios o vista previa), refresca y devuelve `true`: no hace falta enseñar
    /// el banner del sistema, porque el mensaje sale dentro de la app.
    @discardableResult
    public static func willPresentNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard MessagesRuntime.isRefreshSignal(userInfo) else { return false }
        Task { await runtime.refreshFromSignal() }
        return true
    }

    // MARK: Vista previa y depuración

    /// Pinta una campaña ahora mismo en modo prueba: los botones dicen qué harían y no se
    /// cuenta nada. Es el mismo presentador que en producción.
    public static func preview(
        campaign: Campaign,
        language: String? = nil,
        variant: PreviewVariant = .init(),
        theme: MessagesTheme? = nil
    ) {
        let lang = language ?? campaign.defaultLanguage
        presenter.enqueue(MessageRequest(campaign: campaign, language: lang, mode: .test, variant: variant, theme: theme))
    }

    /// Pinta una campaña pegada en JSON (modo prueba). Lanza si el JSON no es una campaña.
    public static func preview(json: String, language: String? = nil) throws {
        let campaign = try JSONDecoder.messages.decode(Campaign.self, from: Data(json.utf8))
        preview(campaign: campaign, language: language)
    }

    /// Enseña de verdad una campaña de la caché (o la pide), saltándose disparadores.
    public static func show(campaignId: String) {
        runtime.open(campaignId: campaignId)
    }

    /// Lo que usa esta app (tema, rutas, acciones, pantallas y eventos vistos, atributos propios),
    /// en JSON para pegarlo en el admin: Apps → Importar desde la app. `nil` sin `configure`.
    public static func appReport() async -> String? {
        guard let report = await runtime.appReport(),
              let data = try? JSONEncoder.messagesPretty.encode(report) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Las campañas que el hub ha servido a este usuario (para un menú de depuración).
    public static var cachedCampaigns: [Campaign] { runtime.cachedCampaigns }

    /// Borra la caché, la frecuencia local y las impresiones pendientes.
    public static func resetLocalState() {
        runtime.resetLocalState()
    }

    /// Las campañas de ejemplo que trae el paquete (una de cada presentación).
    public static var examples: [Campaign] { Examples.campaigns }

    /// La configuración de ejemplo de ReWearly.
    public static var exampleApp: AppConfig? { Examples.app }
}

// MARK: - Disparador de pantalla

public extension View {
    /// Marca la pantalla para el disparador `screen`.
    func messagePlacement(_ screen: String) -> some View {
        modifier(MessagePlacementModifier(screen: screen))
    }
}

struct MessagePlacementModifier: ViewModifier {
    let screen: String

    func body(content: Content) -> some View {
        content
            .onAppear { Messages.runtime.placementAppeared(screen) }
            .onDisappear { Messages.runtime.placementDisappeared(screen) }
    }
}

// MARK: - Ejemplos

enum Examples {
    static let campaigns: [Campaign] = load(prefixExcluding: "app-")
        .compactMap { try? JSONDecoder.messages.decode(Campaign.self, from: $0.data) }
        .sorted { $0.name < $1.name }

    static let app: AppConfig? = load(prefix: "app-")
        .compactMap { try? JSONDecoder.messages.decode(AppConfig.self, from: $0.data) }
        .first

    /// El JSON crudo de cada ejemplo, por nombre de archivo.
    static func load(prefix: String? = nil, prefixExcluding: String? = nil) -> [(name: String, data: Data)] {
        let urls = Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: "Examples")
            ?? Bundle.module.urls(forResourcesWithExtension: "json", subdirectory: nil)
            ?? []
        return urls.compactMap { url in
            let name = url.deletingPathExtension().lastPathComponent
            if let prefix, !name.hasPrefix(prefix) { return nil }
            if let prefixExcluding, name.hasPrefix(prefixExcluding) { return nil }
            return (try? Data(contentsOf: url)).map { (name, $0) }
        }
    }
}
