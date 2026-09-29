import Foundation

/// Versión del esquema de campaña.
public let messagesSchemaVersion = 1

/// Un mensaje: a qué apps va, a quién, cuándo, cómo se presenta, con qué contenido y acciones.
public struct Campaign: Sendable, Hashable, Codable, Identifiable {
    public enum Status: String, Sendable, Hashable, Codable, CaseIterable {
        case draft, scheduled, live, paused, archived
    }

    public var id: String
    public var name: String
    public var appIds: [String]
    public var status: Status
    /// Más alto sale antes.
    public var priority: Int
    public var presentation: Presentation
    public var dismissible: Bool
    public var defaultLanguage: String
    /// Idioma → bloques.
    public var content: [String: [Block]]
    public var trigger: Trigger
    public var audience: Audience
    public var schedule: Schedule
    public var frequency: Frequency
    public var push: PushSpec?
    public var schemaVersion: Int
    public var createdBy: String?
    /// Carpeta en el admin (p. ej. «Onboarding», «Pro»). Las apps no la usan.
    public var group: String?
    public var updatedAt: Date?
    /// Solo en respuestas del hub: campaña forzada con "Enviar a un usuario"
    /// (se salta audiencia y frecuencia, y sale en el siguiente disparo).
    public var forced: Bool?

    public init(
        id: String = UUID().uuidString.lowercased(),
        name: String,
        appIds: [String] = [],
        status: Status = .draft,
        priority: Int = 0,
        presentation: Presentation = .init(),
        dismissible: Bool = true,
        defaultLanguage: String = "es",
        content: [String: [Block]] = [:],
        trigger: Trigger = .init(),
        audience: Audience = .init(),
        schedule: Schedule = .init(),
        frequency: Frequency = .init(),
        push: PushSpec? = nil,
        schemaVersion: Int = messagesSchemaVersion,
        createdBy: String? = nil,
        updatedAt: Date? = nil,
        forced: Bool? = nil
    ) {
        self.id = id; self.name = name; self.appIds = appIds; self.status = status
        self.priority = priority; self.presentation = presentation; self.dismissible = dismissible
        self.defaultLanguage = defaultLanguage; self.content = content; self.trigger = trigger
        self.audience = audience; self.schedule = schedule; self.frequency = frequency
        self.push = push; self.schemaVersion = schemaVersion; self.createdBy = createdBy
        self.updatedAt = updatedAt; self.forced = forced
    }

    /// Los bloques para un idioma: el pedido, si no el de su prefijo (`es-ES` → `es`),
    /// y si no el idioma por defecto de la campaña.
    public func blocks(for language: String?) -> [Block] {
        content[resolvedLanguage(for: language)] ?? []
    }

    public func resolvedLanguage(for language: String?) -> String {
        if let language {
            if content[language]?.isEmpty == false { return language }
            let prefix = String(language.prefix(while: { $0 != "-" && $0 != "_" }))
            if content[prefix]?.isEmpty == false { return prefix }
        }
        if content[defaultLanguage] != nil { return defaultLanguage }
        return content.keys.sorted().first ?? defaultLanguage
    }

    /// Todas las acciones de la campaña, en todos los idiomas, más la del push.
    public var allActions: [MessageAction] {
        var out = content.values.flatMap { $0.flatMap(\.actions) }
        if let tap = presentation.tapAction { out.append(tap) }
        if let push, let a = push.action { out.append(a) }
        return out
    }

    /// Rutas y acciones propias que la app tiene que saber hacer para mostrar esta campaña.
    public var requiredCapabilities: (routes: Set<String>, actions: Set<String>) {
        var routes = Set<String>(), actions = Set<String>()
        for a in allActions {
            switch a.kind {
            case .route(let name, _): routes.insert(name)
            case .custom(let name, _): actions.insert(name)
            default: break
            }
        }
        return (routes, actions)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case id, name, appIds, status, priority, presentation, dismissible, defaultLanguage, content
        case trigger, audience, schedule, frequency, push, schemaVersion, createdBy, group, updatedAt, forced
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID().uuidString.lowercased())
        name = c.value(.name, default: "")
        appIds = c.value(.appIds, default: [])
        status = c.value(.status, default: .draft)
        priority = c.value(.priority, default: 0)
        presentation = c.value(.presentation, default: .init())
        dismissible = c.value(.dismissible, default: true)
        defaultLanguage = c.value(.defaultLanguage, default: "es")
        let raw: [String: LossyBlocks] = c.value(.content, default: [:])
        content = raw.mapValues(\.blocks)
        trigger = c.value(.trigger, default: .init())
        audience = c.value(.audience, default: .init())
        schedule = c.value(.schedule, default: .init())
        frequency = c.value(.frequency, default: .init())
        push = c.optional(.push)
        schemaVersion = c.value(.schemaVersion, default: messagesSchemaVersion)
        createdBy = c.optional(.createdBy)
        group = (c.optional(.group) as String?).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        updatedAt = c.optional(.updatedAt)
        forced = c.optional(.forced)
    }
}

