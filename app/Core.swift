import Foundation
import Darwin
import os

/// One subsystem for the GUI, the scheduler and the privileged helper, so a single
/// `log show --predicate 'subsystem == "com.kastruppro.brewau"'` covers all three.
/// Nothing here may carry secrets, file contents or a full environment.
enum BrewauLog {
    static let app = Logger(subsystem: "com.kastruppro.brewau", category: "app")
    static let agent = Logger(subsystem: "com.kastruppro.brewau", category: "agent")
    static let helper = Logger(subsystem: "com.kastruppro.brewau", category: "helper")
}

enum BrewauError: LocalizedError {
    case message(String)
    /// Danish text for the GUI plus a separate English line for upgrade.log and the unified log.
    case reported(ui: String, log: String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .reported(let ui, _): return ui
        }
    }
    /// The English wording to print where the log is read, not the user interface.
    var logDescription: String? { if case .reported(_, let text) = self { return text }; return nil }
}

struct ScheduleSettings: Codable, Equatable, Sendable {
    var autoUpgrade = true
    var scanMinutes = 60
    var mode = "daily"
    var intervalHours = 1
    var weekday = 2 // Calendar: Sunday = 1.
    var minutes = [240]
    var updateHomebrew = true
    var greedy = true

    func validate() throws {
        guard [15, 30, 60, 360, 720, 1440].contains(scanMinutes),
              ["interval", "daily", "weekly"].contains(mode),
              [1, 2, 4, 6, 12, 24].contains(intervalHours), (1...7).contains(weekday),
              !minutes.isEmpty, minutes.count <= 24, Set(minutes).count == minutes.count,
              minutes.allSatisfy({ (0..<1440).contains($0) }) else {
            throw BrewauError.message("Ugyldig tidsplan. Vælg forskellige tidspunkter og et gyldigt interval.")
        }
    }
    static func readConfig(_ text: String) throws -> ScheduleSettings {
        let values = configValues(text)
        var result = ScheduleSettings()
        func boolean(_ key: String, _ fallback: Bool) -> Bool {
            guard let value = values[key] else { return fallback }
            return ["1", "yes", "true", "on"].contains(value.lowercased())
        }
        result.autoUpgrade = boolean("AUTO_UPGRADE", true)
        result.greedy = boolean("UPGRADE_GREEDY", true)
        result.updateHomebrew = boolean("UPDATE_HOMEBREW", true)
        result.scanMinutes = Int(values["SCAN_MINUTES"] ?? "60") ?? 0
        result.mode = values["UPGRADE_MODE"] ?? "daily"
        result.intervalHours = Int(values["UPGRADE_INTERVAL_HOURS"] ?? "1") ?? 0
        result.weekday = Int(values["UPGRADE_WEEKDAY"] ?? "2") ?? 0
        if let times = values["UPGRADE_TIMES"], !times.isEmpty {
            let entries = times.split(separator: " ")
            result.minutes = entries.compactMap { Int($0) }
            guard entries.count == result.minutes.count else { throw BrewauError.message("Ugyldige tidspunkter i brewau.conf.") }
        } else {
            let hour = Int(values["UPGRADE_HOUR"] ?? "4") ?? -1
            let minute = Int(values["UPGRADE_MINUTE"] ?? "0") ?? -1
            guard (0...23).contains(hour), (0...59).contains(minute) else { throw BrewauError.message("Ugyldigt tidspunkt i brewau.conf.") }
            result.minutes = [hour * 60 + minute]
        }
        try result.validate()
        return result
    }
    static func decodeRequest(_ data: Data) throws -> ScheduleSettings {
        let allowed: Set<String> = ["autoUpgrade", "scanMinutes", "mode", "intervalHours", "weekday", "minutes", "updateHomebrew", "greedy"]
        guard data.count <= 8192, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == allowed else { throw BrewauError.message("Ugyldig konfigurationsanmodning.") }
        let result = try JSONDecoder().decode(Self.self, from: data)
        try result.validate()
        return result
    }
    var configEntries: [String: String] {
        ["AUTO_UPGRADE": autoUpgrade ? "1" : "0", "SCAN_MINUTES": "\(scanMinutes)",
         "UPGRADE_MODE": mode, "UPGRADE_INTERVAL_HOURS": "\(intervalHours)",
         "UPGRADE_WEEKDAY": "\(weekday)", "UPGRADE_TIMES": minutes.sorted().map(String.init).joined(separator: " "),
         "UPDATE_HOMEBREW": updateHomebrew ? "1" : "0", "UPGRADE_GREEDY": greedy ? "1" : "0"]
    }
    func replacingConfig(_ text: String) -> String {
        var entries = configEntries
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let key = String(line.prefix(while: { $0 != "=" })).trimmingCharacters(in: .whitespaces)
            if configEntries[key] != nil {
                if let value = entries.removeValue(forKey: key) { lines.append("\(key)=\"\(value)\"") }
            } else { lines.append(line) }
        }
        for key in entries.keys.sorted() { lines.append("\(key)=\"\(entries[key]!)\"") }
        return lines.joined(separator: "\n") + "\n"
    }
    func latestOccurrence(at now: Date, calendar: Calendar = .current) -> Date? {
        guard autoUpgrade, mode != "interval" else { return nil }
        // Calendar arithmetic preserves local wall times across DST and sleeping Macs.
        for offset in 0...7 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { continue }
            if mode == "weekly", calendar.component(.weekday, from: day) != weekday { continue }
            let dates = minutes.compactMap { value in
                calendar.date(bySettingHour: value / 60, minute: value % 60, second: 0, of: day)
            }.filter { $0 <= now }
            if let latest = dates.max() { return latest }
        }
        return nil
    }
    func upgradeDue(at now: Date, lastAttempt: Date?, installedAt: Date, calendar: Calendar = .current) -> Bool {
        guard autoUpgrade else { return false }
        let last = lastAttempt ?? installedAt
        if mode == "interval" { return now.timeIntervalSince(last) >= Double(intervalHours * 3600) }
        guard let occurrence = latestOccurrence(at: now, calendar: calendar) else { return false }
        return occurrence > last
    }
    var summary: String {
        guard autoUpgrade else { return "Manuel opdatering" }
        if mode == "interval" { return intervalHours == 1 ? "Hver time" : "Hver \(intervalHours). time" }
        let times = minutes.sorted().map { String(format: "%02d.%02d", $0 / 60, $0 % 60) }.joined(separator: " og ")
        let weekdays = ["søndag", "mandag", "tirsdag", "onsdag", "torsdag", "fredag", "lørdag"]
        return mode == "weekly" ? "Hver \(weekdays[weekday - 1]) kl. \(times)" : "Hver dag kl. \(times)"
    }
}

