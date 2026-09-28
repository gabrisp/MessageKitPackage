import Foundation
import Testing
@testable import MessagesKit

@Suite("Reglas")
struct RulesTests {
    let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    func d(_ s: String) -> Date { ISO8601.date(from: s)! }

    @Test("Frecuencia")
    func frequency() {
        let now = d("2026-10-10T12:00:00Z")
        let yesterday = d("2026-10-09T12:00:00Z")
        let earlier = d("2026-10-10T08:00:00Z")
        #expect(Rules.frequencyAllows(.init(mode: .once), history: .init(), now: now, calendar: utc))
        #expect(!Rules.frequencyAllows(.init(mode: .once), history: .init(shown: [yesterday]), now: now, calendar: utc))
        #expect(!Rules.frequencyAllows(.init(mode: .daily), history: .init(shown: [earlier]), now: now, calendar: utc))
        #expect(Rules.frequencyAllows(.init(mode: .daily, stopOnDismiss: false), history: .init(shown: [yesterday]), now: now, calendar: utc))
        #expect(!Rules.frequencyAllows(.init(mode: .cooldown, cooldownHours: 6), history: .init(shown: [earlier]), now: now, calendar: utc))
        #expect(Rules.frequencyAllows(.init(mode: .cooldown, cooldownHours: 3), history: .init(shown: [earlier]), now: now, calendar: utc))
        #expect(!Rules.frequencyAllows(.init(mode: .every, maxImpressions: 2), history: .init(shown: [yesterday, earlier]), now: now, calendar: utc))
        #expect(!Rules.frequencyAllows(.init(mode: .every, maxPerDay: 1), history: .init(shown: [earlier]), now: now, calendar: utc))
        #expect(!Rules.frequencyAllows(.init(mode: .every, stopOnDismiss: true), history: .init(shown: [earlier], dismissedAt: earlier), now: now, calendar: utc))
        #expect(!Rules.frequencyAllows(.init(mode: .every, stopOnAction: true), history: .init(actedAt: earlier), now: now, calendar: utc))
        #expect(Rules.frequencyAllows(.init(mode: .every, stopOnDismiss: false), history: .init(shown: [earlier], dismissedAt: earlier), now: now, calendar: utc))
    }

    @Test("Calendario")
    func schedule() {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        // Sábado 10 de octubre de 2026, 20:30 UTC = 22:30 en Madrid.
        let now = d("2026-10-10T20:30:00Z")
        #expect(Rules.scheduleAllows(.init(), now: now, userTimeZone: madrid))
        #expect(!Rules.scheduleAllows(.init(startAt: d("2026-10-11T00:00:00Z")), now: now, userTimeZone: madrid))
        #expect(!Rules.scheduleAllows(.init(endAt: d("2026-10-10T20:00:00Z")), now: now, userTimeZone: madrid))
        #expect(!Rules.scheduleAllows(.init(daysOfWeek: [1, 2, 3, 4, 5]), now: now, userTimeZone: madrid))
        #expect(Rules.scheduleAllows(.init(daysOfWeek: [6]), now: now, userTimeZone: madrid))
        #expect(!Rules.scheduleAllows(.init(hours: .init(from: 9, to: 21)), now: now, userTimeZone: madrid))
        #expect(Rules.scheduleAllows(.init(timezone: "UTC", hours: .init(from: 9, to: 21)), now: now, userTimeZone: madrid))
        #expect(Rules.scheduleAllows(.init(hours: .init(from: 22, to: 2)), now: now, userTimeZone: madrid), "Franja que cruza la medianoche")
    }

    @Test("Audiencia y comparaciones")
    func audience() {
        let attrs: [String: JSONValue] = [
            "isPro": false, "language": "es", "appVersion": "1.10.2", "daysSinceInstall": 4,
            "custom": ["garmentCount": 12, "tags": ["work", "gym"]],
        ]
        func rule(_ attr: String, _ op: RuleNode.Condition.Op, _ v: JSONValue) -> Bool {
            Rules.evaluate(.condition(.init(attr: attr, op: op, value: v)), attrs)
        }
        #expect(rule("isPro", .eq, false))
        #expect(rule("isPro", .eq, "false"))
        #expect(rule("language", .in, ["es", "ca"]))
        #expect(rule("language", .nin, ["en"]))
        #expect(rule("appVersion", .gte, "1.2"), "1.10.2 >= 1.2 como versión, no como número")
        #expect(rule("appVersion", .lt, "1.11"))
        #expect(rule("daysSinceInstall", .gte, 3))
        #expect(rule("garmentCount", .gt, 10), "Busca en custom")
        #expect(rule("custom.garmentCount", .lte, 12))
        #expect(rule("tags", .contains, "gym"))
        #expect(rule("country", .exists, false))
        #expect(!rule("country", .eq, "ES"))
        #expect(rule("country", .neq, "ES"))

        let audience = Audience(rules: .all([
            .condition(.init(attr: "isPro", op: .eq, value: false)),
            .any([.condition(.init(attr: "language", op: .eq, value: "en")), .condition(.init(attr: "daysSinceInstall", op: .gte, value: 3))]),
        ]))
        #expect(Rules.audienceMatches(audience, userId: "u1", campaignId: "c1", attributes: attrs))
        #expect(!Rules.audienceMatches(Audience(userIds: ["u2"]), userId: "u1", campaignId: "c1", attributes: attrs))
    }

    @Test("Despliegue parcial estable y repartido")
    func rollout() {
        #expect(Rules.fnv1a32("") == 0x811C_9DC5)
        #expect(Rules.fnv1a32("a") == 0xE40C_292C)
        let ids = (0..<2000).map { "user-\($0)" }
        let inside = ids.filter { Rules.inRollout(percent: 25, userId: $0, campaignId: "c") }.count
        #expect((400...600).contains(inside), "≈25 %: \(inside)")
        #expect(ids.allSatisfy { Rules.inRollout(percent: 25, userId: $0, campaignId: "c") == Rules.inRollout(percent: 25, userId: $0, campaignId: "c") })
    }
}
