import AppKit
import SwiftUI

// shortcut: sample data and in-memory settings only; connect the privileged service after design approval.
struct AppUpdate: Identifiable {
    let id: String
    let name: String
    let installed: String
    let available: String
    let symbol: String
    let color: Color

    static let samples = [
        AppUpdate(id: "postman", name: "Postman", installed: "12.33.3", available: "12.33.4", symbol: "paperplane.fill", color: .orange),
        AppUpdate(id: "vscode", name: "Visual Studio Code", installed: "1.104.2", available: "1.105.0", symbol: "chevron.left.forwardslash.chevron.right", color: .blue),
        AppUpdate(id: "raycast", name: "Raycast", installed: "1.103.1", available: "1.104.0", symbol: "command", color: .red)
    ]
    static let docker = AppUpdate(id: "docker", name: "Docker Desktop", installed: "4.47.0", available: "4.48.0", symbol: "shippingbox.fill", color: .blue)
}

enum Schedule: String, CaseIterable, Identifiable {
    case hourly = "Interval", daily = "Dagligt", weekly = "Ugentligt"
    var id: String { rawValue }
}

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "Generelt", schedule = "Tidsplan", restart = "Genstart", notifications = "Notifikationer", homebrew = "Homebrew"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .schedule: "calendar.badge.clock"
        case .restart: "arrow.clockwise"
        case .notifications: "bell"
        case .homebrew: "shippingbox"
        }
    }
    var subtitle: String {
        switch self {
        case .general: "Et lille overblik. Resten sker i baggrunden."
        case .schedule: "Du bestemmer, hvornår brewau arbejder."
        case .restart: "Dine apps. Dine regler for genstart."
        case .notifications: "Kun besked, når det er relevant."
        case .homebrew: "Hold også fundamentet opdateret."
        }
    }
}

@MainActor final class MockupModel: ObservableObject {
    @Published var updates = AppUpdate.samples
    @Published var pending = [AppUpdate.docker]
    @Published var busy = false
    @Published var lastScan = "Sidst tjekket for 2 minutter siden"
    @Published var page = SettingsPage.schedule
    @Published var autoUpgrade = true
    @Published var scanMinutes = 60
    @Published var schedule = Schedule.daily
    @Published var intervalHours = 1
    @Published var weekday = 2
    @Published var times = [MockupModel.time(3), MockupModel.time(15)]
    @Published var launchAtLogin = true
    @Published var notifications = true
    @Published var notifyAvailable = false
    @Published var notifyComplete = true
    @Published var notifyRestart = true
    @Published var notifyFailure = true
    @Published var updateHomebrew = true
    @Published var greedy = true
    @Published var forceAllowed: Set<String> = []
    @Published var notice: String?
    @Published var completionRepairPreview = false

    static func time(_ hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: hour))!
    }
    static let weekdays = ["Søndag", "Mandag", "Tirsdag", "Onsdag", "Torsdag", "Fredag", "Lørdag"]
    var scanSummary: String {
        scanMinutes < 60 ? "hvert \(scanMinutes). minut" : scanMinutes == 60 ? "hver time" : "hver \(scanMinutes / 60). time"
    }
    var scheduleSummary: String {
        guard autoUpgrade else { return "Manuel opdatering" }
        if schedule == .hourly { return intervalHours == 1 ? "Hver time" : "Hver \(intervalHours). time" }
        let clock = times.map { $0.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)).replacingOccurrences(of: ":", with: ".") }.sorted().joined(separator: " og ")
        return schedule == .daily ? "Hver dag kl. \(clock)" : "Hver \(Self.weekdays[weekday - 1].lowercased()) kl. \(clock)"
    }
    func scan() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        try? await Task.sleep(for: .seconds(1))
        updates = AppUpdate.samples
        lastScan = "Sidst tjekket lige nu · demodata"
    }
    func upgrade() async {
        guard !busy, !updates.isEmpty else { return }
        busy = true
        defer { busy = false }
        try? await Task.sleep(for: .seconds(1.5))
        for app in updates where !pending.contains(where: { $0.id == app.id }) {
            // Force permission is demonstrated separately; the prototype never closes real apps.
            if !forceAllowed.contains(app.id) { pending.append(app) }
        }
        updates = []
        lastScan = "Opdateret lige nu · simulering"
    }
    func restart(_ app: AppUpdate) {
        pending.removeAll { $0.id == app.id }
    }
}

@main struct BrewauMockup: App {
    @StateObject private var model = MockupModel()

