import Foundation
import SwiftUI
import Testing
@testable import MessagesKit

@Suite("Configuración de la app → admin")
struct AppReportTests {
    func report() -> AppReport {
        AppReport(
            appId: "myapp", bundleId: "com.example.myapp", name: "My App", languages: ["es", "en"],
            theme: ThemeSpec(), routes: ["paywall", "editItem"], actions: ["claimReward"],
            screens: ["home", "settings"], events: ["task_completed"],
            attributes: [.init(name: "itemCount", kind: .number), .init(name: "isCreator", kind: .bool)],
            sdkVersion: "test"
        )
    }

    @Test("Ida y vuelta por JSON, tal como lo copia la app")
    func roundTrip() throws {
        let json = String(decoding: try JSONEncoder.messagesPretty.encode(report()), as: UTF8.self)
        let back = try #require(AppReport.parse(json))
        #expect(back == report())
    }

    @Test("Se pega bien aunque venga con comillas tipográficas, espacios y texto alrededor")
    func tolerantPaste() throws {
        let json = String(decoding: try JSONEncoder.messages.encode(report()), as: UTF8.self)
        let messy = "Aquí va la config:\n  " + json.replacingOccurrences(of: "\"appId\"", with: "\u{201C}appId\u{201D}") + "  \n¡gracias!"
        #expect(AppReport.parse(messy)?.appId == "myapp")
    }

    @Test("Lo que no es un informe de app no se acepta")
    func rejectsOtherJSON() {
        #expect(AppReport.parse("{ \"name\": \"Campaña\", \"content\": {} }") == nil)
        #expect(AppReport.parse("hola") == nil)
        #expect(AppReport.parse(#"{ "kind": "messageskit.appReport", "appId": "  " }"#) == nil)
    }

    @Test("Faltan campos: se queda vacío, no falla")
    func missingFields() throws {
        let r = try #require(AppReport.parse(#"{ "kind": "messageskit.appReport", "appId": "myapp", "screens": ["home"] }"#))
        #expect(r.screens == ["home"])
        #expect(r.routes.isEmpty)
        #expect(r.theme.colors["accent"] != nil, "Tema por defecto")
        let app = r.makeApp()
        #expect(app.name == "myapp")
        #expect(app.languages == ["es", "en"])
    }

    @Test("Limpieza: sin vacíos, sin repetidos, recortado y hasta 128 caracteres")
    func cleanup() {
        var r = report()
        r.screens = [" home ", "home", "", String(repeating: "x", count: 200)]
        r.attributes = [.init(name: " itemCount ", kind: .number), .init(name: "itemCount", kind: .string), .init(name: "  ", kind: .bool)]
        let c = r.cleaned()
        #expect(c.screens == ["home", String(repeating: "x", count: 128)])
        #expect(c.attributes.map(\.name) == ["itemCount"])
        #expect(c.attributes.first?.kind == .number)
    }

    @Test("Al mezclar respeta lo escrito en el admin y añade lo nuevo")
    func mergeKeepsExisting() {
        var existing = AppConfig(appId: "myapp", name: "Mi App bonita", bundleId: "")
        existing.routes = ["paywall": .init(description: "Paywall de Pro", params: [.init(name: "source")])]
        existing.attributes = [.init(name: "itemCount", kind: .string, description: "Elementos guardados")]
        existing.screens = ["onboarding"]
        let merged = report().merged(into: existing)
        #expect(merged.name == "Mi App bonita")
        #expect(merged.bundleId == "com.example.myapp")
        #expect(merged.routes["paywall"]?.description == "Paywall de Pro", "No pisa la descripción")
        #expect(merged.routes["editItem"] != nil)
        #expect(merged.customActions["claimReward"] != nil)
        #expect(merged.screens == ["home", "onboarding", "settings"])
        #expect(merged.attributes.first { $0.name == "itemCount" }?.kind == .string, "No pisa el tipo ya elegido")
        #expect(merged.attributes.contains { $0.name == "isCreator" && $0.kind == .bool })
    }

    @Test("Tipo de atributo deducido del valor")
    func inferredKinds() {
        #expect(AppConfig.Attribute.Kind.inferred(from: true) == .bool)
        #expect(AppConfig.Attribute.Kind.inferred(from: 12) == .number)
        #expect(AppConfig.Attribute.Kind.inferred(from: "1.10.2") == .version)
        #expect(AppConfig.Attribute.Kind.inferred(from: "2026-03-10T12:00:00Z") == .date)
        #expect(AppConfig.Attribute.Kind.inferred(from: ["a", "b"]) == .list)
        #expect(AppConfig.Attribute.Kind.inferred(from: "hola") == .string)
    }

    @Test("El tema de la app pasa a hex (claro y oscuro) y vuelve igual")
    @MainActor
    func themeToSpec() {
        let theme = MessagesTheme(colors: ["accent": Color(lightHex: "#7C5CFF", darkHex: "#9E86FF")!], fontDesign: .rounded, cardRadius: 34)
        let spec = ThemeSpec(theme: theme)
        #expect(spec.colors["accent"]?.light == "#7C5CFF")
        #expect(spec.colors["accent"]?.dark == "#9E86FF")
        #expect(spec.fontDesign == .rounded)
        #expect(spec.cardRadius == 34)
    }

    @Test("Parámetros declarados por la app: tipo, mezcla y validación")
    func declaredParams() throws {
        let tab = AppConfig.Param("tab", options: ["info", "series"])
        #expect(tab.kind == .options)
        let decoded = try JSONDecoder.messages.decode(AppConfig.Param.self, from: Data(#"{ "name": "tab", "options": ["a"] }"#.utf8))
        #expect(decoded.kind == .options)

        var r = report()
        r.routeParams = ["editItem": [.init("id", required: true), tab, .init("autoplay", kind: .bool)]]
        var existing = AppConfig(appId: "myapp", name: "My App")
        existing.routes = ["editItem": .init(description: "Editar", params: [.init("id", description: "Id del elemento")])]
        let merged = r.merged(into: existing)
        let params = try #require(merged.routes["editItem"]?.params)
        #expect(params.map(\.name) == ["id", "tab", "autoplay"])
        #expect(params[0].required && params[0].description == "Id del elemento", "No pisa la descripción, sí marca obligatorio")
        #expect(merged.routes["editItem"]?.description == "Editar")

        func issues(_ p: RouteParams) -> [ValidationIssue] {
            let c = Campaign(name: "x", appIds: ["myapp"], content: ["es": [
                Block(.heading(.init(text: "Hola"))),
                Block(.button(.init(title: "Ir", action: .route("editItem", p)))),
            ]])
            return CampaignValidator.validate(c, apps: [merged])
        }
        #expect(issues([:]).contains { $0.severity == .error && $0.message.contains("id") })
        #expect(!issues(["id": "42"]).contains { $0.severity == .error })
        #expect(issues(["id": "42", "tab": "otra"]).contains { $0.severity == .warning && $0.message.contains("tab") })
    }
}
