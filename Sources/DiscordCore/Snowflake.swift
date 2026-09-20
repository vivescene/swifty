import Foundation

/// A Discord snowflake represented exactly as its decimal wire string.
///
/// Snowflakes are deliberately not converted to an integer. This avoids
/// precision loss in JSON adapters and keeps the type usable on all targets.
public struct Snowflake: Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public var description: String { rawValue }

    public init(_ value: String) throws {
        guard !value.isEmpty else { throw SnowflakeError.empty }
        guard value.unicodeScalars.allSatisfy({ (48...57).contains($0.value) }) else {
            throw SnowflakeError.notDecimal(value)
        }
        guard value == "0" || value.first != "0" else {
            throw SnowflakeError.leadingZero(value)
        }
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum SnowflakeError: Error, Equatable, Sendable {
    case empty
    case notDecimal(String)
    case leadingZero(String)
}