// MARK: - Presentación

public struct Presentation: Sendable, Hashable, Codable {
    public enum Style: String, Sendable, Hashable, Codable, CaseIterable {
        case alert, banner, toast, sheet, fullscreen
    }

    /// Alturas de un `sheet`: las del sistema (`medium`, `large`) y las propias (`fitted`
    /// mide el contenido, `fraction` es una fracción de la pantalla, `height` son puntos).
    /// En JSON: `"medium"`, `"large"`, `"fitted"`, `{ "fraction": 0.4 }`, `{ "height": 320 }`.
    public enum Detent: Sendable, Hashable, Codable {
        case medium, large, fitted
        case fraction(Double)
        case height(Double)

        private enum CodingKeys: String, CodingKey { case fraction, height }

        public init(from decoder: Decoder) throws {
            if let s = try? decoder.singleValueContainer().decode(String.self) {
                switch s {
                case "medium": self = .medium
                case "large": self = .large
                case "fitted": self = .fitted
                default: throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Detent desconocido: \(s)"))
                }
                return
            }
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let f = try c.decodeIfPresent(Double.self, forKey: .fraction), f > 0 { self = .fraction(min(f, 1)) }
            else if let h = try c.decodeIfPresent(Double.self, forKey: .height), h > 0 { self = .height(h) }
            else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Detent sin valor")) }
        }

        public func encode(to encoder: Encoder) throws {
            switch self {
            case .medium: var c = encoder.singleValueContainer(); try c.encode("medium")
            case .large: var c = encoder.singleValueContainer(); try c.encode("large")
            case .fitted: var c = encoder.singleValueContainer(); try c.encode("fitted")
            case .fraction(let f): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(f, forKey: .fraction)
            case .height(let h): var c = encoder.container(keyedBy: CodingKeys.self); try c.encode(h, forKey: .height)
            }
        }
    }

    public enum Position: String, Sendable, Hashable, Codable, CaseIterable {
        case top, bottom
    }

    public var style: Style
    /// Solo `sheet`. El primero es la altura con la que se abre.
    public var detents: [Detent]
    /// Solo `banner` y `toast`.
    public var position: Position
    /// Solo `banner` y `toast`: se cierra solo tras estos segundos. `nil` en banner = no se cierra solo.
    public var autoDismissSeconds: Double?
    /// Solo `banner` (y `toast` con botón): acción al tocarlo. Si falta, la del primer botón.
    public var tapAction: MessageAction?

    public init(
        style: Style = .alert,
        detents: [Detent] = [.medium, .large],
        position: Position = .top,
        autoDismissSeconds: Double? = nil,
        tapAction: MessageAction? = nil
    ) {
        self.style = style; self.detents = detents; self.position = position
        self.autoDismissSeconds = autoDismissSeconds; self.tapAction = tapAction
    }

    private enum CodingKeys: String, CodingKey { case style = "type", detents, position, autoDismissSeconds, tapAction }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = c.value(.style, default: .alert)
        // Los que no se entienden se ignoran; si no queda ninguno, `large`.
        let raw: [JSONValue] = c.value(.detents, default: ["medium", "large"])
        let parsed = raw.compactMap { v -> Detent? in
            guard let data = try? JSONEncoder().encode(v) else { return nil }
            return try? JSONDecoder().decode(Detent.self, from: data)
        }
        detents = parsed.isEmpty ? [.large] : parsed
        position = c.value(.position, default: .top)
        autoDismissSeconds = c.optional(.autoDismissSeconds)
        tapAction = c.optional(.tapAction)
    }

    /// Segundos efectivos de cierre automático (el toast siempre se va solo).
    public var effectiveAutoDismiss: Double? {
        switch style {
        case .toast: autoDismissSeconds ?? 3
        case .banner: autoDismissSeconds
        default: nil
        }
    }
}

// MARK: - Disparador

