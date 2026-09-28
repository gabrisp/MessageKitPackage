import SwiftUI

/// Lo que una app usa de verdad (tema, rutas, acciones, pantallas, eventos y atributos), para
/// pegarlo en el admin (Apps → Importar desde la app) y no tener que declararlo a mano.
/// Sale de `Messages.appReport()` o del botón de `MessagesDebugView`. No viaja al hub solo.
public struct AppReport: Sendable, Hashable, Codable {
    public var kind = "messageskit.appReport"
    public var appId: String
    public var bundleId: String
    public var name: String
    public var languages: [String]
    public var theme: ThemeSpec
    public var routes: [String]
    public var actions: [String]
    public var screens: [String]
    public var events: [String]
    /// Atributos propios (sin los de serie), con el tipo deducido de su valor actual.
    public var attributes: [AppConfig.Attribute]
    public var sdkVersion: String

    /// Mezcla el informe en una app del admin: añade lo que falte y respeta lo ya escrito
    /// (descripciones, parámetros). El tema se sustituye por el de la app.
    public func merged(into app: AppConfig) -> AppConfig {
        var out = app
        if out.bundleId.isEmpty { out.bundleId = bundleId }
        if out.name.isEmpty || out.name == out.appId { out.name = name }
        for l in languages where !out.languages.contains(l) { out.languages.append(l) }
        for r in routes where out.routes[r] == nil { out.routes[r] = .init() }
        for a in actions where out.customActions[a] == nil { out.customActions[a] = .init() }
        out.screens = Array(Set(out.screens).union(screens)).sorted()
        out.events = Array(Set(out.events).union(events)).sorted()
        for attr in attributes where !out.attributes.contains(where: { $0.name == attr.name }) {
            out.attributes.append(attr)
        }
        out.theme = theme
        return out
    }

    /// Una app nueva del admin a partir del informe.
    public func makeApp() -> AppConfig {
        merged(into: AppConfig(appId: appId, name: name, bundleId: bundleId, languages: languages, defaultLanguage: languages.first ?? "es"))
    }
}

extension AppConfig.Attribute.Kind {
    /// El tipo que se deduce de un valor.
    static func inferred(from value: JSONValue) -> Self {
        switch value {
        case .bool: return .bool
        case .number: return .number
        case .array: return .list
        case .string(let s):
            if s.range(of: #"^\d+(\.\d+)+$"#, options: .regularExpression) != nil { return .version }
            if ISO8601.date(from: s) != nil { return .date }
            return .string
        default: return .string
        }
    }
}

// MARK: - Tema → JSON

extension ThemeSpec {
    /// El tema de una app convertido a colores hex (claro y oscuro), para el admin.
    @MainActor
    public init(theme: MessagesTheme) {
        var colors: [String: ColorPair] = [:]
        for (token, color) in theme.colors {
            colors[token] = ColorPair(color.hex(for: .light), color.hex(for: .dark))
        }
        var tint: String?
        var tintOpacity = 0.15
        if let glassTint = theme.glassTint {
            tint = glassTint.hex(for: .light, includeAlpha: false)
            tintOpacity = glassTint.alpha(for: .light)
        }
        self.init(
            colors: colors,
            fontDesign: FontDesign(theme.fontDesign),
            cardRadius: theme.cardRadius,
            buttonRadius: theme.buttonRadius.map(Double.init),
            imageRadius: theme.imageRadius,
            glass: theme.glass,
            glassTint: tint,
            glassTintOpacity: tintOpacity
        )
    }
}

extension ThemeSpec.FontDesign {
    init(_ design: Font.Design) {
        switch design {
        case .rounded: self = .rounded
        case .serif: self = .serif
        case .monospaced: self = .monospaced
        default: self = .default
        }
    }
}

extension Color {
    @MainActor
    func resolved(for scheme: ColorScheme) -> Color.Resolved {
        var env = EnvironmentValues()
        env.colorScheme = scheme
        return resolve(in: env)
    }

    @MainActor
    func hex(for scheme: ColorScheme, includeAlpha: Bool = true) -> String {
        let r = resolved(for: scheme)
        func c(_ v: Float) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        let base = String(format: "#%02X%02X%02X", c(r.red), c(r.green), c(r.blue))
        return includeAlpha && r.opacity < 0.999 ? base + String(format: "%02X", c(r.opacity)) : base
    }

    @MainActor
    func alpha(for scheme: ColorScheme) -> Double { Double(resolved(for: scheme).opacity) }
}
