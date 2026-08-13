import Foundation

public enum InstallerError: LocalizedError, Equatable {
    case missingSibling(String)
    case invalidHooksFile

    public var errorDescription: String? {
        switch self {
        case let .missingSibling(name):
            return "The \(name) executable is missing. Run `swift build -c release` before installing."
        case .invalidHooksFile:
            return "The existing Codex hooks file is not a JSON object."
        }
    }
}

public enum HookInstaller {
    public static let marker = "HEADROOM_QUOTA_RESERVE"

    public static func command(for hookExecutable: URL) -> String {
        "\"\(hookExecutable.path.replacingOccurrences(of: "\"", with: "\\\""))\" # \(marker)"
    }

    public static func mergedHooks(existing: Data?, hookExecutable: URL) throws -> Data {
        var root: [String: Any]
        if let existing, !existing.isEmpty {
            guard let object = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
                throw InstallerError.invalidHooksFile
            }
            root = object
        } else {
            root = [:]
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in ["UserPromptSubmit", "PostToolUse"] {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups = removeOwnedGroups(groups)
            groups.append([
                "hooks": [[
                    "type": "command",
                    "command": command(for: hookExecutable),
                    "timeout": 15,
                    "statusMessage": "Checking Headroom reserve",
                ]],
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    public static func removingHeadroom(from existing: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else {
            throw InstallerError.invalidHooksFile
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in ["UserPromptSubmit", "PostToolUse"] {
            let groups = hooks[event] as? [[String: Any]] ?? []
            let cleaned = removeOwnedGroups(groups)
            if cleaned.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = cleaned }
        }
        root["hooks"] = hooks
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func removeOwnedGroups(_ groups: [[String: Any]]) -> [[String: Any]] {
        groups.compactMap { group in
            var copy = group
            let handlers = (group["hooks"] as? [[String: Any]] ?? []).filter { handler in
                guard let command = handler["command"] as? String else { return true }
                return !command.contains(marker)
            }
            guard !handlers.isEmpty else { return nil }
            copy["hooks"] = handlers
            return copy
        }
    }
}

public struct HeadroomInstaller {
    public let home: URL
    public let sourceDirectory: URL

    public init(
        home: URL = HeadroomPaths.defaultHome,
        sourceExecutable: URL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    ) {
        self.home = home
        self.sourceDirectory = sourceExecutable.deletingLastPathComponent()
    }

    public func install() throws {
        let manager = FileManager.default
        let support = HeadroomPaths.supportDirectory(home: home)
        let bin = support.appendingPathComponent("bin", isDirectory: true)
        try manager.createDirectory(at: bin, withIntermediateDirectories: true)

        for name in ["headroomctl", "headroom-hook"] {
            let source = sourceDirectory.appendingPathComponent(name)
            guard manager.isExecutableFile(atPath: source.path) else { throw InstallerError.missingSibling(name) }
            let destination = bin.appendingPathComponent(name)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: source, to: destination)
        }

        let hooksURL = HeadroomPaths.hooksURL(home: home)
        try manager.createDirectory(at: hooksURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = manager.fileExists(atPath: hooksURL.path) ? try Data(contentsOf: hooksURL) : nil
        let merged = try HookInstaller.mergedHooks(
            existing: existing,
            hookExecutable: bin.appendingPathComponent("headroom-hook")
        )
        try merged.write(to: hooksURL, options: .atomic)

        let appBinary = sourceDirectory.appendingPathComponent("Headroom")
        if manager.isExecutableFile(atPath: appBinary.path) {
            try installApp(binary: appBinary, manager: manager)
        }
        let store = ConfigurationStore(url: HeadroomPaths.configurationURL(home: home))
        if !manager.fileExists(atPath: store.url.path) { try store.save(.default) }
    }

    public func uninstall() throws {
        let manager = FileManager.default
        let hooksURL = HeadroomPaths.hooksURL(home: home)
        if manager.fileExists(atPath: hooksURL.path) {
            let cleaned = try HookInstaller.removingHeadroom(from: Data(contentsOf: hooksURL))
            try cleaned.write(to: hooksURL, options: .atomic)
        }
        let app = home.appendingPathComponent("Applications/Headroom.app")
        if manager.fileExists(atPath: app.path) { try manager.removeItem(at: app) }
        let support = HeadroomPaths.supportDirectory(home: home)
        if manager.fileExists(atPath: support.path) { try manager.removeItem(at: support) }
    }

    private func installApp(binary: URL, manager: FileManager) throws {
        let app = home.appendingPathComponent("Applications/Headroom.app")
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        if manager.fileExists(atPath: app.path) { try manager.removeItem(at: app) }
        try manager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try manager.copyItem(at: binary, to: macOS.appendingPathComponent("Headroom"))
        let plist: [String: Any] = [
            "CFBundleExecutable": "Headroom",
            "CFBundleIdentifier": "com.thaninkongkiatsophon.headroom",
            "CFBundleName": "Headroom",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "14.0",
            "LSUIElement": true,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"), options: .atomic)
    }
}
