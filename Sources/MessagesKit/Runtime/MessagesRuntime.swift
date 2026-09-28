import SwiftUI
import UserNotifications

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
            state = await store.load()
            MessagesLog.debug("Caché: \(state.campaigns.count) campañas, \(state.pendingEvents.count) eventos pendientes")
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
            Task {
                await refresh(force: false)
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
        if let running = refreshTask { await running.value; return }
        let task = Task {
            do {
                let request = MessagesRequest(
                    appId: config.appId, publicKey: config.publicKey,
                    userId: await userId(), locale: language,
                    attributes: await attributes(),
                    capabilities: Capabilities(routes: routes.keys.sorted(), actions: customActions.keys.sorted()),
                    etag: state.campaigns.isEmpty ? nil : state.etag,
                    sdkVersion: messagesKitVersion
                )
                let response = try await client.call("messages", request, as: MessagesResponse.self)
                apply(response)
            } catch {
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
        if launchEvaluated { presentForced() }
    }

    /// Las forzadas ("Enviar a un usuario") salen en cuanto se puede, sin disparador.
    private func presentForced() {
        guard layerVisible else { return }
        for c in state.forced where !presenter.contains(campaignId: c.id) {
            presenter.enqueue(MessageRequest(campaign: c, language: language, mode: .live))
        }
    }

    // MARK: Disparadores

    func placementAppeared(_ screen: String) {
        activeScreens[screen, default: 0] += 1
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

    func fire(_ trigger: TriggerFire) {
        guard config != nil else { return }
        guard launchEvaluated else {
            if case .event(let e) = trigger { earlyEvents.append(e) }
            return
        }
        let now = Date.now
        let candidates = state.campaigns
            .filter { trigger.matches($0.trigger) }
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

    // MARK: Push

    func registerDeviceToken(_ token: Data, sandbox: Bool?) {
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

    /// Lo llama la app al abrir un aviso. Devuelve `true` si era de MessagesKit.
    func handleNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
        guard let campaignId = userInfo["campaignId"] as? String else { return false }
        record(.pushOpened, nil, campaignId: campaignId)
        if userInfo["preview"] != nil {
            Task { await refresh(force: true) }
            return true
        }
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
        if let c = (state.campaigns + state.forced).first(where: { $0.id == campaignId }) {
            presenter.enqueue(MessageRequest(campaign: c, language: language, mode: .live))
            return
        }
        Task {
            await refresh(force: true)
            if let c = state.campaigns.first(where: { $0.id == campaignId }) {
                presenter.enqueue(MessageRequest(campaign: c, language: language, mode: .live))
            }
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

    func invalidateUser() { cachedUserId = nil }

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
