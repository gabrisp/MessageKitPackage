import SwiftUI

// Las cinco presentaciones. Cada componente pinta solo la superficie del mensaje; el
// `messagesLayer` (de verdad) y `MessageInlinePreview` (el marco del admin) los envuelven.

/// Botón de cerrar. No es de cristal porque va encima de una superficie que ya lo es.
struct CloseButton: View {
    let action: () -> Void
    @Environment(\.messageLanguage) private var language

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(.fill.tertiary, in: .circle)
                // Se ve de 30 pt pero se toca como uno de 44.
                .contentShape(Circle().inset(by: -7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L.string("Cerrar", "Close", language: language))
    }
}

// MARK: - Alert

/// Tarjeta de cristal centrada, como el aviso de regalos de ReWearly.
struct AlertCard: View {
    let blocks: [Block]
    let dismissible: Bool
    let onClose: () -> Void
    @Environment(\.messagesTheme) private var theme

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            ViewThatFits(in: .vertical) {
                content
                ScrollView { content }.scrollBounceBehavior(.basedOnSize)
            }
            .frame(maxWidth: 340)
            .overlay(alignment: .topTrailing) {
                if dismissible { CloseButton(action: onClose).padding(14) }
            }
            .glassEffect(theme.surfaceGlass(), in: .rect(cornerRadius: theme.cardRadius, style: .continuous))
        }
        .environment(\.messageSurface, .alert)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var content: some View {
        BlocksView(blocks, spacing: 12)
            .padding(.horizontal, 24)
            .padding(.top, dismissible ? 30 : 24)
            .padding(.bottom, 22)
    }
}

// MARK: - Banner y toast (compactos)

/// Lo que se saca de los bloques para una presentación compacta.
struct CompactParts {
    var icon: Block.Icon?
    var title: String?
    var body: String?
    var button: Block.Button?

    init(_ blocks: [Block]) {
        for b in blocks {
            switch b.kind {
            case .icon(let i) where icon == nil: icon = i
            case .heading(let h) where title == nil: title = h.text
            case .text(let t):
                if title == nil { title = t.text } else if body == nil { body = t.text }
            case .button(let btn) where button == nil: button = btn
            case .buttonRow(let row) where button == nil: button = row.buttons.first
            default: break
            }
        }
    }
}

struct BannerCard: View {
    let blocks: [Block]
    let presentation: Presentation
    let dismissible: Bool
    let onTap: (MessageAction) -> Void
    let onClose: (DismissReason) -> Void
    @Environment(\.messagesTheme) private var theme
    @State private var drag: CGFloat = 0

