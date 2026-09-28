import SwiftUI
import UserNotifications

/// La última petición al hub, para ver qué está pasando (en `MessagesDebugView` o en tu propia pantalla).
public struct SyncStatus: Sendable, Hashable {
    public var date: Date
    /// El `userId` con el que se pidió: tiene que coincidir con el de las audiencias por usuario.
    public var userId: String
    public var ok: Bool
    /// Campañas que el hub le sirve a este usuario ahora (sin contar las forzadas).
    public var campaigns: Int
    public var notModified: Bool
    /// El error, si falló.
    public var error: String?
    public var duration: Duration
}

/// Qué ha hecho saltar una evaluación de campañas.
enum TriggerFire: Sendable, Hashable {
    case launch
    case foreground
    case screen(String)
    case event(String)

    func matches(_ t: Trigger) -> Bool {
        switch (self, t.on) {
        case (.launch, .launch), (.foreground, .foreground): true
        case (.screen(let s), .screen): t.screen == s
        case (.event(let e), .event): t.event == e
        default: false
        }
    }
}

/// El motor de la app anfitriona: pide las campañas al hub, decide el momento (disparadores),
/// aplica la frecuencia local de respaldo y manda las impresiones.
@MainActor
final class MessagesRuntime {
    let presenter: MessagePresenter
    private(set) var config: MessagesConfiguration?
    private var client: HubClient?
    private var store: MessagesStore?
    private var state = PersistedState()

    var routes: [String: @MainActor (RouteParams) -> Void] = [:]
    var customActions: [String: @MainActor (JSONValue) -> Void] = [:]
    var purchaseHandler: (@MainActor (PurchaseRequest) async throws -> PurchaseOutcome)?
    /// Parámetros declarados al registrar (para el informe del admin).
    var routeParams: [String: [AppConfig.Param]] = [:]
    var actionParams: [String: [AppConfig.Param]] = [:]

    private let sessionStart = Date()
    private var activeScreens: [String: Int] = [:]
    private var launchEvaluated = false
    /// Ya se ha intentado el hub al abrir (con respuesta o por tiempo).
    private var launchReady = false
    /// Eventos que llegan antes de estar listos; se repiten después.
    private var earlyEvents: [String] = []
    private var layerVisible = false
    private var lastPhase: ScenePhase?
    private var pending: [String: Task<Void, Never>] = [:]
    private var refreshTask: Task<Void, Never>?
    private var flushTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var cachedUserId: String?
    /// La última petición al hub.
    private(set) var lastSync: SyncStatus?
    /// Campaña de la última acción (para apuntar el resultado de una compra).
    private var lastActionCampaignId: String?
    /// La caché del disco ya está cargada.
    private var loaded = false
    /// El token de avisos: el sistema lo da nada más arrancar, a menudo antes de `configure`.
    /// Se guarda, se manda en cuanto hay configuración y se vuelve a mandar si cambia el usuario.
    private var deviceToken: (token: Data, sandbox: Bool?)?
    /// Avisos tocados antes de estar listos (abrir la app desde un push): se atienden al estarlo.
    private var earlyNotifications: [[AnyHashable: Any]] = []
    /// Las capacidades (rutas y acciones) de la última petición al hub.
    private var sentCapabilities: Capabilities?
    private var capabilitiesTask: Task<Void, Never>?

    init(presenter: MessagePresenter) {
        self.presenter = presenter
        presenter.onShown = { [weak self] in self?.didShow($0) }
        presenter.onDismissed = { [weak self] in self?.didDismiss($0, reason: $1) }
        presenter.onLiveAction = { [weak self] in self?.didTap($1, in: $0) }
    }

    // MARK: Configuración

