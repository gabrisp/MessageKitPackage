import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Variantes de vista previa (solo para el admin y la depuración).
public struct PreviewVariant: Sendable, Hashable {
    public var colorScheme: ColorScheme?
    public var dynamicTypeSize: DynamicTypeSize?
    /// Fuerza dismisseable o no, sin tocar la campaña.
    public var dismissible: Bool?

    public init(colorScheme: ColorScheme? = nil, dynamicTypeSize: DynamicTypeSize? = nil, dismissible: Bool? = nil) {
        self.colorScheme = colorScheme; self.dynamicTypeSize = dynamicTypeSize; self.dismissible = dismissible
    }
}

/// Un mensaje en la cola (o en pantalla).
public struct MessageRequest: Identifiable, Sendable {
    public enum Mode: Sendable, Hashable {
        /// De verdad: ejecuta acciones y cuenta impresiones.
        case live
        /// Modo prueba: los botones dicen qué harían y no se cuenta nada.
        case test
        /// Mensajes propios del paquete (el toast de "copiado"): ni acciones ni impresiones.
        case local
    }

    public let id = UUID()
    public var campaign: Campaign
    public var language: String
    public var mode: Mode
    public var variant: PreviewVariant
    /// Tema propio (el admin pinta cada campaña con el de su app). `nil` = el del presentador.
    public var theme: MessagesTheme?
    let enqueuedAt = Date()

    public init(campaign: Campaign, language: String, mode: Mode = .live, variant: PreviewVariant = .init(), theme: MessagesTheme? = nil) {
        self.campaign = campaign; self.language = language; self.mode = mode
        self.variant = variant; self.theme = theme
    }

    public var blocks: [Block] { campaign.blocks(for: language) }
    public var style: Presentation.Style { campaign.presentation.style }
    public var dismissible: Bool { variant.dismissible ?? campaign.dismissible }
}

/// Por qué se cerró un mensaje.
public enum DismissReason: String, Sendable {
    /// Con la X.
    case closeButton
    /// Arrastrando o tocando fuera.
    case gesture
    /// Se fue solo (toast, banner con tiempo).
    case auto
    /// Por una acción con `thenDismiss`.
    case action
    /// Lo quitó la app (suprimir, reemplazar…).
    case programmatic
}

/// Lo que dijo un botón en modo prueba.
public struct TestActionEntry: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let campaignName: String
    public let action: MessageAction
    public let description: String
    public let at = Date()
}

/// A dónde llevaría una acción en modo prueba (una ruta, un deep link, una web…). El admin
/// la pinta con `testDestinationContent` para que también se pueda "navegar" en la vista previa.
public struct TestDestination: Identifiable, Sendable {
    public let id = UUID()
    public let action: MessageAction
    public let campaign: Campaign
    public let language: String

    /// Acciones que llevan a algún sitio (el resto solo se registran).
    static func navigates(_ action: MessageAction) -> Bool {
        switch action.kind {
        case .route, .deepLink, .openURL, .custom, .requestReview, .requestPushPermission, .share, .purchase: true
        default: false
        }
    }
}

/// Acciones del sistema que solo están en el entorno de SwiftUI (las pone `messagesLayer`).
@MainActor
struct SystemActions {
    var openURL: OpenURLAction?
    var requestReview: (() -> Void)?
}

/// Presentador único: una cola con prioridad, nunca dos mensajes a la vez y nunca encima
/// de algo que la app haya presentado por su cuenta.
@MainActor
@Observable
public final class MessagePresenter {
    public private(set) var current: MessageRequest?
    /// En modo prueba, cuánto dura en pantalla uno que no se puede cerrar.
    public static let testLockTimeout: Duration = .seconds(6)
    public private(set) var queue: [MessageRequest] = []
    /// La app pide silencio (onboarding, compra, grabando…).
    public var isSuppressed = false {
        didSet { if !isSuppressed { advance() } }
    }
    /// El tema por defecto de los mensajes.
    public var theme: MessagesTheme = .default

    /// Registro de lo que dijeron los botones en modo prueba (lo más nuevo primero).
    public internal(set) var testLog: [TestActionEntry] = []
    /// Aviso breve en pantalla con lo que haría un botón en modo prueba.
    public internal(set) var testNotice: TestActionEntry?

