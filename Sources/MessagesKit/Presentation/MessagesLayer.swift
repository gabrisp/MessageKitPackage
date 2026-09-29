import SwiftUI
import StoreKit

public extension View {
    /// Pone la capa de mensajes (alerts, banners, toasts, sheets y pantalla completa).
    /// Una vez, en la raíz de la app.
    func messagesLayer() -> some View {
        modifier(MessagesLayerModifier(presenter: Messages.presenter))
    }

    /// Igual, con un presentador propio (vistas previas, tests).
    func messagesLayer(presenter: MessagePresenter) -> some View {
        modifier(MessagesLayerModifier(presenter: presenter))
    }
}

struct MessagesLayerModifier: ViewModifier {
    @Bindable var presenter: MessagePresenter
    @Environment(\.requestReview) private var requestReview
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .overlay { overlays }
            .sheet(item: binding(for: [.sheet])) { request in
                SheetHost(request: request, presenter: presenter)
            }
            #if os(iOS)
            .fullScreenCover(item: binding(for: [.fullscreen])) { request in
                fullscreen(request)
            }
            #endif
            .testDestinationHost(presenter, isHost: !presenter.isShowingModalMessage)
            .onAppear {
                let review = requestReview
                presenter.system = SystemActions(openURL: openURL, requestReview: { review() })
                Messages.runtime.layerDidAppear()
            }
            .onChange(of: scenePhase) { _, phase in
                Messages.runtime.scenePhaseChanged(phase)
            }
    }

    /// Un binding que solo muestra el mensaje actual si es de uno de esos estilos. Cerrar
    /// con el gesto del sistema lo pone a `nil` → se registra como cierre por gesto.
    private func binding(for styles: Set<Presentation.Style>) -> Binding<MessageRequest?> {
        Binding(
            get: {
                guard let c = presenter.current, styles.contains(c.style) else { return nil }
                return c
            },
            set: { newValue in
                if newValue == nil, let c = presenter.current, styles.contains(c.style) {
                    presenter.dismiss(.gesture, id: c.id)
                }
            }
        )
    }

    @ViewBuilder private var overlays: some View {
        ZStack {
            if let request = presenter.current {
                let handler = presenter.handler(for: request)
                switch request.style {
                case .alert:
                    // Tocar fuera no cierra nada: solo tapa la app de detrás (como un alert del sistema).
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .contentShape(.rect)
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    AlertCard(blocks: request.blocks, dismissible: request.dismissible) {
                        presenter.dismiss(.closeButton, id: request.id)
                    }
                    .padding(24)
                    .messageEnvironment(request, theme: presenter.theme, handler: handler)
                    .modifier(OptionalColorScheme(scheme: request.variant.colorScheme))
                    .transition(.scale(scale: 0.88).combined(with: .opacity))
                    .id(request.id)
                case .banner:
                    let p = request.campaign.presentation
                    BannerCard(
                        blocks: request.blocks, presentation: p, dismissible: request.dismissible,
                        onTap: { handler($0) }, onClose: { presenter.dismiss($0, id: request.id) }
                    )
                    .padding(.horizontal, 12)
                    .padding(.bottom, p.position == .bottom ? presenter.theme.bannerBottomInset : 0)
                    .frame(maxHeight: .infinity, alignment: p.position == .top ? .top : .bottom)
                    .messageEnvironment(request, theme: presenter.theme, handler: handler)
                    .modifier(OptionalColorScheme(scheme: request.variant.colorScheme))
                    .transition(.move(edge: p.position == .top ? .top : .bottom).combined(with: .opacity))
                    .task(id: request.id) { await autoDismiss(request) }
                    .id(request.id)
                case .toast:
                    let p = request.campaign.presentation
                    let h = ToastCapsule.placement(request.blocks).horizontal
                    ToastCapsule(blocks: request.blocks) { handler($0) }
                        .padding(.horizontal, 16)
                        .padding(.bottom, p.position == .bottom ? presenter.theme.bannerBottomInset : 0)
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: Alignment(horizontal: h, vertical: p.position == .top ? .top : .bottom))
                        .messageEnvironment(request, theme: presenter.theme, handler: handler)
                        .modifier(OptionalColorScheme(scheme: request.variant.colorScheme))
                        .transition(.move(edge: p.position == .top ? .top : .bottom).combined(with: .opacity))
                        .task(id: request.id) { await autoDismiss(request) }
                        .id(request.id)
                #if os(macOS)
                case .fullscreen:
                    fullscreen(request)
                        .transition(.opacity.combined(with: .scale(scale: 1.03)))
                        .id(request.id)
                #endif
                default:
                    EmptyView()
                }
            }
            if let notice = presenter.testNotice {
                TestNoticeView(entry: notice)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(notice.id)
            }
        }
        .animation(.spring(duration: 0.4, bounce: 0.18), value: presenter.current?.id)
        .animation(.spring(duration: 0.35), value: presenter.testNotice?.id)
    }

    private func fullscreen(_ request: MessageRequest) -> some View {
        FullscreenMessageContent(blocks: request.blocks, dismissible: request.dismissible) {
            presenter.dismiss(.closeButton, id: request.id)
        }
        .messageEnvironment(request, theme: presenter.theme, handler: presenter.handler(for: request))
        .modifier(OptionalColorScheme(scheme: request.variant.colorScheme, preferred: true))
        #if os(iOS)
        .testDestinationHost(presenter, isHost: presenter.current?.id == request.id)
        #endif
        .overlay {
            // En la pantalla completa el aviso del modo prueba tiene que ir por dentro.
            if let notice = presenter.testNotice {
                TestNoticeView(entry: notice)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: presenter.testNotice?.id)
    }

    private func autoDismiss(_ request: MessageRequest) async {
        guard let seconds = request.campaign.presentation.effectiveAutoDismiss, seconds > 0 else { return }
        try? await Task.sleep(for: .seconds(seconds))
        guard !Task.isCancelled else { return }
        presenter.dismiss(.auto, id: request.id)
    }
}

