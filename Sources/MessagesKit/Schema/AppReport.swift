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

    public init(
        appId: String, bundleId: String, name: String, languages: [String], theme: ThemeSpec,
        routes: [String], actions: [String], screens: [String], events: [String],
        attributes: [AppConfig.Attribute], sdkVersion: String
    ) {
        self.appId = appId; self.bundleId = bundleId; self.name = name; self.languages = languages
        self.theme = theme; self.routes = routes; self.actions = actions; self.screens = screens
        self.events = events; self.attributes = attributes; self.sdkVersion = sdkVersion
    }

    /// Tolerante: lo que falte se queda vacío (y el tema, el de por defecto).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = c.value(.kind, default: "messageskit.appReport")
        appId = c.value(.appId, default: "")
        bundleId = c.value(.bundleId, default: "")
        name = c.value(.name, default: "")
        languages = c.value(.languages, default: [])
        theme = c.value(.theme, default: .init())
        routes = c.value(.routes, default: [])
        actions = c.value(.actions, default: [])
        screens = c.value(.screens, default: [])
        events = c.value(.events, default: [])
        attributes = c.value(.attributes, default: [])
        sdkVersion = c.value(.sdkVersion, default: "")
    }

    /// Lee lo que se pega en el admin: admite espacios alrededor, comillas tipográficas (al pasar
    /// por Notas o un chat) y texto antes o después del JSON. `nil` si no es un informe de app.
    public static func parse(_ text: String) -> AppReport? {
        var t = text
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
        if let start = t.firstIndex(of: "{"), let end = t.lastIndex(of: "}") { t = String(t[start...end]) }
        guard let report = try? JSONDecoder.messages.decode(AppReport.self, from: Data(t.utf8)),
              report.kind == "messageskit.appReport", !report.appId.trimmingCharacters(in: .whitespaces).isEmpty
        else { return nil }
        return report.cleaned()
    }

    /// Nombres limpios: sin espacios sobrantes, vacíos ni repetidos, y de 128 caracteres como
    /// mucho (lo que admite el hub para pantallas y eventos).
    public func cleaned() -> AppReport {
        func names(_ list: [String]) -> [String] {
            var seen = Set<String>()
            return list.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128)) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
        }
        var out = self
        out.appId = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        out.languages = names(languages)
        out.routes = names(routes)
        out.actions = names(actions)
        out.screens = names(screens)
        out.events = names(events)
        var seen = Set<String>()
        out.attributes = attributes.compactMap { a in
            let n = String(a.name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
            guard !n.isEmpty, seen.insert(n).inserted else { return nil }
            return .init(name: n, kind: a.kind, description: a.description)
        }
        return out
    }

    /// Mezcla el informe en una app del admin: añade lo que falte y respeta lo ya escrito
    /// (descripciones, parámetros y el tipo de los atributos que ya estaban). El tema se
    /// sustituye por el de la app.
    public func merged(into app: AppConfig) -> AppConfig {
        let r = cleaned()
        var out = app
        if out.bundleId.isEmpty { out.bundleId = r.bundleId }
        if out.name.isEmpty || out.name == out.appId { out.name = r.name.isEmpty ? out.appId : r.name }
        for l in r.languages where !out.languages.contains(l) { out.languages.append(l) }
        for route in r.routes where out.routes[route] == nil { out.routes[route] = .init() }
        for a in r.actions where out.customActions[a] == nil { out.customActions[a] = .init() }
        out.screens = Array(Set(out.screens).union(r.screens)).sorted()
        out.events = Array(Set(out.events).union(r.events)).sorted()
        for attr in r.attributes where !out.attributes.contains(where: { $0.name == attr.name }) {
            out.attributes.append(attr)
        }
        out.theme = r.theme
        return out
    }

    /// Una app nueva del admin a partir del informe.
    public func makeApp() -> AppConfig {
        let r = cleaned()
        let langs = r.languages.isEmpty ? ["es", "en"] : r.languages
        return r.merged(into: AppConfig(appId: r.appId, name: r.name.isEmpty ? r.appId : r.name, bundleId: r.bundleId,
                                        languages: langs, defaultLanguage: langs.first ?? "es"))
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
