import Foundation

/// Textos propios del paquete, en español e inglés. Hay pocos y casi todos llevan
/// interpolación, así que van aquí en vez de en un catálogo.
public enum L {
    /// Idioma de los textos del paquete. `nil` = el del sistema.
    nonisolated(unsafe) public static var override: String?

    public static var current: String {
        override ?? Locale.preferredLanguages.first ?? "es"
    }

    public static func string(_ es: String, _ en: String, language: String? = nil) -> String {
        (language ?? current).hasPrefix("es") ? es : en
    }
}