    func configure(_ config: MessagesConfiguration) {
        self.config = config
        MessagesLog.enabled = config.debugLogging
        presenter.theme = config.theme
        client = HubClient(endpoint: config.endpoint, projectId: config.projectId)
        let store = MessagesStore(appId: config.appId)
        self.store = store
        InstallDate.ensure()
        Task {
            // Lo apuntado antes de cargar la caché (impresiones, forzadas) no se pierde.
            let early = state
            state = await store.load()
            state.pendingEvents.append(contentsOf: early.pendingEvents)
            for f in early.forced where !state.forced.contains(where: { $0.id == f.id }) { state.forced.append(f) }
            loaded = true
            MessagesLog.debug("Caché: \(state.campaigns.count) campañas, \(state.pendingEvents.count) eventos pendientes")
            if let deviceToken { sendDeviceToken(deviceToken.token, sandbox: deviceToken.sandbox) }
            // Al abrir: el hub con un tope de tiempo; si no llega, la caché.
            let timeout = config.launchTimeout
            let fetch = Task { await self.refresh(force: true) }
            let deadline = Task { try? await Task.sleep(for: timeout) }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await fetch.value }
                group.addTask { await deadline.value }
                await group.next()
                group.cancelAll()
            }
            deadline.cancel()
            launchReady = true
            evaluateLaunch()
            flushSoon(after: .seconds(2))
        }
    }

    func layerDidAppear() {
        layerVisible = true
        evaluateLaunch()
    }

    func scenePhaseChanged(_ phase: ScenePhase) {
        defer { if phase != .inactive { lastPhase = phase } }
        switch phase {
        case .active where lastPhase == .background:
            // Al volver a la app: siempre se pregunta al hub (con etag, casi gratis) y lo nuevo o
            // cambiado sale por sus disparadores. Es el único momento, junto a abrirla y tocar un
            // aviso, en que aparecen mensajes nuevos: nunca a mitad de uso.
            Task {
                await refreshAndPresentNew()
                fire(.foreground)
            }
        case .background:
            flushSoon(after: .zero)
            scheduleSave(immediately: true)
        default:
            break
        }
    }

    private func evaluateLaunch() {
        guard !launchEvaluated, launchReady, layerVisible else { return }
        launchEvaluated = true
        presentForced()
        // Los avisos tocados al abrir la app (antes de estar listos).
        let notifications = earlyNotifications
        earlyNotifications.removeAll()
        for userInfo in notifications { _ = handleNotification(userInfo) }
        fire(.launch)
        // Lo que pasó mientras se esperaba al hub.
        for screen in activeScreens.keys { fire(.screen(screen)) }
        for event in earlyEvents { fire(.event(event)) }
        earlyEvents.removeAll()
    }

    // MARK: Hub

    /// Pide las campañas al hub. Sin `force`, solo si la caché ha caducado.
    func refresh(force: Bool) async {
        guard let config, let client else { return }
        if !force, let fetched = state.fetchedAt, Date.now.timeIntervalSince(fetched) < min(state.ttlSeconds, 300) { return }
        // Una en marcha: sin `force` vale su resultado; con `force` se espera y se vuelve a pedir,
        // porque la que estaba en marcha salió con los atributos de antes (p. ej. aún no era Pro).
        while let running = refreshTask {
            await running.value
            if !force { return }
        }
        let task = Task {
            let started = ContinuousClock.now
            let uid = await userId()
            do {
                let capabilities = Capabilities(routes: routes.keys.sorted(), actions: customActions.keys.sorted())
                sentCapabilities = capabilities
                let request = MessagesRequest(
                    appId: config.appId, publicKey: config.publicKey,
                    userId: uid, locale: language,
                    attributes: await attributes(),
                    capabilities: capabilities,
                    etag: state.campaigns.isEmpty ? nil : state.etag,
                    sdkVersion: messagesKitVersion
                )
                let response = try await client.call("messages", request, as: MessagesResponse.self)
                apply(response)
                lastSync = SyncStatus(date: .now, userId: uid, ok: true, campaigns: state.campaigns.count,
                                      notModified: response.notModified, error: nil, duration: ContinuousClock.now - started)
                MessagesLog.debug("Hub OK: \(state.campaigns.count) campañas para \(uid)")
            } catch {
                lastSync = SyncStatus(date: .now, userId: uid, ok: false, campaigns: state.campaigns.count,
                                      notModified: false, error: error.localizedDescription, duration: ContinuousClock.now - started)
                MessagesLog.error("No se pudieron pedir los mensajes: \(error.localizedDescription)")
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    private func apply(_ response: MessagesResponse) {
        state.fetchedAt = .now
        state.ttlSeconds = response.ttlSeconds
        state.dailyCap = response.dailyCap
        if response.notModified {
            MessagesLog.debug("Sin cambios (etag \(response.etag))")
        } else {
            let forced = response.campaigns.filter { $0.forced == true }
            state.campaigns = response.campaigns.filter { $0.forced != true }
            state.etag = response.etag
            for f in forced where !state.forced.contains(where: { $0.id == f.id }) { state.forced.append(f) }
            MessagesLog.debug("Hub: \(state.campaigns.count) campañas, \(forced.count) forzadas")
        }
        scheduleSave()
    }

    /// Una ruta o acción registrada después de pedir los mensajes: el hub no sirve campañas con
    /// botones que la app no sabe ejecutar, así que se vuelven a pedir (una vez, agrupadas).
    func capabilitiesChanged() {
        guard let sent = sentCapabilities else { return }
        let now = Capabilities(routes: routes.keys.sorted(), actions: customActions.keys.sorted())
        guard now.routes != sent.routes || now.actions != sent.actions else { return }
        capabilitiesTask?.cancel()
        capabilitiesTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            MessagesLog.debug("Rutas o acciones nuevas: se vuelven a pedir los mensajes")
            await self.refreshAndPresentNew()
        }
    }

    /// Una campaña sin bloques en ningún idioma es solo de push: no hay nada que enseñar.
    private func hasContent(_ c: Campaign) -> Bool {
        !c.blocks(for: language).isEmpty
    }

    /// Las forzadas ("Enviar a un usuario") salen en cuanto se puede, sin disparador.
    private func presentForced() {
        guard layerVisible else { return }
        for c in state.forced where !presenter.contains(campaignId: c.id) && hasContent(c) {
            presenter.enqueue(MessageRequest(campaign: c, language: language, mode: .live))
        }
    }

    // MARK: Disparadores

    func placementAppeared(_ screen: String) {
        activeScreens[screen, default: 0] += 1
        if state.seenScreens.insert(screen).inserted { scheduleSave() }
        fire(.screen(screen))
    }

    func placementDisappeared(_ screen: String) {
        let n = (activeScreens[screen] ?? 1) - 1
        activeScreens[screen] = n > 0 ? n : nil
        guard n <= 0 else { return }
        // Lo que esperaba a esta pantalla ya no tiene sentido.
        for c in state.campaigns where c.trigger.on == .screen && c.trigger.screen == screen {
            pending[c.id]?.cancel()
            pending[c.id] = nil
        }
        presenter.removeQueued { $0.campaign.trigger.on == .screen && $0.campaign.trigger.screen == screen && $0.mode == .live }
    }

    func fire(_ trigger: TriggerFire, only ids: Set<String>? = nil) {
        guard config != nil else { return }
        guard launchEvaluated else {
            if case .event(let e) = trigger { earlyEvents.append(e) }
            return
        }
        let now = Date.now
        let candidates = state.campaigns
            .filter { trigger.matches($0.trigger) && (ids?.contains($0.id) ?? true) && hasContent($0) }
            .sorted { $0.priority > $1.priority }
        for campaign in candidates where isEligibleLocally(campaign, now: now) {
            let elapsed = now.timeIntervalSince(sessionStart)
            let wait = max(campaign.trigger.delaySeconds, campaign.trigger.minSessionSeconds - elapsed, 0)
            MessagesLog.debug("«\(campaign.name)» sale en \(wait)s por \(trigger)")
            pending[campaign.id] = Task { [weak self] in
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard !Task.isCancelled, let self else { return }
                self.pending[campaign.id] = nil
                if case .screen(let s) = trigger, self.activeScreens[s] == nil { return }
                guard self.isEligibleLocally(campaign, now: .now) else { return }
                self.presenter.enqueue(MessageRequest(campaign: campaign, language: self.language, mode: .live))
            }
        }
    }

    /// La comprobación local, de respaldo: lo que acabas de ver no vuelve a salir aunque el
    /// hub aún no se haya enterado.
    private func isEligibleLocally(_ c: Campaign, now: Date) -> Bool {
        if pending[c.id] != nil || presenter.contains(campaignId: c.id) { return false }
        if !Rules.scheduleAllows(c.schedule, now: now, userTimeZone: .current) { return false }
        let history = state.history[c.id] ?? .init()
        if !Rules.frequencyAllows(c.frequency, history: history, now: now, calendar: .current) { return false }
        if state.dailyCap > 0 {
            let today = state.history.values.reduce(0) { $0 + $1.shown.filter { Calendar.current.isDateInToday($0) }.count }
            if today >= state.dailyCap { return false }
        }
        return true
    }

    // MARK: Impresiones

    private func didShow(_ r: MessageRequest) {
        let id = r.campaign.id
        state.history[id, default: .init()].shown.append(.now)
        state.forced.removeAll { $0.id == id }
        record(.shown, r)
    }

    private func didDismiss(_ r: MessageRequest, reason: DismissReason) {
        switch reason {
        case .closeButton, .gesture:
            state.history[r.campaign.id, default: .init()].dismissedAt = .now
            record(.dismissed, r, actionId: reason.rawValue)
        case .auto, .action, .programmatic:
            scheduleSave()
        }
    }

    private func didTap(_ action: MessageAction, in r: MessageRequest) {
        if case .dismiss = action.kind {
            state.history[r.campaign.id, default: .init()].dismissedAt = .now
            record(.dismissed, r, actionId: action.trackingId)
        } else {
            state.history[r.campaign.id, default: .init()].actedAt = .now
            record(.clicked, r, actionId: action.trackingId)
        }
        lastActionCampaignId = r.campaign.id
        perform(action, from: r)
    }

    func record(_ event: ImpressionEvent, _ r: MessageRequest?, campaignId: String? = nil, actionId: String? = nil) {
        guard let cid = campaignId ?? r?.campaign.id else { return }
        state.pendingEvents.append(Impression(campaignId: cid, event: event, actionId: actionId))
        if let analytics = config?.analytics {
            var props: [String: any Sendable] = ["campaign_id": cid]
            if let r {
                props["campaign_name"] = r.campaign.name
                props["presentation"] = r.style.rawValue
                props["language"] = r.language
            }
            if let actionId { props["action_id"] = actionId }
            analytics("message_\(event.rawValue)", props)
        }
        scheduleSave()
        flushSoon(after: .seconds(5))
    }

    private func flushSoon(after delay: Duration) {
        flushTask?.cancel()
        flushTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    /// Manda las impresiones pendientes en lotes; si falla, se quedan para el siguiente intento.
    func flush() async {
        guard let config, let client, !state.pendingEvents.isEmpty else { return }
        let batch = Array(state.pendingEvents.prefix(100))
        do {
            try await client.fire("events", EventsRequest(appId: config.appId, publicKey: config.publicKey, userId: await userId(), events: batch))
            let sent = Set(batch.map(\.id))
            state.pendingEvents.removeAll { sent.contains($0.id) }
            scheduleSave()
            if !state.pendingEvents.isEmpty { flushSoon(after: .seconds(1)) }
        } catch {
            MessagesLog.debug("Impresiones sin enviar (\(state.pendingEvents.count)): \(error.localizedDescription)")
            flushSoon(after: .seconds(60))
        }
    }

    private func scheduleSave(immediately: Bool = false) {
        guard let store else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(500)) }
            guard !Task.isCancelled, let snapshot = self?.state else { return }
            await store.save(snapshot)
        }
    }

    // MARK: Acciones de verdad

    func perform(_ action: MessageAction, from r: MessageRequest?) {
        // Si el mensaje se cierra, la acción espera a que termine de irse (un sheet de la
        // app no puede salir mientras se cierra el nuestro).
        let waits = action.dismisses && (r?.style == .sheet || r?.style == .fullscreen)
        Task {
            if waits { try? await Task.sleep(for: .milliseconds(550)) }
            execute(action)
        }
    }

    private func execute(_ action: MessageAction) {
        switch action.kind {
        case .dismiss, .unknown:
            break
        case .route(let name, let params):
            if let handler = routes[name] { handler(params) } else { MessagesLog.error("Ruta no registrada: \(name)") }
        case .custom(let name, let payload):
            if let handler = customActions[name] { handler(payload) } else { MessagesLog.error("Acción no registrada: \(name)") }
        case .purchase(let productId, let offering, let packageId):
            let request = PurchaseRequest(productId: productId, offering: offering, packageId: packageId)
            Task {
                let outcome: PurchaseOutcome
                if let purchaseHandler {
                    do { outcome = try await purchaseHandler(request) } catch {
                        MessagesLog.error("Compra fallida: \(error.localizedDescription)")
                        outcome = .failed
                    }
                } else if let productId, !productId.isEmpty {
                    outcome = await StoreKitPurchase.buy(productId: productId)
                } else {
                    MessagesLog.error("Compra sin producto y sin Messages.register(purchase:)")
                    outcome = .failed
                }
                purchaseFinished(outcome, action: action)
            }
        case .deepLink(let url):
            if let u = URL(string: url) { presenter.system.openURL?(u) }
        case .openURL(let url, let inApp):
            guard let u = URL(string: url) else { return }
            if inApp, SystemBridge.presentSafari(u) { return }
            presenter.system.openURL?(u)
        case .requestReview:
            presenter.system.requestReview?()
        case .requestPushPermission:
            Task {
                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])) ?? false
                if granted { SystemBridge.registerForRemoteNotifications() }
                config?.analytics?("message_push_permission", ["granted": granted])
            }
        case .share(let text, let url):
            SystemBridge.share(items: [text, url].compactMap { $0 })
        case .copy(let text, let toast):
            SystemBridge.copy(text)
            if let toast, !toast.isEmpty {
                let c = Campaign(
                    id: "_copy", name: "copy", presentation: .init(style: .toast, autoDismissSeconds: 2),
                    defaultLanguage: language,
                    content: [language: [Block(.icon(.init(symbol: "doc.on.doc.fill", tint: "positive", size: 20))), Block(.text(.init(text: toast)))]]
                )
                presenter.enqueue(MessageRequest(campaign: c, language: language, mode: .local))
            }
        case .openCampaign(let id):
            if let next = (state.campaigns + state.forced).first(where: { $0.id == id }) {
                var chained = next
                chained.priority = Int.max / 2
                presenter.enqueue(MessageRequest(campaign: chained, language: language, mode: .live))
            } else {
                MessagesLog.error("Campaña encadenada no disponible: \(id)")
            }
        case .track(let event, let properties):
            config?.analytics?(event, properties.mapValues { $0.anySendable })
        }
    }

    /// El resultado de la compra también queda en impresiones y analítica.
    private func purchaseFinished(_ outcome: PurchaseOutcome, action: MessageAction) {
        guard let campaignId = lastActionCampaignId else { return }
        record(.action, nil, campaignId: campaignId, actionId: "\(action.trackingId):\(outcome.rawValue)")
        if outcome == .purchased { Task { await refresh(force: true) } }
    }

    // MARK: Push

    func registerDeviceToken(_ token: Data, sandbox: Bool?) {
        deviceToken = (token, sandbox)
        // Sin `configure` todavía (lo normal: el token llega en `didFinishLaunching`), se manda al configurar.
        guard loaded else { return }
        sendDeviceToken(token, sandbox: sandbox)
    }

    private func sendDeviceToken(_ token: Data, sandbox: Bool?) {
        guard let config, let client else { return }
        let hex = token.map { String(format: "%02x", $0) }.joined()
        Task {
            let body = DeviceRequest(
                appId: config.appId, publicKey: config.publicKey, userId: await userId(), token: hex,
                sandbox: sandbox ?? SystemBridge.isSandboxBuild, attributes: await attributes()
            )
            do {
                struct Ack: Decodable, Sendable {}
                _ = try await client.call("devices", body, as: Ack.self)
                MessagesLog.debug("Token de avisos registrado")
            } catch {
                MessagesLog.error("No se pudo registrar el token: \(error.localizedDescription)")
            }
        }
    }

    /// Si un aviso es de los que solo dicen "hay cambios" (el de "Enviar prueba").
    static func isRefreshSignal(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["messageskit"] as? String == "refresh" || userInfo["preview"] != nil
    }

    /// Pide los mensajes y lo nuevo (o cambiado) pasa por sus disparadores como si la app acabara
    /// de abrirse. Al volver a primer plano, al tocar un aviso y si la app registra rutas tarde.
    func refreshAndPresentNew() async {
        guard config != nil else { return }
        let before = Dictionary(state.campaigns.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        await refresh(force: true)
        guard launchEvaluated else { return }
        presentForced()
        // Las nuevas y las que han cambiado (editadas y vueltas a publicar). La frecuencia local
        // sigue mandando: lo que ya se vio y era "una vez" no vuelve a salir.
        let fresh = Set(state.campaigns.filter { before[$0.id] != $0 }.map(\.id))
        guard !fresh.isEmpty else { return }
        MessagesLog.debug("\(fresh.count) campañas nuevas o cambiadas")
        fire(.launch, only: fresh)
        fire(.foreground, only: fresh)
        for screen in activeScreens.keys { fire(.screen(screen), only: fresh) }
    }

    /// Lo llama la app al abrir un aviso. Devuelve `true` si era de MessagesKit.
    func handleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        let isOurs = Self.isRefreshSignal(userInfo) || userInfo["campaignId"] is String
        // Abriendo la app desde el aviso: aún no hay configuración ni caché. Se atiende al estar listos.
        if isOurs, !launchEvaluated {
            earlyNotifications.append(userInfo)
            return true
        }
        if Self.isRefreshSignal(userInfo) {
            if let campaignId = userInfo["campaignId"] as? String { record(.pushOpened, nil, campaignId: campaignId) }
            Task { await refreshAndPresentNew() }
            return true
        }
        guard let campaignId = userInfo["campaignId"] as? String else { return false }
        record(.pushOpened, nil, campaignId: campaignId)
        if let raw = userInfo["action"] as? String,
           let action = try? JSONDecoder.messages.decode(MessageAction.self, from: Data(raw.utf8)) {
            if case .openCampaign(let id) = action.kind { open(campaignId: id) } else { perform(action, from: nil) }
        } else {
            open(campaignId: campaignId)
        }
        return true
    }

    /// Enseña una campaña concreta (de la caché o, si no está, tras pedirla al hub).
    func open(campaignId: String) {
        func show() -> Bool {
            guard let c = (state.campaigns + state.forced).first(where: { $0.id == campaignId }) else { return false }
            if hasContent(c), !presenter.contains(campaignId: c.id) {
                presenter.enqueue(MessageRequest(campaign: c, language: language, mode: .live))
            }
            return true
        }
        if show() { return }
        Task {
            await refresh(force: true)
            if !show() { MessagesLog.debug("La campaña \(campaignId) ya no le toca a este usuario") }
        }
    }

    // MARK: Depuración

    var cachedCampaigns: [Campaign] { state.campaigns + state.forced }
    var history: [String: ImpressionHistory] { state.history }

    func resetLocalState() {
        state = PersistedState()
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        Task { await store?.erase() }
    }

    // MARK: Datos del usuario

    var language: String {
        let raw = config?.language ?? Locale.preferredLanguages.first ?? "es"
        return String(raw.prefix(while: { $0 != "-" && $0 != "_" }))
    }

    private func userId() async -> String {
        if let cachedUserId { return cachedUserId }
        let id = await config?.userId() ?? ""
        cachedUserId = id
        return id
    }

    /// Otro usuario: su id nuevo en las peticiones y el token de avisos pasa a ser suyo.
    func invalidateUser() {
        cachedUserId = nil
        if loaded, let deviceToken { sendDeviceToken(deviceToken.token, sandbox: deviceToken.sandbox) }
    }

    func noteEvent(_ name: String) {
        if state.seenEvents.insert(name).inserted { scheduleSave() }
    }

    /// Lo que usa esta app, para pegarlo en el admin (Apps → Importar desde la app).
    func appReport() async -> AppReport? {
        guard let config else { return nil }
        let builtIn = Set(AppConfig.Attribute.builtIn.map(\.name) + ["locale", "custom"])
        let custom = await attributes().filter { !builtIn.contains($0.key) && $0.value != .null }
        let info = Bundle.main.infoDictionary ?? [:]
        return AppReport(
            appId: config.appId,
            bundleId: Bundle.main.bundleIdentifier ?? "",
            name: info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? config.appId,
            languages: Bundle.main.localizations.filter { $0 != "Base" }.sorted(),
            theme: ThemeSpec(theme: config.theme),
            routes: routes.keys.sorted(),
            actions: customActions.keys.sorted(),
            screens: state.seenScreens.sorted(),
            events: state.seenEvents.sorted(),
            attributes: custom.keys.sorted().map { .init(name: $0, kind: .inferred(from: custom[$0]!)) },
            routeParams: routeParams,
            actionParams: actionParams,
            sdkVersion: messagesKitVersion
        )
    }

    private func attributes() async -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        let info = Bundle.main.infoDictionary ?? [:]
        let install = InstallDate.value
        out["language"] = .string(language)
        out["locale"] = .string(Locale.current.identifier)
        if let region = Locale.current.region?.identifier { out["country"] = .string(region) }
        out["appVersion"] = .string(info["CFBundleShortVersionString"] as? String ?? "0")
        out["build"] = .string(info["CFBundleVersion"] as? String ?? "0")
        #if os(iOS)
        out["platform"] = "ios"
        #else
        out["platform"] = "macos"
        #endif
        let os = ProcessInfo.processInfo.operatingSystemVersion
        out["osVersion"] = .string("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)")
        out["installDate"] = .string(ISO8601.string(from: install))
        out["daysSinceInstall"] = .number(Double(Calendar.current.dateComponents([.day], from: install, to: .now).day ?? 0))
        out["timezone"] = .string(TimeZone.current.identifier)
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        out["pushAuthorized"] = .bool(settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
        if let custom = await config?.attributes() {
            for (k, v) in custom { out[k] = JSONValue(any: v) }
        }
        return out
    }
}

/// Fecha de la primera vez que el paquete corre en este dispositivo.
enum InstallDate {
    static let key = "messageskit.installDate"

    static func ensure() {
        if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(Date.now, forKey: key) }
    }

    static var value: Date { UserDefaults.standard.object(forKey: key) as? Date ?? .now }
}

extension JSONValue {
    /// Para pasar propiedades a la analítica de la app.
    var anySendable: any Sendable {
        switch self {
        case .string(let s): s
        case .number(let n): n
        case .bool(let b): b
        case .array(let a): a.map(\.anySendable)
        case .object(let o): o.mapValues(\.anySendable)
        case .null: Optional<String>.none as any Sendable
        }
    }
}
