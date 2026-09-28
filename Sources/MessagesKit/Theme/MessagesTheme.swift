import SwiftUI

/// El aspecto de los mensajes en una app: colores (por token), tipografía, radios y el
/// tinte del cristal. El cristal en sí es siempre el nativo de Liquid Glass.
public struct MessagesTheme: Sendable {
    /// Token → color. Tokens estándar: `accent`, `primaryText`, `secondaryText`,
    /// `background`, `positive`, `warning`, `danger`.
    public var colors: [String: Color]
    public var fontDesign: Font.Design
    public var cardRadius: CGFloat
    /// `nil` = el radio por defecto de los botones del sistema.
    public var buttonRadius: CGFloat?
    public var imageRadius: CGFloat
    public var glass: ThemeSpec.GlassStyle
    public var glassTint: Color?
    /// Hueco inferior que deja un banner abajo para no tapar la barra de pestañas.
    public var bannerBottomInset: CGFloat

    public init(
        colors: [String: Color] = [:],
        fontDesign: Font.Design = .default,
        cardRadius: CGFloat = 32,
        buttonRadius: CGFloat? = nil,
        imageRadius: CGFloat = 18,
        glass: ThemeSpec.GlassStyle = .regular,
        glassTint: Color? = nil,
        bannerBottomInset: CGFloat = 64
    ) {
        self.colors = MessagesTheme.systemColors.merging(colors) { _, new in new }
        self.fontDesign = fontDesign
        self.cardRadius = cardRadius
        self.buttonRadius = buttonRadius
        self.imageRadius = imageRadius
        self.glass = glass
        self.glassTint = glassTint
        self.bannerBottomInset = bannerBottomInset
    }

    /// El tema desde la configuración del hub (lo usa el admin para la vista previa).
    public init(spec: ThemeSpec) {
        var colors: [String: Color] = [:]
        for (token, pair) in spec.colors {
            if let c = Color(lightHex: pair.light, darkHex: pair.dark) { colors[token] = c }
        }
        self.init(
            colors: colors,
            fontDesign: spec.fontDesign.swiftUI,
            cardRadius: spec.cardRadius,
            buttonRadius: spec.buttonRadius.map { CGFloat($0) },
            imageRadius: spec.imageRadius,
            glass: spec.glass
        )
        if let tint = spec.glassTint {
            glassTint = color(tint).opacity(spec.glassTintOpacity)
        }
    }

    public static let `default` = MessagesTheme()

    static let systemColors: [String: Color] = [
        "accent": .accentColor,
        "primaryText": .primary,
        "secondaryText": .secondary,
        "background": Color(lightHex: "#F2F2F7", darkHex: "#000000")!,
        "positive": .green,
        "warning": .orange,
        "danger": .red,
    ]

    public var accent: Color { color("accent") }

    /// Un token (`accent`) o un hex (`#FF8800`). Lo desconocido cae en `accent`.
    public func color(_ tokenOrHex: String?) -> Color {
        guard let tokenOrHex, !tokenOrHex.isEmpty else { return accent }
        if let c = colors[tokenOrHex] { return c }
        if tokenOrHex.hasPrefix("#"), let c = Color(lightHex: tokenOrHex, darkHex: tokenOrHex) { return c }
        return colors["accent"] ?? .accentColor
    }

    /// El cristal del tema para una superficie (tarjeta, banner, toast).
    func surfaceGlass(interactive: Bool = false) -> Glass {
        var g: Glass = glass == .clear ? .clear : .regular
        if let glassTint { g = g.tint(glassTint) }
        if interactive { g = g.interactive() }
        return g
    }
}

extension ThemeSpec.FontDesign {
    var swiftUI: Font.Design {
        switch self {
        case .default: .default
        case .rounded: .rounded
        case .serif: .serif
        case .monospaced: .monospaced
        }
    }
}

extension EnvironmentValues {
    @Entry public var messagesTheme: MessagesTheme = .default
}

// MARK: - Colores en hex con variante clara y oscura

extension Color {
    /// `#RGB`, `#RRGGBB` o `#RRGGBBAA`, con una variante para el modo oscuro.
    public init?(lightHex: String, darkHex: String) {
        guard let light = RGBA(hex: lightHex), let dark = RGBA(hex: darkHex) else { return nil }
        if light == dark {
            self = Color(.sRGB, red: light.r, green: light.g, blue: light.b, opacity: light.a)
            return
        }
        #if os(iOS)
        self = Color(UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
        #else
        self = Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let c = isDark ? dark : light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        })
        #endif
    }
}

struct RGBA: Equatable {
    var r, g, b, a: Double

    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255; g = Double((v >> 8) & 0xFF) / 255; b = Double(v & 0xFF) / 255; a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255; g = Double((v >> 16) & 0xFF) / 255; b = Double((v >> 8) & 0xFF) / 255; a = Double(v & 0xFF) / 255
        }
    }
}