    var body: some View {
        let parts = CompactParts(blocks)
        let tapAction = presentation.tapAction ?? parts.button?.action
        HStack(alignment: .center, spacing: 12) {
            if let icon = parts.icon {
                Image(systemName: icon.symbol)
                    .font(.system(size: min(icon.size, 30), weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.color(icon.tint))
                    .frame(width: 36)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                if let title = parts.title {
                    MarkdownText(title).font(.subheadline.weight(.semibold)).foregroundStyle(theme.color("primaryText"))
                }
                if let body = parts.body {
                    MarkdownText(body).font(.footnote).foregroundStyle(theme.color("secondaryText"))
                }
                if let button = parts.button {
                    Text(button.title).font(.footnote.weight(.semibold)).foregroundStyle(theme.accent).padding(.top, 2)
                }
            }
            .fontDesign(theme.fontDesign)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            if dismissible {
                CloseButton { onClose(.closeButton) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: 520)
        .contentShape(.rect(cornerRadius: 26))
        .glassEffect(theme.surfaceGlass(interactive: tapAction != nil), in: .rect(cornerRadius: 26, style: .continuous))
        .offset(y: drag)
        .onTapGesture { if let tapAction { onTap(tapAction) } }
        .gesture(dismissible ? swipe : nil)
        .environment(\.messageSurface, .banner)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(tapAction != nil ? .isButton : [])
        .accessibilityAction { if let tapAction { onTap(tapAction) } }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { v in
                let dy = v.translation.height
                // Solo hacia fuera de la pantalla; hacia dentro, con resistencia.
                drag = presentation.position == .top ? (dy < 0 ? dy : dy / 6) : (dy > 0 ? dy : dy / 6)
            }
            .onEnded { v in
                let out = presentation.position == .top ? v.translation.height < -40 : v.translation.height > 40
                if out { onClose(.gesture) } else { withAnimation(.spring) { drag = 0 } }
            }
    }
}

struct ToastCapsule: View {
    let blocks: [Block]
    let onAction: (MessageAction) -> Void
    @Environment(\.messagesTheme) private var theme

    var body: some View {
        let parts = CompactParts(blocks)
        HStack(spacing: 10) {
            if let icon = parts.icon {
                Image(systemName: icon.symbol)
                    .font(.body.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(theme.color(icon.tint))
                    .accessibilityHidden(true)
            }
            if let title = parts.title {
                MarkdownText(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(theme.color("primaryText"))
                    .lineLimit(2)
            }
            if let button = parts.button {
                Button { onAction(button.action) } label: {
                    // Área de toque más grande que el texto, sin agrandar la cápsula.
                    Text(button.title).contentShape(Rectangle().inset(by: -10))
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.accent)
                .buttonStyle(.plain)
            }
        }
        .fontDesign(theme.fontDesign)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(theme.surfaceGlass(), in: .capsule)
        .environment(\.messageSurface, .toast)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Sheet

/// El contenido de la hoja del sistema, construido con bloques.
struct SheetMessageContent: View {
    let blocks: [Block]
    let dismissible: Bool
    let onClose: () -> Void
    /// Alto del contenido, para el detent `fitted`.
    var onHeight: ((CGFloat) -> Void)?

    var body: some View {
        ScrollView {
            BlocksView(blocks)
                .padding(.horizontal, 24)
                .padding(.top, dismissible ? 52 : 32)
                .padding(.bottom, 24)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeight?($0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .overlay(alignment: .topTrailing) {
            if dismissible { CloseButton(action: onClose).padding(16) }
        }
        .environment(\.messageSurface, .sheet)
    }
}

// MARK: - Pantalla completa

struct FullscreenMessageContent: View {
    let blocks: [Block]
    let dismissible: Bool
    let onClose: () -> Void
    @Environment(\.messagesTheme) private var theme

    var body: some View {
        let hero: Block.Image? = if case .image(let img) = blocks.first?.kind { img } else { nil }
        let rest = hero == nil ? blocks : Array(blocks.dropFirst())
        ScrollView {
            VStack(spacing: 0) {
                if let hero {
                    // La imagen de cabecera llega hasta los bordes y se extiende bajo la zona segura.
                    Color.clear
                        .aspectRatio(hero.aspectRatio ?? 1.2, contentMode: .fit)
                        .overlay {
                            AsyncImage(url: URL(string: hero.url)) { img in
                                img.resizable().aspectRatio(contentMode: .fill)
                            } placeholder: {
                                Rectangle().fill(.quaternary)
                            }
                        }
                        .clipped()
                        .backgroundExtensionEffect()
                        .accessibilityLabel(hero.alt ?? "")
                        .accessibilityHidden(hero.alt == nil)
                }
                BlocksView(rest, spacing: 16)
                    .padding(.horizontal, 28)
                    .padding(.top, hero == nil ? 72 : 28)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 560)
            }
            .frame(maxWidth: .infinity)
        }
        .ignoresSafeArea(edges: hero == nil ? [] : .top)
        .scrollBounceBehavior(.basedOnSize)
        .scrollEdgeEffectStyle(.soft, for: .all)
        .background(theme.color("background").ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            if dismissible {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.body.weight(.semibold)).frame(width: 24, height: 24).contentShape(.circle)
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.large)
                .padding(16)
                .accessibilityLabel(L.string("Cerrar", "Close"))
            }
        }
        .environment(\.messageSurface, .fullscreen)
    }
}

// MARK: - Aviso del modo prueba

struct TestNoticeView: View {
    let entry: TestActionEntry

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hammer.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(L.string("Modo prueba", "Test mode")).font(.caption2.weight(.bold)).foregroundStyle(.secondary).textCase(.uppercase)
                Text(entry.description).font(.footnote.weight(.medium)).lineLimit(3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 460)
        .glassEffect(.regular, in: .rect(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Entorno de un mensaje

extension View {
    /// Aplica tema, idioma, variantes y el manejador de acciones de un mensaje.
    func messageEnvironment(_ request: MessageRequest, theme: MessagesTheme, handler: MessageActionHandler) -> some View {
        self
            .environment(\.messagesTheme, request.theme ?? theme)
            .environment(\.messageLanguage, request.language)
            .environment(\.messageActionHandler, handler)
            .environment(\.locale, Locale(identifier: request.language))
            .modifier(OptionalDynamicType(size: request.variant.dynamicTypeSize))
    }
}

struct OptionalDynamicType: ViewModifier {
    let size: DynamicTypeSize?
    func body(content: Content) -> some View {
        if let size { content.dynamicTypeSize(size) } else { content }
    }
}

struct OptionalColorScheme: ViewModifier {
    let scheme: ColorScheme?
    /// `true` en hojas y pantallas completas: cambia también la presentación.
    var preferred = false
    func body(content: Content) -> some View {
        if let scheme {
            if preferred { content.preferredColorScheme(scheme) } else { content.environment(\.colorScheme, scheme) }
        } else {
            content
        }
    }
}
