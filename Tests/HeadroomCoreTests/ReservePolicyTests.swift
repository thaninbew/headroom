import Foundation
import Testing
@testable import HeadroomCore

@Suite("Reserve policy")
struct ReservePolicyTests {
    let configuration = HeadroomConfiguration(enabled: true, reservePercent: 10)

    @Test("Allows at 89% used")
    func allowsBeforeCutoff() {
        let snapshot = RateLimitSnapshot(
            primary: RateLimitWindow(usedPercent: 89, windowDurationMins: 300),
            secondary: nil
        )
        #expect(ReservePolicy.evaluate(snapshot: snapshot, configuration: configuration) == .allow)
    }

    @Test("Protects exactly at 90% used")
    func protectsAtCutoff() {
        let window = RateLimitWindow(usedPercent: 90, windowDurationMins: 300)
        let decision = ReservePolicy.evaluate(
            snapshot: RateLimitSnapshot(primary: window, secondary: nil),
            configuration: configuration
        )
        #expect(decision == .protect(window: window))
    }

    @Test("Protects whichever reported window is most consumed")
    func protectsSecondaryWindow() {
        let secondary = RateLimitWindow(usedPercent: 93, windowDurationMins: 10_080)
        let decision = ReservePolicy.evaluate(
            snapshot: RateLimitSnapshot(
                primary: RateLimitWindow(usedPercent: 42, windowDurationMins: 300),
                secondary: secondary
            ),
            configuration: configuration
        )
        #expect(decision == .protect(window: secondary))
    }

    @Test("Disabled protection always allows")
    func disabledAllows() {
        let decision = ReservePolicy.evaluate(
            snapshot: RateLimitSnapshot(primary: RateLimitWindow(usedPercent: 100), secondary: nil),
            configuration: HeadroomConfiguration(enabled: false, reservePercent: 10)
        )
        #expect(decision == .allow)
    }
}

@Suite("Hook responses")
struct HookResponseTests {
    let window = RateLimitWindow(usedPercent: 90, windowDurationMins: 300)

    @Test("Prompt boundary blocks before a request")
    func promptBlock() throws {
        let response = HookPolicy.response(
            for: "UserPromptSubmit",
            decision: .protect(window: window),
            reservePercent: 10
        )
        let json = try #require(try JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any])
        #expect(json["decision"] as? String == "block")
        #expect(json["reason"] as? String != nil)
        #expect(json["continue"] == nil)
    }

    @Test("Post-tool boundary stops without asking the model again")
    func postToolStop() throws {
        let response = HookPolicy.response(
            for: "PostToolUse",
            decision: .protect(window: window),
            reservePercent: 10
        )
        let json = try #require(try JSONSerialization.jsonObject(with: response.jsonData()) as? [String: Any])
        #expect(json["continue"] as? Bool == false)
        #expect(json["stopReason"] as? String != nil)
        #expect(json["decision"] == nil)
    }

    @Test("PreToolUse is deliberately unsupported")
    func preToolAllows() {
        let response = HookPolicy.response(
            for: "PreToolUse",
            decision: .protect(window: window),
            reservePercent: 10
        )
        #expect(response == .allow)
    }
}
