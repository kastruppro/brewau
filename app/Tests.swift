import Foundation
import Darwin

@main struct CoreTests {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            checks += 1
            guard value else { fatalError(message) }
        }
        func rejects(_ action: () throws -> Void) -> Bool { do { try action(); return false } catch { return true } }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Copenhagen")!
        func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
        var settings = ScheduleSettings()
        settings.minutes = [180, 900]
        let morning = date("2026-10-23T01:00:00Z")
        let afternoon = date("2026-10-23T13:00:00Z")
        check(settings.summary == "Hver dag kl. 03.00 og 15.00", "Multiple daily times")
        check(settings.upgradeDue(at: afternoon, lastAttempt: morning, installedAt: morning, calendar: calendar), "Afternoon run is due")
        check(!settings.upgradeDue(at: afternoon, lastAttempt: afternoon, installedAt: morning, calendar: calendar), "An occurrence runs only once")
        check(settings.upgradeDue(at: date("2026-10-24T08:00:00Z"), lastAttempt: morning, installedAt: morning, calendar: calendar), "A sleeping Mac catches up")
        check(!settings.upgradeDue(at: afternoon, lastAttempt: nil, installedAt: afternoon, calendar: calendar), "A new install does not immediately upgrade")
        settings.mode = "weekly"; settings.weekday = 2; settings.minutes = [180]
        check(settings.summary == "Hver mandag kl. 03.00", "Weekly label")
        check(settings.upgradeDue(at: date("2026-10-26T08:00:00Z"), lastAttempt: morning, installedAt: morning, calendar: calendar), "Weekly schedule crosses DST")
        check(!settings.upgradeDue(at: date("2026-10-25T08:00:00Z"), lastAttempt: morning, installedAt: morning, calendar: calendar), "No premature weekly run")
        settings.mode = "interval"
        check(settings.upgradeDue(at: morning.addingTimeInterval(3600), lastAttempt: morning, installedAt: morning), "Hourly interval")
        check(!settings.upgradeDue(at: morning.addingTimeInterval(3599), lastAttempt: morning, installedAt: morning), "Not before interval")
        settings.autoUpgrade = false
        check(!settings.upgradeDue(at: afternoon, lastAttempt: morning, installedAt: morning), "Disabled stays disabled")
        settings.minutes = [60, 60]
        check(rejects { try settings.validate() }, "Duplicate times rejected")
        settings.minutes = [1440]
        check(rejects { try settings.validate() }, "Out of range times rejected")
        settings = ScheduleSettings()
        let data = try JSONEncoder().encode(settings)
        check(try ScheduleSettings.decodeRequest(data) == settings, "JSON round trip")
        var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        object["ALLOWED_TAPS"] = "evil/tap"
        let injected = try JSONSerialization.data(withJSONObject: object)
        check(rejects { _ = try ScheduleSettings.decodeRequest(injected) }, "Policy injection rejected")
        check(rejects { _ = try ScheduleSettings.decodeRequest(Data(repeating: 32, count: 8193)) }, "Request size bounded")
        let config = "# Keep me\nALLOWED_TAPS=\"acme/tools\"\nUPGRADE_HOUR=\"08\"\nUPGRADE_MINUTE=\"30\"\n"
        check(try ScheduleSettings.readConfig(config).minutes == [510], "Legacy schedule migration")
        let replaced = settings.replacingConfig(config)
        check(replaced.contains("ALLOWED_TAPS=\"acme/tools\""), "Policy preserved")
        check(try ScheduleSettings.readConfig(replaced) == settings, "Config round trip")
        check(rejects { _ = try ScheduleSettings.readConfig("UPGRADE_TIMES=\"180 nonsense\"") }, "Invalid config times rejected")
        let outdated = Data(#"{"formulae":[{"name":"git","installed_versions":["2.50.0"],"current_version":"2.51.0","pinned":true}],"casks":[{"name":"postman","installed_versions":["12.33.3"],"current_version":"12.33.4"}]}"#.utf8)
        let updates = try BrewData.updates(outdated)
        check(updates.count == 2 && updates.first?.blocked == true, "Pinned packages remain visible")
        check(updates.last?.available == "12.33.4", "New cask version")
        check(try BrewData.updates(outdated, exclusions: ["postman"]).allSatisfy(\.blocked), "Exclusions remain visible")
        check(rejects { _ = try BrewData.updates(Data("{}".utf8)) }, "Malformed snapshot rejected")
        let catalog = Data(#"{"casks":[{"token":"postman","installed":"12.33.4","installed_time":1792717200,"artifacts":[{"app":["Postman.app"]}]},{"token":"rename","installed":"2","artifacts":[{"app":["Source.app",{"target":"Renamed.app"}]}]},{"token":"bad","artifacts":[{"app":["Bad.app",{"target":"../../Bad.app"}]}]}]}"#.utf8)
        let apps = try BrewData.apps(catalog)
        check(apps.count == 2, "Paths outside Applications rejected")
        check(apps.contains { $0.path == "/Applications/Renamed.app" }, "Artifact target respected")
        check(apps.first?.installedAt != nil, "Installation timestamp retained")
        let pkgCatalog = Data(#"{"casks":[{"token":"pkg-app","installed":"2","artifacts":[{"pkg":["Installer.pkg"]},{"uninstall":[{"quit":["com.example.app","com.example.app"]}]}]}]}"#.utf8)
        let pkgApps = try BrewData.apps(pkgCatalog, applicationURL: { _ in URL(fileURLWithPath: "/Applications/Pkg App.app") })
        check(pkgApps.count == 1 && pkgApps.first?.name == "Pkg App", "pkg casks resolve app identities without duplicates")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let lock = work.appendingPathComponent("lock").path
        try withFileLock(lock) {
            let other = open(lock, O_RDWR)
            defer { close(other) }
            check(flock(other, LOCK_EX | LOCK_NB) != 0, "Concurrent worker excluded")
        }
        check(FileManager.default.fileExists(atPath: lock), "Lock inode is retained")
        check(try withFileLock(lock, nonblocking: true) { true } == true, "Lock released after completion")
        let event = OperationState(kind: "scan", started: morning, finished: afternoon, succeeded: false, message: "Offline")
        let eventFile = work.appendingPathComponent("event.json")
        try writeJSON(event, to: eventFile)
        check(try readOperation(eventFile).message == "Offline", "Operation state round trip")
        check(try runCommand("/bin/echo", ["safe argument"]) == "safe argument\n", "Process arguments preserved")
        check(rejects { _ = try runCommand("/usr/bin/false", []) }, "Process errors propagate")
        let prefix = work.appendingPathComponent("prefix")
        let source = prefix.appendingPathComponent("share/zsh/site-functions")
        let destination = work.appendingPathComponent("trusted")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let real = prefix.appendingPathComponent("real")
        let outside = work.appendingPathComponent("outside")
        try Data("#compdef demo\n".utf8).write(to: real)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("_demo"), withDestinationURL: real)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("_escape"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("_missing"), withDestinationURL: prefix.appendingPathComponent("missing"))
        try FileManager.default.createSymbolicLink(at: destination.appendingPathComponent("_demo"), withDestinationURL: outside)
        try Data("stale".utf8).write(to: destination.appendingPathComponent("_stale"))
        let count = try copyCompletions(from: source, into: destination, prefix: prefix, owner: getuid(), group: getgid())
        check(count == 1, "Only valid completions are copied")
        check(try String(contentsOf: outside, encoding: .utf8) == "outside", "Destination symlink does not change its target")
        check(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("_demo").path)[.type] as? FileAttributeType == .typeRegular, "Snapshot contains regular files")
        check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("_stale").path), "Removed completions are pruned")
        check(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("_escape").path), "Source symlinks cannot escape Homebrew")
        check(try FileManager.default.attributesOfItem(atPath: destination.appendingPathComponent("_demo").path)[.posixPermissions] as? Int == 0o644, "Copied completions are not writable by other users")
        let audit = try runCommand("/bin/zsh", ["-dfc", "fpath=(\"$1\" ${fpath:#/opt/homebrew/*}); autoload -Uz compaudit; _compdir='' compaudit", "brewau-test", destination.path])
        check(audit.isEmpty, "zsh compaudit accepts the completion snapshot")
        print("\(checks) native checks passed")
    }
}
