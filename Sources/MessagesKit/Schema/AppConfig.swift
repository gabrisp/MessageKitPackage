import Foundation

/// Una app registrada en el hub: qué rutas y acciones sabe hacer, idiomas y su tema.
public struct AppConfig: Sendable, Hashable, Codable, Identifiable {
    /// Un parámetro de una ruta o de una acción propia. La app los declara al registrarlas
    /// (`Messages.register(route:params:)`) y el admin enseña el control adecuado para cada uno.
    public struct Param: Sendable, Hashable, Codable, Identifiable {
        public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
            /// Texto libre.
            case string
            /// Número.
            case number
            /// Sí/No (llega como "true" / "false").
            case bool
            /// Uno de `options`.
            case options
        }

        public var name: String
        public var kind: Kind
        public var required: Bool
        /// Valores permitidos (solo `options`).
        public var options: [String]
        public var description: String?
        public var id: String { name }

        public init(name: String, kind: Kind = .string, required: Bool = false, options: [String] = [], description: String? = nil) {
            self.name = name
            self.kind = options.isEmpty ? kind : .options
            self.required = required
            self.options = options
            self.description = description
        }

        /// `.init("id", required: true)`, `.init("tab", options: ["info", "series"])`, `.init("autoplay", kind: .bool)`.
        public init(_ name: String, kind: Kind = .string, required: Bool = false, options: [String] = [], description: String? = nil) {
            self.init(name: name, kind: kind, required: required, options: options, description: description)
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            options = c.value(.options, default: [])
            kind = options.isEmpty ? c.value(.kind, default: .string) : .options
            required = c.value(.required, default: false)
            description = c.optional(.description)
        }

        /// Completa lo que falte con lo que declara la app (tipo, valores, obligatorio), sin
        /// pisar la descripción que se haya escrito en el admin.
        func filled(from other: Param) -> Param {
            var out = self
            if out.kind == .string && out.options.isEmpty { out.kind = other.kind; out.options = other.options }
            if !out.required { out.required = other.required }
            if out.description == nil { out.description = other.description }
            return out
        }
    }

    /// Un atributo propio de la app para las reglas de audiencia (`garmentCount`, `followers`…).
    /// Solo sirve al admin para ofrecerlo en el constructor de reglas con el control adecuado;
    /// la app lo manda en `attributes` y el hub lo evalúa sin necesitar esta declaración.
    public struct Attribute: Sendable, Hashable, Codable, Identifiable {
        public enum Kind: String, Sendable, Hashable, Codable, CaseIterable {
            case bool, number, string, version, date, list
        }

        public var name: String
        public var kind: Kind
        public var description: String?
        public var id: String { name }

        public init(name: String, kind: Kind = .string, description: String? = nil) {
            self.name = name; self.kind = kind; self.description = description
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            kind = c.value(.kind, default: .string)
            description = c.optional(.description)
        }

        /// Los que manda MessagesKit en todas las apps.
        public static let builtIn: [Attribute] = [
            .init(name: "isPro", kind: .bool, description: "Suscripción activa (lo manda la app)"),
            .init(name: "language", kind: .string, description: "Idioma del usuario (es, en…)"),
            .init(name: "country", kind: .string, description: "Región (ES, MX…)"),
            .init(name: "appVersion", kind: .version, description: "Versión de la app"),
            .init(name: "build", kind: .version, description: "Build"),
            .init(name: "platform", kind: .string, description: "ios o macos"),
            .init(name: "osVersion", kind: .version, description: "Versión del sistema"),
            .init(name: "installDate", kind: .date, description: "Primera vez que se abrió"),
            .init(name: "daysSinceInstall", kind: .number, description: "Días desde la instalación"),
            .init(name: "pushAuthorized", kind: .bool, description: "Avisos permitidos"),
            .init(name: "onboardingCompleted", kind: .bool, description: "Onboarding terminado (lo manda la app)"),
            .init(name: "timezone", kind: .string, description: "Zona horaria (Europe/Madrid…)"),
        ]
    }

    /// Una ruta (pantalla u hoja propia de la app) o una acción propia.
    public struct Capability: Sendable, Hashable, Codable {
        public var description: String?
        public var params: [Param]

        public init(description: String? = nil, params: [Param] = []) {
            self.description = description; self.params = params
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            description = c.optional(.description)
            params = c.value(.params, default: [])
        }
    }

    public var appId: String
    public var name: String
    public var bundleId: String
    public var languages: [String]
    public var defaultLanguage: String
    public var routes: [String: Capability]
    public var customActions: [String: Capability]
    /// Pantallas marcadas con `.messagePlacement(_:)`, para los menús del admin.
    public var screens: [String]
    /// Eventos que manda la app, para los menús del admin.
    public var events: [String]
    /// Atributos propios de la app para las reglas de audiencia (los de serie no hace falta).
    public var attributes: [Attribute]
    public var theme: ThemeSpec
    /// Máximo de mensajes al día por usuario (todas las campañas). 0 = sin tope.
    public var dailyCap: Int
    /// Silencio tras la instalación, en horas.
    public var quietHoursAfterInstall: Double
    /// Además, nada hasta que la app mande `onboardingCompleted: true` en sus atributos.
    public var quietUntilOnboarding: Bool
    public var publicKey: String
    /// Proyecto de PostHog para el enlace de Resultados (opcional).
    public var posthogURL: String?

    public var id: String { appId }

    public init(
        appId: String, name: String, bundleId: String = "", languages: [String] = ["es", "en"],
        defaultLanguage: String = "es", routes: [String: Capability] = [:], customActions: [String: Capability] = [:],
        screens: [String] = [], events: [String] = [], attributes: [Attribute] = [], theme: ThemeSpec = .init(), dailyCap: Int = 2,
        quietHoursAfterInstall: Double = 0, quietUntilOnboarding: Bool = false, publicKey: String = AppConfig.newPublicKey(),
        posthogURL: String? = nil
    ) {
        self.appId = appId; self.name = name; self.bundleId = bundleId; self.languages = languages
        self.defaultLanguage = defaultLanguage; self.routes = routes; self.customActions = customActions
        self.screens = screens; self.events = events; self.attributes = attributes; self.theme = theme; self.dailyCap = dailyCap
        self.quietHoursAfterInstall = quietHoursAfterInstall; self.quietUntilOnboarding = quietUntilOnboarding
        self.publicKey = publicKey; self.posthogURL = posthogURL
    }

    public static func newPublicKey() -> String {
        "pk_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appId = try c.decode(String.self, forKey: .appId)
        name = c.value(.name, default: appId)
        bundleId = c.value(.bundleId, default: "")
        languages = c.value(.languages, default: ["es", "en"])
        defaultLanguage = c.value(.defaultLanguage, default: "es")
        routes = c.value(.routes, default: [:])
        customActions = c.value(.customActions, default: [:])
        screens = c.value(.screens, default: [])
        events = c.value(.events, default: [])
        attributes = c.value(.attributes, default: [])
        theme = c.value(.theme, default: .init())
        dailyCap = c.value(.dailyCap, default: 2)
        quietHoursAfterInstall = c.value(.quietHoursAfterInstall, default: 0)
        quietUntilOnboarding = c.value(.quietUntilOnboarding, default: false)
        publicKey = c.value(.publicKey, default: "")
        posthogURL = c.optional(.posthogURL)
    }
}

