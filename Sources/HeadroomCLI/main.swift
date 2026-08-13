import Foundation
import HeadroomCore

func printUsage() {
    print("""
    Usage: headroomctl <command>

      check       Read the current Codex quota without changing configuration
      install     Install Headroom binaries and merge its Codex hooks
      uninstall   Remove only Headroom's binaries and Codex hooks
    """)
}

let command = CommandLine.arguments.dropFirst().first
do {
    switch command {
    case "check":
        let client = try CodexAppServerClient()
        let snapshot = try MeterService(client: client).refresh()
        if snapshot.windows.isEmpty { print("No Codex quota windows were reported.") }
        for window in snapshot.windows {
            print("\(window.displayName): \(window.remainingPercent)% remaining")
        }
    case "install":
        try HeadroomInstaller().install()
        print("Headroom installed. Codex will discover the new hooks on its next configuration refresh.")
    case "uninstall":
        try HeadroomInstaller().uninstall()
        print("Headroom removed. Unrelated Codex hooks were preserved.")
    default:
        printUsage()
        exit(command == nil ? EXIT_SUCCESS : EXIT_FAILURE)
    }
} catch {
    FileHandle.standardError.write(Data("headroomctl: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
