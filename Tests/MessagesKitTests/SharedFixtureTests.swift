import Foundation
import Testing
@testable import MessagesKit

/// Los mismos casos que `functions/shared/test/rules-cases.json` pasa el hub en TypeScript:
/// así Swift y TypeScript deciden exactamente lo mismo. Solo corre si el paquete está junto
/// a `functions/` (en su repo suelto no hay hub al lado y se salta).
enum SharedFixture {
    struct Case: Decodable {
        var name: String
        var kind: String
        var input: JSONValue
        var expected: JSONValue
    }

    static let fixtureURL = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "functions/shared/test/rules-cases.json")

    static let cases: [Case] = {
        guard let data = try? Data(contentsOf: fixtureURL) else { return [] }
        return (try? JSONDecoder.messages.decode([Case].self, from: data)) ?? []
    }()
}

@Suite("Casos compartidos con el hub", .enabled(if: !SharedFixture.cases.isEmpty))
struct SharedFixtureTests {
    typealias Case = SharedFixture.Case
    static var cases: [Case] { SharedFixture.cases }
    static var fixtureURL: URL { SharedFixture.fixtureURL }

    func decode<T: Decodable>(_ type: T.Type, _ value: JSONValue?) throws -> T {
        try JSONDecoder.messages.decode(T.self, from: JSONEncoder.messages.encode(value ?? .null))
    }

    @Test("Hay casos") func loaded() {
        #expect(Self.cases.count > 100, "No se encontró \(Self.fixtureURL.path)")
    }

    @Test("Mismo resultado que TypeScript", arguments: cases.map { ($0.name, $0.kind) })
    func matches(name: String, kind: String) throws {
        let c = try #require(Self.cases.first { $0.name == name && $0.kind == kind })
        let i = c.input
        switch c.kind {
        case "frequency":
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: i["timezone"]?.stringValue ?? "UTC")!
            let got = Rules.frequencyAllows(
                try decode(Frequency.self, i["frequency"]),
                history: try decode(ImpressionHistory.self, i["history"]),
                now: try decode(Date.self, i["now"]), calendar: cal
            )
            #expect(got == c.expected.boolValue, "\(name)")
        case "schedule":
            let got = Rules.scheduleAllows(
                try decode(Schedule.self, i["schedule"]),
                now: try decode(Date.self, i["now"]),
                userTimeZone: i["userTimeZone"]?.stringValue.flatMap(TimeZone.init(identifier:))
            )
            #expect(got == c.expected.boolValue, "\(name)")
        case "audience":
            let got = Rules.audienceMatches(
                try decode(Audience.self, i["audience"]),
                userId: i["userId"]?.stringValue ?? "", campaignId: i["campaignId"]?.stringValue ?? "",
                attributes: i["attributes"]?.objectValue ?? [:]
            )
            #expect(got == c.expected.boolValue, "\(name)")
        case "compare":
            let got = Rules.compare(i["a"] ?? .null, i["b"] ?? .null).map { $0.rawValue }
            let want = c.expected.doubleValue.map { Int($0) }
            #expect(got == want, "\(name)")
        default:
            Issue.record("Tipo desconocido: \(c.kind)")
        }
    }
}
