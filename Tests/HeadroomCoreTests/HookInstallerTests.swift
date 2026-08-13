import Foundation
import Testing
@testable import HeadroomCore

@Suite("Hook installation")
struct HookInstallerTests {
    let executable = URL(fileURLWithPath: "/Applications/Headroom Support/headroom-hook")

    @Test("Merge preserves unrelated hooks")
    func mergePreservesHooks() throws {
        let existing = Data(#"{"hooks":{"UserPromptSubmit":[{"matcher":"hello","hooks":[{"type":"command","command":"/tmp/other-hook"}]}],"Stop":[{"hooks":[{"type":"command","command":"/tmp/stop"}]}]}}"#.utf8)
        let merged = try HookInstaller.mergedHooks(existing: existing, hookExecutable: executable)
        let root = try #require(try JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let prompts = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
        #expect(prompts.count == 2)
        #expect(hooks["PostToolUse"] != nil)
        #expect(hooks["PreToolUse"] == nil)
        #expect(hooks["Stop"] != nil)
    }

    @Test("Merge is idempotent")
    func mergeIsIdempotent() throws {
        let once = try HookInstaller.mergedHooks(existing: nil, hookExecutable: executable)
        let twice = try HookInstaller.mergedHooks(existing: once, hookExecutable: executable)
        let root = try #require(try JSONSerialization.jsonObject(with: twice) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        for event in ["UserPromptSubmit", "PostToolUse"] {
            let groups = try #require(hooks[event] as? [[String: Any]])
            #expect(groups.count == 1)
        }
    }

    @Test("Removal deletes only Headroom handlers")
    func removalIsScoped() throws {
        let existing = Data(#"{"hooks":{"PostToolUse":[{"hooks":[{"type":"command","command":"/tmp/other"},{"type":"command","command":"/tmp/headroom # HEADROOM_QUOTA_RESERVE"}]}]}}"#.utf8)
        let removed = try HookInstaller.removingHeadroom(from: existing)
        let root = try #require(try JSONSerialization.jsonObject(with: removed) as? [String: Any])
        let hooks = try #require(root["hooks"] as? [String: Any])
        let groups = try #require(hooks["PostToolUse"] as? [[String: Any]])
        let handlers = try #require(groups.first?["hooks"] as? [[String: Any]])
        #expect(handlers.count == 1)
        #expect(handlers.first?["command"] as? String == "/tmp/other")
    }

    @Test("CLI and menu app products cannot collide on case-insensitive macOS")
    func productNamesRemainDistinct() {
        #expect("headroomctl".caseInsensitiveCompare("Headroom") != .orderedSame)
        #expect("headroom-hook".caseInsensitiveCompare("Headroom") != .orderedSame)
    }

    @Test("Installer and uninstaller stay inside the selected home")
    func isolatedLifecycle() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory
            .appendingPathComponent("headroom-install-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        for name in ["headroomctl", "headroom-hook", "Headroom"] {
            let url = source.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let hooksURL = HeadroomPaths.hooksURL(home: home)
        try manager.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/tmp/keep"}]}]}}"#.utf8)
            .write(to: hooksURL)

        let installer = HeadroomInstaller(
            home: home,
            sourceExecutable: source.appendingPathComponent("headroomctl")
        )
        try installer.install()

        #expect(manager.isExecutableFile(atPath: HeadroomPaths.supportDirectory(home: home)
            .appendingPathComponent("bin/headroomctl").path))
        #expect(manager.isExecutableFile(atPath: HeadroomPaths.supportDirectory(home: home)
            .appendingPathComponent("bin/headroom-hook").path))
        #expect(manager.fileExists(atPath: home.appendingPathComponent("Applications/Headroom.app").path))
        let installedHooks = try String(contentsOf: hooksURL, encoding: .utf8)
        #expect(installedHooks.contains(HookInstaller.marker))
        #expect(installedHooks.contains("/tmp/keep"))

        try installer.uninstall()
        let remainingHooks = try String(contentsOf: hooksURL, encoding: .utf8)
        #expect(!remainingHooks.contains(HookInstaller.marker))
        #expect(remainingHooks.contains("/tmp/keep"))
        #expect(!manager.fileExists(atPath: HeadroomPaths.supportDirectory(home: home).path))
        #expect(!manager.fileExists(atPath: home.appendingPathComponent("Applications/Headroom.app").path))
    }
}