public struct Trigger: Sendable, Hashable, Codable {
    public enum On: String, Sendable, Hashable, Codable, CaseIterable {
        case launch, foreground, screen, event
        /// En cuanto llega: al abrir, al volver y también cuando el hub avisa de que hay algo nuevo,
        /// aunque se esté usando la app. (Una versión antigua del paquete la trata como `launch`.)
        case immediate
    }

    public var on: On
    public var screen: String?
    public var event: String?
    public var delaySeconds: Double
    public var minSessionSeconds: Double

    public init(on: On = .launch, screen: String? = nil, event: String? = nil, delaySeconds: Double = 0, minSessionSeconds: Double = 0) {
        self.on = on; self.screen = screen; self.event = event
        self.delaySeconds = delaySeconds; self.minSessionSeconds = minSessionSeconds
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        on = c.value(.on, default: .launch)
        screen = c.optional(.screen)
        event = c.optional(.event)
        delaySeconds = c.value(.delaySeconds, default: 0)
        minSessionSeconds = c.value(.minSessionSeconds, default: 0)
    }
}

// MARK: - Audiencia

public struct Audience: Sendable, Hashable, Codable {
    public var userIds: [String]
    /// 0…100. Despliegue parcial estable con un hash de `userId + campaignId`.
    public var percent: Double
    public var rules: RuleNode?
    /// Solo builds de desarrollo (las de Xcode): para probar una campaña de verdad en tu móvil sin
    /// que la vea nadie. `nil` = todos. La app manda `environment` (`development`/`production`).
    public var developmentOnly: Bool?

    public init(userIds: [String] = [], percent: Double = 100, rules: RuleNode? = nil, developmentOnly: Bool? = nil) {
        self.userIds = userIds; self.percent = percent; self.rules = rules; self.developmentOnly = developmentOnly
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        userIds = c.value(.userIds, default: [])
        percent = c.value(.percent, default: 100)
        developmentOnly = (c.optional(.developmentOnly) as Bool?) == true ? true : nil
        // Unas reglas que no se entienden no pueden abrir la campaña a todo el mundo:
        // si vienen pero no se decodifican, no le sale a nadie.
        if c.contains(.rules), (try? c.decodeNil(forKey: .rules)) != true {
            rules = c.optional(.rules) ?? RuleNode.never
        } else {
            rules = nil
        }
    }
}

/// Un nodo del árbol de reglas: un grupo `all`/`any` o una condición.
public indirect enum RuleNode: Sendable, Hashable, Codable {
    case all([RuleNode])
    case any([RuleNode])
    case condition(Condition)

    public struct Condition: Sendable, Hashable, Codable {
        public enum Op: String, Sendable, Hashable, Codable, CaseIterable {
            case eq, neq, `in`, nin, gt, gte, lt, lte, exists, contains
        }

        public var attr: String
        public var op: Op
        public var value: JSONValue

        public init(attr: String, op: Op, value: JSONValue) {
            self.attr = attr; self.op = op; self.value = value
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            attr = try c.decode(String.self, forKey: .attr)
            op = try c.decode(Op.self, forKey: .op)
            value = c.value(.value, default: .null)
        }
    }

    /// Una regla que nunca se cumple (para reglas mal formadas).
    public static let never = RuleNode.condition(.init(attr: "__invalid_rules__", op: .exists, value: true))

    private enum CodingKeys: String, CodingKey { case all, any }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let all = try c.decodeIfPresent([RuleNode].self, forKey: .all) { self = .all(all) }
        else if let any = try c.decodeIfPresent([RuleNode].self, forKey: .any) { self = .any(any) }
        else { self = .condition(try Condition(from: decoder)) }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .all(let nodes):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(nodes, forKey: .all)
        case .any(let nodes):
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(nodes, forKey: .any)
        case .condition(let cond):
            try cond.encode(to: encoder)
        }
    }
}

// MARK: - Calendario

public struct Schedule: Sendable, Hashable, Codable {
    public struct Hours: Sendable, Hashable, Codable {
        /// 0…23, inclusive.
        public var from: Int
        /// 1…24, exclusiva (`to: 21` = hasta las 20:59).
        public var to: Int
        public init(from: Int = 9, to: Int = 21) { self.from = from; self.to = to }
    }

    public var startAt: Date?
    public var endAt: Date?
    /// `user` (hora local del usuario), `UTC` o un identificador IANA (`Europe/Madrid`).
    public var timezone: String
    /// ISO: 1 = lunes … 7 = domingo. Vacío = todos.
    public var daysOfWeek: [Int]
    public var hours: Hours?