func configValues(_ text: String) -> [String: String] {
    var values: [String: String] = [:]
    for line in text.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
        values[String(trimmed[..<equals])] = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }
    return values
}

struct PackageUpdate: Identifiable, Equatable, Sendable {
    let id: String
    let token: String
    let name: String
    let installed: String
    let available: String
    let isCask: Bool
    let blocked: Bool
}

struct InstalledApp: Identifiable, Equatable, Sendable {
    var id: String { token + "|" + path }
    let token: String
    let name: String
    let path: String
    let version: String
    let installedAt: Date?
}

enum BrewData {
    static func object(_ data: Data) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BrewauError.message("Homebrew returnerede ugyldige data.") }
        return object
    }
    static func updates(_ data: Data, exclusions: Set<String> = []) throws -> [PackageUpdate] {
        let object = try object(data)
        guard let formulae = object["formulae"] as? [[String: Any]], let casks = object["casks"] as? [[String: Any]] else {
            throw BrewauError.message("Homebrews opdateringsliste mangler formulae eller casks.")
        }
        return try [(false, formulae), (true, casks)].flatMap { isCask, records in
            try records.map { row -> PackageUpdate in
                guard let token = row["name"] as? String, let current = row["current_version"] as? String,
                      let versions = row["installed_versions"] as? [String] else { throw BrewauError.message("En opdatering mangler versionsdata.") }
                let installed = versions.joined(separator: ", ")
                return PackageUpdate(id: (isCask ? "cask:" : "formula:") + token, token: token,
                                     name: token, installed: installed, available: current, isCask: isCask,
                                     blocked: (row["pinned"] as? Bool == true) || exclusions.contains(String(token.split(separator: "/").last ?? "")))
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    static func apps(_ data: Data, applicationURL: (String) -> URL? = { _ in nil }) throws -> [InstalledApp] {
        let object = try object(data)
        guard let casks = object["casks"] as? [[String: Any]] else { throw BrewauError.message("App-listen kunne ikke læses.") }
        return casks.flatMap { row -> [InstalledApp] in
            guard let token = row["token"] as? String, let artifacts = row["artifacts"] as? [[String: Any]] else { return [] }
            let version = row["installed"] as? String ?? row["version"] as? String ?? "Ukendt"
            let installedAt = (row["installed_time"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            let direct = artifacts.compactMap { artifact -> InstalledApp? in
                guard let apps = artifact["app"] as? [Any], let source = apps.first as? String else { return nil }
                let options = apps.compactMap { $0 as? [String: Any] }.first
                let target = artifact["target"] as? String ?? options?["target"] as? String ?? (source as NSString).lastPathComponent
                let path = target.hasPrefix("/") ? target : "/Applications/" + target
                guard path.hasPrefix("/Applications/"), path.hasSuffix(".app"), !path.contains("/../"), !path.contains("/./") else { return nil }
                return InstalledApp(token: token, name: ((path as NSString).lastPathComponent as NSString).deletingPathExtension,
                                    path: path, version: version, installedAt: installedAt)
            }
            if !direct.isEmpty { return direct }
            // pkg-based casks often declare the app's identity in their uninstall quit stanza.
            let ids = artifacts.flatMap { $0["uninstall"] as? [[String: Any]] ?? [] }.flatMap { item -> [String] in
                if let id = item["quit"] as? String { return [id] }
                return item["quit"] as? [String] ?? []
            }
            var seen: Set<String> = []
            return ids.compactMap { id in
                guard let url = applicationURL(id), url.path.hasPrefix("/Applications/"), url.path.hasSuffix(".app"),
                      seen.insert(url.path).inserted else { return nil }
                return InstalledApp(token: token, name: url.deletingPathExtension().lastPathComponent, path: url.path, version: version, installedAt: installedAt)
            }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct OperationState: Codable, Sendable {
    var kind: String
    var started: Date
    var finished: Date?
    var succeeded: Bool?
    var message: String?
    var processID: Int32? = nil
}

/// One package in a run result, as `brewau-upgrade` records it.
struct RunResultItem: Equatable, Sendable {
    let name: String
    let kind: String
    let version: String
    let reason: String
    /// Opaque installed-version signature the shell layer matches a retry against.
    let installed: String
    var isCask: Bool { kind == "cask" }
    /// Casks may be named `tap/user/token`; the catalog knows them by the last component.
    var token: String { String(name.split(separator: "/").last ?? "") }
}

/// `state/last-result.json` (upgrades) and `state/last-scan-result.json` (scans), written by
/// `brewau-upgrade`. Fields are read defensively: a file from an older brewau, a partly
/// written file or an unexpected type must never keep the GUI from starting.
struct RunResult: Equatable, Sendable {
    var finished: Date?
    var job = ""
    var status = ""
    var reason = ""
    var upgraded: [RunResultItem] = []
    var failed: [RunResultItem] = []
    var blocked: [RunResultItem] = []

    static func decode(_ data: Data) throws -> RunResult {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BrewauError.message("Resultatfilen kunne ikke læses.")
        }
        var result = RunResult()
        result.finished = (object["finished"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        result.job = object["job"] as? String ?? ""
        result.status = object["status"] as? String ?? ""
        result.reason = object["reason"] as? String ?? ""
        func items(_ key: String) -> [RunResultItem] {
            (object[key] as? [[String: Any]] ?? []).compactMap { row in
                guard let name = row["name"] as? String, !name.isEmpty else { return nil }
                return RunResultItem(name: name, kind: row["kind"] as? String ?? "",
                                     version: row["version"] as? String ?? "",
                                     reason: row["reason"] as? String ?? "",
                                     installed: row["installed"] as? String ?? "")
            }
        }
        result.upgraded = items("upgraded")
        result.failed = items("failed")
        result.blocked = items("blocked")
        return result
    }

    /// No network: the run did nothing and will try again, so it is not a failure.
    var isOffline: Bool { reason == "offline" }
    /// Statuses the shell layer exits 0 with; everything else left work undone.
    var isFailure: Bool { !["ok", "blocked", "skipped", ""].contains(status) }
    /// Casks macOS App Management keeps the background job from upgrading.
    var appManagementBlocks: [RunResultItem] { blocked.filter { $0.reason == "app-management" } }
    /// Failures that are not already explained by a block.
    var otherFailures: [RunResultItem] {
        let names = Set(appManagementBlocks.map(\.name))
        return failed.filter { !names.contains($0.name) }
    }
    var hasSomethingToReport: Bool { isOffline || isFailure || !appManagementBlocks.isEmpty }

    /// Danish explanation for the menu, or nil when the run needs no comment.
    /// `displayName` turns a package into the app name the user recognises.
    func danishSummary(displayName: (RunResultItem) -> String = { $0.name }) -> String? {
        var parts: [String] = []
        if isOffline {
            parts.append("Ingen forbindelse til Homebrew. brewau prøver igen ved næste kørsel.")
        }
        for item in otherFailures {
            let name = displayName(item)
            switch item.reason {
            case "protect-failed":
                parts.append("\(name) blev ikke opdateret, fordi appens filer i /Applications ikke kunne sikres. Se loggen for detaljer.")
            default:
                parts.append("\(name) kunne ikke opdateres, fordi Homebrew meldte en fejl. Se loggen for detaljer.")
            }
        }
        if let blocks = RunResult.danishBlocks(appManagementBlocks.map(displayName)) { parts.append(blocks) }
        if parts.isEmpty, isFailure { parts.append(RunResult.danishStatus(status, job: job)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Short Danish headline for the menu, or nil when the run needs no headline of its own.
    var danishHeadline: String? {
        // A run whose only problem is App Management is reported as blocked, not as a failure,
        // also on the first run: there is nothing for the user to retry blindly.
        if isFailure, !otherFailures.isEmpty || appManagementBlocks.isEmpty {
            return job == "scan" ? "Scanningen mislykkedes" : "Opdateringen mislykkedes"
        }
        if !appManagementBlocks.isEmpty {
            return appManagementBlocks.count == 1 ? "1 app er blokeret af macOS" : "\(appManagementBlocks.count) apps er blokeret af macOS"
        }
        if isOffline { return "Sprunget over – ingen forbindelse" }
        return nil
    }

    /// One English line for upgrade.log and the unified log.
    var logSummary: String {
        var parts: [String] = []
        if isOffline { parts.append("offline, nothing was changed") }
        for item in otherFailures { parts.append("\(item.name): \(item.reason.isEmpty ? "failed" : item.reason)") }
        for item in appManagementBlocks {
            parts.append("\(item.name) \(item.version): blocked by macOS App Management, skipped until a newer version or a manual upgrade")
        }
        if parts.isEmpty { parts.append("status \(status.isEmpty ? "unknown" : status) (reason \(reason.isEmpty ? "unknown" : reason))") }
        return parts.joined(separator: "; ")
    }

    /// The App Management explanation, also shown on its own next to the retry buttons.
    static func danishBlocks(_ names: [String]) -> String? {
        if names.count == 1 {
            return "\(names[0]) kunne ikke opdateres, fordi macOS App Management blokerer baggrundsjobbet. Den springes over, indtil der kommer en nyere version eller du opdaterer den manuelt."
        }
        if names.count > 1 {
            return "\(list(names)) kunne ikke opdateres, fordi macOS App Management blokerer baggrundsjobbet. De springes over, indtil der kommer nyere versioner, eller du opdaterer dem manuelt."
        }
        return nil
    }
    static func danishStatus(_ status: String, job: String) -> String {
        switch status {
        case "update-failed": return "Homebrew kunne ikke opdatere sig selv. Se loggen for detaljer."
        case "outdated-failed": return "Listen over opdateringer kunne ikke hentes fra Homebrew. Se loggen for detaljer."
        case "snapshot-failed": return "Opdateringslisten kunne ikke gemmes. Se loggen for detaljer."
        case "restart-failed": return "En systemtjeneste kunne ikke genstartes efter opdateringen. Se loggen for detaljer."
        case "protect-failed": return "Apps i /Applications kunne ikke sikres efter opdateringen. Se loggen for detaljer."
        case "tap-check-failed": return "brewau kunne ikke afgøre, hvilke taps der er tilladt, og kørte ikke Homebrew."
        default: return job == "scan" ? "Scanningen mislykkedes. Se loggen for detaljer." : "Opdateringen mislykkedes. Se loggen for detaljer."
        }
    }
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.joined() }
        return names.dropLast().joined(separator: ", ") + " og " + names[names.count - 1]
    }
}

/// Same shape as the shell layer's `log()` (`date +%Y-%m-%dT%H:%M:%S%z` and a job tag),
/// so upgrade.log reads as one stream whoever wrote the line.
func brewauLogLine(_ job: String, _ message: String, at date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
    return "\(formatter.string(from: date)) [\(job)] \(message)"
}

/// Missing or unreadable result files leave the GUI on its previous information.
func readRunResult(_ url: URL) -> RunResult? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? RunResult.decode(data)
}

func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(value).write(to: url, options: .atomic)
}

func readOperation(_ url: URL) throws -> OperationState {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(OperationState.self, from: Data(contentsOf: url))
}

/// One pipe is drained while the child runs, so verbose stderr cannot deadlock stdout.
func runCommand(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = URL(fileURLWithPath: "/")
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    let stdin = Pipe()
    process.standardInput = input == nil ? FileHandle.nullDevice : stdin
    try process.run()
    if let input {
        try stdin.fileHandleForWriting.write(contentsOf: input)
        try stdin.fileHandleForWriting.close()
    }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data.suffix(16000), as: UTF8.self)
    // Call sites pass fixed executables and validated subcommands; payloads travel on stdin,
    // so the command line is safe to log while the child's output is not.
    let command = ([executable] + arguments).joined(separator: " ")
    guard process.terminationStatus == 0 else {
        BrewauLog.helper.error("\(command, privacy: .public) exited \(process.terminationStatus)")
        throw BrewauError.message(text.isEmpty ? "Handlingen mislykkedes (\(process.terminationStatus))." : text)
    }
    BrewauLog.helper.notice("\(command, privacy: .public) succeeded")
    return text
}

/// Locks survive crashes as unlocked files; never unlink a file another worker may be waiting on.
/// `owner` hands a lock file that root opens to the account that shares it, so root
/// creating it never locks that account out.
func withFileLock<T>(_ path: String, nonblocking: Bool = false, owner: (uid_t, gid_t)? = nil,
                     _ action: () throws -> T) throws -> T? {
    let descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard descriptor >= 0 else { throw BrewauError.message("Kunne ikke åbne lås: \(path)") }
    defer { close(descriptor) }
    if let owner, fchown(descriptor, owner.0, owner.1) != 0 { throw BrewauError.message("Kunne ikke give låsen videre: \(path)") }
    guard flock(descriptor, LOCK_EX | (nonblocking ? LOCK_NB : 0)) == 0 else {
        if nonblocking, errno == EWOULDBLOCK { return nil }
        throw BrewauError.message("Kunne ikke låse: \(path)")
    }
    defer { flock(descriptor, LOCK_UN) }
    return try action()
}