    init() {
        if CommandLine.arguments.contains("--self-check") {
            Self.check()
            exit(0)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--render"), CommandLine.arguments.count > index + 1 {
            NSApplication.shared.setActivationPolicy(.accessory)
            do { try renderPreviews(to: CommandLine.arguments[index + 1]) }
            catch { fputs("Preview failed: \(error)\n", stderr); exit(1) }
            exit(0)
        }
    }
    var body: some Scene {
        MenuBarExtra {
            UpdatePopover(model: model)
        } label: {
            Label("brewau", systemImage: model.updates.isEmpty ? "checkmark.circle" : "arrow.triangle.2.circlepath")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
    static func check() {
        let model = MockupModel()
        assert(model.updates.count == 3)
        assert(model.scheduleSummary.contains("03.00") && model.scheduleSummary.contains("15.00"))
        model.schedule = .weekly
        model.times = [MockupModel.time(3)]
        assert(model.scheduleSummary == "Hver mandag kl. 03.00")
        model.schedule = .hourly
        assert(model.scheduleSummary == "Hver time")
        model.intervalHours = 6
        assert(model.scheduleSummary == "Hver 6. time")
        model.autoUpgrade = false
        assert(model.scheduleSummary == "Manuel opdatering")
        model.restart(.docker)
        assert(model.pending.isEmpty)
        assert(model.forceAllowed.isEmpty)
        print("Mockup self-check passed: schedules, sample data, restart state, safe defaults.")
    }
}

struct AppIcon: View {
    let app: AppUpdate
    var body: some View {
        Image(systemName: app.symbol)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(app.color)
            .frame(width: 34, height: 34)
            .background(app.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

struct UpdatePopover: View {
    @ObservedObject var model: MockupModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 19, weight: .medium))
                Text("brewau").font(.system(size: 19, weight: .semibold))
                Spacer()
                Text("MOCKUP").font(.system(size: 9, weight: .semibold)).tracking(1)
                    .foregroundStyle(.secondary).padding(.horizontal, 7).padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }.padding(20)
            Divider()
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(model.updates.isEmpty ? "Alt er opdateret" : "\(model.updates.count) opdateringer klar")
                            .font(.system(size: 20, weight: .semibold))
                        Text(model.lastScan).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { Task { await model.scan() } } label: {
                        if model.busy { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.clockwise") }
                    }
                    .frame(width: 28, height: 28)
                    .disabled(model.busy)
                    .help("Scan efter opdateringer")
                    .accessibilityLabel("Scan efter opdateringer")
                }
                if !model.updates.isEmpty {
                    HStack {
                        Text("APP")
                        Spacer()
                        Text("INSTALLERET → NY")
                    }.font(.system(size: 9, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
                    VStack(spacing: 14) {
                        ForEach(model.updates) { app in
                            HStack(spacing: 10) {
                                AppIcon(app: app)
                                Text(app.name).font(.system(size: 12, weight: .medium))
                                Spacer(minLength: 4)
                                HStack(spacing: 5) {
                                    Text(app.installed).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                    Text(app.available).fontWeight(.medium)
                                }.font(.system(size: 10)).monospacedDigit()
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(app.name), installeret \(app.installed), ny version \(app.available)")
                        }
                    }
                    Button { Task { await model.upgrade() } } label: {
                        Text(model.busy ? "Arbejder…" : "Opdater alle")
                            .frame(maxWidth: .infinity).padding(.vertical, 5)
                    }.buttonStyle(.borderedProminent).disabled(model.busy)
                } else {
                    Label("Alle apps er ajour", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary).padding(.vertical, 12)
                }
                Label(model.scheduleSummary, systemImage: "clock")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(20)
            if !model.pending.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Label("Afventer genstart", systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 12, weight: .semibold))
                    ForEach(model.pending) { app in
                        HStack(spacing: 10) {
                            AppIcon(app: app)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(app.name).font(.system(size: 12, weight: .medium))
                                Text("\(app.available) klar efter genstart").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Genstart…") {
                                model.notice = app.id
                            }.controlSize(.small).disabled(model.busy)
                        }
                    }
                    Text("Apps lukkes kun automatisk med din tilladelse.")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(20)
            }
            Divider()
            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: { Label("Indstillinger…", systemImage: "gearshape") }
                .keyboardShortcut(",")
                Spacer()
                Menu {
                    Button("Nulstil demo") { model.updates = AppUpdate.samples; model.pending = [.docker] }
                    Divider()
                    Button("Afslut brewau") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Flere muligheder")
            }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 410)
        .background(.background)
        .tint(.blue)
        .alert("Genstart app?", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("Annuller", role: .cancel) { model.notice = nil }
            Button("Simuler genstart") {
                if let app = model.pending.first(where: { $0.id == model.notice }) { model.restart(app) }
                model.notice = nil
            }
        } message: { Text("Gem dit arbejde først. I mockuppen ændres kun listen; ingen app bliver lukket.") }
    }
}

