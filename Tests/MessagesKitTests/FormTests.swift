import Foundation
import Testing
@testable import MessagesKit

@Suite("Formularios")
struct FormTests {
    @Test("El bloque form se decodifica con sus valores por defecto y vuelve a codificarse igual")
    func roundTrip() throws {
        let json = """
        { "name": "x", "content": { "es": [
          { "id": "f1", "type": "form", "fields": [
            { "id": "email", "label": "Tu email", "placeholder": "tu@email.com", "type": "email", "required": true },
            { "id": "nota", "label": "¿Algo más?", "type": "multiline" },
            { "label": "Sin tipo" }
          ]}
        ]}}
        """
        let c = try JSONDecoder.messages.decode(Campaign.self, from: Data(json.utf8))
        guard case .form(let f) = c.blocks(for: "es").first?.kind else { Issue.record("no es un form"); return }
        #expect(f.fields.map(\.type) == [.email, .multiline, .text])
        #expect(f.fields[0].required && !f.fields[1].required)
        #expect(f.submitTitle == "Enviar")
        #expect(f.submitStyle == .primary)
        #expect(f.thenDismiss)
        #expect(c.hasForm)
        let again = try JSONDecoder.messages.decode(Campaign.self, from: JSONEncoder.messages.encode(c))
        #expect(again == c)
        // Sin `fields` viene mal formado: desconocido, no rompe.
        let broken = try JSONDecoder.messages.decode(Block.self, from: Data(#"{ "type": "form" }"#.utf8))
        if case .unknown = broken.kind {} else { Issue.record("form sin fields debería ser unknown") }
    }

    @Test("Validación de cada campo: obligatorio, email, número y teléfono")
    func fieldProblems() {
        let email = Block.Form.Field(id: "email", label: "Email", type: .email, required: true)
        #expect(email.problem(with: "  ", language: "es") != nil)
        #expect(email.problem(with: "hola", language: "es") != nil)
        #expect(email.problem(with: "a@b", language: "es") != nil)
        #expect(email.problem(with: "a b@c.com", language: "es") != nil)
        #expect(email.problem(with: " ana@example.com ", language: "es") == nil)
        let optional = Block.Form.Field(id: "email2", label: "Email", type: .email)
        #expect(optional.problem(with: "", language: "es") == nil, "Opcional y vacío vale")
        #expect(optional.problem(with: "mal", language: "es") != nil, "Opcional pero escrito: tiene que ser un email")
        #expect(Block.Form.Field(id: "n", label: "N", type: .number).problem(with: "3,5", language: "es") == nil)
        #expect(Block.Form.Field(id: "n", label: "N", type: .number).problem(with: "tres", language: "es") != nil)
        #expect(Block.Form.Field(id: "t", label: "T", type: .phone).problem(with: "+34 600 00 00 00", language: "es") == nil)
        #expect(Block.Form.Field(id: "t", label: "T", type: .phone).problem(with: "12", language: "es") != nil)
        let long = String(repeating: "a", count: Block.Form.maxValueLength + 1)
        #expect(Block.Form.Field(id: "x", label: "X").problem(with: long, language: "es") != nil)
    }

    @Test("El validador de campañas pide campos con clave única y un botón con título")
    func campaignValidation() {
        func issues(_ form: Block.Form) -> [String] {
            CampaignValidator.formIssues(form, lang: "es").filter { $0.severity == .error }.map(\.message)
        }
        #expect(issues(.init(fields: [.init(id: "email", label: "Email", type: .email, required: true)])).isEmpty)
        #expect(!issues(.init(fields: [])).isEmpty)
        #expect(!issues(.init(fields: [.init(id: "a", label: "A"), .init(id: "a", label: "B")])).isEmpty)
        #expect(!issues(.init(fields: [.init(id: "", label: "A")])).isEmpty)
        #expect(!issues(.init(fields: [.init(id: "con espacio", label: "A")])).isEmpty)
        #expect(!issues(.init(fields: [.init(id: "a", label: "A")], submitTitle: " ")).isEmpty)
    }

    @Test("El paquete declara que sabe pintar formularios")
    func feature() {
        #expect(Capabilities.supportedFeatures.contains("form"))
        #expect(Block.allTypes.contains("form"))
    }
}
