import Foundation

public enum RateLimitScope: Equatable, Hashable, Sendable {
    case route(String)
    case global
}

/// A loss-tolerant observation of Discord's rate-limit response metadata.
/// Missing or malformed fields are represented as nil; unknown fields are
/// ignored. This type records server-provided values and never invents a
/// request budget or retry interval.
public struct RateLimitObservation: Equatable, Sendable {
    public let scope: RateLimitScope
    public let retryAfter: Duration?
    public let limit: Int?
    public let remaining: Int?
    public let resetAfter: Duration?

    public init(
        scope: RateLimitScope,
        retryAfter: Duration? = nil,
        limit: Int? = nil,
        remaining: Int? = nil,
        resetAfter: Duration? = nil
    ) {
        self.scope = scope
        self.retryAfter = retryAfter
        self.limit = limit
        self.remaining = remaining
        self.resetAfter = resetAfter
    }

    /// Creates an observation from header values and an optional Discord 429
    /// JSON body. Header names are case-insensitive. Parsing is deliberately
    /// non-throwing so one malformed field cannot discard useful metadata.
    public init(route: String, headers: [String: String], body: Data? = nil) {
        let normalized = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) },
            uniquingKeysWith: { first, _ in first }
        )
        let bodyValues = Self.bodyValues(from: body)

        let global = Self.bool(
            normalized["x-ratelimit-global"]
        ) ?? bodyValues.global
        self.scope = global == true ? .global : .route(route)
        self.retryAfter = Self.duration(
            normalized["retry-after"]
        ) ?? bodyValues.retryAfter
        self.limit = Self.nonNegativeInteger(normalized["x-ratelimit-limit"])
        self.remaining = Self.nonNegativeInteger(normalized["x-ratelimit-remaining"])
        self.resetAfter = Self.duration(normalized["x-ratelimit-reset-after"])
    }

    private struct BodyValues {
        var global: Bool?
        var retryAfter: Duration?
    }

    private static func bodyValues(from data: Data?) -> BodyValues {
        guard let data,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return BodyValues(global: nil, retryAfter: nil) }

        let global: Bool?
        if let value = dictionary["global"] as? Bool {
            global = value
        } else if let value = dictionary["global"] as? String {
            global = bool(value)
        } else {
            global = nil
        }

        let retryAfter: Duration?
        if let number = dictionary["retry_after"] as? NSNumber {
            retryAfter = duration(number.stringValue)
        } else if let string = dictionary["retry_after"] as? String {
            retryAfter = duration(string)
        } else {
            retryAfter = nil
        }
        return BodyValues(global: global, retryAfter: retryAfter)
    }

    private static func bool(_ value: String?) -> Bool? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "true", "1": return true
        case "false", "0": return false
        default: return nil
        }
    }

    private static func nonNegativeInteger(_ value: String?) -> Int? {
        guard let value, let result = Int(value), result >= 0 else { return nil }
        return result
    }

    /// Parses a finite non-negative decimal number of seconds into nanosecond
    /// precision without using floating point. Values beyond Duration's
    /// representable range are treated as malformed.
    private static func duration(_ value: String?) -> Duration? {
        guard let value, !value.isEmpty, !value.contains(where: { $0 == "e" || $0 == "E" }) else {
            return nil
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2,
              !parts[0].isEmpty,
              parts[0].allSatisfy(Self.isASCIIDigit),
              let whole = UInt64(parts[0]),
              parts[0].first != "-"
        else { return nil }

        let fractional = parts.count == 2 ? String(parts[1]) : ""
        guard fractional.count <= 9,
              fractional.allSatisfy(Self.isASCIIDigit)
        else { return nil }

        let paddedFraction = fractional + String(repeating: "0", count: 9 - fractional.count)
        guard let fraction = UInt64(paddedFraction) else { return nil }
        let (wholeNanoseconds, overflow) = whole.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { return nil }
        let (nanoseconds, additionOverflow) = wholeNanoseconds.addingReportingOverflow(fraction)
        guard !additionOverflow, nanoseconds <= UInt64(Int64.max) else { return nil }
        return .nanoseconds(Int64(nanoseconds))
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first
        else { return false }
        return scalar.value >= 48 && scalar.value <= 57
    }
}

/// Stores the most recent server-provided observations. A partial observation
/// does not erase fields that were previously known, which makes the model
/// tolerant of proxies or response variants that omit optional headers.
public struct RateLimitSnapshot: Equatable, Sendable {
    private var routes: [String: RateLimitObservation] = [:]
    private var globalObservation: RateLimitObservation?

    public init() {}

    public var global: RateLimitObservation? { globalObservation }

    public func observation(forRoute route: String) -> RateLimitObservation? {
        routes[route]
    }

    public mutating func record(_ observation: RateLimitObservation) {
        switch observation.scope {
        case .global:
            globalObservation = merge(globalObservation, with: observation)
        case .route(let route):
            routes[route] = merge(routes[route], with: observation)
        }
    }

    public mutating func clearRoute(_ route: String) {
        routes.removeValue(forKey: route)
    }

    public mutating func clearGlobal() {
        globalObservation = nil
    }

    /// Returns the greater applicable delay when both a global and route
    /// signal exist. The caller owns clocking, expiry, and queue scheduling.
    public func effectiveRetryAfter(forRoute route: String) -> Duration? {
        let routeDelay = routes[route]?.retryAfter
        let globalDelay = globalObservation?.retryAfter
        switch (globalDelay, routeDelay) {
        case let (global?, route?): return Self.maximum(global, route)
        case (let delay?, nil), (nil, let delay?): return delay
        case (nil, nil): return nil
        }
    }

    private func merge(
        _ previous: RateLimitObservation?,
        with current: RateLimitObservation
    ) -> RateLimitObservation {
        guard let previous else { return current }
        return RateLimitObservation(
            scope: current.scope,
            retryAfter: current.retryAfter ?? previous.retryAfter,
            limit: current.limit ?? previous.limit,
            remaining: current.remaining ?? previous.remaining,
            resetAfter: current.resetAfter ?? previous.resetAfter
        )
    }

    private static func maximum(_ lhs: Duration, _ rhs: Duration) -> Duration {
        let left = lhs.components
        let right = rhs.components
        if left.seconds != right.seconds {
            return left.seconds > right.seconds ? lhs : rhs
        }
        return left.attoseconds >= right.attoseconds ? lhs : rhs
    }
}
