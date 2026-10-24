import AppKit
import SwiftUI
import ServiceManagement

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

struct AppIcon: View {
    var path: String?
    var isCask = true
    var body: some View {
        Group {
            if let path {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().scaledToFit()
            } else {
                Image(systemName: isCask ? "app.dashed" : "terminal")
                    .font(.system(size: 19)).foregroundStyle(.secondary)
            }
        }.frame(width: 32, height: 32).accessibilityHidden(true)
    }
}

struct UpdatePopover: View {
    @ObservedObject var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @State private var restartConfirmation: PendingApp? = nil
    @State private var contentHeight: CGFloat = 0
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(nsImage: menuBarIcon(updates: false, busy: false)).resizable().frame(width: 20, height: 20)
                Text("brewau").font(.system(size: 19, weight: .semibold))
                Spacer()
                Button { Task { await model.request("scan") } } label: {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "arrow.clockwise") }
                }.frame(width: 28, height: 28).disabled(model.busy || !model.installed)
                    .help("Scan efter opdateringer").accessibilityLabel("Scan efter opdateringer")
            }.padding(20)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(!model.installed ? "Tjenesten skal opdateres" : model.failed ? "Kørsel mislykkedes" : !model.hasScanned ? "Klar til scanning" : model.updates.isEmpty ? "Alt er opdateret" : "\(model.updates.count) opdateringer klar")
                            .font(.system(size: 20, weight: .semibold))
                        Text(model.status).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.updates.isEmpty {
                        HStack {
                            Text("APP / PAKKE")
                            Spacer()
                            Text("INSTALLERET → NY")
                        }.font(.system(size: 9, weight: .medium)).tracking(0.6).foregroundStyle(.secondary)
                        ForEach(model.updates) { update in
                            HStack(spacing: 10) {
                                AppIcon(path: model.apps.first(where: { $0.token == update.token })?.path, isCask: update.isCask)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.name(for: update)).font(.system(size: 12, weight: .medium))
                                    if update.blocked { Text("Fastlåst eller udelukket").font(.system(size: 10)).foregroundStyle(.secondary) }
                                }
                                Spacer(minLength: 4)
                                HStack(spacing: 5) {
                                    Text(update.installed).foregroundStyle(.secondary)
                                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                                    Text(update.available).fontWeight(.medium)
                                }.font(.system(size: 10)).monospacedDigit().lineLimit(1)
                            }.help("\(model.name(for: update)): \(update.installed) → \(update.available)")
                        }
                    }
                    if model.installed {
                        Button { Task { await model.request(model.hasScanned ? "upgrade" : "scan") } } label: {
                            Text(model.busy ? "Arbejder…" : model.hasScanned ? "Opdater alle" : "Scan nu")
                                .frame(maxWidth: .infinity).padding(.vertical, 5)
                        }.buttonStyle(.borderedProminent)
                            .disabled(model.busy || (model.hasScanned && model.availableUpdates.isEmpty))
                        Label(model.savedSettings.summary, systemImage: "clock").font(.system(size: 11)).foregroundStyle(.secondary)
                    } else {
                        Text("Installer den medfølgende brewau.pkg. Dine eksisterende indstillinger bevares.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !model.pending.isEmpty {
                        Divider().padding(.vertical, 2)
                        Label("Afventer genstart", systemImage: "arrow.clockwise.circle").font(.system(size: 12, weight: .semibold))
                        ForEach(model.pending) { item in
                            HStack(spacing: 10) {
                                AppIcon(path: item.app.path)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(item.app.name).font(.system(size: 12, weight: .medium))
                                    Text("\(item.app.version) klar efter genstart").font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(model.restarting.contains(item.id) ? "Genstarter…" : "Genstart…") { restartConfirmation = item }
                                    .controlSize(.small).disabled(model.busy || model.restarting.contains(item.id))
                            }
                        }
                        Text("Apps lukkes kun automatisk med din tilladelse.").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }.padding(20).onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            // MenuBarExtra windows size a ScrollView to zero unless it gets an explicit height.
            .frame(height: min(contentHeight, 510))
            Divider()
            HStack {
                Button {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                } label: { Label("Indstillinger…", systemImage: "gearshape") }.keyboardShortcut(",")
                Spacer()
                Menu {
                    Button("Vis log") { model.showLog() }
                    Divider()
                    Button("Afslut brewau") { NSApp.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Flere muligheder")
            }.font(.system(size: 11)).buttonStyle(.plain).padding(.horizontal, 20).padding(.vertical, 14)
        }.frame(width: 410).background(.background).tint(.blue)
            .alert("Genstart app?", isPresented: Binding(get: { restartConfirmation != nil }, set: { if !$0 { restartConfirmation = nil } })) {
                Button("Annuller", role: .cancel) { restartConfirmation = nil }
                Button("Genstart") {
                    if let item = restartConfirmation { Task { await model.restart(item) } }
                    restartConfirmation = nil
                }
            } message: { Text("Gem dit arbejde først. Appen lukkes og åbnes igen. Tvungen genstart bruges kun, hvis du har tilladt den i indstillingerne.") }
            .alert("Handlingen kunne ikke gennemføres", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { model.error = nil }
                Button("Vis log") { model.showLog(); model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var forceConfirmation: InstalledApp? = nil
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Image(nsImage: menuBarIcon(updates: false, busy: false)).resizable().frame(width: 22, height: 22)
                    Text("brewau").font(.system(size: 21, weight: .semibold))
                }.padding(.horizontal, 12).padding(.top, 28).padding(.bottom, 24)
                ForEach(SettingsPage.allCases) { page in
                    Button { model.page = page } label: {
                        Label(page.rawValue, systemImage: page.symbol)
                            .font(.system(size: 13, weight: model.page == page ? .medium : .regular))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12).padding(.vertical, 10).contentShape(Rectangle())
                            .background(model.page == page ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).accessibilityAddTraits(model.page == page ? .isSelected : [])
                }
                Spacer()
                VStack(alignment: .leading, spacing: 5) {
                    Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")").font(.system(size: 11, weight: .medium))
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
                }.formStyle(.grouped).scrollContentBackground(.hidden).disabled(model.saving)
                Divider()
                HStack {
                    Text(model.settings == model.savedSettings ? (model.installed ? "Tjenesten arbejder også, når GUI’en er lukket" : "Installer brewau.pkg for at forbinde tjenesten") : "Tidsplanen gælder alle brewau-brugere på denne Mac")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    Spacer()
                    if model.settings != model.savedSettings {
                        Button("Annuller") { model.settings = model.savedSettings }.disabled(model.saving)
                        Button(model.saving ? "Gemmer…" : "Gem") { Task { await model.saveSettings() } }
                            .buttonStyle(.borderedProminent).disabled(model.saving || !model.installed)
                    }
                }.padding(.horizontal, 24).padding(.vertical, 14)
            }.frame(maxWidth: .infinity).background(Color(nsColor: .windowBackgroundColor))
        }.frame(width: 800, height: 620).tint(.blue)
            .onAppear { model.refreshLoginStatus() }
            .alert("Handlingen kunne ikke gennemføres", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
                Button("OK", role: .cancel) { model.error = nil }
                Button("Vis log") { model.showLog(); model.error = nil }
            } message: { Text(model.error ?? "") }
            .alert("Tillad tvungen genstart?", isPresented: Binding(get: { forceConfirmation != nil }, set: { if !$0 { forceConfirmation = nil } })) {
                Button("Annuller", role: .cancel) { forceConfirmation = nil }
                Button("Tillad", role: .destructive) {
                    if let app = forceConfirmation { model.setForceAllowed(app, true) }
                    forceConfirmation = nil
                }
            } message: { Text("\(forceConfirmation?.name ?? "Appen") må lukkes og åbnes automatisk efter en opdatering. Ugemt arbejde kan gå tabt.") }
    }
    private var general: some View {
        Group {
            Section {
                Toggle("Start brewau ved login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
                if model.loginApproval {
                    Button("Godkend i Systemindstillinger…") { SMAppService.openSystemSettingsLoginItems() }
                }
                LabeledContent("Visning", value: "Kun i menulinjen")
            } header: { Text("På din Mac") } footer: { Text("Hold GUI’en åben for notifikationer og automatisk genstart. Scanning og opdatering kører uafhængigt.") }
            Section("Overblik") {
                LabeledContent("Scanning", value: "Automatisk \(model.scanSummary)")
                LabeledContent("Opdateringer", value: model.savedSettings.summary)
                LabeledContent("Tilladt tvungen genstart", value: "\(model.apps.filter { model.forceIsAllowed($0) }.count) apps")
                Button("Vis opdateringslog") { model.showLog() }
            }
        }
    }
    private var schedule: some View {
        Group {
            Section {
                Picker("Scan efter opdateringer", selection: $model.settings.scanMinutes) {
                    Text("Hvert 15. minut").tag(15); Text("Hvert 30. minut").tag(30)
                    Text("Hver time").tag(60); Text("Hver 6. time").tag(360)
                    Text("Hver 12. time").tag(720); Text("Hver dag").tag(1440)
                }
            } header: { Text("Find opdateringer") } footer: { Text("Scanning finder nye versioner uden at installere dem.") }
            Section {
                Toggle("Opdater automatisk", isOn: $model.settings.autoUpgrade)
                if model.settings.autoUpgrade {
                    Picker("Gentag", selection: $model.settings.mode) {
                        Text("Interval").tag("interval"); Text("Dagligt").tag("daily"); Text("Ugentligt").tag("weekly")
                    }.pickerStyle(.segmented)
                    if model.settings.mode == "interval" {
                        Picker("Opdater", selection: $model.settings.intervalHours) {
                            ForEach([1, 2, 4, 6, 12, 24], id: \.self) { Text($0 == 1 ? "Hver time" : "Hver \($0). time").tag($0) }
                        }
                    } else {
                        if model.settings.mode == "weekly" {
                            Picker("Ugedag", selection: $model.settings.weekday) {
                                ForEach(Array(["Søndag", "Mandag", "Tirsdag", "Onsdag", "Torsdag", "Fredag", "Lørdag"].enumerated()), id: \.offset) { index, day in Text(day).tag(index + 1) }
                            }
                        }
                        ForEach(model.settings.minutes.indices, id: \.self) { index in
                            HStack {
                                DatePicker("Tidspunkt", selection: timeBinding(index), displayedComponents: .hourAndMinute)
                                    .environment(\.locale, Locale(identifier: "da_DK"))
                                Button { model.settings.minutes.remove(at: index) } label: { Image(systemName: "minus.circle") }
                                    .buttonStyle(.borderless).disabled(model.settings.minutes.count == 1)
                                    .accessibilityLabel("Fjern tidspunkt \(index + 1)")
                            }
                        }
                        Button("Tilføj tidspunkt", systemImage: "plus") {
                            if let next = stride(from: 0, to: 1440, by: 60).first(where: { !model.settings.minutes.contains($0) }) { model.settings.minutes.append(next) }
                        }.buttonStyle(.borderless).disabled(model.settings.minutes.count >= 24)
                    }
                }
            } header: { Text("Installer opdateringer") } footer: { Text("Tider følger din Macs tidszone. Missede kørsler indhentes efter vågeblus. Fejl forsøges igen ved næste planlagte kørsel.") }
            Section { Label(model.settings.summary, systemImage: "calendar.badge.clock").fontWeight(.medium) }
        }
    }
    private func timeBinding(_ index: Int) -> Binding<Date> {
        Binding(get: {
            let minute = model.settings.minutes.indices.contains(index) ? model.settings.minutes[index] : 0
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            guard model.settings.minutes.indices.contains(index) else { return }
            model.settings.minutes[index] = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
        })
    }
    private var restart: some View {
        Group {
            Section {
                Label("Spørg før apps lukkes", systemImage: "hand.raised").fontWeight(.medium)
                Text("Kørende apps vises som “Afventer genstart”, når en ny version er installeret.").font(.caption).foregroundStyle(.secondary)
            } header: { Text("Standardadfærd") }
            Section {
                if model.apps.isEmpty { Text("App-listen vises efter den første scanning.").foregroundStyle(.secondary) }
                ForEach(model.apps) { app in
                    Toggle(isOn: Binding(get: { model.forceIsAllowed(app) }, set: { allowed in
                        if allowed { forceConfirmation = app } else { model.setForceAllowed(app, false) }
                    })) {
                        HStack(spacing: 10) { AppIcon(path: app.path); Text(app.name) }
                    }.accessibilityLabel("Tillad tvungen genstart af \(app.name)")
                }
            } header: { Text("Tillad tvungen genstart") } footer: { Text("Kun valgte apps må lukkes og åbnes automatisk i din session. Ugemt arbejde kan gå tabt. Alle er slået fra som udgangspunkt.") }
        }
    }
    private var notifications: some View {
        Group {
            Section {
                Toggle("Tillad notifikationer", isOn: $model.notificationPreferences.enabled)
                LabeledContent("macOS", value: model.notificationStatus)
                if !model.notificationAllowed {
                    Button("Anmod om tilladelse…") { Task { await model.requestNotificationPermission() } }
                    Button("Åbn notifikationsindstillinger…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            Section("Giv mig besked") {
                Toggle("Nye opdateringer fundet", isOn: $model.notificationPreferences.available)
                Toggle("Opdateringer installeret", isOn: $model.notificationPreferences.complete)
                Toggle("En app skal genstartes", isOn: $model.notificationPreferences.restart)
                Toggle("En opdatering mislykkedes", isOn: $model.notificationPreferences.failure)
            }.disabled(!model.notificationPreferences.enabled)
            Section {
                Button("Send testnotifikation") { Task { await model.sendNotification(id: "test", title: "brewau", body: "Notifikationer virker. Du får besked efter dine valg.") } }
                    .disabled(!model.notificationAllowed || !model.notificationPreferences.enabled)
            }
        }
    }
    private var homebrew: some View {
        Group {
            Section {
                Toggle("Opdater Homebrew før scanning", isOn: $model.settings.updateHomebrew)
                Toggle("Medtag apps med egen auto-update", isOn: $model.settings.greedy)
            } header: { Text("Homebrew") } footer: { Text("Homebrew opdateres altid før installation af nye versioner.") }
            Section("Installation") {
                LabeledContent("Homebrew", value: model.homebrewVersion)
                LabeledContent("Arkitektur", value: "Apple Silicon (arm64)")
                LabeledContent("Tjeneste", value: model.installed ? "Installeret" : "Kræver ny brewau.pkg")
            }
            Section {
                Text("Root-ejede completions fjerner ejerskabsadvarsler og bevarer zshs sikkerhedstjek.").font(.caption).foregroundStyle(.secondary)
                Button(model.saving ? "Reparerer…" : "Reparer terminal-completions") { Task { await model.repairTerminal() } }.disabled(!model.installed || model.saving)
                if let status = model.repairStatus { Text(status).font(.caption) }
            } header: { Text("Terminal") } footer: { Text("Retter dine zsh-profiler og peger brew shellenv på brewau. Der gemmes en backup før ændringer.") }
        }
    }
}

