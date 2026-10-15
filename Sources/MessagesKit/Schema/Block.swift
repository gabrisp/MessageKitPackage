import Foundation

/// Versión del esquema de bloques que entiende este paquete. La app la manda al hub
/// para que no le sirva campañas con bloques más nuevos de los que sabe pintar.
public let messagesBlocksVersion = 1

/// Un bloque de contenido. En JSON va aplanado: `{ "id": "…", "type": "heading", "text": "…" }`.
/// Un bloque que no se conoce (o que viene mal formado) se decodifica como `.unknown`,
/// no se pinta y se conserva al volver a codificar.
public struct Block: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var kind: Kind

    public init(id: String = Block.newId(), _ kind: Kind) {
        self.id = id
        self.kind = kind
    }

    public static func newId() -> String {
        String(UUID().uuidString.prefix(8)).lowercased()
    }

    public enum Kind: Sendable, Hashable {
        case heading(Heading)
        case text(Text)
        case image(Image)
        case icon(Icon)
        case list(List)
        case stat(Stat)
        case badge(Badge)
        case spacer(Spacer)
        case divider
        case button(Button)
        case buttonRow(ButtonRow)
        case countdown(Countdown)
        case web(Web)
        case form(Form)
        case unknown(type: String, raw: JSONValue)
    }

    public var type: String {
        switch kind {
        case .heading: "heading"
        case .text: "text"
        case .image: "image"
        case .icon: "icon"
        case .list: "list"
        case .stat: "stat"
        case .badge: "badge"
        case .spacer: "spacer"
        case .divider: "divider"
        case .button: "button"
        case .buttonRow: "buttonRow"
        case .countdown: "countdown"
        case .web: "web"
        case .form: "form"
        case .unknown(let type, _): type
        }
    }

    public static let allTypes = [
        "heading", "text", "image", "icon", "list", "stat", "badge",
        "spacer", "divider", "button", "buttonRow", "countdown", "web", "form",
    ]

    /// Todas las acciones que lleva el bloque (para validar capacidades).
    public var actions: [MessageAction] {
        switch kind {
        case .button(let b): [b.action]
        case .buttonRow(let r): r.buttons.map(\.action)
        default: []
        }
    }

    // MARK: Tipos de bloque

    public enum Alignment: String, Sendable, Hashable, Codable, CaseIterable {
        case leading, center, trailing
    }

    public struct Heading: Sendable, Hashable, Codable {
        public enum Size: String, Sendable, Hashable, Codable, CaseIterable { case large, medium }
        public var text: String
        public var size: Size
        public var align: Alignment?

        public init(text: String, size: Size = .large, align: Alignment? = nil) {
            self.text = text; self.size = size; self.align = align
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            size = c.value(.size, default: .large)
            align = c.optional(.align)
        }
    }

    public struct Text: Sendable, Hashable, Codable {
        public enum Style: String, Sendable, Hashable, Codable, CaseIterable { case body, secondary, caption }
        /// Markdown ligero: **negrita**, *cursiva* y [enlaces](https://…).
        public var text: String
        public var style: Style
        public var align: Alignment?

        public init(text: String, style: Style = .body, align: Alignment? = nil) {
            self.text = text; self.style = style; self.align = align
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            text = try c.decode(String.self, forKey: .text)
            style = c.value(.style, default: .body)
            align = c.optional(.align)
        }
    }

    public struct Image: Sendable, Hashable, Codable {
        public enum ContentMode: String, Sendable, Hashable, Codable, CaseIterable { case fit, fill }
        public var url: String
        /// Ancho / alto. `nil` respeta la proporción de la imagen.
        public var aspectRatio: Double?
        public var corner: Double?
        public var contentMode: ContentMode
        /// Descripción para VoiceOver. Sin ella la imagen es decorativa.
        public var alt: String?

        public init(url: String, aspectRatio: Double? = 16.0 / 9.0, corner: Double? = nil, contentMode: ContentMode = .fill, alt: String? = nil) {
            self.url = url; self.aspectRatio = aspectRatio; self.corner = corner; self.contentMode = contentMode; self.alt = alt
        }

        private enum CodingKeys: String, CodingKey { case url, aspectRatio, corner, contentMode = "fit", alt }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            aspectRatio = c.optional(.aspectRatio)
            corner = c.optional(.corner)
            contentMode = c.value(.contentMode, default: .fill)
            alt = c.optional(.alt)
        }
    }

    public struct Icon: Sendable, Hashable, Codable {
        public var symbol: String
        /// Token de color (`accent`, `positive`…) o hex (`#FF8800`).
        public var tint: String?
        public var size: Double

        public init(symbol: String, tint: String? = "accent", size: Double = 44) {
            self.symbol = symbol; self.tint = tint; self.size = size
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            symbol = try c.decode(String.self, forKey: .symbol)
            tint = c.optional(.tint)
            if let n: Double = c.optional(.size) {
                size = n
            } else {
                switch c.value(.size, default: "large") as String {
                case "small": size = 28
                case "medium": size = 36
                default: size = 44
                }
            }
        }
    }

    public struct List: Sendable, Hashable, Codable {
        public struct Item: Sendable, Hashable, Codable, Identifiable {
            public var id: String
            public var symbol: String?
            public var text: String
            public var tint: String?

            public init(id: String = Block.newId(), symbol: String? = nil, text: String, tint: String? = nil) {
                self.id = id; self.symbol = symbol; self.text = text; self.tint = tint
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = c.value(.id, default: Block.newId())
                symbol = c.optional(.symbol)
                text = c.value(.text, default: "")
                tint = c.optional(.tint)
            }
        }

        public var items: [Item]
        public var tint: String?

        public init(items: [Item], tint: String? = nil) {
            self.items = items; self.tint = tint
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            items = try c.decode([Item].self, forKey: .items)
            tint = c.optional(.tint)
        }
    }

    public struct Stat: Sendable, Hashable, Codable {
        public var value: String
        public var label: String?
        public var tint: String?

        public init(value: String, label: String? = nil, tint: String? = nil) {
            self.value = value; self.label = label; self.tint = tint
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let s: String = c.optional(.value) { value = s }
            else if let n: Double = c.optional(.value) { value = JSONValue.number(n).stringValue ?? "" }
            else { throw DecodingError.keyNotFound(CodingKeys.value, .init(codingPath: c.codingPath, debugDescription: "stat sin value")) }
            label = c.optional(.label)
            tint = c.optional(.tint)
        }
    }

    public struct Badge: Sendable, Hashable, Codable {
        public var text: String
        public var tint: String?

        public init(text: String, tint: String? = "accent") {
            self.text = text; self.tint = tint
        }
    }

    public struct Spacer: Sendable, Hashable, Codable {
        public var height: Double

        public init(height: Double = 16) { self.height = height }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            height = c.value(.height, default: 16)
        }
    }

    public struct Button: Sendable, Hashable, Codable, Identifiable {
        public enum Style: String, Sendable, Hashable, Codable, CaseIterable {
            case primary, secondary, glass, destructive, link
        }

        public var id: String
        public var title: String
        public var style: Style
        public var symbol: String?
        public var action: MessageAction

        public init(id: String = Block.newId(), title: String, style: Style = .primary, symbol: String? = nil, action: MessageAction) {
            self.id = id; self.title = title; self.style = style; self.symbol = symbol; self.action = action
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = c.value(.id, default: Block.newId())
            title = try c.decode(String.self, forKey: .title)
            style = c.value(.style, default: .primary)
            symbol = c.optional(.symbol)
            action = c.value(.action, default: .dismiss)
        }
    }

    public struct ButtonRow: Sendable, Hashable, Codable {
        public var buttons: [Button]

        public init(buttons: [Button]) { self.buttons = buttons }
    }

    public struct Countdown: Sendable, Hashable, Codable {
        public var until: Date
        public var label: String?
        /// Texto cuando ya ha terminado.
        public var expiredText: String?

        public init(until: Date, label: String? = nil, expiredText: String? = nil) {
            self.until = until; self.label = label; self.expiredText = expiredText
        }
    }

    public struct Web: Sendable, Hashable, Codable {
        public var url: String
        public var height: Double

        public init(url: String, height: Double = 320) {
            self.url = url; self.height = height
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            height = c.value(.height, default: 320)
        }
    }

    /// Un formulario: uno o varios campos y un botón de enviar. La respuesta va al hub (función
    /// `forms`) con la campaña, la app y el usuario. Pensado sobre todo para pedir el email.
    public struct Form: Sendable, Hashable, Codable {
        public struct Field: Sendable, Hashable, Codable, Identifiable {
            public enum FieldType: String, Sendable, Hashable, Codable, CaseIterable {
                case email, text, multiline, phone, number
            }

            /// La clave del valor en la respuesta (`email`, `name`…). Igual en todos los idiomas.
            public var id: String
            public var label: String
            public var placeholder: String?
            public var type: FieldType
            public var required: Bool

            public init(id: String, label: String, placeholder: String? = nil, type: FieldType = .text, required: Bool = false) {
                self.id = id; self.label = label; self.placeholder = placeholder; self.type = type; self.required = required
            }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                id = c.value(.id, default: Block.newId())
                label = c.value(.label, default: "")
                placeholder = c.optional(.placeholder)
                type = c.value(.type, default: .text)
                required = c.value(.required, default: false)
            }

            /// Si el valor vale para este campo: obligatorio con algo escrito y, si es email, con
            /// forma de email. Devuelve el problema (en el idioma del mensaje) o `nil`.
            public func problem(with value: String, language: String = L.current) -> String? {
                let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if v.isEmpty {
                    return required ? L.string("Este campo es obligatorio.", "This field is required.", language: language) : nil
                }
                if v.count > Form.maxValueLength {
                    return L.string("Es demasiado largo.", "It's too long.", language: language)
                }
                switch type {
                case .email where !Form.isEmail(v):
                    return L.string("Escribe un email válido.", "Enter a valid email.", language: language)
                case .number where Double(v.replacingOccurrences(of: ",", with: ".")) == nil:
                    return L.string("Escribe un número.", "Enter a number.", language: language)
                case .phone where v.filter(\.isNumber).count < 6:
                    return L.string("Escribe un teléfono válido.", "Enter a valid phone number.", language: language)
                default:
                    return nil
                }
            }
        }

        public var fields: [Field]
        public var submitTitle: String
        public var submitStyle: Button.Style
        /// Lo que se ve al enviar (en lugar de los campos). `nil` = «¡Gracias!».
        public var successText: String?
        /// Si el mensaje se cierra solo un momento después de enviar.
        public var thenDismiss: Bool

        public init(fields: [Field], submitTitle: String = "Enviar", submitStyle: Button.Style = .primary, successText: String? = nil, thenDismiss: Bool = true) {
            self.fields = fields; self.submitTitle = submitTitle; self.submitStyle = submitStyle
            self.successText = successText; self.thenDismiss = thenDismiss
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            fields = try c.decode([Field].self, forKey: .fields)
            submitTitle = c.value(.submitTitle, default: "Enviar")
            submitStyle = c.value(.submitStyle, default: .primary)
            successText = c.optional(.successText)
            thenDismiss = c.value(.thenDismiss, default: true)
        }

        /// Lo más largo que se guarda de un valor (el hub aplica el mismo tope).
        public static let maxValueLength = 2000
        /// Cuántos campos como mucho (el hub aplica el mismo tope).
        public static let maxFields = 8

        /// Validación básica: algo@algo.tld, sin espacios. La de verdad la hace quien escribe.
        public static func isEmail(_ s: String) -> Bool {
            s.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]{2,}/) != nil
        }
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case id, type }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: Block.newId())
        let type: String = c.value(.type, default: "")
        func payload<T: Decodable>(_: T.Type) -> T? { try? T(from: decoder) }
        let known: Kind? = switch type {
        case "heading": payload(Heading.self).map(Kind.heading)
        case "text": payload(Text.self).map(Kind.text)
        case "image": payload(Image.self).map(Kind.image)
        case "icon": payload(Icon.self).map(Kind.icon)
        case "list": payload(List.self).map(Kind.list)
        case "stat": payload(Stat.self).map(Kind.stat)
        case "badge": payload(Badge.self).map(Kind.badge)
        case "spacer": payload(Spacer.self).map(Kind.spacer)
        case "divider": .divider
        case "button": payload(Button.self).map(Kind.button)
        case "buttonRow": payload(ButtonRow.self).map(Kind.buttonRow)
        case "countdown": payload(Countdown.self).map(Kind.countdown)
        case "web": payload(Web.self).map(Kind.web)
        case "form": payload(Form.self).map(Kind.form)
        default: nil
        }
        kind = known ?? .unknown(type: type, raw: (try? JSONValue(from: decoder)) ?? .null)
    }

    public func encode(to encoder: Encoder) throws {
        switch kind {
        case .heading(let v): try v.encode(to: encoder)
        case .text(let v): try v.encode(to: encoder)
        case .image(let v): try v.encode(to: encoder)
        case .icon(let v): try v.encode(to: encoder)
        case .list(let v): try v.encode(to: encoder)
        case .stat(let v): try v.encode(to: encoder)
        case .badge(let v): try v.encode(to: encoder)
        case .spacer(let v): try v.encode(to: encoder)
        case .divider: break
        case .button(let v): try v.encode(to: encoder)
        case .buttonRow(let v): try v.encode(to: encoder)
        case .countdown(let v): try v.encode(to: encoder)
        case .web(let v): try v.encode(to: encoder)
        case .form(let v): try v.encode(to: encoder)
        case .unknown(_, let raw):
            try raw.encode(to: encoder)
            return
        }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
    }
}

/// Un array de bloques que nunca falla al decodificar: si un elemento no es ni siquiera
/// un objeto, se descarta.
struct LossyBlocks: Decodable {
    var blocks: [Block]

    init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var out: [Block] = []
        while !c.isAtEnd {
            if let b = try? c.decode(Block.self) { out.append(b) }
            else { _ = try? c.decode(JSONValue.self) }
        }
        blocks = out
    }
}
