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
    private let updater = Updater.shared

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(Preferences.Appearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, a in Preferences.applyAppearance(a) }
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in setLogin(on) }
                Text("Silent Route appears in the menu bar. The VPN does not turn on by itself — only you turn it on.")
                    .font(.caption).foregroundStyle(.secondary)
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
            Section("Notifications") {
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
            updatesSection
            Section("Helper") {
                LabeledContent("Helper version", value: model.helperVersion ?? "—")
                LabeledContent("App build", value: AppModel.appVersion ?? "—")
                if model.helperOutdated {
                    Button("Update Helper…") { Task { await model.installHelper() } }.disabled(model.busy)
                }
            }
            Section("About") {
                Text("Silent Route is free software under the GNU GPL v3. It runs sing-box (GPL-3.0-or-later, by nekohasekai and contributors), an independent project that is not affiliated with Silent Route. Address and site lists are downloaded on first use from the sing-box project’s public rule-sets.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let page = updater.releasesPage {
                    Link("Releases and source code", destination: page).font(.callout)
                }
            }
            Section {
                Button("Uninstall Silent Route…", role: .destructive) { confirmUninstall = true }
                    .foregroundStyle(.red)
                    .disabled(model.busy)
                Text("Removes everything: the helper, profiles, logs, settings and the app itself. macOS asks for an administrator password. Without the app: run “Uninstall Silent Route.command” in /Library/Application Support/Silent Route.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $confirmUninstall) { uninstallSheet }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    @ViewBuilder
    private var updatesSection: some View {
        Section("Updates") {
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
                        Button("Install and Relaunch") { Task { await updater.install() } }
                            .buttonStyle(.borderedProminent)
                    } else {
                        Button("Check Now") { Task { await updater.check() } }
                            .disabled(updater.state == .checking)
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
            Text("The VPN turns off, all blocking is lifted and the network goes back to normal. The helper, all profiles (exits and rules), logs and settings are deleted, and the app moves to the Trash.")
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Keep a copy of the profiles in /Users/Shared/Silent Route profiles", isOn: $keepProfiles)
            HStack {
                Spacer()
                Button("Cancel") { confirmUninstall = false }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) {
                    confirmUninstall = false
                    Task { await model.uninstallEverything(keepProfiles: keepProfiles) }
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