struct SettingsView: View {
    @ObservedObject var model: MockupModel

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 21))
                    Text("brewau").font(.system(size: 21, weight: .semibold))
                }.padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 24)
                ForEach(SettingsPage.allCases) { page in
                    Button { model.page = page } label: {
                        Label(page.rawValue, systemImage: page.symbol)
                            .font(.system(size: 13, weight: model.page == page ? .medium : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10)
                            .contentShape(Rectangle())
                            .background(model.page == page ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain)
                    .accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Designprototype").font(.system(size: 11, weight: .medium))
                    Text("Apple Silicon · native macOS").font(.system(size: 10)).foregroundStyle(.secondary)
                }.padding(12)
            }.padding(12).frame(width: 185).background(.ultraThinMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(model.page.rawValue).font(.system(size: 25, weight: .semibold))
                    Text(model.page.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                }.padding(.horizontal, 28).padding(.top, 30).padding(.bottom, 8)
                Form {
                    switch model.page {
                    case .general: general
                    case .schedule: schedule
                    case .restart: restart
                    case .notifications: notifications
                    case .homebrew: homebrew
                    }
                }.formStyle(.grouped).scrollContentBackground(.hidden)
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("Mockup · ændringer gælder kun denne demo")
                }.font(.system(size: 10)).foregroundStyle(.secondary)
                    .padding(.horizontal, 28).padding(.vertical, 14)
            }.frame(maxWidth: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.frame(width: 800, height: 620).tint(.blue)
    }

    private var general: some View {
        Group {
            Section {
                Toggle("Start brewau ved login", isOn: $model.launchAtLogin)
                LabeledContent("Visning", value: "Kun i menulinjen")
            } header: { Text("På din Mac") } footer: {
                Text("Ingen Dock-app. Opdateringer og genstart er altid et klik væk.")
            }
            Section("Overblik") {
                LabeledContent("Scanning", value: "Automatisk \(model.scanSummary)")
                LabeledContent("Opdateringer", value: model.scheduleSummary)
                LabeledContent("Tilladt tvungen genstart", value: "\(model.forceAllowed.count) apps")
            }
        }
    }
    private var schedule: some View {
        Group {
            Section {
                Picker("Scan efter opdateringer", selection: $model.scanMinutes) {
                    Text("Hvert 15. minut").tag(15)
                    Text("Hvert 30. minut").tag(30)
                    Text("Hver time").tag(60)
                    Text("Hver 6. time").tag(360)
                    Text("Hver 12. time").tag(720)
                    Text("Hver dag").tag(1440)
                }
            } header: { Text("Find opdateringer") } footer: {
                Text("Scanning finder nye versioner uden at installere dem.")
            }
            Section {
                Toggle("Opdater automatisk", isOn: $model.autoUpgrade)
                if model.autoUpgrade {
                    Picker("Gentag", selection: $model.schedule) {
                        ForEach(Schedule.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    if model.schedule == .hourly {
                        Picker("Opdater", selection: $model.intervalHours) {
                            ForEach([1, 2, 4, 6, 12], id: \.self) { Text($0 == 1 ? "Hver time" : "Hver \($0). time").tag($0) }
                        }
                    } else {
                        if model.schedule == .weekly {
                            Picker("Ugedag", selection: $model.weekday) {
                                ForEach(1...7, id: \.self) { Text(MockupModel.weekdays[$0 - 1]).tag($0) }
                            }
                        }
                        ForEach(model.times.indices, id: \.self) { index in
                            HStack {
                                DatePicker("Tidspunkt", selection: $model.times[index], displayedComponents: .hourAndMinute)
                                    .environment(\.locale, Locale(identifier: "da_DK"))
                                Button {
                                    model.times.remove(at: index)
                                } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).disabled(model.times.count == 1)
                                .accessibilityLabel("Fjern tidspunkt \(index + 1)")
                            }
                        }
                        Button("Tilføj tidspunkt", systemImage: "plus") { model.times.append(MockupModel.time(9)) }
                            .buttonStyle(.borderless)
                    }
                }
            } header: { Text("Installer opdateringer") } footer: {
                Text("Tider følger din Macs lokale tidszone.")
            }
            Section {
                Label(model.scheduleSummary, systemImage: "calendar.badge.clock").fontWeight(.medium)
            }
        }
    }
    private var restart: some View { RestartSettings(model: model) }
    private var notifications: some View {
        Group {
            Section {
                Toggle("Tillad notifikationer", isOn: $model.notifications)
            } footer: { Text("Den færdige app skal også have tilladelse i macOS' Systemindstillinger.") }
            Section("Giv mig besked") {
                Toggle("Nye opdateringer fundet", isOn: $model.notifyAvailable)
                Toggle("Opdateringer installeret", isOn: $model.notifyComplete)
                Toggle("En app skal genstartes", isOn: $model.notifyRestart)
                Toggle("En opdatering mislykkedes", isOn: $model.notifyFailure)
            }.disabled(!model.notifications)
            Section("Eksempel") {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.triangle.2.circlepath").font(.title2).padding(9)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("brewau").fontWeight(.semibold)
                        Text("Docker Desktop er klar til genstart")
                        Text("Gem dit arbejde, og genstart for at bruge den nye version.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("nu").font(.caption).foregroundStyle(.secondary)
                }.padding(.vertical, 6)
            }
        }
    }
    private var homebrew: some View {
        Group {
            Section {
                Toggle("Opdater Homebrew før scanning", isOn: $model.updateHomebrew)
                Toggle("Medtag apps med egen auto-update", isOn: $model.greedy)
            } header: { Text("Homebrew") } footer: {
                Text("Hold Homebrew og pakkelisten ajour, før brewau søger efter nye versioner.")
            }
            Section {
                LabeledContent("Arkitektur", value: "Apple Silicon (arm64)")
                LabeledContent("Installation", value: "/opt/homebrew")
            } header: { Text("Installation · eksempeldata") }
            Section {
                Label("Terminal-completions kræver reparation", systemImage: "exclamationmark.triangle")
                    .fontWeight(.medium)
                Text("Ret advarsler om usikre mapper i terminalen, og bevar zshs sikkerhedskontrol.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Vis foreslået løsning…") { model.completionRepairPreview = true }
            } header: { Text("Terminal") } footer: {
                Text("Status er illustrativ. Mockuppen undersøger eller ændrer ikke din installation.")
            }
        }
        .alert("Foreslået løsning til zsh", isPresented: $model.completionRepairPreview) {
            Button("Luk", role: .cancel) {}
        } message: {
            Text("Lav en root-ejet kopi af completions og brug den i zshs fpath. Den skal opdateres efter Homebrew-ændringer og håndtere symlinks sikkert. Løsningen skal verificeres med compaudit; sikkerhedstjekket bevares. Dette er kun et designforslag.")
        }
    }
}

