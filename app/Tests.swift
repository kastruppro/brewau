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
        // A discovered App Management block is a block, not a job error: the job records no
        // failed step for it and exits 0.
        let blockedRun = Data(#"""
        {"upgraded":[{"name":"firefox","kind":"cask","version":"145.0","reason":"ok","installed":"[\"144.0\"]"}],
         "failed":[{"name":"kastruppro/tap/parallels","kind":"cask","version":"26.2.1","reason":"app-management","installed":"[\"26.1.0\"]"}],
         "blocked":[{"name":"kastruppro/tap/parallels","kind":"cask","version":"26.2.1","reason":"app-management","installed":"[\"26.1.0\"]"}],
         "errors":[],
         "finished":"2026-11-09T02:00:11Z","job":"upgrade","status":"blocked","reason":"app-management"}
        """#.utf8)
        let blocked = try RunResult.decode(blockedRun)
        check(blocked.job == "upgrade" && blocked.status == "blocked" && blocked.reason == "app-management", "Run result header read")
        check(blocked.hasErrorList && blocked.errors.isEmpty && !blocked.isFailure, "A discovered block records no failed step")
        check(blocked.finished == date("2026-11-09T02:00:11Z"), "Run result timestamp read")
        check(blocked.upgraded.map(\.name) == ["firefox"] && blocked.upgraded.first?.isCask == true, "Successful package kept next to the failure")
        check(blocked.appManagementBlocks.count == 1 && blocked.appManagementBlocks.first?.token == "parallels", "Block is attributed to the cask")
        check(blocked.otherFailures.isEmpty, "A newly blocked cask is not reported twice")
        check(blocked.danishHeadline == "1 app er blokeret af macOS", "A block is not presented as a plain failure")
        check(blocked.danishSummary { $0.token.capitalized } == "Parallels kunne ikke opdateres, fordi macOS App Management blokerer baggrundsjobbet. Den springes over, indtil der kommer en nyere version eller du opdaterer den manuelt.", "Block explains itself with the app's name")
        check(blocked.logSummary == "kastruppro/tap/parallels 26.2.1: blocked by macOS App Management, skipped until a newer version or a manual upgrade", "Log line names package and version in English")
        check(blocked.hasSomethingToReport, "A blocked run is reported")

        let standingBlock = try RunResult.decode(Data(#"{"upgraded":[],"failed":[],"blocked":[{"name":"parallels","kind":"cask","version":"26.2.1","reason":"app-management","installed":"x"}],"errors":[],"finished":"2026-11-09T04:00:00Z","job":"upgrade","status":"blocked","reason":"app-management"}"#.utf8))
        check(!standingBlock.isFailure, "A standing block is not a failure")
        check(standingBlock.danishHeadline == "1 app er blokeret af macOS", "A standing block keeps its headline")

        let offline = try RunResult.decode(Data(#"{"upgraded":[],"failed":[],"blocked":[],"errors":[],"finished":"2026-11-09T06:00:00Z","job":"scan","status":"skipped","reason":"offline"}"#.utf8))
        check(offline.isOffline && !offline.isFailure, "An offline run is not a failure")
        check(offline.danishHeadline == "Sprunget over – ingen forbindelse", "Offline headline")
        check(offline.danishSummary() == "Ingen forbindelse til Homebrew. brewau prøver igen ved næste kørsel.", "Offline explains itself")
        check(offline.logSummary == "offline, nothing was changed", "Offline log line")

        let brewError = try RunResult.decode(Data(#"{"upgraded":[],"failed":[{"name":"ffmpeg","kind":"formula","version":"8.0","reason":"brew-error","installed":""}],"blocked":[],"errors":[{"stage":"upgrade","reason":"brew-error"}],"finished":"2026-11-09T07:00:00Z","job":"upgrade","status":"upgrade-failed","reason":"brew-error"}"#.utf8))
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

        // --- a result file cannot forge a log line or exhaust memory ------------------
        let forged = try RunResult.decode(Data(#"""
        {"failed":[{"name":"evil\n2026-11-09T03:00:00+0100 [upgrade] everything is up to date","kind":"cask","version":"1\u00072","reason":"brew-error","installed":""}],
         "blocked":[],"job":"upgrade","status":"upgrade\u2028-failed","reason":"brew-error"}
        """#.utf8))
        check(!forged.failed[0].name.contains("\n") && !forged.failed[0].version.contains("\u{07}"),
              "Control characters in a result are flattened at ingest")
        check(!forged.status.contains("\u{2028}"), "Line separators cannot split a status")
        check(brewauLogLine("upgrade", forged.logSummary, at: morning).components(separatedBy: "\n").count == 1,
              "A forged name cannot produce a second log line")
        check(brewauLogLine("up\ngrade", "x", at: morning).components(separatedBy: "\n").count == 1,
              "Nor can a forged job tag")
        check(brewauSingleLine(String(repeating: "a", count: 500), limit: 64).count == 65, "Long strings are capped")
        check(try RunResult.decode(Data(#"{"job":"upgrade","status":"ok","reason":"ok","upgraded":[]}"#.utf8)).upgraded.isEmpty, "Normal results still decode")
        let manyItems = "{\"job\":\"upgrade\",\"status\":\"ok\",\"reason\":\"ok\",\"upgraded\":["
            + (0..<600).map { "{\"name\":\"p\($0)\",\"kind\":\"cask\",\"version\":\"1\",\"reason\":\"ok\",\"installed\":\"\"}" }.joined(separator: ",") + "]}"
        check(try RunResult.decode(Data(manyItems.utf8)).upgraded.count == RunResult.itemLimit, "Item count is bounded")
        check(rejects { _ = try RunResult.decode(Data(repeating: 32, count: RunResult.sizeLimit + 1)) }, "Oversized results are refused")
        let oversized = work.appendingPathComponent("oversized.json")
        try Data(repeating: 0x20, count: RunResult.sizeLimit + 64).write(to: oversized)
        check(readRunResult(oversized) == nil, "An oversized result file is not loaded whole")

        // --- a result only explains the run that published it -------------------------
        let runStart = date("2026-11-09T05:00:00Z")
        let staleOffline = try RunResult.decode(Data(#"{"job":"scan","status":"skipped","reason":"offline","finished":"2026-11-09T04:00:00Z"}"#.utf8))
        check(correlatedResult(staleOffline, job: "scan", startedAt: runStart) == nil, "A result from an earlier run is not reused")
        check(correlatedResult(staleOffline, job: "scan", startedAt: date("2026-11-09T04:00:00Z")) != nil, "Its own run still matches it")
        // The shell layer truncates finished to whole seconds, so a sub-second run must match.
        check(correlatedResult(staleOffline, job: "scan", startedAt: date("2026-11-09T04:00:00Z").addingTimeInterval(0.8)) != nil,
              "A run shorter than a second still matches its result")
        check(correlatedResult(staleOffline, job: "upgrade", startedAt: date("2026-11-09T04:00:00Z")) == nil, "The other job's result does not match")
        check(correlatedResult(try RunResult.decode(Data(#"{"job":"scan","status":"skipped","reason":"offline"}"#.utf8)), job: "scan", startedAt: runStart) == nil,
              "A result without a timestamp cannot be correlated")
        // A crashed worker leaves no new result: the failure must be reported as a failure.
        check(runNotice(job: "scan", succeeded: false, result: correlatedResult(staleOffline, job: "scan", startedAt: runStart)) == .failure,
              "A stale offline result does not excuse a new failure")
        check(runNotice(job: "scan", succeeded: false, result: staleOffline) == .silent, "while its own offline run stays quiet")

        // --- the per-run channel leaves standing blocks to the per-package channel ----
        check(blocked.isBlockOnly && runNotice(job: "upgrade", succeeded: true, result: blocked) == .upgradeFinished,
              "The run that discovers a block reports the package it did upgrade, and nothing else")
        check(runNotice(job: "upgrade", succeeded: true, result: standingBlock) == .silent,
              "A standing block does not announce a finished upgrade")
        check(runNotice(job: "upgrade", succeeded: false, result: brewError) == .failure, "An unrelated failure is still notified")
        let mixed = try RunResult.decode(Data(#"{"upgraded":[],"failed":[{"name":"parallels","kind":"cask","version":"1","reason":"app-management","installed":""},{"name":"ffmpeg","kind":"formula","version":"8.0","reason":"brew-error","installed":""}],"blocked":[{"name":"parallels","kind":"cask","version":"1","reason":"app-management","installed":""}],"errors":[{"stage":"upgrade","reason":"brew-error"}],"job":"upgrade","status":"upgrade-failed","reason":"brew-error"}"#.utf8))
        check(!mixed.isBlockOnly && runNotice(job: "upgrade", succeeded: false, result: mixed) == .failure, "A failure next to a block is notified")
        check(mixed.danishSummary(includingBlocks: false) == "ffmpeg kunne ikke opdateres, fordi Homebrew meldte en fejl. Se loggen for detaljer.",
              "and its banner leaves the block to the block banner")
        check(mixed.danishSummary()?.contains("App Management") == true, "while the menu still explains both")
        let didUpgrade = try RunResult.decode(Data(#"{"upgraded":[{"name":"firefox","kind":"cask","version":"145.0","reason":"ok","installed":""}],"job":"upgrade","status":"ok","reason":"ok"}"#.utf8))
        check(runNotice(job: "upgrade", succeeded: true, result: didUpgrade) == .upgradeFinished, "A real upgrade is announced")
        check(runNotice(job: "upgrade", succeeded: true, result: sparse) == .silent, "An upgrade that installed nothing is not news")
        check(runNotice(job: "upgrade", succeeded: true, result: nil) == .upgradeFinished, "Without a result file the old behaviour stands")
        check(runNotice(job: "scan", succeeded: true, result: didUpgrade) == .updatesAvailable, "A finished scan reports what it found")
        check(runNotice(job: "scan", succeeded: true, result: offline) == .silent, "An offline scan reports nothing")

        // --- every failed step of a run is reported, also next to a standing block ---
        let standingItem = #"{"name":"parallels","kind":"cask","version":"26.2.1","reason":"app-management","installed":"x"}"#
        let formulaUpgraded = #"{"name":"tailscale","kind":"formula","version":"1.90","reason":"ok","installed":""}"#
        /// A result in the job's own shape: the first failed step decides status and reason.
        func run(_ errors: [(String, String)], upgraded: String = "", failed: String = "", blocked: String = "") throws -> RunResult {
            let steps = errors.map { #"{"stage":""# + $0.0 + #"","reason":""# + $0.1 + #""}"# }.joined(separator: ",")
            let status = errors.first.map { $0.0 + "-failed" } ?? (blocked.isEmpty ? "ok" : "blocked")
            let reason = errors.first?.1 ?? (blocked.isEmpty ? "ok" : "app-management")
            var json = #"{"upgraded":["# + upgraded + #"],"failed":["# + failed + #"],"#
            json += #""blocked":["# + blocked + #"],"errors":["# + steps + #"],"#
            json += #""finished":"2026-11-09T09:00:00Z","job":"upgrade","status":""# + status + #"","reason":""# + reason + #""}"#
            return try RunResult.decode(Data(json.utf8))
        }
        let restartBeside = try run([("restart", "brew-error")], upgraded: formulaUpgraded, blocked: standingItem)
        check(restartBeside.status == "restart-failed" && !restartBeside.isBlockOnly, "A failed step beside a block is not block-only")
        check(runNotice(job: "upgrade", succeeded: false, result: restartBeside) == .failure, "A failed service restart beside a block is notified")
        check(restartBeside.danishHeadline == "Opdateringen mislykkedes", "and keeps the failure headline")
        check(restartBeside.danishSummary { $0.token.capitalized } == "En systemtjeneste kunne ikke genstartes efter opdateringen. Se loggen for detaljer. Parallels kunne ikke opdateres, fordi macOS App Management blokerer baggrundsjobbet. Den springes over, indtil der kommer en nyere version eller du opdaterer den manuelt.",
              "and is named before the block, which is still explained")
        check(restartBeside.danishSummary(includingBlocks: false) == "En systemtjeneste kunne ikke genstartes efter opdateringen. Se loggen for detaljer.",
              "while its banner leaves the block to the block banner")
        check(restartBeside.logSummary == "restart stage failed (brew-error); parallels 26.2.1: blocked by macOS App Management, skipped until a newer version or a manual upgrade",
              "and upgrade.log names the step in English")

        let protectBeside = try run([("protect", "protect-failed")], blocked: standingItem)
        check(runNotice(job: "upgrade", succeeded: false, result: protectBeside) == .failure, "A protection failure beside a block is notified")
        check(protectBeside.status == "protect-failed" && protectBeside.reason == "protect-failed", "with the reason the step reported")
        check(protectBeside.danishSummary(includingBlocks: false) == "Apps i /Applications kunne ikke sikres, så casks blev ikke opdateret. Se loggen for detaljer.", "and its own wording")
        // Several steps can fail independently in one run; all of them are named, in order.
        let pinAndUpgrade = try run([("pin", "brew-error"), ("upgrade", "brew-error")],
                                    failed: #"{"name":"ffmpeg","kind":"formula","version":"8.0","reason":"brew-error","installed":""}"#)
        check(pinAndUpgrade.status == "pin-failed", "The first failed step decides the status")
        check(pinAndUpgrade.errors.map(\.stage) == ["pin", "upgrade"], "and every step is kept in order")
        check(pinAndUpgrade.danishSummary() == "brewau kunne ikke bekræfte, at udelukkede pakker er fastlåst, og sprang formulae over. ffmpeg kunne ikke opdateres, fordi Homebrew meldte en fejl. Se loggen for detaljer.",
              "The pin failure is named next to the package the upgrade step could not install")
        check(pinAndUpgrade.logSummary == "pin stage failed (brew-error); ffmpeg: brew-error", "and the log names the step and the package it could not install")
        let everyStage = ["tap-check", "update", "protect", "pin", "outdated", "restart", "upgrade", "cleanup", "snapshot"]
        check(everyStage.allSatisfy { RunResult.danishStage($0) != RunResult.danishStage("unknown-stage") }, "Every stage the job records has its own wording")
        check(RunResult.danishStage("future").contains("future"), "and an unknown one still names itself")
        check(try run([("cleanup", "brew-error")]).danishSummary() == "Homebrews oprydning af hentede filer mislykkedes. Se loggen for detaljer.", "A failed cleanup is reported")
        check(try run([("tap-check", "brew-error")]).danishHeadline == "Opdateringen mislykkedes", "A refused tap check is a failed run")
        // A cask can be both blocked and left unprotected; the protection failure is its own.
        let blockedAndUnprotected = try run([("protect", "protect-failed")],
                                            failed: #"{"name":"parallels","kind":"cask","version":"26.2.1","reason":"protect-failed","installed":""}"#,
                                            blocked: standingItem)
        check(blockedAndUnprotected.otherFailures.count == 1, "A protection failure is not filtered out with the block of the same cask")
        check(blockedAndUnprotected.danishSummary()?.contains("ikke kunne sikres") == true, "and is explained")
        // Offline: the job stops before any step, and a standing block is still carried over.
        let offlineWithBlock = try RunResult.decode(Data((#"{"upgraded":[],"failed":[],"blocked":["# + standingItem + #"],"errors":[],"finished":"2026-11-09T09:00:00Z","job":"upgrade","status":"skipped","reason":"offline"}"#).utf8))
        check(!offlineWithBlock.isFailure && !offlineWithBlock.isBlockOnly, "An offline run is neither a failure nor block-only")
        check(runNotice(job: "upgrade", succeeded: true, result: offlineWithBlock) == .silent, "and is not notified")
        check(offlineWithBlock.danishSummary()?.hasPrefix("Ingen forbindelse") == true, "but still says why nothing happened")

        // --- result files from a brewau before this contract --------------------------
        // No step list: the status is the only signal, and that version published
        // upgrade-failed for the run that discovered a block.
        let legacyBlock = try RunResult.decode(Data((#"{"upgraded":[],"failed":[{"name":"parallels","kind":"cask","version":"26.2.1","reason":"app-management","installed":"x"}],"blocked":["# + standingItem + #"],"finished":"2026-11-09T02:00:00Z","job":"upgrade","status":"upgrade-failed","reason":"app-management"}"#).utf8))
        check(!legacyBlock.hasErrorList && legacyBlock.isBlockOnly, "An old discovered block is still block-only")
        check(runNotice(job: "upgrade", succeeded: false, result: legacyBlock) == .silent, "so its failed run raises no second banner")
        check(legacyBlock.danishHeadline == "1 app er blokeret af macOS", "and it is presented as blocked")
        let legacyRestart = try RunResult.decode(Data((#"{"upgraded":[],"failed":[],"blocked":["# + standingItem + #"],"finished":"2026-11-09T02:00:00Z","job":"upgrade","status":"restart-failed","reason":"app-management"}"#).utf8))
        check(!legacyRestart.isBlockOnly, "An old failure the block cannot explain is still a failure")
        check(runNotice(job: "upgrade", succeeded: false, result: legacyRestart) == .failure, "and is notified")
        check(legacyRestart.danishSummary(includingBlocks: false) == "En systemtjeneste kunne ikke genstartes efter opdateringen. Se loggen for detaljer.", "from its status alone")
        check(legacyRestart.logSummary.contains("status restart-failed"), "which upgrade.log records")

        // --- the step list is bounded and single-line like the other arrays ----------
        let manyErrors = #"{"job":"upgrade","status":"restart-failed","reason":"brew-error","errors":["#
            + (0..<600).map { _ in #"{"stage":"restart","reason":"brew-error"}"# }.joined(separator: ",") + "]}"
        check(try RunResult.decode(Data(manyErrors.utf8)).errors.count == RunResult.itemLimit, "The step count is bounded")
        let forgedStage = try RunResult.decode(Data(#"{"job":"upgrade","status":"restart-failed","reason":"brew-error","errors":[{"stage":"rest\nart","reason":"brew\u0007error"},{"reason":"brew-error"}]}"#.utf8))
        check(forgedStage.errors.count == 1 && !forgedStage.errors[0].stage.contains("\n"), "A step without a stage is skipped and control characters are flattened")
        check(brewauLogLine("upgrade", forgedStage.logSummary, at: morning).components(separatedBy: "\n").count == 1, "so a step cannot forge a log line")
        check(try RunResult.decode(Data(#"{"job":"upgrade","status":"ok","reason":"ok","errors":"none"}"#.utf8)).hasErrorList == false, "A step list of the wrong type is treated as absent")

        // --- a scheduler failure after a clean script is still reported ---------------
        // The script exits 0 for a block-only run; the privileged completions refresh that
        // follows it can still fail, and that is news the result cannot describe.
        check(standingBlock.hasErrorList && !standingBlock.explainsFailure, "A block-only result does not account for a failed run")
        check(runNotice(job: "upgrade", succeeded: false, result: standingBlock) == .failure,
              "so a scheduler failure after it is notified")
        check(standingBlock.danishSummary(includingBlocks: false) == nil,
              "with the scheduler's own message, not the block text")
        check(runHeadline(job: "upgrade", succeeded: false, result: standingBlock) == "Opdateringen mislykkedes",
              "and the menu says the run failed")
        check(runNotice(job: "upgrade", succeeded: false, result: blocked) == .failure, "The same holds for the run that discovered the block")
        // A result file from before the step list reported the discovering run as a failure.
        check(legacyBlock.isLegacyBlockOnly && legacyBlock.explainsFailure, "An old block-only result accounts for its failed run")
        check(runNotice(job: "upgrade", succeeded: false, result: legacyBlock) == .silent, "so it still raises no second banner")
        check(runHeadline(job: "upgrade", succeeded: false, result: legacyBlock) == "1 app er blokeret af macOS", "and still reads as blocked")
        check(runHeadline(job: "upgrade", succeeded: true, result: standingBlock) == "1 app er blokeret af macOS", "A successful block-only run reads as blocked")
        check(runHeadline(job: "upgrade", succeeded: false, result: restartBeside) == "Opdateringen mislykkedes", "A recorded failure keeps its headline")
        check(restartBeside.explainsFailure, "because the result accounts for it")
        check(runHeadline(job: "scan", succeeded: false, result: nil) == "Scanningen mislykkedes", "A failure without a result names the job")
        check(runHeadline(job: "upgrade", succeeded: true, result: didUpgrade) == nil, "A clean run needs no headline of its own")
        check(runHeadline(job: "scan", succeeded: false, result: offline) == "Sprunget over – ingen forbindelse", "An offline run stays a skip")
        check(runNotice(job: "scan", succeeded: false, result: offline) == .silent, "and is not notified")

        // --- a one-shot notification survives a permission granted later -------------
        var ledger = OneShotNotice()
        let blockKey = "blocked-parallels-26.2.1"
        check(ledger.shouldSubmit(blockKey, delivered: false), "A new block is submitted")
        check(!ledger.shouldSubmit(blockKey, delivered: false), "but not twice while the first submission runs")
        check(!ledger.finish(blockKey, delivered: false), "A refused delivery is not remembered")
        check(ledger.shouldSubmit(blockKey, delivered: false), "so it is tried again once permission is granted")
        check(ledger.finish(blockKey, delivered: true), "A delivered banner is remembered")
        check(!ledger.shouldSubmit(blockKey, delivered: true), "and never repeats")
        check(ledger.inFlight.isEmpty, "No key is left in flight")
        print("\(checks) native checks passed")
    }
}
