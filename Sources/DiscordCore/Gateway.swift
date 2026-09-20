import Foundation

/// Gateway opcodes that Discord currently documents. Unknown values survive
/// decoding so a new server opcode cannot terminate an account session.
public enum GatewayOpcode: Codable, Hashable, Sendable {
    case dispatch
    case heartbeat
    case identify
    case presenceUpdate
    case voiceStateUpdate
    case resume
    case reconnect
    case requestGuildMembers
    case invalidSession
    case hello
    case heartbeatAcknowledged
    case requestSoundboardSounds
    case updateTimeSpentSessionId
    case unknown(Int)

    public init(rawValue: Int) {
        switch rawValue {
        case 0: self = .dispatch
        case 1: self = .heartbeat
        case 2: self = .identify
        case 3: self = .presenceUpdate
        case 4: self = .voiceStateUpdate
        case 6: self = .resume
        case 7: self = .reconnect
        case 8: self = .requestGuildMembers
        case 9: self = .invalidSession
        case 10: self = .hello
        case 11: self = .heartbeatAcknowledged
        case 12: self = .requestSoundboardSounds
        case 13: self = .updateTimeSpentSessionId
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: Int {
        switch self {
        case .dispatch: return 0
        case .heartbeat: return 1
        case .identify: return 2
        case .presenceUpdate: return 3
        case .voiceStateUpdate: return 4
        case .resume: return 6
        case .reconnect: return 7
        case .requestGuildMembers: return 8
        case .invalidSession: return 9
        case .hello: return 10
        case .heartbeatAcknowledged: return 11
        case .requestSoundboardSounds: return 12
        case .updateTimeSpentSessionId: return 13
        case .unknown(let value): return value
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(Int.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// Connection lifecycle states. State transitions belong to the Gateway actor;
/// this value type is intentionally passive and easy to exercise in fixtures.
public enum GatewayConnectionState: Equatable, Sendable {
    case loggedOut
    case disconnected
    case connecting(attempt: Int)
    case identifying
    case ready(sessionID: String, sequence: Int)
    case resuming(sessionID: String, sequence: Int)
    case backingOff(attempt: Int, delay: Duration)
}

public enum GatewayDisconnectReason: Equatable, Sendable {
    case network
    case serverRequestedReconnect
    case invalidSession
    case authentication
    case cancelled
}

/// A small deterministic exponential backoff. `attempt` is one-based; values
/// at or below zero return no delay. No randomness is involved, making retry
/// behavior reproducible in tests and debuggable in logs.
public struct ExponentialBackoff: Hashable, Sendable {
    private let baseNanoseconds: UInt64
    private let maximumNanoseconds: UInt64
    private let multiplier: UInt64

    public init(
        base: Duration = .milliseconds(250),
        maximum: Duration = .seconds(30),
        multiplier: UInt64 = 2
    ) throws {
        let baseNanoseconds = try Self.nanoseconds(from: base)
        let maximumNanoseconds = try Self.nanoseconds(from: maximum)
        guard maximumNanoseconds >= baseNanoseconds else {
            throw ExponentialBackoffError.maximumBeforeBase
        }
        guard multiplier > 0 else { throw ExponentialBackoffError.invalidMultiplier }
        self.baseNanoseconds = baseNanoseconds
        self.maximumNanoseconds = maximumNanoseconds
        self.multiplier = multiplier
    }

    public func delay(forAttempt attempt: Int) -> Duration {
        guard attempt > 0, baseNanoseconds > 0 else { return .zero }
        if multiplier == 1 { return .nanoseconds(Int64(baseNanoseconds)) }
        var value = baseNanoseconds
        for _ in 1..<attempt {
            if value >= maximumNanoseconds { return .nanoseconds(Int64(maximumNanoseconds)) }
            let (next, overflow) = value.multipliedReportingOverflow(by: multiplier)
            value = overflow || next > maximumNanoseconds ? maximumNanoseconds : next
        }
        return .nanoseconds(Int64(min(value, maximumNanoseconds)))
    }

    private static func nanoseconds(from duration: Duration) throws -> UInt64 {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            throw ExponentialBackoffError.negativeDuration
        }
        let seconds = UInt64(components.seconds)
        let (whole, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        guard !overflow else { throw ExponentialBackoffError.durationOverflow }
        let nanos = UInt64(components.attoseconds / 1_000_000_000)
        let (result, nanosOverflow) = whole.addingReportingOverflow(nanos)
        guard !nanosOverflow else { throw ExponentialBackoffError.durationOverflow }
        guard result <= UInt64(Int64.max) else { throw ExponentialBackoffError.durationOverflow }
        return result
    }
}

public enum ExponentialBackoffError: Error, Equatable, Sendable {
    case negativeDuration
    case durationOverflow
    case maximumBeforeBase
    case invalidMultiplier
}