    public init(startAt: Date? = nil, endAt: Date? = nil, timezone: String = "user", daysOfWeek: [Int] = [], hours: Hours? = nil) {
        self.startAt = startAt; self.endAt = endAt; self.timezone = timezone
        self.daysOfWeek = daysOfWeek; self.hours = hours
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        startAt = c.optional(.startAt)
        endAt = c.optional(.endAt)
        timezone = c.value(.timezone, default: "user")
        daysOfWeek = c.value(.daysOfWeek, default: [])
        hours = c.optional(.hours)
    }
}

// MARK: - Frecuencia

public struct Frequency: Sendable, Hashable, Codable {
    public enum Mode: String, Sendable, Hashable, Codable, CaseIterable {
        /// Una vez en la vida.
        case once
        /// Cada vez que salte el disparador.
        case every
        /// Como mucho una vez cada `cooldownHours`.
        case cooldown
        /// Como mucho una vez por día (del usuario).
        case daily
        /// Como mucho una vez cada 7 días.
        case weekly
    }

    public var mode: Mode
    public var cooldownHours: Double?
    public var maxImpressions: Int?
    /// Tope de veces por día para esta campaña (para `every`).
    public var maxPerDay: Int?
    public var stopOnDismiss: Bool
    public var stopOnAction: Bool

    public init(mode: Mode = .once, cooldownHours: Double? = nil, maxImpressions: Int? = nil, maxPerDay: Int? = nil, stopOnDismiss: Bool = true, stopOnAction: Bool = true) {
        self.mode = mode; self.cooldownHours = cooldownHours; self.maxImpressions = maxImpressions
        self.maxPerDay = maxPerDay; self.stopOnDismiss = stopOnDismiss; self.stopOnAction = stopOnAction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = c.value(.mode, default: .once)
        cooldownHours = c.optional(.cooldownHours)
        maxImpressions = c.optional(.maxImpressions)
        maxPerDay = c.optional(.maxPerDay)
        stopOnDismiss = c.value(.stopOnDismiss, default: true)
        stopOnAction = c.value(.stopOnAction, default: true)
    }
}

// MARK: - Push

public struct PushSpec: Sendable, Hashable, Codable {
    public enum When: String, Sendable, Hashable, Codable, CaseIterable {
        /// En cuanto la campaña pasa a `live`.
        case now
        /// Una vez, en `at`.
        case at
        /// Recurrente: cada día o cada semana a `time`.
        case recurring
    }

    public enum Repeat: String, Sendable, Hashable, Codable, CaseIterable { case daily, weekly }

    public enum Target: String, Sendable, Hashable, Codable, CaseIterable {
        /// Topics de la app (`rewearly-all`, `rewearly-es`…).
        case topics
        /// Los usuarios de la audiencia de la campaña con dispositivo registrado.
        case audience
    }

    public var enabled: Bool
    public var title: [String: String]
    public var body: [String: String]
    /// Al tocarlo. `nil` = abrir la propia campaña.
    public var action: MessageAction?
    public var when: When
    public var at: Date?
    public var `repeat`: Repeat?
    /// "HH:mm" en la zona de `timezone`.
    public var time: String?
    public var daysOfWeek: [Int]
    public var timezone: String
    public var target: Target
    /// Para `target: topics`. Vacío = `<appId>-all`.
    public var topics: [String]
    /// Máximo de envíos para los recurrentes.
    public var maxSends: Int?

    public init(
        enabled: Bool = true, title: [String: String] = [:], body: [String: String] = [:],
        action: MessageAction? = nil, when: When = .now, at: Date? = nil, repeat: Repeat? = nil,
        time: String? = nil, daysOfWeek: [Int] = [], timezone: String = "Europe/Madrid",
        target: Target = .topics, topics: [String] = [], maxSends: Int? = nil
    ) {
        self.enabled = enabled; self.title = title; self.body = body; self.action = action
        self.when = when; self.at = at; self.repeat = `repeat`; self.time = time
        self.daysOfWeek = daysOfWeek; self.timezone = timezone; self.target = target
        self.topics = topics; self.maxSends = maxSends
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = c.value(.enabled, default: true)
        title = c.value(.title, default: [:])
        body = c.value(.body, default: [:])
        action = c.optional(.action)
        when = c.value(.when, default: .now)
        at = c.optional(.at)
        self.repeat = c.optional(.repeat)
        time = c.optional(.time)
        daysOfWeek = c.value(.daysOfWeek, default: [])
        timezone = c.value(.timezone, default: "Europe/Madrid")
        target = c.value(.target, default: .topics)
        topics = c.value(.topics, default: [])
        maxSends = c.optional(.maxSends)
    }
}
