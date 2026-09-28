import Foundation

// Reglas puras de audiencia, calendario y frecuencia. El hub (TypeScript, `functions/shared`)
// implementa exactamente lo mismo; la app las usa como respaldo local y el admin para simular.
// Cualquier cambio aquí tiene que ir también allí (y a `functions/shared/test/rules.test.ts`).

/// Lo que se sabe de lo que un usuario ha hecho con una campaña.
public struct ImpressionHistory: Sendable, Hashable, Codable {
    public var shown: [Date]
    public var dismissedAt: Date?
    public var actedAt: Date?

    public init(shown: [Date] = [], dismissedAt: Date? = nil, actedAt: Date? = nil) {
        self.shown = shown; self.dismissedAt = dismissedAt; self.actedAt = actedAt
    }
}

public enum Rules {
    // MARK: Frecuencia

    /// Si la frecuencia permite volver a mostrar la campaña ahora.
    public static func frequencyAllows(_ f: Frequency, history h: ImpressionHistory, now: Date, calendar: Calendar) -> Bool {
        if f.stopOnAction, h.actedAt != nil { return false }
        if let max = f.maxImpressions, max > 0, h.shown.count >= max { return false }
        if let perDay = f.maxPerDay, perDay > 0,
           h.shown.filter({ calendar.isDate($0, inSameDayAs: now) }).count >= perDay { return false }
        let last = h.shown.max()
        switch f.mode {
        case .once:
            return h.shown.isEmpty && h.dismissedAt == nil
        case .every:
            if f.stopOnDismiss, h.dismissedAt != nil { return false }
            return true
        case .cooldown:
            if f.stopOnDismiss, h.dismissedAt != nil { return false }
            guard let last else { return true }
            return now.timeIntervalSince(last) >= (f.cooldownHours ?? 24) * 3600
        case .daily:
            if f.stopOnDismiss, h.dismissedAt != nil { return false }
            guard let last else { return true }
            return !calendar.isDate(last, inSameDayAs: now)
        case .weekly:
            if f.stopOnDismiss, h.dismissedAt != nil { return false }
            guard let last else { return true }
            return now.timeIntervalSince(last) >= 7 * 86400
        }
    }

    // MARK: Calendario

    public static func scheduleAllows(_ s: Schedule, now: Date, userTimeZone: TimeZone?) -> Bool {
        if let start = s.startAt, now < start { return false }
        if let end = s.endAt, now >= end { return false }
        guard !s.daysOfWeek.isEmpty || s.hours != nil else { return true }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone(s.timezone, user: userTimeZone)
        if !s.daysOfWeek.isEmpty {
            // Calendar: 1 = domingo … 7 = sábado → ISO: 1 = lunes … 7 = domingo.
            let wd = cal.component(.weekday, from: now)
            let iso = wd == 1 ? 7 : wd - 1
            if !s.daysOfWeek.contains(iso) { return false }
        }
        if let h = s.hours {
            let hour = cal.component(.hour, from: now)
            let inside = h.from <= h.to ? (hour >= h.from && hour < h.to) : (hour >= h.from || hour < h.to)
            if !inside { return false }
        }
        return true
    }

    static func timeZone(_ id: String, user: TimeZone?) -> TimeZone {
        switch id {
        case "user": user ?? TimeZone(identifier: "UTC")!
        case "UTC", "utc", "": TimeZone(identifier: "UTC")!
        default: TimeZone(identifier: id) ?? TimeZone(identifier: "UTC")!
        }
    }

    // MARK: Audiencia

    /// `attributes` es el diccionario plano que manda la app; los propios pueden ir
    /// en `attributes["custom"]` (se buscan ahí si no están arriba).
    public static func audienceMatches(_ a: Audience, userId: String, campaignId: String, attributes: [String: JSONValue]) -> Bool {
        if !a.userIds.isEmpty, !a.userIds.contains(userId) { return false }
        if let rules = a.rules, !evaluate(rules, attributes) { return false }
        return inRollout(percent: a.percent, userId: userId, campaignId: campaignId)
    }

