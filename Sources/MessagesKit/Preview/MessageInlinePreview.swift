import SwiftUI

public extension MessagePresenter {
    /// Apunta en el registro de pruebas lo que haría una acción y lo avisa en pantalla.
    func recordTestAction(_ action: MessageAction, campaign: Campaign, language: String) {
        let entry = TestActionEntry(campaignName: campaign.name, action: action, description: ActionDescriber.describe(action, language: language, messageDismissible: campaign.dismissible))
        testLog.insert(entry, at: 0)
        showNotice(entry)
        if case .openCampaign(let id) = action.kind, let next = testCampaignResolver?(id) {
            enqueue(MessageRequest(campaign: next, language: language, mode: .test))
        } else {
            openTestDestination(action, campaign: campaign, language: language, after: .zero)
        }
    }
}

/// La campaña pintada dentro de un marco (el iPhone del editor), con los mismos componentes
/// que usa `messagesLayer`, sin presentarla de verdad. Los botones van en modo prueba.
public struct MessageInlinePreview: View {
    let campaign: Campaign
    let language: String
    let theme: MessagesTheme
    let variant: PreviewVariant
    let presenter: MessagePresenter

    public init(campaign: Campaign, language: String, theme: MessagesTheme = .default, variant: PreviewVariant = .init(), presenter: MessagePresenter = Messages.presenter) {
        self.campaign = campaign; self.language = language; self.theme = theme
        self.variant = variant; self.presenter = presenter
    }

    private var blocks: [Block] { campaign.blocks(for: language) }
    private var dismissible: Bool { variant.dismissible ?? campaign.dismissible }

    public var body: some View {
        surface
            .environment(\.messagesTheme, theme)
            .environment(\.messageLanguage, language)
            .environment(\.locale, Locale(identifier: language))
            .environment(\.messageActionHandler, MessageActionHandler { [presenter, campaign, language] in
                presenter.recordTestAction($0, campaign: campaign, language: language)
            })
            .modifier(OptionalDynamicType(size: variant.dynamicTypeSize))
            .modifier(OptionalColorScheme(scheme: variant.colorScheme))
    }

    private func close() {
        presenter.recordTestAction(.dismiss, campaign: campaign, language: language)
    }

    @ViewBuilder private var surface: some View {
        let p = campaign.presentation
        switch p.style {
        case .alert:
            ZStack {
                Color.black.opacity(0.3)
                AlertCard(blocks: blocks, dismissible: dismissible, onClose: close).padding(20)
            }
        case .banner:
            BannerCard(blocks: blocks, presentation: p, dismissible: dismissible,
                       onTap: { presenter.recordTestAction($0, campaign: campaign, language: language) },
                       onClose: { _ in close() })
                .padding(.horizontal, 12)
                .padding(.vertical, p.position == .top ? 54 : 90)
                .frame(maxHeight: .infinity, alignment: p.position == .top ? .top : .bottom)
        case .toast:
            ToastCapsule(blocks: blocks) { presenter.recordTestAction($0, campaign: campaign, language: language) }
                .padding(.horizontal, 16)
                .padding(.vertical, p.position == .top ? 54 : 90)
                .frame(maxHeight: .infinity, alignment: p.position == .top ? .top : .bottom)
        case .sheet:
            InlineSheet(blocks: blocks, detent: p.detents.first ?? .large, dismissible: dismissible, onClose: close)
        case .fullscreen:
            FullscreenMessageContent(blocks: blocks, dismissible: dismissible, onClose: close)
        }
    }
}

/// Un sheet dibujado en su sitio (el de verdad lo presenta el sistema con "Mostrar aquí").
struct InlineSheet: View {
    let blocks: [Block]
    let detent: Presentation.Detent
    let dismissible: Bool
    let onClose: () -> Void
    @State private var contentHeight: CGFloat = 300

    var body: some View {
        GeometryReader { geo in
            let maxHeight = geo.size.height - 56
            let height: CGFloat = switch detent {
            case .medium: geo.size.height * 0.5
            case .large: maxHeight
            case .fitted: min(contentHeight + 20, maxHeight)
            case .fraction(let f): min(geo.size.height * f, maxHeight)
            case .height(let h): min(h, maxHeight)
            }
            let shape = UnevenRoundedRectangle(topLeadingRadius: 38, topTrailingRadius: 38, style: .continuous)
            ZStack(alignment: .bottom) {
                Color.black.opacity(detent == .large ? 0.25 : 0.12)
                    .onTapGesture { if dismissible { onClose() } }
                SheetMessageContent(blocks: blocks, dismissible: dismissible, onClose: onClose, onHeight: { contentHeight = $0 })
                    .overlay(alignment: .top) {
                        if dismissible {
                            Capsule().fill(.tertiary).frame(width: 36, height: 5).padding(.top, 6)
                        }
                    }
                    .frame(height: height)
                    .frame(maxWidth: .infinity)
                    .background(.background, in: shape)
                    .clipShape(shape)
            }
        }
    }
}

/// Un bloque suelto, con el tema de la app, como se verá dentro de un mensaje.
public struct MessageBlockPreview: View {
    let block: Block
    let style: Presentation.Style
    let language: String
    let theme: MessagesTheme
    let presenter: MessagePresenter

    public init(block: Block, style: Presentation.Style = .sheet, language: String, theme: MessagesTheme = .default, presenter: MessagePresenter = Messages.presenter) {
        self.block = block; self.style = style; self.language = language; self.theme = theme; self.presenter = presenter
    }

    public var body: some View {
        let testCampaign = Campaign(name: "Bloque", defaultLanguage: language)
        // Tarjeta y botones de cristal agrupados: nunca cristal suelto encima de cristal.
        MessageGlassGroup(spacing: 12) {
            BlockView(block: block)
                .padding(20)
                .frame(maxWidth: 360)
                .messageSurface(theme, in: .rect(cornerRadius: theme.cardRadius, style: .continuous))
        }
            .environment(\.messagesTheme, theme)
            .environment(\.messageSurface, MessageSurface(style))
            .environment(\.messageLanguage, language)
            .environment(\.messageActionHandler, MessageActionHandler { [presenter] in
                presenter.recordTestAction($0, campaign: testCampaign, language: language)
            })
    }
}
