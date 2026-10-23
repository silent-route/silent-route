import ServiceManagement
import SwiftUI

/// App settings (⌘,). Profiles hold everything about the network; this is
/// only about the app itself.
public struct SettingsView: View {
    let model: AppModel
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmUninstall = false
    @State private var keepProfiles = true
    @AppStorage(Preferences.appearanceKey) private var appearance = Preferences.Appearance.system
    @AppStorage(Preferences.quitKey) private var quit = Preferences.Quit.disconnect
    @AppStorage(Preferences.checkUpdatesKey) private var checkUpdates = true
    @AppStorage(Preferences.notificationsKey) private var notifications = Preferences.Notifications.routes
    @AppStorage(Preferences.sessionCounterKey) private var sessionCounter = Preferences.SessionCounter.connection
    @AppStorage(Preferences.logsInBackupsKey) private var logsInBackups = false
    @AppStorage(Preferences.transparencyKey) private var transparency = Preferences.Transparency.standard
    @AppStorage(Preferences.logsIndexedKey) private var logsIndexed = false
    @State private var deleteLogs = true
    private let updater = Updater.shared

    public init(model: AppModel) { self.model = model }

    @State private var pane: Pane = .general

    /// The sections of the sidebar.
    enum Pane: String, CaseIterable, Identifiable {
        case general, notifications, updates, advanced
        var id: Self { self }
        var title: String {
            switch self {
            case .general: "General"
            case .notifications: "Notifications"
            case .updates: "Updates"
            case .advanced: "Advanced"
            }
        }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .notifications: "bell"
            case .updates: "arrow.down.circle"
            case .advanced: "wrench.and.screwdriver"
            }
        }
    }

    public var body: some View {
        // A sidebar of sections and the chosen one on the right — the
        // layout of System Settings.
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch pane {
                case .general: general
                case .notifications: notificationsTab
                case .updates: updatesTab
                case .advanced: advanced
                }
            }
            .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 470)
        .sheet(isPresented: $confirmUninstall) { uninstallSheet }
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    /// One section's page: a grouped form that scrolls when it has to.
    private func page<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        Form { content() }
            .formStyle(.grouped)
    }

    private var general: some View {
        page {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Preferences.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, a in Preferences.applyAppearance(a) }
                Picker("Transparency", selection: $transparency) {
                    Text("Standard").tag(Preferences.Transparency.standard)
                    Text("More").tag(Preferences.Transparency.more)
                }
                .pickerStyle(.segmented)
                Text("How see-through the glass panels are. “More” can make text harder to read on a busy background. If everything looks opaque, check System Settings › Accessibility › Display › Reduce transparency.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLogin(on) }
                Text("Silent Route appears in the menu bar. The VPN does not turn on by itself — only you turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Connection time and traffic") {
                Picker("Connection time and traffic", selection: $sessionCounter) {
                    Text("Start again after a reconnect").tag(Preferences.SessionCounter.connection)
                    Text("Count from turning the VPN on").tag(Preferences.SessionCounter.session)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(sessionCounter == .connection
                     ? "The time and the traffic shown in the menu bar and the window count the current connection."
                     : "The time and the traffic count the whole session, across reconnects and profile switches, until you turn the VPN off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("When Silent Route quits") {
                Picker("When Silent Route quits", selection: $quit) {
                    Text("Turn the VPN off").tag(Preferences.Quit.disconnect)
                    Text("Keep the VPN running").tag(Preferences.Quit.keepRunning)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(quit == .disconnect
                     ? "Quitting asks first, then turns the VPN off and leaves the network as it was. Closing the window does not quit."
                     : "The VPN keeps running in the background without the app. Open Silent Route again to see it or turn it off.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notificationsTab: some View {
        page {
            Section("Notify about") {
                Picker("Notify about", selection: $notifications) {
                    Text("Route changes only").tag(Preferences.Notifications.routes)
                    Text("All events").tag(Preferences.Notifications.all)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Text(notifications == .routes
                     ? "When a route switches to a backup server, goes direct, is blocked, or comes back."
                     : "Route changes, plus connecting, disconnecting and losing the connection.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button("Open Notification Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Text("Whether banners appear and make a sound is set in System Settings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var updatesTab: some View {
        page { updatesSection }
    }

    private var advanced: some View {
        page {
            Section("Helper") {
                LabeledContent("Helper version", value: model.helperVersion ?? "—")
                LabeledContent("App build", value: AppModel.appVersion ?? "—")
                if model.helperOutdated {
                    Button("Update Helper…") { Task { await model.installHelper() } }.disabled(model.busy)
                }
            }
            Section("Session logs") {
                Toggle("Include logs in Time Machine backups", isOn: $logsInBackups)
                    .onChange(of: logsInBackups) { _, _ in Preferences.applyLogFolderSettings() }
                Toggle("Let Spotlight index logs", isOn: $logsIndexed)
                    .onChange(of: logsIndexed) { _, _ in Preferences.applyLogFolderSettings() }
                Text("Logs are kept in ~/Library/Logs/Silent Route, readable only by you. They can name the sites you open and your servers, so by default they are left out of backups and out of Spotlight search.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button("Uninstall Silent Route…", role: .destructive) { confirmUninstall = true }
                    .foregroundStyle(.red)
                    .disabled(model.busy)
                Text("Removes everything: the helper, profiles, logs, settings and the app itself. macOS asks for an administrator password. Without the app: run “Uninstall Silent Route.command” in /Library/Application Support/Silent Route.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("About") {
                Text("Silent Route is free software under the GNU GPL v3. It runs sing-box (GPL-3.0-or-later, by nekohasekai and contributors), an independent project that is not affiliated with Silent Route. Address and site lists are downloaded on first use from the sing-box project’s public rule-sets.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let page = updater.releasesPage {
                    Link("Releases and source code", destination: page).font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section {
            LabeledContent("Version", value: updater.currentVersion)
            if updater.repository == nil {
                Text("This build has no update source. Download new versions from the project’s Releases page.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Toggle("Check for updates automatically", isOn: $checkUpdates)
                HStack {
                    switch updater.state {
                    case .idle: EmptyView()
                    case .checking: ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary)
                    case .upToDate: Label("Silent Route is up to date", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    case .available(let r): Label("Version \(r.version) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(.blue)
                    case .installing(let step): ProgressView().controlSize(.small); Text(step).foregroundStyle(.secondary)
                    case .failed(let why): Text(why).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if let r = updater.available {
                        Link("What’s New", destination: r.page)
                    }
                    // Always there: a result found earlier may be out of date.
                    Button("Check Now") { Task { await updater.check() } }
                        .disabled(updater.state == .checking || { if case .installing = updater.state { true } else { false } }())
                    if updater.available != nil {
                        Button("Install and Relaunch") { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .font(.callout)
                Text("Updates come from the project’s GitHub releases. Profiles are kept; the helper is updated after the relaunch (macOS asks for an administrator password).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var uninstallSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Uninstall Silent Route?", systemImage: "trash").font(.title3.weight(.semibold))
            Text("The VPN turns off, all blocking is lifted and the network goes back to normal. The helper, all profiles (servers and routes) and settings are deleted, and the app moves to the Trash.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Keep a copy of each user's profiles in their home folder", isOn: $keepProfiles)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Delete session logs", isOn: $deleteLogs)
                Text("The logs in ~/Library/Logs/Silent Route of every user of this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
            HStack {
                Spacer()
                Button("Cancel") { confirmUninstall = false }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) {
                    confirmUninstall = false
                    Task { await model.uninstallEverything(keepProfiles: keepProfiles, keepLogs: !deleteLogs) }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func setLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
