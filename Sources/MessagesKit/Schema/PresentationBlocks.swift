import Foundation

/// Qué bloques caben y se ven de verdad en cada presentación. El toast y el banner compactan: solo
/// usan el primer icono, un título (y el banner, un texto), y un botón; el resto no se pinta.
/// Lo usan el editor (para no dejar añadir lo que no se verá) y la validación.
extension Presentation.Style {
    /// Cuántos bloques tiene sentido poner como mucho (`nil` = sin límite).
    public var maxBlocks: Int? {
        switch self {
        case .toast: 3
        case .banner: 4
        case .alert: 10
        case .sheet, .fullscreen: nil
        }
    }

    /// Los tipos de bloque que se pintan (`nil` = todos).
    public var allowedBlockTypes: Set<String>? {
        switch self {
        case .toast: ["icon", "heading", "text", "button"]
        case .banner: ["icon", "heading", "text", "button", "buttonRow"]
        default: nil
        }
    }

    /// Lo que se ve en esta presentación, en una frase.
    public var blocksNote: String? {
        switch self {
        case .toast: L.string("En un toast solo se ven el primer icono, un texto y un botón.",
                              "A toast only shows the first icon, one text and one button.")
        case .banner: L.string("En un banner solo se ven el primer icono, un título, un texto y un botón.",
                               "A banner only shows the first icon, a title, one text and one button.")
        case .alert: L.string("Un alert admite hasta 10 bloques: más no caben en pantalla.",
                              "An alert takes up to 10 blocks: more don't fit on screen.")
        default: nil
        }
    }

    /// Los bloques que se pintan de verdad (en el mismo orden de elección que el toast y el banner).
    public func visibleBlockIds(_ blocks: [Block]) -> Set<String> {
        guard self == .toast || self == .banner else {
            return Set(blocks.prefix(maxBlocks ?? blocks.count).map(\.id))
        }
        var out = Set<String>()
        var icon = false, title = false, body = false, button = false
        for b in blocks {
            switch b.kind {
            case .icon where !icon: icon = true; out.insert(b.id)
            case .heading where !title: title = true; out.insert(b.id)
            case .text:
                if !title { title = true; out.insert(b.id) } else if !body, self == .banner { body = true; out.insert(b.id) }
            case .button where !button: button = true; out.insert(b.id)
            case .buttonRow where !button && self == .banner: button = true; out.insert(b.id)
            default: break
            }
        }
        return out
    }
}
