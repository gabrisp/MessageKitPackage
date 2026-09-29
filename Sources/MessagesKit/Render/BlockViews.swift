import SwiftUI
import WebKit

// MARK: - Contexto de pintado

/// Quién ejecuta las acciones de los botones. Es una clase para que su identidad sea
/// estable en el entorno (no se guarda un cierre suelto).
@MainActor
public final class MessageActionHandler {
    let perform: @MainActor (MessageAction) -> Void
    /// Si el mensaje tiene una acción en marcha (una compra…): sus botones no responden.
    /// Se lee desde el presentador (observable), así que la vista se actualiza sola.
    let busy: @MainActor () -> Bool

    public init(_ perform: @escaping @MainActor (MessageAction) -> Void, busy: @escaping @MainActor () -> Bool = { false }) {
        self.perform = perform
        self.busy = busy
    }

    public func callAsFunction(_ action: MessageAction) { perform(action) }

    @MainActor public var isBusy: Bool { busy() }
}

/// Dónde se está pintando el contenido: cambia la alineación por defecto y el espaciado.
public enum MessageSurface: Sendable, Hashable {
    case alert, banner, toast, sheet, fullscreen, inline

    init(_ style: Presentation.Style) {
        switch style {
        case .alert: self = .alert
        case .banner: self = .banner
        case .toast: self = .toast
        case .sheet: self = .sheet
        case .fullscreen: self = .fullscreen
        }
    }

    var defaultAlignment: Block.Alignment { self == .alert ? .center : .leading }
}

extension EnvironmentValues {
    @Entry public var messageActionHandler: MessageActionHandler? = nil
    @Entry public var messageSurface: MessageSurface = .inline
    /// Idioma del mensaje (para los textos del propio paquete: "Cerrar", la cuenta atrás…).
    @Entry public var messageLanguage: String = L.current
    /// En el editor: el bloque seleccionado se resalta.
    @Entry public var messageSelectedBlockId: String? = nil
}

