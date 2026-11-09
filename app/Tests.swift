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

        // --- run results from brewau-upgrade ------------------------------------------
        let blockedRun = Data(#"""
        {"upgraded":[{"name":"firefox","kind":"cask","version":"145.0","reason":"ok","installed":"[\"144.0\"]"}],
         "failed":[{"name":"kastruppro/tap/parallels","kind":"cask","version":"26.2.1","reason":"app-management","installed":"[\"26.1.0\"]"}],
         "blocked":[{"name":"kastruppro/tap/parallels","kind":"cask","version":"26.2.1","reason":"app-management","installed":"[\"26.1.0\"]"}],
         "finished":"2026-11-09T02:00:11Z","job":"upgrade","status":"upgrade-failed","reason":"app-management"}
        """#.utf8)
        let blocked = try RunResult.decode(blockedRun)
        check(blocked.job == "upgrade" && blocked.status == "upgrade-failed" && blocked.reason == "app-management", "Run result header read")
        check(blocked.finished == date("2026-11-09T02:00:11Z"), "Run result timestamp read")
        check(blocked.upgraded.map(\.name) == ["firefox"] && blocked.upgraded.first?.isCask == true, "Successful package kept next to the failure")
        check(blocked.appManagementBlocks.count == 1 && blocked.appManagementBlocks.first?.token == "parallels", "Block is attributed to the cask")
        check(blocked.otherFailures.isEmpty, "A newly blocked cask is not reported twice")
        check(blocked.danishHeadline == "1 app er blokeret af macOS", "A block is not presented as a plain failure")
        check(blocked.danishSummary { $0.token.capitalized } == "Parallels kunne ikke opdateres, fordi macOS App Management blokerer baggrundsjobbet. Den springes over, indtil der kommer en nyere version eller du opdaterer den manuelt.", "Block explains itself with the app's name")
        check(blocked.logSummary == "kastruppro/tap/parallels 26.2.1: blocked by macOS App Management, skipped until a newer version or a manual upgrade", "Log line names package and version in English")
        check(blocked.hasSomethingToReport, "A blocked run is reported")

        let standingBlock = Data(#"{"upgraded":[],"failed":[],"blocked":[{"name":"parallels","kind":"cask","version":"26.2.1","reason":"app-management","installed":"x"}],"finished":"2026-11-09T04:00:00Z","job":"upgrade","status":"blocked","reason":"app-management"}"#.utf8)
        check(!(try RunResult.decode(standingBlock).isFailure), "A standing block is not a failure")
        check(try RunResult.decode(standingBlock).danishHeadline == "1 app er blokeret af macOS", "A standing block keeps its headline")

        let offline = try RunResult.decode(Data(#"{"upgraded":[],"failed":[],"blocked":[],"finished":"2026-11-09T06:00:00Z","job":"scan","status":"skipped","reason":"offline"}"#.utf8))
        check(offline.isOffline && !offline.isFailure, "An offline run is not a failure")
        check(offline.danishHeadline == "Sprunget over – ingen forbindelse", "Offline headline")
        check(offline.danishSummary() == "Ingen forbindelse til Homebrew. brewau prøver igen ved næste kørsel.", "Offline explains itself")
        check(offline.logSummary == "offline, nothing was changed", "Offline log line")

        let brewError = try RunResult.decode(Data(#"{"upgraded":[],"failed":[{"name":"ffmpeg","kind":"formula","version":"8.0","reason":"brew-error","installed":""}],"blocked":[],"finished":"2026-11-09T07:00:00Z","job":"upgrade","status":"upgrade-failed","reason":"brew-error"}"#.utf8))
        check(brewError.isFailure && brewError.danishHeadline == "Opdateringen mislykkedes", "An ordinary failure is still a failure")
        check(brewError.danishSummary() == "ffmpeg kunne ikke opdateres, fordi Homebrew meldte en fejl. Se loggen for detaljer.", "Ordinary failure names the package")
        check(brewError.logSummary == "ffmpeg: brew-error", "Ordinary failure log line")

        let protectFailed = try RunResult.decode(Data(#"{"failed":[{"name":"vlc","kind":"cask","version":"4.0","reason":"protect-failed","installed":""}],"job":"upgrade","status":"upgrade-failed","reason":"protect-failed"}"#.utf8))
        check(protectFailed.danishSummary() == "vlc blev ikke opdateret, fordi appens filer i /Applications ikke kunne sikres. Se loggen for detaljer.", "Protection failure has its own wording")
        check(try RunResult.decode(Data(#"{"job":"scan","status":"update-failed","reason":"brew-error"}"#.utf8)).danishSummary() == "Homebrew kunne ikke opdatere sig selv. Se loggen for detaljer.", "A failure without packages falls back to its status")

        let twoBlocks = try RunResult.decode(Data(#"{"blocked":[{"name":"parallels","kind":"cask","version":"1","reason":"app-management","installed":""},{"name":"docker","kind":"cask","version":"2","reason":"app-management","installed":""}],"job":"upgrade","status":"blocked","reason":"app-management"}"#.utf8))
        check(twoBlocks.danishSummary()?.hasPrefix("parallels og docker kunne ikke opdateres") == true, "Several blocks are listed in one sentence")
        check(twoBlocks.danishHeadline == "2 apps er blokeret af macOS", "Several blocks are counted")

        // Files from an older brewau, or a half-written one, must not keep the GUI from starting.
        let sparse = try RunResult.decode(Data("{}".utf8))
        check(!sparse.isFailure && !sparse.hasSomethingToReport && sparse.danishSummary() == nil, "An empty result reports nothing")
        let wrongTypes = try RunResult.decode(Data(#"{"status":7,"blocked":"none","failed":[{"kind":"cask"},{"name":"ok","kind":"cask"}]}"#.utf8))
        check(wrongTypes.status.isEmpty && wrongTypes.blocked.isEmpty && wrongTypes.failed.map(\.name) == ["ok"], "Unexpected types are skipped, not fatal")
        check(rejects { _ = try RunResult.decode(Data("not json".utf8)) }, "Malformed result rejected")
        check(readRunResult(work.appendingPathComponent("absent.json")) == nil, "A missing result file is not an error")
        let resultFile = work.appendingPathComponent("last-result.json")
        try blockedRun.write(to: resultFile)
        check(readRunResult(resultFile)?.appManagementBlocks.count == 1, "Result files are read from disk")
        check(brewauLogLine("upgrade", "done", at: morning).hasSuffix(" [upgrade] done"), "Log lines carry the shell layer's job tag")
        check(brewauLogLine("scan", "x", at: morning).range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}[+-][0-9]{4} ", options: .regularExpression) != nil, "Log stamp matches date +%Y-%m-%dT%H:%M:%S%z")
        print("\(checks) native checks passed")
    }
}
