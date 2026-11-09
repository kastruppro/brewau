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
    @Published var repairStatus: String?
    @Published var homebrewVersion = "Ukendt"
    @Published var upgradeResult: RunResult?
    @Published var scanResult: RunResult?
    @Published var clearingBlocked = false
    /// Which job the newest finished run belonged to, so the headline describes that run.
    @Published var lastRunJob: String?
    @Published var notificationPreferences = NotificationPreferences() { didSet { savePreferences() } }
    @Published var forceAllowed: Set<String> = [] { didSet { savePreferences() } }
    private let defaults = UserDefaults.standard
    private let stateDirectory = URL(fileURLWithPath: "/opt/brewau/var/state", isDirectory: true)
    private var polling: Task<Void, Never>?
    private var requestPendingUntil: Date?
    private var automaticRestartAttempts: Set<String> = []
    private var loadingPreferences = true

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
    func displayName(for item: RunResultItem) -> String { apps.first(where: { $0.token == item.token })?.name ?? item.token }
    func appManagementBlock(for update: PackageUpdate) -> RunResultItem? {
        blockedByAppManagement.first { $0.token == update.token }
    }
    var blockedMessage: String? { RunResult.danishBlocks(blockedByAppManagement.map { displayName(for: $0) }) }
    var headline: String {
        if !installed { return "Tjenesten skal opdateres" }
        if let line = (lastRunJob.flatMap { result(for: $0) })?.danishHeadline { return line }
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
            BrewauLog.app.error("clear-blocked failed: \(error.localizedDescription, privacy: .public)")
            self.error = error.localizedDescription
        }
    }
    /// Privacy & Security > App Management, where the user can add the background job.
    func openAppManagementSettings() {
        BrewauLog.app.notice("opening the App Management privacy settings")
        for identifier in ["com.apple.settings.PrivacySecurity.extension", "com.apple.preference.security"] {
            if let url = URL(string: "x-apple.systempreferences:\(identifier)?Privacy_AppBundles"),
               NSWorkspace.shared.open(url) { return }
        }
        error = "Systemindstillinger kunne ikke åbnes. Gå til Anonymitet og sikkerhed › App-administration."
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
                if let version = try? String(contentsOf: state.appendingPathComponent("homebrew-version"), encoding: .utf8) {
                    snapshot.homebrew = version.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            } catch {
                BrewauLog.app.error("reading brewau state failed: \(error.localizedDescription, privacy: .public)")
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
        let operation = snapshot.operation
        lastRunJob = operation?.finished == nil ? nil : operation?.kind
        let result = operation.flatMap { self.result(for: $0.kind) }
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
            } else {
                status = detail ?? operation.message ?? "Handlingen mislykkedes. Se loggen."
            }
        } else if operation?.finished == nil && operation != nil && !running {
            status = "Sidste kørsel blev afbrudt. Du kan prøve igen."
        } else if hasScanned { status = "Opdateringslisten er klar" }
        else { status = "Klar til den første scanning" }
        if let message = snapshot.error { status = message }
        await refreshNotificationStatus()
        detectPending()
        for event in [snapshot.lastScan, snapshot.lastUpgrade].compactMap({ $0 }) {
            await notify(event, result: self.result(for: event.kind))
        }
        await notifyBlocked()
        if !busy { await automaticallyRestartAllowed() }
        refreshLoginStatus()
    }

    func request(_ kind: String) async {
        guard !busy, installed else { return }
        busy = true
        requestPendingUntil = Date().addingTimeInterval(15)
        BrewauLog.app.notice("requesting \(kind, privacy: .public)")
        do {
            _ = try await Task.detached { try runCommand("/opt/brewau/bin/brewau", [kind == "upgrade" ? "run" : "scan"]) }.value
            await refresh()
        } catch {
            BrewauLog.app.error("\(kind, privacy: .public) could not be started: \(error.localizedDescription, privacy: .public)")
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
            BrewauLog.app.error("saving the schedule failed: \(error.localizedDescription, privacy: .public)")
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
        // A run without network did nothing; it is neither a failure nor news worth a banner.
        guard result?.isOffline != true else { return }
        var body: String?
        if event.succeeded == false, notificationPreferences.failure {
            body = result?.danishSummary { self.displayName(for: $0) } ?? event.message ?? "En opdatering mislykkedes. Åbn brewau for detaljer."
        }
        else if event.kind == "upgrade", notificationPreferences.complete { body = "Opdateringen er færdig.\(pending.isEmpty ? "" : " \(pending.count) apps afventer genstart.")" }
        else if event.kind == "scan", notificationPreferences.available, !availableUpdates.isEmpty { body = "\(availableUpdates.count) opdateringer er klar til installation." }
        if let body { await sendNotification(id: key, title: "brewau", body: body) }
    }
    /// A block repeats on every scheduled run, so the banner is tied to the package and the
    /// version it got stuck on instead of to the run.
    func notifyBlocked() async {
        guard notificationPreferences.enabled, notificationPreferences.failure else { return }
        for item in blockedByAppManagement {
            let key = "blocked-\(item.name)-\(item.version)"
            guard !defaults.bool(forKey: key) else { continue }
            defaults.set(true, forKey: key)
            BrewauLog.app.notice("reporting blocked package \(item.name, privacy: .public) \(item.version, privacy: .public)")
            await sendNotification(id: key, title: "\(displayName(for: item)) kunne ikke opdateres",
                                   body: "macOS App Management blokerer baggrundsjobbet. Åbn brewau for at se, hvad du kan gøre.")
        }
    }
    func sendNotification(id: String, title: String, body: String) async {
        guard notificationAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do { try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) }
        catch { status = "Notifikation kunne ikke sendes: \(error.localizedDescription)" }
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
        defer { restarting.remove(item.id); detectPending() }
        item.process.terminate()
        for _ in 0..<30 {
            if item.process.isTerminated { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if !item.process.isTerminated && forceIsAllowed(item.app) {
            item.process.forceTerminate()
            for _ in 0..<10 {
                if item.process.isTerminated { break }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        guard item.process.isTerminated else {
            BrewauLog.app.error("\(item.app.token, privacy: .public) would not quit")
            error = "\(item.app.name) kunne ikke afsluttes. Gem dit arbejde, og luk appen selv, eller tillad tvungen genstart i indstillingerne."
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