/// El tema de una app en JSON (lo guarda el hub en `apps.theme` y lo usa el admin
/// para que la vista previa se vea como en la app). En la app real se pasa un
/// `MessagesTheme` directamente.
public struct ThemeSpec: Sendable, Hashable, Codable {
    /// Un color con variante clara y oscura, en hex (`#RRGGBB` o `#RRGGBBAA`).
    public struct ColorPair: Sendable, Hashable, Codable {
        public var light: String
        public var dark: String

        public init(_ light: String, _ dark: String? = nil) {
            self.light = light; self.dark = dark ?? light
        }

        public init(from decoder: Decoder) throws {
            if let single = try? decoder.singleValueContainer().decode(String.self) {
                light = single; dark = single; return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            light = try c.decode(String.self, forKey: .light)
            dark = c.value(.dark, default: light)
        }
    }

    public enum FontDesign: String, Sendable, Hashable, Codable, CaseIterable {
        case `default`, rounded, serif, monospaced
    }

    public enum GlassStyle: String, Sendable, Hashable, Codable, CaseIterable {
        case regular, clear
    }

    /// Token → color. Tokens estándar: `accent`, `primaryText`, `secondaryText`,
    /// `background`, `positive`, `warning`, `danger`. Se pueden añadir los propios.
    public var colors: [String: ColorPair]
    public var fontDesign: FontDesign
    public var cardRadius: Double
    public var buttonRadius: Double?
    public var imageRadius: Double
    public var glass: GlassStyle
    /// Token o hex para teñir el cristal. `nil` = sin tinte.
    public var glassTint: String?
    public var glassTintOpacity: Double

    public init(
        colors: [String: ColorPair] = ThemeSpec.defaultColors, fontDesign: FontDesign = .default,
        cardRadius: Double = 32, buttonRadius: Double? = nil, imageRadius: Double = 18,
        glass: GlassStyle = .regular, glassTint: String? = nil, glassTintOpacity: Double = 0.15
    ) {
        self.colors = colors; self.fontDesign = fontDesign; self.cardRadius = cardRadius
        self.buttonRadius = buttonRadius; self.imageRadius = imageRadius; self.glass = glass
        self.glassTint = glassTint; self.glassTintOpacity = glassTintOpacity
    }

    public static let defaultColors: [String: ColorPair] = [
        "accent": .init("#0A84FF"),
        "primaryText": .init("#000000", "#FFFFFF"),
        "secondaryText": .init("#3C3C4399", "#EBEBF599"),
        "background": .init("#F2F2F7", "#000000"),
        "positive": .init("#34C759", "#30D158"),
        "warning": .init("#FF9500", "#FF9F0A"),
        "danger": .init("#FF3B30", "#FF453A"),
    ]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let custom: [String: ColorPair] = c.value(.colors, default: [:])
        colors = ThemeSpec.defaultColors.merging(custom) { _, new in new }
        fontDesign = c.value(.fontDesign, default: .default)
        cardRadius = c.value(.cardRadius, default: 32)
        buttonRadius = c.optional(.buttonRadius)
        imageRadius = c.value(.imageRadius, default: 18)
        glass = c.value(.glass, default: .regular)
        glassTint = c.optional(.glassTint)
        glassTintOpacity = c.value(.glassTintOpacity, default: 0.15)
    }
}
