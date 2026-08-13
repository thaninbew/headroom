import Foundation

public struct HeadroomConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var reservePercent: Int

    public init(enabled: Bool = true, reservePercent: Int = 10) {
        self.enabled = enabled
        self.reservePercent = min(max(reservePercent, 0), 99)
    }

    public static let `default` = HeadroomConfiguration()
}

public struct RateLimitWindow: Codable, Equatable, Sendable, Identifiable {
    public let usedPercent: Int
    public let windowDurationMins: Int?
    public let resetsAt: Int?

    public init(usedPercent: Int, windowDurationMins: Int? = nil, resetsAt: Int? = nil) {
        self.usedPercent = min(max(usedPercent, 0), 100)
        self.windowDurationMins = windowDurationMins
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Int { max(0, 100 - usedPercent) }
    public var id: String { "\(windowDurationMins ?? -1)-\(resetsAt ?? -1)" }

    public var displayName: String {
        guard let minutes = windowDurationMins else { return "Usage window" }
        if minutes >= 10_080 { return "Weekly" }
        if minutes >= 60, minutes.isMultiple(of: 60) { return "\(minutes / 60)-hour" }
        return "\(minutes)-minute"
    }
}

public struct RateLimitSnapshot: Codable, Equatable, Sendable {
    public let primary: RateLimitWindow?
    public let secondary: RateLimitWindow?

    public init(primary: RateLimitWindow?, secondary: RateLimitWindow?) {
        self.primary = primary
        self.secondary = secondary
    }

    public var windows: [RateLimitWindow] { [primary, secondary].compactMap { $0 } }
}

public enum ProtectionDecision: Equatable, Sendable {
    case allow
    case protect(window: RateLimitWindow)
}

public enum ReservePolicy {
    public static func evaluate(
        snapshot: RateLimitSnapshot,
        configuration: HeadroomConfiguration
    ) -> ProtectionDecision {
        guard configuration.enabled else { return .allow }
        let cutoff = 100 - configuration.reservePercent
        guard let protected = snapshot.windows
            .filter({ $0.usedPercent >= cutoff })
            .max(by: { $0.usedPercent < $1.usedPercent })
        else { return .allow }
        return .protect(window: protected)
    }
}

public struct HeadroomStatus: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let snapshot: RateLimitSnapshot?
    public let error: String?

    public init(checkedAt: Date = Date(), snapshot: RateLimitSnapshot?, error: String?) {
        self.checkedAt = checkedAt
        self.snapshot = snapshot
        self.error = error
    }
}

public enum HookEvent: String, Codable, Sendable {
    case userPromptSubmit = "UserPromptSubmit"
    case postToolUse = "PostToolUse"
}

public struct HookInput: Decodable, Sendable {
    public let hookEventName: String

    enum CodingKeys: String, CodingKey {
        case hookEventName = "hook_event_name"
    }
}

public enum HookResponse: Equatable, Sendable {
    case allow
    case blockPrompt(reason: String)
    case stopTurn(reason: String)

    public func jsonData() throws -> Data {
        let value: [String: Any]
        switch self {
        case .allow:
            value = [:]
        case let .blockPrompt(reason):
            value = [
                "decision": "block",
                "reason": reason,
                "systemMessage": reason,
            ]
        case let .stopTurn(reason):
            value = [
                "continue": false,
                "stopReason": reason,
                "systemMessage": reason,
            ]
        }
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}

public enum HookPolicy {
    public static func response(
        for eventName: String,
        decision: ProtectionDecision,
        reservePercent: Int
    ) -> HookResponse {
        guard case let .protect(window) = decision else { return .allow }
        let reason = "Headroom stopped Codex with \(window.remainingPercent)% remaining in the \(window.displayName.lowercased()) window. The configured reserve is \(reservePercent)%."
        switch HookEvent(rawValue: eventName) {
        case .userPromptSubmit:
            return .blockPrompt(reason: reason)
        case .postToolUse:
            return .stopTurn(reason: reason)
        case nil:
            return .allow
        }
    }
}