/// La hoja del sistema con sus detents (se abre en el primero).
struct SheetHost: View {
    let request: MessageRequest
    let presenter: MessagePresenter
    @State private var fittedHeight: CGFloat = 320
    @State private var selection: PresentationDetent = .large

    var body: some View {
        SheetMessageContent(
            blocks: request.blocks,
            dismissible: request.dismissible,
            onClose: { presenter.dismiss(.closeButton, id: request.id) },
            onHeight: { fittedHeight = $0 }
        )
        .messageEnvironment(request, theme: presenter.theme, handler: presenter.handler(for: request))
        .overlay {
            if let notice = presenter.testNotice {
                TestNoticeView(entry: notice)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.35), value: presenter.testNotice?.id)
        .testDestinationHost(presenter, isHost: presenter.current?.id == request.id)
        .presentationDetents(Set(detents), selection: $selection)
        .presentationDragIndicator(request.dismissible ? .visible : .hidden)
        .interactiveDismissDisabled(!request.dismissible)
        .modifier(OptionalColorScheme(scheme: request.variant.colorScheme, preferred: true))
        .onAppear { selection = detents.first ?? .large }
        #if os(macOS)
        .frame(minWidth: 420, idealWidth: 480, minHeight: 320, idealHeight: min(max(fittedHeight, 320), 720))
        #endif
    }

    private var detents: [PresentationDetent] {
        request.campaign.presentation.detents.map { $0.swiftUI(fittedHeight: fittedHeight) }
    }
}

extension Presentation.Detent {
    func swiftUI(fittedHeight: CGFloat) -> PresentationDetent {
        switch self {
        case .medium: .medium
        case .large: .large
        case .fitted: .height(min(fittedHeight, 900))
        case .fraction(let f): .fraction(max(0.1, min(f, 1)))
        case .height(let h): .height(max(80, h))
        }
    }
}
