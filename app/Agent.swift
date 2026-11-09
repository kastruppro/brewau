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
            case "self-update", "self-update-now":
                // Root: installs brewau's package. Holding the operation lock keeps scans and
                // upgrades out; the marker tells the package scripts that this job is the installer.
                try requireRoot()
                let now = CommandLine.arguments[1] == "self-update-now"
                if !now, !FileManager.default.fileExists(atPath: state.appendingPathComponent("self-update-due").path) { return }
                guard let account = getpwnam("_brewau") else { throw BrewauError.message("_brewau is missing.") }
                let ran: Void? = try withFileLock(state.appendingPathComponent("operation.lock").path, nonblocking: true,
                                           owner: (account.pointee.pw_uid, account.pointee.pw_gid)) {
                    try selfUpdate(now: now)
                }
                if ran == nil, now { throw BrewauError.message("brewau scanner eller opdaterer; prøv igen, når det er færdigt.") }
            case "scan", "upgrade", "scheduled":
                guard let user = getpwuid(getuid()), String(cString: user.pointee.pw_name) == "_brewau" else {
                    throw BrewauError.message("This command must run as _brewau.")
                }
                try withFileLock(state.appendingPathComponent("operation.lock").path, nonblocking: true) {
                    try perform(CommandLine.arguments[1])
                }
            case "clear-blocked":
                // Root marks the retry because the state directory belongs to _brewau.
                // The next upgrade drops the block list and tries the casks again.
                try requireRoot()
                try requestBlockedRetry()
                BrewauLog.agent.notice("blocked casks will be retried on the next upgrade")
                print("Blocked casks will be retried on the next upgrade.")
            default: throw BrewauError.message("Unknown command.")
            }
        } catch {
            if let line = (error as? BrewauError)?.logDescription { fputs("\(line)\n", stderr) }
            else { fputs("brewau: \(brewauSingleLine(error.localizedDescription, limit: 1000))\n", stderr) }
            exit(1)
        }
    }
    static func requireRoot() throws {
        guard getuid() == 0 else { throw BrewauError.message("This command must run as root.") }
    }
    /// `O_NOFOLLOW` and no `O_TRUNC`: _brewau owns the directory, so a symlink planted there
    /// must never make root create or shorten a file somewhere else. `O_NONBLOCK` keeps a
    /// FIFO planted in its place from making root wait for a reader, and `fstat` then
    /// refuses anything that is not a regular file.
    static func requestBlockedRetry() throws {
        let path = state.appendingPathComponent("clear-blocked").path
        let descriptor = open(path, O_CREAT | O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o644))
        guard descriptor >= 0 else { throw BrewauError.message("Kunne ikke anmode om et nyt forsøg.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw BrewauError.message("Kunne ikke anmode om et nyt forsøg: uventet fil i tilstandsmappen.")
        }
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
        BrewauLog.agent.notice("\(kind, privacy: .public) started")
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
            if child.terminationStatus != 0 { throw resultFailure(kind, exit: child.terminationStatus, startedAt: now) }
        } catch { failure = error }
        // A fixed root-only command refreshes trusted completion copies after any Homebrew run.
        do { _ = try runCommand("/usr/bin/sudo", ["-n", root.appendingPathComponent("libexec/brewau-agent").path, "completions"]) }
        catch { if failure == nil { failure = error } }
        operation.finished = Date()
        operation.succeeded = failure == nil
        operation.message = failure?.localizedDescription
        try writeJSON(operation, to: state.appendingPathComponent("operation.json"))
        try writeJSON(operation, to: state.appendingPathComponent("last-\(kind).json"))
        if let failure {
            // resultFailure already carries a tagged English line; anything else (a missing
            // helper, a failed completions refresh) gets one here so upgrade.log stays uniform.
            guard (failure as? BrewauError)?.logDescription != nil else {
                // The description can be a child's output: upgrade.log gets it as one
                // flattened line, the unified log only the fact that the job failed.
                BrewauLog.agent.error("\(kind, privacy: .public) failed")
                throw BrewauError.reported(ui: failure.localizedDescription,
                                           log: brewauLogLine(kind, "failed: \(failure.localizedDescription)"))
            }
            throw failure
        }
        // The script already wrote its own lines to upgrade.log; this only mirrors the outcome
        // into the unified log.
        let file = state.appendingPathComponent(kind == "scan" ? "last-scan-result.json" : "last-result.json")
        let result = correlatedResult(readRunResult(file), job: kind, startedAt: now)
        BrewauLog.agent.notice("\(kind, privacy: .public) finished: \(result?.logSummary ?? "no result for this run", privacy: .public)")
    }
    /// The script records what actually went wrong, so the run no longer reports a generic
    /// "see the log for details". The GUI gets Danish; upgrade.log and the unified log get
    /// the English line, tagged like the shell layer's own lines.
    static func resultFailure(_ kind: String, exit code: Int32, startedAt: Date) -> Error {
        let file = state.appendingPathComponent(kind == "scan" ? "last-scan-result.json" : "last-result.json")
        // Only a result this run published may explain it. A worker that died before writing
        // one would otherwise be explained by the previous run's result.
        let result = correlatedResult(readRunResult(file), job: kind, startedAt: startedAt)
            .flatMap { $0.hasSomethingToReport ? $0 : nil }
        let english = result?.logSummary ?? "exited with code \(code) and left no usable result"
        let danish = result?.danishSummary() ?? RunResult.danishStatus(result?.status ?? "", job: kind)
        BrewauLog.agent.error("\(kind, privacy: .public) failed: \(english, privacy: .public)")
        return BrewauError.reported(ui: danish, log: brewauLogLine(kind, english))
    }
    static func selfUpdate(now: Bool) throws {
        let marker = root.appendingPathComponent("etc/self-update.pid")
        try Data("\(getpid())\n".utf8).write(to: marker, options: .atomic)
        defer { try? FileManager.default.removeItem(at: marker) }
        let child = Process()
        child.executableURL = root.appendingPathComponent("libexec/brewau-setup")
        child.arguments = now ? ["self-update", "--now"] : ["self-update"]
        child.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        child.currentDirectoryURL = URL(fileURLWithPath: "/")
        child.standardInput = FileHandle.nullDevice
        BrewauLog.agent.notice("self-update started")
        try child.run()
        child.waitUntilExit()
        if child.terminationStatus != 0 {
            BrewauLog.agent.error("self-update failed: brewau-setup exited \(child.terminationStatus)")
            throw BrewauError.reported(ui: "Selvopdatering mislykkedes. Se loggen for detaljer.",
                                       log: brewauLogLine("self-update", "brewau-setup self-update exited \(child.terminationStatus)"))
        }
        BrewauLog.agent.notice("self-update finished")
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