    public static func inRollout(percent: Double, userId: String, campaignId: String) -> Bool {
        if percent >= 100 { return true }
        if percent <= 0 { return false }
        let bucket = Double(fnv1a32("\(userId):\(campaignId)") % 10000) / 100
        return bucket < percent
    }

    /// FNV-1a de 32 bits sobre UTF-8. Igual en TypeScript.
    public static func fnv1a32(_ s: String) -> UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        for byte in s.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        return hash
    }

    public static func evaluate(_ node: RuleNode, _ attrs: [String: JSONValue]) -> Bool {
        switch node {
        case .all(let nodes): nodes.allSatisfy { evaluate($0, attrs) }
        case .any(let nodes): nodes.isEmpty || nodes.contains { evaluate($0, attrs) }
        case .condition(let c): evaluate(c, attrs)
        }
    }

    static func lookup(_ attr: String, _ attrs: [String: JSONValue]) -> JSONValue? {
        if attr.hasPrefix("custom.") { return attrs["custom"]?[String(attr.dropFirst(7))] }
        if let v = attrs[attr], v != .null { return v }
        if let v = attrs["custom"]?[attr], v != .null { return v }
        return nil
    }

    static func evaluate(_ c: RuleNode.Condition, _ attrs: [String: JSONValue]) -> Bool {
        let actual = lookup(c.attr, attrs)
        switch c.op {
        case .exists:
            return (actual != nil) == (c.value.boolValue ?? true)
        case .eq:
            guard let actual else { return false }
            return compare(actual, c.value) == .orderedSame
        case .neq:
            guard let actual else { return true }
            return compare(actual, c.value) != .orderedSame
        case .in:
            guard let actual else { return false }
            return (c.value.arrayValue ?? [c.value]).contains { compare(actual, $0) == .orderedSame }
        case .nin:
            guard let actual else { return true }
            return !(c.value.arrayValue ?? [c.value]).contains { compare(actual, $0) == .orderedSame }
        case .gt, .gte, .lt, .lte:
            guard let actual, let r = compare(actual, c.value) else { return false }
            switch c.op {
            case .gt: return r == .orderedDescending
            case .gte: return r != .orderedAscending
            case .lt: return r == .orderedAscending
            default: return r != .orderedDescending
            }
        case .contains:
            guard let actual else { return false }
            if let arr = actual.arrayValue { return arr.contains { compare($0, c.value) == .orderedSame } }
            if let s = actual.stringValue, let needle = c.value.stringValue { return s.localizedCaseInsensitiveContains(needle) }
            return false
        }
    }

    /// Compara con coerción: versiones en texto (`1.2`, `1.10.3`) por componentes, números
    /// (o texto numérico) como números, booleanos como booleanos y el resto como texto. `nil` si no se puede.
    public static func compare(_ a: JSONValue, _ b: JSONValue) -> ComparisonResult? {
        if case .bool(let x) = a, let y = b.boolValue { return x == y ? .orderedSame : (x ? .orderedDescending : .orderedAscending) }
        if case .bool(let y) = b, let x = a.boolValue { return x == y ? .orderedSame : (x ? .orderedDescending : .orderedAscending) }
        let aIsText = { if case .string = a { true } else { false } }()
        let bIsText = { if case .string = b { true } else { false } }()
        if aIsText || bIsText, let x = a.stringValue, let y = b.stringValue,
           isVersion(x), isVersion(y), x.contains(".") || y.contains(".") {
            return compareVersions(x, y)
        }
        if let x = numeric(a), let y = numeric(b) { return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending) }
        guard let x = a.stringValue, let y = b.stringValue else { return a == b ? .orderedSame : nil }
        return x == y ? .orderedSame : (x < y ? .orderedAscending : .orderedDescending)
    }

    static func numeric(_ v: JSONValue) -> Double? {
        switch v {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }

    static func isVersion(_ s: String) -> Bool {
        !s.isEmpty && s.allSatisfy { $0.isNumber || $0 == "." } && s.first != "." && s.last != "."
    }

    public static func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