    /// El destino simulado que está abierto (modo prueba).
    public internal(set) var testDestination: TestDestination?
    /// Cómo se pinta un destino simulado. Sin esto, las acciones solo se registran.
    @ObservationIgnored public var testDestinationContent: (@MainActor (TestDestination) -> AnyView)?

    /// Para encadenar `openCampaign` en modo prueba (el admin busca en sus campañas).
    public var testCampaignResolver: (@MainActor (String) -> Campaign?)?

    // Enganches del runtime (modo real).
    var onShown: (@MainActor (MessageRequest) -> Void)?
    var onDismissed: (@MainActor (MessageRequest, DismissReason) -> Void)?
    var onLiveAction: (@MainActor (MessageRequest, MessageAction) -> Void)?

    var system = SystemActions()
    /// Mensajes con una acción en marcha (compra, permiso de avisos…): sus botones no responden.
    public internal(set) var busyRequestIds: Set<UUID> = []
    /// Último toque por mensaje: un segundo toque muy seguido se ignora (no abrir dos veces).
    @ObservationIgnored private var lastTap: [UUID: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    public init() {}

    // MARK: Cola

    public func enqueue(_ request: MessageRequest) {
        queue.append(request)
        queue.sort {
            $0.campaign.priority != $1.campaign.priority
                ? $0.campaign.priority > $1.campaign.priority
                : $0.enqueuedAt < $1.enqueuedAt
        }
        advance()
    }

    /// Si la campaña ya está en pantalla o esperando.
    public func contains(campaignId: String) -> Bool {
        current?.campaign.id == campaignId || queue.contains { $0.campaign.id == campaignId }
    }

    /// Una versión nueva de una campaña (la has editado y publicado): la que está en pantalla se
    /// cambia en el sitio, sin cerrarse ni volver a animarse; si ha cambiado de tipo (alert → hoja…),
    /// se cierra y sale la nueva. Las que esperan en la cola, también. `true` si estaba en pantalla.
    @discardableResult
    func update(campaign: Campaign) -> Bool {
        for i in queue.indices where queue[i].campaign.id == campaign.id && queue[i].mode == .live {
            queue[i].campaign = campaign
        }
        guard var shown = current, shown.mode == .live, shown.campaign.id == campaign.id, shown.campaign != campaign else { return false }
        if shown.style == campaign.presentation.style {
            shown.campaign = campaign
            // Textos que cambian letra a letra y bloques con desenfoque (ver BlocksView).
            withAnimation(.smooth(duration: 0.35)) { current = shown }
        } else {
            dismiss(.programmatic, id: shown.id)
            enqueue(MessageRequest(campaign: campaign, language: shown.language, mode: .live, variant: shown.variant, theme: shown.theme))
        }
        return true
    }

    /// Quita de la cola (no de la pantalla) lo que cumpla la condición.
    public func removeQueued(where predicate: (MessageRequest) -> Bool) {
        queue.removeAll(where: predicate)
    }

    func advance() {
        guard current == nil, !isSuppressed, !queue.isEmpty else { return }
        if HostInspector.isPresentingForeignModal() {
            // La app tiene algo suyo encima: se vuelve a mirar en un momento.
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                self?.advance()
            }
            return
        }
        let next = queue.removeFirst()
        withAnimation(.spring(duration: 0.4, bounce: 0.18)) { current = next }
        // En modo prueba (el admin) uno que no se puede cerrar no te deja atrapado: se va solo.
        if next.mode == .test, !next.dismissible {
            Task { [weak self] in
                try? await Task.sleep(for: Self.testLockTimeout)
                self?.dismiss(.programmatic, id: next.id)
            }
        }
        if next.mode == .live { onShown?(next) }
        if next.style == .toast || next.style == .banner {
            let text = next.blocks.compactMap(\.plainText).joined(separator: ". ")
            AccessibilityNotification.Announcement(text).post()
        }
    }

    /// Cierra el mensaje en pantalla (si es `id`, cuando se indica).
    public func dismiss(_ reason: DismissReason = .programmatic, id: UUID? = nil) {
        guard let shown = current, id == nil || shown.id == id else { return }
        withAnimation(.smooth(duration: 0.3)) { current = nil }
        if shown.mode == .live { onDismissed?(shown, reason) }
        Task { [weak self] in
            // Deja que termine la animación (o el cierre del sheet) antes del siguiente.
            try? await Task.sleep(for: .milliseconds(450))
            self?.advance()
        }
    }