struct RestartSettings: View {
    @ObservedObject var model: MockupModel
    @State private var confirmation: AppUpdate?
    private var apps: [AppUpdate] { AppUpdate.samples + [.docker] }

    var body: some View {
        Section {
            Label("Spørg før apps lukkes", systemImage: "hand.raised")
                .fontWeight(.medium)
            Text("Apps, der kører, vises som “Afventer genstart”. Du kan genstarte dem fra menulinjen, når det passer dig.")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("Standardadfærd") }
        Section {
            ForEach(apps) { app in
                Toggle(isOn: Binding(get: { model.forceAllowed.contains(app.id) }, set: { allow in
                    if allow { confirmation = app }
                    else { model.forceAllowed.remove(app.id) }
                })) {
                    HStack(spacing: 10) {
                        AppIcon(app: app)
                        Text(app.name)
                    }
                }.accessibilityLabel("Tillad tvungen genstart af \(app.name)")
            }
        } header: { Text("Tillad tvungen genstart") } footer: {
            Text("Kun valgte apps må lukkes og åbnes automatisk ved en opdatering. Ugemt arbejde kan gå tabt. Alle er slået fra som udgangspunkt.")
        }
        .alert("Tillad tvungen genstart?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            Button("Annuller", role: .cancel) { confirmation = nil }
            Button("Tillad", role: .destructive) {
                if let app = confirmation { model.forceAllowed.insert(app.id) }
                confirmation = nil
            }
        } message: {
            Text("\(confirmation?.name ?? "Appen") må lukkes og åbnes automatisk. Ugemt arbejde kan gå tabt. I mockuppen gemmes kun dit valg.")
        }
    }
}

@MainActor func renderPreviews(to directory: String) throws {
    let url = URL(fileURLWithPath: directory, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let model = MockupModel()
    func render<V: View>(_ view: V, name: String, size: NSSize, dark: Bool = false) throws {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).environment(\.controlActiveState, .active).environment(\.locale, Locale(identifier: "da_DK")))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { throw CocoaError(.fileWriteUnknown) }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url.appendingPathComponent("\(name).png"))
    }
    try render(UpdatePopover(model: model), name: "menulinje", size: NSSize(width: 410, height: 566))
    try render(UpdatePopover(model: model), name: "menulinje-dark", size: NSSize(width: 410, height: 566), dark: true)
    for page in SettingsPage.allCases {
        model.page = page
        try render(SettingsView(model: model), name: "settings-\(page.symbol.components(separatedBy: ".").first!)", size: NSSize(width: 800, height: 620))
    }
    model.page = .schedule
    try render(SettingsView(model: model), name: "settings-dark", size: NSSize(width: 800, height: 620), dark: true)
    print("Previews written to \(directory)")
}
