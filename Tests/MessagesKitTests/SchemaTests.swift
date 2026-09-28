import Foundation
import Testing
@testable import MessagesKit

@Suite("Esquema")
struct SchemaTests {
    @Test("Todos los ejemplos se decodifican y vuelven a codificarse igual")
    func examplesRoundTrip() throws {
        let raw = Examples.load(prefixExcluding: "app-")
        #expect(raw.count >= 6)
        for (name, data) in raw {
            let c = try JSONDecoder.messages.decode(Campaign.self, from: data)
            #expect(!c.content.isEmpty, "\(name) sin contenido")
            for blocks in c.content.values {
                #expect(!blocks.contains { if case .unknown = $0.kind { true } else { false } }, "\(name) tiene bloques desconocidos")
            }
            let again = try JSONDecoder.messages.decode(Campaign.self, from: JSONEncoder.messages.encode(c))
            #expect(again == c, "\(name) cambia al recodificar")
        }
        let styles = Set(Examples.campaigns.map(\.presentation.style))
        #expect(styles == Set(Presentation.Style.allCases), "Falta un ejemplo de alguna presentación")
    }

    @Test("La app de ejemplo se decodifica")
    func exampleApp() throws {
        let app = try #require(Examples.app)
        #expect(app.appId == "rewearly")
        #expect(app.routes["paywall"] != nil)
        #expect(app.theme.colors["accent"]?.light == "#7C5CFF")
        #expect(app.theme.colors["danger"] != nil, "Los colores por defecto se mezclan con los propios")
    }

    @Test("Un bloque desconocido se ignora, no rompe, y se conserva")
    func unknownBlocks() throws {
        let json = """
        { "name": "x", "content": { "es": [
          { "type": "heading", "text": "Hola" },
          { "type": "carousel", "items": [1, 2, 3] },
          { "type": "image" },
          42,
          { "type": "text", "text": "Adiós" }
        ]}}
        """
        let c = try JSONDecoder.messages.decode(Campaign.self, from: Data(json.utf8))
        let blocks = c.blocks(for: "es")
        #expect(blocks.map(\.type) == ["heading", "carousel", "image", "text"])
        guard case .unknown(let t, let raw) = blocks[1].kind else { Issue.record("carousel no es unknown"); return }
        #expect(t == "carousel")
        #expect(raw["items"]?.arrayValue?.count == 3)
        // `image` sin url viene mal formado → desconocido, no rompe.
        if case .unknown = blocks[2].kind {} else { Issue.record("image sin url debería ser unknown") }
        // Se conserva al recodificar.
        let out = try JSONDecoder.messages.decode(Campaign.self, from: JSONEncoder.messages.encode(c))
        #expect(out.blocks(for: "es")[1].type == "carousel")
    }

    @Test("Acciones: tipos, valores por defecto de cierre y acciones desconocidas")
    func actions() throws {
        func action(_ s: String) throws -> MessageAction { try JSONDecoder.messages.decode(MessageAction.self, from: Data(s.utf8)) }
        let route = try action(#"{ "type": "route", "name": "editWorkout", "params": { "id": 42, "full": true } }"#)
        #expect(route.kind == .route(name: "editWorkout", params: ["id": "42", "full": "true"]))
        #expect(route.dismisses)
        #expect(try !action(#"{ "type": "copy", "text": "ABC" }"#).dismisses)
        #expect(try action(#"{ "type": "copy", "text": "ABC", "thenDismiss": true }"#).dismisses)
        #expect(try action(#"{ "type": "dismiss", "thenDismiss": false }"#).dismisses, "dismiss siempre cierra")
        let unknown = try action(#"{ "type": "teleport", "to": "mars" }"#)
        #expect(unknown.type == "teleport")
        let back = try JSONDecoder.messages.decode(JSONValue.self, from: JSONEncoder.messages.encode(unknown))
        #expect(back["to"] == "mars")
    }

    @Test("Detents del sistema y propios")
    func detents() throws {
        let json = #"{ "type": "sheet", "detents": ["fitted", { "fraction": 0.35 }, { "height": 420 }, "large", "huge", { "fraction": 3 }] }"#
        let p = try JSONDecoder.messages.decode(Presentation.self, from: Data(json.utf8))
        #expect(p.detents == [.fitted, .fraction(0.35), .height(420), .large, .fraction(1)])
        let again = try JSONDecoder.messages.decode(Presentation.self, from: JSONEncoder.messages.encode(p))
        #expect(again.detents == p.detents)
        let none = try JSONDecoder.messages.decode(Presentation.self, from: Data(#"{ "type": "sheet", "detents": ["huge"] }"#.utf8))
        #expect(none.detents == [.large])
    }

    @Test("Idioma: exacto, prefijo y por defecto")
    func language() {
        let c = Campaign(name: "x", defaultLanguage: "es", content: [
            "es": [Block(.heading(.init(text: "Hola")))],
            "en": [Block(.heading(.init(text: "Hi")))],
        ])
        #expect(c.resolvedLanguage(for: "en") == "en")
        #expect(c.resolvedLanguage(for: "en-GB") == "en")
        #expect(c.resolvedLanguage(for: "fr") == "es")
        #expect(c.resolvedLanguage(for: nil) == "es")
    }

    @Test("Capacidades que pide una campaña")
    func capabilities() throws {
        let c = try #require(Examples.campaigns.first { $0.id == "example-toast" })
        #expect(c.requiredCapabilities.actions == ["claimGift"])
        let offer = try #require(Examples.campaigns.first { $0.id == "example-offer" })
        #expect(offer.requiredCapabilities.routes == ["paywall"])
    }
}

@Suite("Validación")
struct ValidationTests {
    let app = Examples.app!

    @Test("Los ejemplos son publicables contra la app de ejemplo")
    func examplesValid() {
        let now = ISO8601.date(from: "2026-10-01T10:00:00Z")!
        for c in Examples.campaigns {
            let errors = CampaignValidator.validate(c, apps: [app], now: now).filter { $0.severity == .error }
            #expect(errors.isEmpty, "\(c.name): \(errors.map(\.message))")
        }
    }

    @Test("No dismisseable sin salida no se puede publicar")
    func nonDismissibleNeedsExit() {
        var c = Campaign(name: "x", appIds: ["rewearly"], dismissible: false, content: ["es": [
            Block(.heading(.init(text: "Hola"))),
            Block(.button(.init(title: "Copiar", action: MessageAction(.copy(text: "a", toast: nil))))),
        ]])
        #expect(CampaignValidator.validate(c, apps: [app]).contains { $0.severity == .error })
        c.content["es"]!.append(Block(.button(.init(title: "Vale", action: .dismiss))))
        #expect(!CampaignValidator.validate(c, apps: [app]).contains { $0.severity == .error })
    }

    @Test("Rutas que la app no declara")
    func unknownRoute() {
        let c = Campaign(name: "x", appIds: ["rewearly"], content: ["es": [
            Block(.heading(.init(text: "Hola"))),
            Block(.button(.init(title: "Ir", action: .route("editWorkout")))),
        ]])
        let messages = CampaignValidator.validate(c, apps: [app]).map(\.message)
        #expect(messages.contains { $0.contains("editWorkout") })
    }
}