    /// Vacía la cola y cierra lo que haya.
    public func clear() {
        queue.removeAll()
        dismiss(.programmatic)
    }

    // MARK: Acciones

    /// Lo llama cada botón (a través de `MessageActionHandler`).
    func setBusy(_ busy: Bool, requestId: UUID) {
        if busy { busyRequestIds.insert(requestId) } else { busyRequestIds.remove(requestId) }
    }

    func handle(_ action: MessageAction, from request: MessageRequest) {
        // Con algo en marcha, nada; y dos toques en menos de medio segundo cuentan como uno.
        guard !busyRequestIds.contains(request.id) else { return }
        let now = ContinuousClock.now
        if let last = lastTap[request.id], now - last < .milliseconds(500) { return }
        lastTap[request.id] = now
        switch request.mode {
        case .live:
            onLiveAction?(request, action)
        case .local:
            break
        case .test:
            let entry = TestActionEntry(campaignName: request.campaign.name, action: action, description: ActionDescriber.describe(action, language: request.language, messageDismissible: request.dismissible))
            testLog.insert(entry, at: 0)
            if case .dismiss = action.kind {} else { showNotice(entry) }
            if case .openCampaign(let id) = action.kind, let next = testCampaignResolver?(id) {
                enqueue(MessageRequest(campaign: next, language: request.language, mode: .test, variant: request.variant, theme: request.theme))
            } else {
                // Si el mensaje se cierra, el destino sale cuando ya se ha ido (como en la app).
                openTestDestination(action, campaign: request.campaign, language: request.language,
                                    after: action.closes(messageDismissible: request.dismissible) && current?.id == request.id ? .milliseconds(550) : .zero)
            }
        }
        if action.closes(messageDismissible: request.dismissible), current?.id == request.id {
            dismiss(.action, id: request.id)
        }
    }

    func handler(for request: MessageRequest) -> MessageActionHandler {
        MessageActionHandler(
            { [weak self] action in self?.handle(action, from: request) },
            busy: { [weak self] in self?.busyRequestIds.contains(request.id) ?? false }
        )
    }

    public func clearTestLog() { testLog.removeAll() }

    /// Si hay en pantalla un mensaje que es una presentación modal (sheet, o pantalla completa en iOS):
    /// los destinos de prueba se presentan desde él y no desde la raíz.
    var isShowingModalMessage: Bool {
        switch current?.style {
        case .sheet: true
        #if os(iOS)
        case .fullscreen: true
        #endif
        default: false
        }
    }

    func openTestDestination(_ action: MessageAction, campaign: Campaign, language: String, after delay: Duration) {
        guard testDestinationContent != nil, TestDestination.navigates(action) else { return }
        let destination = TestDestination(action: action, campaign: campaign, language: language)
        Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            self?.testDestination = destination
        }
    }

    public func closeTestDestination() { testDestination = nil }

    func showNotice(_ entry: TestActionEntry) {
        withAnimation(.spring(duration: 0.35)) { testNotice = entry }
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { self?.testNotice = nil }
        }
    }
}

extension Block {
    /// El texto del bloque sin formato (para VoiceOver y compactar banners).
    var plainText: String? {
        switch kind {
        case .heading(let h): h.text.strippingMarkdown
        case .text(let t): t.text.strippingMarkdown
        default: nil
        }
    }
}

extension String {
    var strippingMarkdown: String {
        guard let a = try? AttributedString(markdown: self, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return self }
        return String(a.characters)
    }
}

// MARK: - Destino de prueba

extension View {
    /// Presenta el destino simulado desde esta vista cuando le toca (`isHost`).
    func testDestinationHost(_ presenter: MessagePresenter, isHost: Bool) -> some View {
        sheet(item: Binding(
            get: { isHost ? presenter.testDestination : nil },
            set: { if $0 == nil, isHost { presenter.closeTestDestination() } }
        )) { destination in
            presenter.testDestinationContent?(destination)
        }
    }
}

// MARK: - ¿Tiene la app algo suyo presentado?

@MainActor
enum HostInspector {
    /// Solo se consulta cuando no hay ningún mensaje en pantalla, así que lo presentado es de la app.
    static func isPresentingForeignModal() -> Bool {
        #if os(iOS)
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let windows = scenes.filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        return windows.contains { $0.isKeyWindow && $0.rootViewController?.presentedViewController != nil }
        #else
        return NSApp.keyWindow?.attachedSheet != nil
        #endif
    }
}
