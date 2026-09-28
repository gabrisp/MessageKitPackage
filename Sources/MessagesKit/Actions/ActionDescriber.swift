import Foundation

/// Describe en una frase lo que haría una acción (modo prueba y editor).
public enum ActionDescriber {
    public static func describe(_ a: MessageAction, language: String? = nil) -> String {
        func t(_ es: String, _ en: String) -> String { L.string(es, en, language: language) }
        let base: String
        switch a.kind {
        case .dismiss:
            return t("Cerraría el mensaje", "Would close the message")
        case .route(let name, let params):
            let p = params.isEmpty ? "" : " (" + params.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ") + ")"
            base = t("Abriría la ruta «\(name)»\(p)", "Would open the route “\(name)”\(p)")
        case .deepLink(let url):
            base = t("Abriría el deep link \(url)", "Would open the deep link \(url)")
        case .openURL(let url, let inApp):
            base = inApp ? t("Abriría \(url) dentro de la app", "Would open \(url) in the app") : t("Abriría \(url) en Safari", "Would open \(url) in Safari")
        case .requestReview:
            base = t("Pediría una reseña (StoreKit decide si sale)", "Would ask for a review (StoreKit decides if it shows)")
        case .requestPushPermission:
            base = t("Pediría permiso para enviar avisos", "Would ask for notification permission")
        case .share(let text, let url):
            base = t("Compartiría «\([text, url].compactMap { $0 }.joined(separator: " "))»", "Would share “\([text, url].compactMap { $0 }.joined(separator: " "))”")
        case .copy(let text, _):
            base = t("Copiaría «\(text)»", "Would copy “\(text)”")
        case .openCampaign(let id):
            base = t("Abriría la campaña \(id)", "Would open campaign \(id)")
        case .track(let event, _):
            base = t("Registraría el evento «\(event)»", "Would track the event “\(event)”")
        case .custom(let name, let payload):
            let p = payload == .null ? "" : " " + (String(data: (try? JSONEncoder.messages.encode(payload)) ?? Data(), encoding: .utf8) ?? "")
            base = t("Ejecutaría la acción propia «\(name)»\(p)", "Would run the custom action “\(name)”\(p)")
        case .unknown(let type, _):
            return t("Acción desconocida «\(type)»: no haría nada", "Unknown action “\(type)”: would do nothing")
        }
        return a.dismisses ? base + t(" y cerraría", " and close") : base
    }
}
