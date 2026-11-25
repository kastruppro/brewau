import AppKit
import Foundation
import ServiceManagement
import UserNotifications

struct PendingApp: Identifiable {
    var id: String { app.id }
    let app: InstalledApp
    let process: NSRunningApplication
}

@MainActor final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var updates: [PackageUpdate] = []
    @Published var apps: [InstalledApp] = []
    @Published var pending: [PendingApp] = []
    @Published var settings = ScheduleSettings()
    @Published var savedSettings = ScheduleSettings()
    @Published var busy = false
    @Published var saving = false
    @Published var installed = false
    @Published var hasScanned = false
    @Published var failed = false
    @Published var status = "Forbinder til brewau…"
    @Published var error: String?
    @Published var page = SettingsPage.schedule
    @Published var launchAtLogin = false
    @Published var loginApproval = false
    @Published var notificationStatus = "Ikke aktiveret"
    @Published var notificationAllowed = false
    @Published var restarting: Set<String> = []
    /// Apps that were asked to quit and are still shutting down.
    @Published var waitingToQuit: Set<String> = []
    @Published var repairStatus: String?
    @Published var homebrewVersion = "Ukendt"
    @Published var upgradeResult: RunResult?
    @Published var scanResult: RunResult?
    @Published var clearingBlocked = false
    /// Apps the daemon could not lock or pin; the app protects them through the helper.
    @Published var unprotected: [UnprotectedApp] = []
    @Published var protecting = false
    /// The helper found the operation lock held; the same request runs again shortly.
    @Published var protectWaiting = false
    /// The helper's last answer was that App Management still refuses (exit 3).
    @Published var protectRefused = false
    /// What the newest finished run published, if the file really belongs to that run,
    /// together with the job it belonged to and the scheduler's verdict for it.
    @Published var runResult: RunResult?
    @Published var runJob: String?
    @Published var runSucceeded = true
    @Published var notificationPreferences = NotificationPreferences() { didSet { savePreferences() } }
    @Published var forceAllowed: Set<String> = [] { didSet { savePreferences() } }
    private let defaults = UserDefaults.standard
    private let stateDirectory = URL(fileURLWithPath: "/opt/brewau/var/state", isDirectory: true)
    private var polling: Task<Void, Never>?
    private var requestPendingUntil: Date?
    private var automaticRestartAttempts: Set<String> = []
    private var loadingPreferences = true
    private var oneShot = OneShotNotice()
    private var blockedLog = ChangeGate()
    private var protectTrigger = ProtectTrigger()

    override init() {
        super.init()
        if let data = defaults.data(forKey: "notifications"), let value = try? JSONDecoder().decode(NotificationPreferences.self, from: data) {
            notificationPreferences = value
        }
        forceAllowed = Set(defaults.stringArray(forKey: "forceAllowed") ?? [])
        loadingPreferences = false
        UNUserNotificationCenter.current().delegate = self
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func savePreferences() {
        guard !loadingPreferences else { return }
        if let data = try? JSONEncoder().encode(notificationPreferences) { defaults.set(data, forKey: "notifications") }
        defaults.set(forceAllowed.sorted(), forKey: "forceAllowed")
    }
    var scanSummary: String {
        settings.scanMinutes < 60 ? "hvert \(settings.scanMinutes). minut" : settings.scanMinutes == 60 ? "hver time" : "hver \(settings.scanMinutes / 60). time"
    }
    var availableUpdates: [PackageUpdate] { updates.filter { !$0.blocked } }
    func name(for update: PackageUpdate) -> String { apps.first(where: { $0.token == update.token })?.name ?? update.name }
    func result(for job: String) -> RunResult? { job == "scan" ? scanResult : upgradeResult }
    /// Casks the last upgrade could not touch because macOS App Management stops the daemon.
    var blockedByAppManagement: [RunResultItem] { upgradeResult?.appManagementBlocks ?? [] }
    func displayName(for item: RunResultItem) -> String {
        brewauSingleLine(apps.first(where: { $0.token == item.token })?.name ?? item.token, limit: 80)
    }
    func appManagementBlock(for update: PackageUpdate) -> RunResultItem? {
        blockedByAppManagement.first { $0.token == update.token }
    }
    /// Protection warnings from a result file of an older brewau, which has no pending list.
    var legacyUnprotected: [RunResultItem] { upgradeResult?.legacyProtectionWarnings ?? [] }
    var blockedMessage: String? {
        let parts = [RunResult.danishBlocks(blockedByAppManagement.map { (displayName(for: $0), $0.name) }),
                     RunResult.danishProtection(legacyUnprotected.map { displayName(for: $0) })].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
    func displayName(for app: UnprotectedApp) -> String {
        brewauSingleLine(apps.first(where: { $0.token == app.token })?.name ?? app.token, limit: 80)
    }
    var unprotectedMessage: String? {
        UnprotectedApp.danishNotice(unprotected, refused: protectRefused) { self.displayName(for: $0) }
    }
    var finishedRuns: [Date?] { [upgradeResult?.finished, scanResult?.finished] }
    /// An update the daemon holds back until the app can be protected.
    func deferredProtection(for update: PackageUpdate) -> UnprotectedApp? {
        unprotected.first { $0.token == update.token && $0.deferred }
    }
    /// Locks and pins the pending apps through the helper. Started on launch, after each
    /// finished run and from the banner; never while a scan or upgrade runs.
    func protectPending(userInitiated: Bool = false) async {
        guard !protecting, !busy, installed, !unprotected.isEmpty else { return }
        protecting = true
        let key = ProtectTrigger.key(pending: unprotected, finishedRuns: finishedRuns)
        let hadDeferred = unprotected.contains { $0.deferred }
        BrewauLog.app.notice("protecting pending apps")
        let answer = await Task.detached { () -> Result<(Int32, String), Error> in
            Result { try runCommandStatus("/usr/bin/sudo", ["-n", "/opt/brewau/libexec/brewau-agent", "protect"]) }
        }.value
        protecting = false
        let outcome = (try? answer.get()).map { ProtectOutcome(exitCode: $0.0) } ?? .failed
        protectTrigger.record(key, outcome: outcome)
        protectWaiting = outcome == .busy
        switch answer {
        case .failure(let failure): self.error = failure.localizedDescription
        case .success(let (code, text)):
            switch outcome {
            case .protected:
                protectRefused = false
                await refresh()
                // The upgrade it held back can run now; a user who asked for it gets it at once,
                // otherwise the schedule or Opdater alle picks it up.
                if userInitiated, hadDeferred { await request("upgrade") }
            case .refused:
                protectRefused = true
                await refresh()
            case .busy: break
            case .failed: self.error = text.isEmpty ? "Apperne kunne ikke beskyttes (\(code))." : text
            }
        }
    }
    var headline: String {
        if !installed { return "Tjenesten skal opdateres" }
        if let job = runJob, let line = runHeadline(job: job, succeeded: runSucceeded, result: runResult) { return line }
        if failed { return "Kørsel mislykkedes" }
        if !hasScanned { return "Klar til scanning" }
        return updates.isEmpty ? "Alt er opdateret" : "\(updates.count) opdateringer klar"
    }
    /// Lets a blocked cask be tried again: root drops the block list, then a new run starts.
    func retryBlocked() async {
        guard !clearingBlocked, !busy, installed else { return }
        clearingBlocked = true
        BrewauLog.app.notice("clearing the blocked cask list")
        do {
            _ = try await Task.detached {
                try runCommand("/usr/bin/sudo", ["-n", "/opt/brewau/libexec/brewau-agent", "clear-blocked"])
            }.value
            clearingBlocked = false
            await request("upgrade")
        } catch {
            clearingBlocked = false
            BrewauLog.app.error("clear-blocked was refused")
            self.error = error.localizedDescription
        }
    }
    /// Privacy & Security > App Management, where the user switches brewau on.
    func openAppManagementSettings() {
        BrewauLog.app.notice("opening the App Management privacy settings")
        for identifier in ["com.apple.settings.PrivacySecurity.extension", "com.apple.preference.security"] {
            if let url = URL(string: "x-apple.systempreferences:\(identifier)?Privacy_AppBundles"),
               NSWorkspace.shared.open(url) { return }
        }
        error = AppManagementGuide.settingsFallback
    }

    func refresh() async {
        struct Snapshot: Sendable {
            var config: ScheduleSettings?
            var updates: [PackageUpdate]?
            var catalog: Data?
            var operation: OperationState?
            var lastScan: OperationState?
            var lastUpgrade: OperationState?
            var upgradeResult: RunResult?
            var scanResult: RunResult?
            var pending: [UnprotectedApp]?
            var error: String?
            var installed: Bool
            var homebrew: String
        }
        let snapshot = await Task.detached { () -> Snapshot in
            let root = URL(fileURLWithPath: "/opt/brewau")
            let state = root.appendingPathComponent("var/state")
            let ready = FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("libexec/brewau-agent").path)
            var snapshot = Snapshot(installed: ready, homebrew: "Ukendt")
            guard ready else { return snapshot }
            do {
                let text = try String(contentsOf: root.appendingPathComponent("etc/brewau.conf"), encoding: .utf8)
                snapshot.config = try ScheduleSettings.readConfig(text)
                let excluded = Set((configValues(text)["UPGRADE_EXCLUDE"] ?? "").split(separator: " ").map { String($0.split(separator: "/").last ?? "") })
                if FileManager.default.fileExists(atPath: state.appendingPathComponent("updates.json").path) {
                    snapshot.updates = try BrewData.updates(Data(contentsOf: state.appendingPathComponent("updates.json")), exclusions: excluded)
                }
                if FileManager.default.fileExists(atPath: state.appendingPathComponent("catalog.json").path) {
                    snapshot.catalog = try Data(contentsOf: state.appendingPathComponent("catalog.json"))
                }
                snapshot.operation = try? readOperation(state.appendingPathComponent("operation.json"))
                snapshot.lastScan = try? readOperation(state.appendingPathComponent("last-scan.json"))
                snapshot.lastUpgrade = try? readOperation(state.appendingPathComponent("last-upgrade.json"))
                // Written by brewau-upgrade. Absent before the first run of brewau 0.8.0.
                snapshot.upgradeResult = readRunResult(state.appendingPathComponent("last-result.json"))
                snapshot.scanResult = readRunResult(state.appendingPathComponent("last-scan-result.json"))
                // No file means nothing is pending; a file that cannot be read leaves the
                // results to say what is unprotected.
                let pendingFile = state.appendingPathComponent("pending-protection.json")
                if !FileManager.default.fileExists(atPath: pendingFile.path) { snapshot.pending = [] }
                else if let handle = try? FileHandle(forReadingFrom: pendingFile) {
                    snapshot.pending = (try? handle.read(upToCount: RunResult.sizeLimit)).flatMap { $0.flatMap(UnprotectedApp.decodePending) }
                    try? handle.close()
                }
                if let version = try? String(contentsOf: state.appendingPathComponent("homebrew-version"), encoding: .utf8) {
                    snapshot.homebrew = version.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                // The description can carry child or file content; the GUI shows it, the log does not.
                BrewauLog.app.error("reading brewau state failed")
                snapshot.error = error.localizedDescription
            }
            return snapshot
        }.value
        installed = snapshot.installed
        homebrewVersion = snapshot.homebrew
        if !installed {
            status = "Installer den nye brewau-pakke for at forbinde tjenesten."
            busy = false
            return
        }
        if let config = snapshot.config {
            if settings == savedSettings { settings = config }
            savedSettings = config
        }
        if let catalog = snapshot.catalog {
            do { apps = try BrewData.apps(catalog, applicationURL: { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }) }
            catch { self.error = error.localizedDescription }
        }
        if let updates = snapshot.updates { self.updates = updates; hasScanned = true }
        upgradeResult = snapshot.upgradeResult
        scanResult = snapshot.scanResult
        unprotected = UnprotectedApp.merge(pending: snapshot.pending, results: [snapshot.upgradeResult, snapshot.scanResult].compactMap { $0 })
        if unprotected.isEmpty { protectRefused = false }
        let operation = snapshot.operation
        // Only a result published for this run may explain it; a stale file (an earlier
        // offline scan, say) must not excuse a worker that died before publishing its own.
        let result = operation?.finished == nil ? nil
            : operation.flatMap { correlatedResult(self.result(for: $0.kind), job: $0.kind, startedAt: $0.started) }
        runResult = result
        runJob = operation?.finished == nil ? nil : operation?.kind
        runSucceeded = operation?.succeeded != false
        // A run that found no network changed nothing and is not a failure.
        failed = snapshot.error != nil || (operation?.succeeded == false && result?.isOffline != true)
        let running = operation?.finished == nil && operation?.processID.map { kill($0, 0) == 0 || errno == EPERM } == true
        busy = running || (requestPendingUntil.map { Date() < $0 } ?? false)
        if running {
            status = operation?.kind == "scan" ? "Søger efter opdateringer…" : "Installerer opdateringer…"
        } else if let operation, let finished = operation.finished {
            if requestPendingUntil == nil || operation.started >= requestPendingUntil!.addingTimeInterval(-16) {
                requestPendingUntil = nil
                busy = false
            }
            // The result file names the package and the reason; the old message only said
            // that something failed and pointed at the log.
            let detail = result?.danishSummary { self.displayName(for: $0) }
            if operation.succeeded == true {
                status = detail ?? "Sidst tjekket \(finished.formatted(.relative(presentation: .named)))"
            } else if result?.explainsFailure == true {
                status = detail ?? operation.message ?? "Handlingen mislykkedes. Se loggen."
            } else {
                // The run itself did not fail, so the scheduler's own message is the news
                // here; the block, if any, keeps its own notice below.
                status = operation.message ?? detail ?? "Handlingen mislykkedes. Se loggen."
            }
        } else if operation?.finished == nil && operation != nil && !running {
            status = "Sidste kørsel blev afbrudt. Du kan prøve igen."
        } else if hasScanned { status = "Opdateringslisten er klar" }
        else { status = "Klar til den første scanning" }
        if let message = snapshot.error { status = message }
        await refreshNotificationStatus()
        detectPending()
        for event in [snapshot.lastScan, snapshot.lastUpgrade].compactMap({ $0 }) {
            await notify(event, result: correlatedResult(self.result(for: event.kind), job: event.kind, startedAt: event.started))
        }
        await notifyBlocked()
        if !busy { await automaticallyRestartAllowed() }
        refreshLoginStatus()
        if !protecting, protectTrigger.shouldRun(pending: unprotected, finishedRuns: finishedRuns, busy: busy) {
            Task { await protectPending() }
        }
    }

    func request(_ kind: String) async {
        // A running protection holds the operation lock, which would make the run a no-op.
        guard !busy, !protecting, installed else { return }
        busy = true
        requestPendingUntil = Date().addingTimeInterval(15)
        BrewauLog.app.notice("requesting \(kind, privacy: .public)")
        do {
            _ = try await Task.detached { try runCommand("/opt/brewau/bin/brewau", [kind == "upgrade" ? "run" : "scan"]) }.value
            await refresh()
        } catch {
            BrewauLog.app.error("\(kind, privacy: .public) could not be started")
            self.error = error.localizedDescription
            requestPendingUntil = nil
            busy = false
        }
    }
    func saveSettings() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            try settings.validate()
            let data = try JSONEncoder().encode(settings)
            _ = try await Task.detached {
                try runCommand("/usr/bin/sudo", ["-n", "/opt/brewau/libexec/brewau-agent", "configure"], input: data)
            }.value
            savedSettings = settings
            BrewauLog.app.notice("schedule saved")
            await refresh()
        } catch {
            BrewauLog.app.error("saving the schedule failed")
            self.error = error.localizedDescription
        }
    }
    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch { self.error = error.localizedDescription }
        refreshLoginStatus()
    }
    func refreshLoginStatus() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginApproval = SMAppService.mainApp.status == .requiresApproval
    }
    func requestNotificationPermission() async {
        do { _ = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
        catch { self.error = error.localizedDescription }
        await refreshNotificationStatus()
    }
    func refreshNotificationStatus() async {
        let permission = await UNUserNotificationCenter.current().notificationSettings()
        notificationAllowed = permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional
        notificationStatus = notificationAllowed ? "Tilladt i macOS" : permission.authorizationStatus == .denied ? "Blokeret i macOS" : "Kræver tilladelse"
    }
    func notify(_ event: OperationState, result: RunResult?) async {
        guard let finished = event.finished else { return }
        let key = "notified-\(event.kind)"
        guard finished.timeIntervalSince1970 > defaults.double(forKey: key) else { return }
        defaults.set(finished.timeIntervalSince1970, forKey: key)
        guard notificationPreferences.enabled else { return }
        var body: String?
        switch runNotice(job: event.kind, succeeded: event.succeeded == true, result: result) {
        case .silent: return
        case .failure:
            guard notificationPreferences.failure else { return }
            // Blocks are left out: their own banner reports them once per version.
            body = result?.danishSummary(includingBlocks: false) { self.displayName(for: $0) }
                ?? event.message ?? "En opdatering mislykkedes. Åbn brewau for detaljer."
        case .upgradeFinished:
            guard notificationPreferences.complete else { return }
            body = "Opdateringen er færdig.\(pending.isEmpty ? "" : " \(pending.count) apps afventer genstart.")"
        case .updatesAvailable:
            guard notificationPreferences.available, !availableUpdates.isEmpty else { return }
            body = "\(availableUpdates.count) opdateringer er klar til installation."
        }
        if let body { _ = await sendNotification(id: key, title: "brewau", body: body) }
    }
    /// A block repeats on every scheduled run, so the banner is tied to the package and the
    /// version it got stuck on instead of to the run.
    func notifyBlocked() async {
        // The result is re-read every few seconds; log the blocked set only when it changes.
        let current = (blockedByAppManagement + legacyUnprotected).map { "\($0.name) \($0.version)" } + unprotected.map { "\($0.key) (unprotected)" }
        if blockedLog.changed(Set(current)) {
            for item in current { BrewauLog.app.notice("reporting blocked package \(item, privacy: .public)") }
        }
        guard notificationPreferences.enabled, notificationPreferences.failure else { return }
        let notices = blockedByAppManagement.map { ($0, "blocked", "\(displayName(for: $0)) kunne ikke opdateres",
                                                    "macOS App Management blokerer opdateringen. Åbn brewau for at se, hvad du kan gøre.") }
            // Only once the helper itself was refused: until then brewau protects them on its own.
            + (protectRefused ? unprotected : []).map {
                (RunResultItem(name: $0.token, kind: "cask", version: $0.version, reason: "app-management", installed: ""),
                 $0.deferred ? "deferred" : "unprotected",
                 "\(displayName(for: $0)) kunne ikke beskyttes",
                 "\(AppManagementGuide.instruction) Åbn brewau for at se, hvad du kan gøre.")
            }
        for (item, prefix, title, body) in notices {
            let key = "\(prefix)-\(item.name)-\(item.version)"
            guard oneShot.shouldSubmit(key, delivered: defaults.bool(forKey: key)) else { continue }
            let delivered = await sendNotification(id: key, title: title, body: body)
            // Remembered only once it was really delivered, so a permission the user grants
            // later still gets the banner.
            if oneShot.finish(key, delivered: delivered) { defaults.set(true, forKey: key) }
        }
    }
    @discardableResult func sendNotification(id: String, title: String, body: String) async -> Bool {
        guard notificationAllowed else { return false }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
            return true
        } catch {
            BrewauLog.app.error("a notification could not be submitted")
            status = "Notifikation kunne ikke sendes: \(error.localizedDescription)"
            return false
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func detectPending() {
        let running = NSWorkspace.shared.runningApplications
        let previous = Set(pending.map(\.id))
        pending = apps.compactMap { app in
            guard let installedAt = app.installedAt,
                  let process = running.first(where: { $0.bundleURL?.standardizedFileURL.path == app.path && !$0.isTerminated }),
                  let launched = process.launchDate, launched < installedAt,
                  process.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
            return PendingApp(app: app, process: process)
        }
        if notificationPreferences.enabled && notificationPreferences.restart {
            for item in pending where !previous.contains(item.id) {
                let key = "restart-\(item.id)-\(Int(item.app.installedAt!.timeIntervalSince1970))"
                guard !defaults.bool(forKey: key) else { continue }
                defaults.set(true, forKey: key)
                Task { await sendNotification(id: key, title: "\(item.app.name) skal genstartes", body: "Gem dit arbejde, og genstart for at bruge \(item.app.version).") }
            }
        }
    }
    func consentKey(_ app: InstalledApp) -> String? {
        guard let bundle = Bundle(url: URL(fileURLWithPath: app.path)), let id = bundle.bundleIdentifier else { return nil }
        return app.id + "|" + id
    }
    func forceIsAllowed(_ app: InstalledApp) -> Bool { consentKey(app).map { forceAllowed.contains($0) } ?? false }
    func setForceAllowed(_ app: InstalledApp, _ allowed: Bool) {
        guard let key = consentKey(app) else { error = "Appens identitet kunne ikke læses."; return }
        if allowed { forceAllowed.insert(key) }
        else { forceAllowed.remove(key) }
    }
    func automaticallyRestartAllowed() async {
        for item in pending where forceIsAllowed(item.app) {
            let key = "\(item.id)|\(item.process.processIdentifier)"
            guard !automaticRestartAttempts.contains(key) else { continue }
            automaticRestartAttempts.insert(key)
            await restart(item)
        }
    }
    func restart(_ item: PendingApp) async {
        guard !restarting.contains(item.id), !item.process.isTerminated,
              item.process.bundleURL?.standardizedFileURL.path == item.app.path else { return }
        restarting.insert(item.id)
        defer { restarting.remove(item.id); waitingToQuit.remove(item.id); detectPending() }
        let oldPID = item.process.processIdentifier
        let started = Date()
        var forced = false
        item.process.terminate()
        waitingToQuit.insert(item.id)
        loop: while true {
            switch RestartTiming.step(elapsed: Date().timeIntervalSince(started), terminated: item.process.isTerminated,
                                      forceAllowed: forceIsAllowed(item.app), forced: forced) {
            case .reopen: break loop
            case .force:
                forced = true
                item.process.forceTerminate()
            case .giveUp:
                BrewauLog.app.error("\(item.app.token, privacy: .public) would not quit")
                error = "\(item.app.name) kunne ikke afsluttes. Gem dit arbejde, og luk appen selv, eller tillad tvungen genstart i indstillingerne."
                return
            case .wait:
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
            .map { (pid: $0.processIdentifier, path: $0.bundleURL?.standardizedFileURL.path) }
        guard RestartTiming.shouldReopen(oldPID: oldPID, running: running, appPath: item.app.path) else {
            BrewauLog.app.notice("\(item.app.token, privacy: .public) was already reopened")
            return
        }
        do { _ = try await NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: item.app.path), configuration: NSWorkspace.OpenConfiguration()) }
        catch { self.error = "\(item.app.name) blev lukket, men kunne ikke åbnes igen: \(error.localizedDescription)" }
    }
    func repairTerminal() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        do {
            _ = try await Task.detached {
                try runCommand("/usr/bin/sudo", ["-n", "/opt/brewau/libexec/brewau-agent", "completions"])
            }.value
            // Shell setup runs as the actual user and preserves symlinked dotfiles and backups.
            _ = try await Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/opt/brewau/bin/brewau")
                process.arguments = ["setup-shell"]
                process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
                let output = Pipe()
                process.standardOutput = output; process.standardError = output
                process.standardInput = FileHandle.nullDevice
                try process.run()
                let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { throw BrewauError.message(text) }
                return text
            }.value
            repairStatus = "Rettet. Åbn en ny terminal. Dine shellfiler er sikkerhedskopieret."
        } catch { self.error = error.localizedDescription }
    }
    func showLog() { NSWorkspace.shared.open(stateDirectory.deletingLastPathComponent().appendingPathComponent("log/upgrade.log")) }
}

struct NotificationPreferences: Codable {
    var enabled = true
    var available = false
    var complete = true
    var restart = true
    var failure = true
}
