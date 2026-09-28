import Foundation

/// Un problema que impide (o desaconseja) publicar una campaña.
public struct ValidationIssue: Sendable, Hashable, Identifiable {
    public enum Severity: Sendable, Hashable { case error, warning }
    public var severity: Severity
    public var message: String
    public var id: String { message }

    public init(severity: Severity, message: String) {
        self.severity = severity
        self.message = message
    }
}

public enum CampaignValidator {
    /// Lo que el admin comprueba antes de publicar. `apps` son las apps de destino.
    public static func validate(_ c: Campaign, apps: [AppConfig], now: Date = .now) -> [ValidationIssue] {
        var out: [ValidationIssue] = []
        func error(_ m: String) { out.append(.init(severity: .error, message: m)) }
        func warning(_ m: String) { out.append(.init(severity: .warning, message: m)) }

        if c.name.trimmingCharacters(in: .whitespaces).isEmpty { error(L.string("La campaña no tiene nombre.", "The campaign has no name.")) }
        if c.appIds.isEmpty { error(L.string("Elige al menos una app.", "Pick at least one app.")) }

        let defaultBlocks = c.content[c.defaultLanguage] ?? []
        if defaultBlocks.isEmpty {
            error(L.string("Falta el contenido en el idioma por defecto (\(c.defaultLanguage)).", "Missing content in the default language (\(c.defaultLanguage))."))
        }
        let hasText = defaultBlocks.contains {
            switch $0.kind {
            case .heading(let h): !h.text.trimmingCharacters(in: .whitespaces).isEmpty
            case .text(let t): !t.text.trimmingCharacters(in: .whitespaces).isEmpty
            default: false
            }
        }
        if !defaultBlocks.isEmpty, !hasText, c.presentation.style != .fullscreen {
            warning(L.string("No hay titular ni texto en el idioma por defecto.", "There's no heading or text in the default language."))
        }

        for (lang, blocks) in c.content {
            for b in blocks {
                if case .unknown(let t, _) = b.kind {
                    warning(L.string("Bloque desconocido «\(t)» en \(lang): no se pintará.", "Unknown block “\(t)” in \(lang): it won't render."))
                }
                if case .button(let btn) = b.kind, btn.title.trimmingCharacters(in: .whitespaces).isEmpty {
                    error(L.string("Hay un botón sin título en \(lang).", "There's a button with no title in \(lang)."))
                }
            }
        }

        // No dismisseable: tiene que haber una salida.
        if !c.dismissible {
            let actions = defaultBlocks.flatMap(\.actions)
            if actions.isEmpty {
                error(L.string("Una campaña que no se puede cerrar necesita al menos un botón.", "A non-dismissible campaign needs at least one button."))
            } else if !actions.contains(where: { $0.closes(messageDismissible: false) }) {
                warning(L.string("Ningún botón la cierra: se queda en pantalla hasta que el usuario deje de estar en la audiencia (p. ej. al hacerse Pro) o la pauses. Si quieres que un botón la cierre, en «Después» elige «Cierra el mensaje».",
                                 "No button closes it: it stays on screen until the user leaves the audience (e.g. goes Pro) or you pause it. To let a button close it, set “Then” to “Close the message”."))
            }
            if c.presentation.style == .toast {
                error(L.string("Un toast siempre se va solo: no puede ser no dismisseable.", "A toast always goes away on its own: it can't be non-dismissible."))
            }
        }

        // Acciones que las apps soportan.
        let (routes, actions) = c.requiredCapabilities
        for app in apps where c.appIds.contains(app.appId) {
            for a in c.allActions {
                let (declared, values, what): ([AppConfig.Param], [String: String], String) = switch a.kind {
                case .route(let name, let params): (app.routes[name]?.params ?? [], params, L.string("la ruta «\(name)»", "the route “\(name)”"))
                case .custom(let name, let payload): (app.customActions[name]?.params ?? [], payload.objectValue?.compactMapValues(\.stringValue) ?? [:], L.string("la acción «\(name)»", "the action “\(name)”"))
                default: ([], [:], "")
                }
                for p in declared {
                    let v = values[p.name] ?? ""
                    if p.required, v.isEmpty {
                        error(L.string("Falta «\(p.name)» en \(what) (obligatorio en \(app.name)).", "“\(p.name)” is missing in \(what) (required in \(app.name))."))
                    } else if p.kind == .options, !v.isEmpty, !p.options.contains(v) {
                        warning(L.string("«\(v)» no es un valor de «\(p.name)» en \(app.name) (\(p.options.joined(separator: ", "))).", "“\(v)” isn't a value of “\(p.name)” in \(app.name) (\(p.options.joined(separator: ", ")))."))
                    }
                }
            }
            for r in routes.sorted() where app.routes[r] == nil {
                error(L.string("\(app.name) no declara la ruta «\(r)».", "\(app.name) doesn't declare the route “\(r)”."))
            }
            for a in actions.sorted() where app.customActions[a] == nil {
                error(L.string("\(app.name) no declara la acción «\(a)».", "\(app.name) doesn't declare the action “\(a)”."))
            }
            if !app.languages.contains(c.defaultLanguage) {
                warning(L.string("\(app.name) no tiene el idioma \(c.defaultLanguage).", "\(app.name) doesn't have the language \(c.defaultLanguage)."))
            }
        }
        for a in c.allActions {
            switch a.kind {
            case .route(let name, _) where name.isEmpty: error(L.string("Hay una acción de ruta sin nombre.", "There's a route action with no name."))
            case .deepLink(let url) where URL(string: url)?.scheme == nil: error(L.string("Deep link no válido: \(url)", "Invalid deep link: \(url)"))
            case .openURL(let url, _) where !(url.hasPrefix("https://") || url.hasPrefix("http://")): error(L.string("Enlace no válido: \(url)", "Invalid link: \(url)"))
            case .openCampaign(let id) where id.isEmpty || id == c.id: error(L.string("«Abrir campaña» necesita otra campaña.", "“Open campaign” needs a different campaign."))
            case .purchase(let product, let offering, let package) where (product ?? "").isEmpty && (package ?? "").isEmpty && (offering ?? "").isEmpty:
                error(L.string("La compra necesita un producto, o un offering y paquete de RevenueCat.", "The purchase needs a product, or a RevenueCat offering and package."))
            case .unknown(let t, _): error(L.string("Acción desconocida «\(t)».", "Unknown action “\(t)”."))
            default: break
            }
        }

        // Fechas.
        if let s = c.schedule.startAt, let e = c.schedule.endAt, e <= s {
            error(L.string("La fecha de fin es anterior a la de inicio.", "The end date is before the start date."))
        }
        if let e = c.schedule.endAt, e <= now { error(L.string("La campaña ya ha terminado (fecha de fin en el pasado).", "The campaign has already ended (end date in the past).")) }
        if let h = c.schedule.hours, h.from == h.to { error(L.string("La franja horaria está vacía.", "The time window is empty.")) }

        // Disparador.
        if c.trigger.on == .screen, (c.trigger.screen ?? "").isEmpty { error(L.string("Falta la pantalla del disparador.", "The trigger is missing its screen.")) }
        if c.trigger.on == .event, (c.trigger.event ?? "").isEmpty { error(L.string("Falta el evento del disparador.", "The trigger is missing its event.")) }

        // Frecuencia.
        if c.frequency.mode == .cooldown, (c.frequency.cooldownHours ?? 0) <= 0 { error(L.string("El modo «cada X horas» necesita horas.", "“Every X hours” mode needs a number of hours.")) }
        if c.audience.percent <= 0 { warning(L.string("El porcentaje de audiencia es 0: no le saldrá a nadie.", "The audience percentage is 0: nobody will see it.")) }

        // Push.
        if let p = c.push, p.enabled {
            if (p.title[c.defaultLanguage] ?? "").isEmpty { error(L.string("El push no tiene título en el idioma por defecto.", "The push has no title in the default language.")) }
            if p.when == .at, p.at == nil { error(L.string("El push programado no tiene fecha.", "The scheduled push has no date.")) }
            if p.when == .recurring, p.time == nil { error(L.string("El push recurrente no tiene hora.", "The recurring push has no time.")) }
        }
        return out
    }
}
