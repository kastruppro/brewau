import Foundation
import Darwin

private let root = URL(fileURLWithPath: "/opt/brewau", isDirectory: true)
private let state = root.appendingPathComponent("var/state", isDirectory: true)
private let config = root.appendingPathComponent("etc/brewau.conf")

@main struct BrewauAgent {
    static func main() {
        umask(0o022)
        do {
            guard CommandLine.arguments.count == 2 else { throw BrewauError.message("Expected one command.") }
            switch CommandLine.arguments[1] {
            case "configure":
                try requireRoot()
                let data = FileHandle.standardInput.readData(ofLength: 8193)
                let settings = try ScheduleSettings.decodeRequest(data)
                try withFileLock(root.appendingPathComponent("etc/settings.lock").path) {
                    let existing = try String(contentsOf: config, encoding: .utf8)
                    let changed = settings.replacingConfig(existing)
                    try Data(changed.utf8).write(to: config, options: .atomic)
                    guard chmod(config.path, 0o644) == 0, chown(config.path, 0, 0) == 0 else { throw BrewauError.message("Could not protect configuration.") }
                }
                print("Tidsplan gemt.")
            case "completions":
                try requireRoot()
                try withFileLock(root.appendingPathComponent("etc/completions.lock").path) { try refreshCompletions() }
            case "scan", "upgrade", "scheduled":
                guard let user = getpwuid(getuid()), String(cString: user.pointee.pw_name) == "_brewau" else {
                    throw BrewauError.message("This command must run as _brewau.")
                }
                try withFileLock(state.appendingPathComponent("operation.lock").path, nonblocking: true) {
                    try perform(CommandLine.arguments[1])
                }
            default: throw BrewauError.message("Unknown command.")
            }
        } catch {
            fputs("brewau: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
    static func requireRoot() throws {
        guard getuid() == 0 else { throw BrewauError.message("This command must run as root.") }
    }
    static func perform(_ request: String) throws {
        let settings = try ScheduleSettings.readConfig(String(contentsOf: config, encoding: .utf8))
        var kind = request
        let now = Date()
        if request == "scheduled" {
            let installedAt = (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("etc/installed").path)[.creationDate] as? Date) ?? now
            let lastUpgrade = timestamp("upgrade-attempt")
            let lastScan = timestamp("scan-attempt")
            if settings.upgradeDue(at: now, lastAttempt: lastUpgrade, installedAt: installedAt) {
                kind = "upgrade"
            } else if lastScan == nil || now.timeIntervalSince(lastScan!) >= Double(settings.scanMinutes * 60) {
                kind = "scan"
            } else { return }
        }
        // Record attempts before running, to avoid a minute-by-minute retry storm on network failure.
        try Data(String(now.timeIntervalSince1970).utf8).write(to: state.appendingPathComponent("\(kind)-attempt"), options: .atomic)
        if kind == "upgrade" { try Data(String(now.timeIntervalSince1970).utf8).write(to: state.appendingPathComponent("scan-attempt"), options: .atomic) }
        var operation = OperationState(kind: kind, started: now, processID: getpid())
        try writeJSON(operation, to: state.appendingPathComponent("operation.json"))
        var failure: Error?
        do {
            // Child logs go directly to launchd's log file, not a terminal or a memory buffer.
            let child = Process()
            child.executableURL = root.appendingPathComponent("libexec/brewau-upgrade")
            child.arguments = [kind]
            child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
            child.currentDirectoryURL = URL(fileURLWithPath: "/")
            child.standardInput = FileHandle.nullDevice
            try child.run()
            child.waitUntilExit()
            if child.terminationStatus != 0 { throw BrewauError.message("\(kind == "scan" ? "Scanning" : "Opdatering") mislykkedes. Se loggen for detaljer.") }
        } catch { failure = error }
        // A fixed root-only command refreshes trusted completion copies after any Homebrew run.
        do { _ = try runCommand("/usr/bin/sudo", ["-n", root.appendingPathComponent("libexec/brewau-agent").path, "completions"]) }
        catch { if failure == nil { failure = error } }
        operation.finished = Date()
        operation.succeeded = failure == nil
        operation.message = failure?.localizedDescription
        try writeJSON(operation, to: state.appendingPathComponent("operation.json"))
        try writeJSON(operation, to: state.appendingPathComponent("last-\(kind).json"))
        if let failure { throw failure }
    }
    static func timestamp(_ name: String) -> Date? {
        guard let text = try? String(contentsOf: state.appendingPathComponent(name), encoding: .utf8), let value = Double(text) else { return nil }
        return Date(timeIntervalSince1970: value)
    }
}

func refreshCompletions() throws {
    let count = try copyCompletions(from: URL(fileURLWithPath: "/opt/homebrew/share/zsh/site-functions"),
                                    into: root.appendingPathComponent("share/zsh/site-functions", isDirectory: true),
                                    prefix: URL(fileURLWithPath: "/opt/homebrew"), owner: 0, group: 0)
    print("Terminal-completions opdateret (\(count)).")
}