extension Block.Alignment {
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var text: TextAlignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    var frame: Alignment {
        switch self {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

// MARK: - Lista de bloques

/// Pinta una lista de bloques con el tema de la app. Lo desconocido no se pinta.
public struct BlocksView: View {
    let blocks: [Block]
    var spacing: CGFloat

    public init(_ blocks: [Block], spacing: CGFloat = 14) {
        self.blocks = blocks
        self.spacing = spacing
    }

    public var body: some View {
        VStack(spacing: spacing) {
            ForEach(blocks) { block in
                // Un bloque que entra, sale o cambia de tipo: con desenfoque, no de golpe.
                BlockView(block: block)
                    .transition(.blurReplace)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.smooth(duration: 0.35), value: blocks)
    }
}

/// Un bloque suelto.
public struct BlockView: View {
    public let block: Block
    @Environment(\.messageSelectedBlockId) private var selectedId
    @Environment(\.messagesTheme) private var theme

    public init(block: Block) { self.block = block }

    public var body: some View {
        content
            .overlay {
                if selectedId == block.id {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(-6)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch block.kind {
        case .heading(let b): HeadingBlockView(block: b)
        case .text(let b): TextBlockView(block: b)
        case .image(let b): ImageBlockView(block: b)
        case .icon(let b): IconBlockView(block: b)
        case .list(let b): ListBlockView(block: b)
        case .stat(let b): StatBlockView(block: b)
        case .badge(let b): BadgeBlockView(block: b)
        case .spacer(let b): Color.clear.frame(height: b.height).accessibilityHidden(true)
        case .divider: Divider()
        case .button(let b): MessageButton(button: b)
        case .buttonRow(let b): ButtonRowView(row: b)
        case .countdown(let b): CountdownBlockView(block: b)
        case .web(let b): WebBlockView(block: b)
        case .unknown: EmptyView()
        }
    }
}

// MARK: - Texto

struct HeadingBlockView: View {
    let block: Block.Heading
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageSurface) private var surface

    var body: some View {
        let align = block.align ?? surface.defaultAlignment
        MarkdownText(block.text)
            .font(block.size == .large ? .title.bold() : .title3.bold())
            .fontDesign(theme.fontDesign)
            .foregroundStyle(theme.color("primaryText"))
            .multilineTextAlignment(align.text)
            .frame(maxWidth: .infinity, alignment: align.frame)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

struct TextBlockView: View {
    let block: Block.Text
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageSurface) private var surface

    var body: some View {
        let align = block.align ?? surface.defaultAlignment
        MarkdownText(block.text)
            .font(block.style == .caption ? .footnote : .body)
            .fontDesign(theme.fontDesign)
            .foregroundStyle(theme.color(block.style == .body ? "primaryText" : "secondaryText"))
            .multilineTextAlignment(align.text)
            .frame(maxWidth: .infinity, alignment: align.frame)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Markdown ligero (negrita, cursiva, enlaces). Los enlaces pasan por la acción `openURL`
/// del mensaje, así cuentan como pulsación y respetan el modo prueba.
struct MarkdownText: View {
    let source: String
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageActionHandler) private var handler

    init(_ source: String) { self.source = source }

    var body: some View {
        Text(attributed)
            // Al actualizarse (campaña editada con el mensaje en pantalla), el texto cambia letra a letra.
            .contentTransition(.numericText())
            .tint(theme.accent)
            .environment(\.openURL, OpenURLAction { url in
                handler?(MessageAction(.openURL(url: url.absoluteString, inApp: true), thenDismiss: false, trackAs: "link"))
                return .handled
            })
    }

    private var attributed: AttributedString {
        (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(source)
    }
}

// MARK: - Imagen e icono

struct ImageBlockView: View {
    let block: Block.Image
    @Environment(\.messagesTheme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: block.corner.map { CGFloat($0) } ?? theme.imageRadius, style: .continuous)
        Group {
            if let ratio = block.aspectRatio, ratio > 0 {
                Color.clear
                    .aspectRatio(ratio, contentMode: .fit)
                    .overlay { image }
            } else {
                image
            }
        }
        .frame(maxWidth: .infinity)
        .clipShape(shape)
        .accessibilityElement()
        .accessibilityLabel(block.alt ?? "")
        .accessibilityHidden(block.alt == nil)
        .accessibilityAddTraits(.isImage)
    }

    private var image: some View {
        AsyncImage(url: URL(string: block.url), transaction: .init(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: block.contentMode == .fill ? .fill : .fit)
            case .failure:
                placeholder(symbol: "photo")
            default:
                placeholder(symbol: nil)
            }
        }
    }

    private func placeholder(symbol: String?) -> some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                if let symbol {
                    Image(systemName: symbol).font(.title).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .frame(minHeight: block.aspectRatio == nil ? 160 : nil)
    }
}

struct IconBlockView: View {
    let block: Block.Icon
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageSurface) private var surface

    var body: some View {
        Image(systemName: block.symbol)
            .font(.system(size: block.size, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(theme.color(block.tint))
            .frame(maxWidth: .infinity, alignment: surface.defaultAlignment.frame)
            .accessibilityHidden(true)
    }
}

// MARK: - Lista (filas propias, nunca `List`)

struct ListBlockView: View {
    let block: Block.List
    @Environment(\.messagesTheme) private var theme

    var body: some View {
        VStack(spacing: 0) {
            ForEach(block.items) { item in
                ListBlockRow(item: item, tint: theme.color(item.tint ?? block.tint), showsSeparator: item.id != block.items.last?.id)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ListBlockRow: View {
    let item: Block.List.Item
    let tint: Color
    let showsSeparator: Bool
    @Environment(\.messagesTheme) private var theme
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 30

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.body.weight(.semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(width: iconWidth)
                    .accessibilityHidden(true)
            }
            MarkdownText(item.text)
                .font(.body)
                .fontDesign(theme.fontDesign)
                .foregroundStyle(theme.color("primaryText"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1 / 3)
                    .padding(.leading, item.symbol == nil ? 0 : iconWidth + 12)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cifra, pastilla

struct StatBlockView: View {
    let block: Block.Stat
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageSurface) private var surface

    var body: some View {
        let align = surface.defaultAlignment
        VStack(alignment: align.horizontal, spacing: 2) {
            Text(block.value)
                .font(.system(.largeTitle, design: theme.fontDesign == .default ? .rounded : theme.fontDesign, weight: .bold))
                .foregroundStyle(block.tint == nil ? theme.color("primaryText") : theme.color(block.tint))
                .monospacedDigit()
            if let label = block.label {
                Text(label)
                    .font(.subheadline)
                    .fontDesign(theme.fontDesign)
                    .foregroundStyle(theme.color("secondaryText"))
            }
        }
        .frame(maxWidth: .infinity, alignment: align.frame)
        .accessibilityElement(children: .combine)
    }
}

struct BadgeBlockView: View {
    let block: Block.Badge
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageSurface) private var surface

    var body: some View {
        let tint = theme.color(block.tint)
        // Sin cristal: va dentro de una tarjeta que ya es de cristal.
        Text(block.text.uppercased())
            .font(.caption.weight(.bold))
            .fontDesign(theme.fontDesign)
            .tracking(0.6)
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(tint.opacity(0.16), in: .capsule)
            .frame(maxWidth: .infinity, alignment: surface.defaultAlignment.frame)
    }
}

// MARK: - Botones

public struct MessageButton: View {
    let button: Block.Button
    var fillsWidth = true
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageActionHandler) private var handler
    /// Para saber lo claro que es el color del botón en el modo actual (claro u oscuro).
    @Environment(\.self) private var environment
    /// Este botón es el que ha lanzado la acción en marcha (enseña la ruedita).
    @State private var pressed = false

    public init(button: Block.Button, fillsWidth: Bool = true) {
        self.button = button
        self.fillsWidth = fillsWidth
    }

    public var body: some View {
        let busy = handler?.isBusy ?? false
        styled
            .controlSize(.large)
            .fontDesign(theme.fontDesign)
            .buttonBorderShape(theme.buttonRadius.map { .roundedRectangle(radius: $0) } ?? .capsule)
            // Mientras hay algo en marcha no responde, pero sin cambiar de aspecto (nada de gris).
            .allowsHitTesting(!busy)
            .onChange(of: busy) { _, now in if !now { pressed = false } }
    }

    private var label: some View {
        let loading = pressed && (handler?.isBusy ?? false)
        return ZStack {
            Group {
                if let symbol = button.symbol {
                    Label(button.title, systemImage: symbol)
                } else {
                    Text(button.title)
                }
            }
            .contentTransition(.numericText())
            .fontWeight(.semibold)
            // El texto no se quita del todo: así el botón no cambia de tamaño.
            .opacity(loading ? 0 : 1)
            if loading {
                ProgressView()
                    .tint(spinnerTint)
                    .accessibilityLabel(L.string("Cargando", "Loading"))
            }
        }
        .frame(maxWidth: fillsWidth && button.style != .link ? .infinity : nil)
        .contentShape(.rect)
        .animation(.smooth(duration: 0.2), value: loading)
    }

    /// El texto sobre un botón relleno: el token del tema si lo tiene (`onAccent`, `onDanger`); si
    /// no, blanco o negro según lo claro que sea el color en el modo actual (el punto en el que
    /// los dos contrastan igual, según WCAG).
    private func onFill(_ fill: Color, token: String) -> Color {
        if let custom = theme.colors[token] { return custom }
        return Self.prefersDarkText(on: fill.resolve(in: environment)) ? .black : .white
    }

    /// Si sobre ese color se lee mejor el texto negro. Luminancia relativa (sRGB linealizado); el
    /// umbral es más alto que el de WCAG (0,179), que pone negro sobre el azul o el rojo del sistema
    /// donde Apple pone blanco: así azul, rojo, verde, naranja y violetas oscuros llevan blanco, y
    /// amarillos, grises claros y colores pastel, negro.
    static func prefersDarkText(on c: Color.Resolved) -> Bool {
        func linear(_ v: Float) -> Double {
            let x = Double(max(0, min(1, v)))
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(c.red) + 0.7152 * linear(c.green) + 0.0722 * linear(c.blue) > 0.45
    }

    /// El color de la ruedita: el mismo que tendría el texto del botón.
    private var spinnerTint: Color {
        switch button.style {
        case .primary: onFill(theme.accent, token: "onAccent")
        case .destructive: onFill(theme.color("danger"), token: "onDanger")
        case .secondary: theme.color("primaryText")
        case .glass, .link: theme.accent
        }
    }

    private func tap() {
        guard handler?.isBusy != true else { return }
        pressed = true
        handler?(button.action)
    }

    @ViewBuilder private var styled: some View {
        switch button.style {
        // El texto, del color que contrasta con el del botón en este modo (no se deja al sistema:
        // en algunos sitios lo pintaba del propio acento).
        case .primary:
            Button(action: tap) { label.foregroundStyle(onFill(theme.accent, token: "onAccent")) }
                .messageButtonStyle(prominent: true)
                .tint(theme.accent)
        case .destructive:
            Button(action: tap) { label.foregroundStyle(onFill(theme.color("danger"), token: "onDanger")) }
                .messageButtonStyle(prominent: true)
                .tint(theme.color("danger"))
        case .secondary:
            Button(action: tap) { label.foregroundStyle(theme.color("primaryText")) }
                .messageButtonStyle(prominent: false)
        case .glass:
            Button(action: tap) { label.foregroundStyle(theme.accent) }
                .messageButtonStyle(prominent: false)
        case .link:
            Button(action: tap) { label.foregroundStyle(theme.accent) }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
        }
    }
}

struct ButtonRowView: View {
    let row: Block.ButtonRow

    var body: some View {
        MessageGlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(row.buttons) { MessageButton(button: $0) }
            }
        }
    }
}

// MARK: - Cuenta atrás

struct CountdownBlockView: View {
    let block: Block.Countdown
    @Environment(\.messagesTheme) private var theme
    @Environment(\.messageSurface) private var surface
    @Environment(\.messageLanguage) private var language

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = max(0, block.until.timeIntervalSince(context.date))
            VStack(alignment: surface.defaultAlignment.horizontal, spacing: 6) {
                if remaining > 0 {
                    if let label = block.label {
                        Text(label)
                            .font(.subheadline)
                            .foregroundStyle(theme.color("secondaryText"))
                    }
                    HStack(spacing: 8) {
                        let parts = Self.parts(remaining)
                        if parts.days > 0 { unit(parts.days, L.string("d", "d", language: language)) }
                        unit(parts.hours, "h")
                        unit(parts.minutes, "m")
                        unit(parts.seconds, "s")
                    }
                } else {
                    Text(block.expiredText ?? L.string("Ha terminado", "It's over", language: language))
                        .font(.headline)
                        .foregroundStyle(theme.color("secondaryText"))
                }
            }
            .fontDesign(theme.fontDesign)
            .frame(maxWidth: .infinity, alignment: surface.defaultAlignment.frame)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText(remaining))
        }
    }

    private func unit(_ value: Int, _ suffix: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(value, format: .number.precision(.integerLength(2)))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: true))
            Text(suffix)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(theme.color("secondaryText"))
        }
        .foregroundStyle(theme.color("primaryText"))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.fill.tertiary, in: .rect(cornerRadius: 10, style: .continuous))
    }

    static func parts(_ t: TimeInterval) -> (days: Int, hours: Int, minutes: Int, seconds: Int) {
        let s = Int(t)
        return (s / 86400, (s % 86400) / 3600, (s % 3600) / 60, s % 60)
    }

    private func accessibilityText(_ remaining: TimeInterval) -> String {
        guard remaining > 0 else { return block.expiredText ?? L.string("Ha terminado", "It's over", language: language) }
        let duration = Duration.seconds(Int(remaining))
        let formatted = duration.formatted(.units(allowed: [.days, .hours, .minutes], width: .wide))
        return [block.label, formatted].compactMap { $0 }.joined(separator: " ")
    }
}

// MARK: - Web (válvula de escape)

struct WebBlockView: View {
    let block: Block.Web
    @Environment(\.messagesTheme) private var theme

    var body: some View {
        Group {
            if let url = URL(string: block.url), url.scheme == "https" {
                MessageWebView(url: url)
            } else {
                Rectangle().fill(.quaternary)
                    .overlay { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
            }
        }
        .frame(height: block.height)
        .frame(maxWidth: .infinity)
        .clipShape(.rect(cornerRadius: theme.imageRadius, style: .continuous))
    }
}
