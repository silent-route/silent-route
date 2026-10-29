import SwiftUI
import VPNCore
import VPNRuntime

/// Edits one profile as a draft; nothing reaches the helper until Save.
struct ProfileEditor: View {
    let model: AppModel
    let saved: Profile
    @State private var draft: Profile
    @State private var section: Section = .routes
    @State private var saveError: String?

    enum Section: String, CaseIterable, Identifiable {
        case routes = "Routes", servers = "Servers", dns = "DNS", network = "Network"
        var id: Self { self }
    }

    init(model: AppModel, saved: Profile, section: Section = .routes) {
        self.model = model
        self.saved = saved
        _draft = State(initialValue: saved)
        _section = State(initialValue: section)
    }

    private var dirty: Bool { draft != saved }

    /// Server checks through the helper, which reaches servers the way the
    /// VPN does (directly); nil without a helper.
    private var helperCheck: (@Sendable (Tunnel) async throws -> Probe.Report)? {
        guard model.helper == .ready else { return nil }
        let model = self.model
        return { t in try await model.probe(t) }
    }
    private var isActive: Bool { saved.id == model.library.activeID }
    private var issues: [Validation.Issue] { Validation.check(draft) }
    /// Live state belongs to the profile that is running.
    private var running: Bool { isActive && model.status.phase == .connected && !model.otherUsersVPN }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if dirty || saveError != nil { changesNotice }
                    Group {
                        switch section {
                        case .routes: RoutesSection(profile: $draft, liveServers: running ? model.status.servers : [],
                                                    liveRoutes: running ? model.status.routes : [])
                        case .servers: ServersSection(check: helperCheck, profile: $draft, live: running ? model.status.servers : [])
                        case .dns: DNSSection(dns: $draft.dns)
                        case .network: NetworkSection(profile: $draft)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: saved) { old, new in
            // Changed elsewhere (menu bar, CLI): follow it unless mid-edit.
            if draft == old { draft = new }
        }
        .background {
            Button("") { Task { await save() } }.keyboardShortcut("s").hidden().disabled(!dirty || !canSave)
        }
        .toolbar {
            // Switching views of the main area: a segmented control in the
            // toolbar, centred (Apple's guidelines for macOS).
            // Save and Revert on the trailing side, Save prominent: Apple's
            // place for a key action (never a bar at the bottom, which a
            // window moved down can hide).
            if dirty {
                ToolbarItem(placement: .automatic) {
                    Button("Revert") { draft = saved; saveError = nil }
                        .help("Discard the unsaved changes")
                }
                ToolbarItem(placement: .automatic) {
                    Button("Save") { Task { await save() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.busy || !canSave)
                        .help(canSave ? "Save the changes (⌘S)" : "This profile is in use: fix the errors first")
                }
            }
            ToolbarItem(placement: .principal) {
                Picker("Section", selection: $section) {
                    ForEach(Section.allCases) { s in Text(s.rawValue).tag(s) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Routes, servers, DNS and network settings of this profile")
            }
        }
    }

    /// The profile's name as the page's title, where reading starts (top,
    /// leading), with its state underneath — like a list in Reminders.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                nameField
                HStack(spacing: 6) {
                    if isActive {
                        StatusDot(color: .green, size: 7)
                        Text("Active").foregroundStyle(.green)
                        Text("·").foregroundStyle(.tertiary)
                    }
                    Text("\(Plural.count(draft.tunnels.count, "server", "servers")) · \(Plural.count(draft.routes.count + 1, "route", "routes"))")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Spacer(minLength: 12)
            if !isActive {
                Button("Make Active") { Task { await model.activate(saved.id) } }
                    .disabled(model.busy || dirty)
                    .help(dirty ? "Save your changes first" : "Switch to this profile — right away if the VPN is on")
            }
        }
    }

    /// The default name ("New Profile 2") the profile has until it is given
    /// one of its own.
    private var defaultName: String {
        AppModel.isDefaultName(saved.name) ? saved.name : model.library.freeName(AppModel.defaultProfileName)
    }

    /// An explicit field. A default name shows as a dimmed placeholder, so it
    /// is clear that it is only a stand-in; an emptied field falls back to it.
    private var nameField: some View {
        let placeholder = defaultName
        let text = Binding(
            get: { draft.name == placeholder ? "" : draft.name },
            set: { new in
                draft.name = new.trimmingCharacters(in: .whitespaces).isEmpty ? placeholder : new
            })
        return TextField("Name", text: text, prompt: Text(placeholder))
            .textFieldStyle(.plain)
            .font(.largeTitle.weight(.bold))
            .frame(maxWidth: 480, alignment: .leading)
            .help("The profile’s name, as the menu bar and the list show it — click to rename")
    }

    private var errors: [Validation.Issue] { issues.filter { $0.severity == .error } }
    /// The running profile must stay valid; others may be saved half-done.
    private var mustBeValid: Bool { isActive && model.status.phase != .off }
    private var canSave: Bool { !(mustBeValid && !errors.isEmpty) }

    /// What is unsaved and what stops it from saving, at the top where it
    /// is read first.
    private var changesNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let saveError {
                Label(Text.sentence(saveError), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            ForEach(errors, id: \.self) { i in
                Label(Text.sentence(i.message), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if dirty {
                Text(canSave ? "Unsaved changes — Save is in the toolbar (⌘S)."
                             : "This profile is in use: it can only be saved without errors.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard(cornerRadius: 12)
    }

    private func save() async {
        saveError = await model.save(draft)
    }
}

// MARK: - Shared pieces

/// A titled group, the building block of every section.
struct Card<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle { Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentCard()
    }
}

// MARK: - DNS

struct DNSSection: View {
    @Binding var dns: DNSSettings
    @State private var direct = ""
    @State private var tunnel = ""
    @State private var suffixes = ""
    @State private var zones = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Servers", subtitle: "Names of sites that go direct are looked up on the direct server; everything else is resolved encrypted (DNS over HTTPS) through the same exit its traffic takes.") {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                    GridRow {
                        Text("Direct").foregroundStyle(.secondary)
                        TextField("223.5.5.5", text: $direct).frame(maxWidth: 220)
                    }
                    GridRow {
                        Text("Through the tunnel (DoH)").foregroundStyle(.secondary)
                        TextField("1.1.1.1", text: $tunnel).frame(maxWidth: 220)
                    }
                }
                .textFieldStyle(.roundedBorder)
                if IPNetwork(direct) == nil || IPNetwork(tunnel) == nil {
                    Text("Enter an IP address, e.g. 1.1.1.1").font(.caption).foregroundStyle(.red)
                }
            }
            Card(title: "Local Names via the Router",
                 subtitle: "While the VPN is on, every other name goes through Silent Route — the router is never asked. Names in these zones only the local network knows (a NAS, a printer, the router's own page), so they are asked of the router. One zone per line; empty: none. Applies while the local network is reachable directly (Network tab).") {
                TextEditor(text: $zones)
                    .font(.body.monospaced())
                    .frame(minHeight: 70)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
            }
            Card(title: "Always Resolved Directly", subtitle: "Domain zones, one per line: cn, lan, home.arpa…") {
                TextEditor(text: $suffixes)
                    .font(.body.monospaced())
                    .frame(minHeight: 90)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
            }
            Button("Restore Defaults") { dns = .default; load() }
        }
        .onAppear(perform: load)
        .onChange(of: direct) { apply() }
        .onChange(of: tunnel) { apply() }
        .onChange(of: suffixes) { apply() }
        .onChange(of: zones) { apply() }
    }

    private func load() {
        direct = dns.directServer.description.replacingOccurrences(of: "/32", with: "")
        tunnel = dns.tunnelServer.description.replacingOccurrences(of: "/32", with: "")
        suffixes = dns.directSuffixes.joined(separator: "\n")
        zones = dns.localZones.joined(separator: "\n")
    }

    private func apply() {
        if let d = IPNetwork(direct) { dns.directServer = d }
        if let t = IPNetwork(tunnel) { dns.tunnelServer = t }
        let list = suffixes.split(whereSeparator: \.isNewline).map { Validation.normalizeDomain(String($0)) }.filter { !$0.isEmpty }
        if list != dns.directSuffixes { dns.directSuffixes = list }
        let local = zones.split(whereSeparator: \.isNewline).map { Validation.normalizeDomain(String($0)) }.filter { !$0.isEmpty }
        if local != dns.localZones { dns.localZones = local }
    }
}

// MARK: - Network

struct NetworkSection: View {
    @Binding var profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Local Network", subtitle: "Printers, the router, AirDrop, a NAS, other computers at home or in the office.") {
                Picker("", selection: $profile.lan) {
                    Text("Reachable directly").tag(LANPolicy.allow)
                    Text("Like the rest of the internet — by this profile's rules").tag(LANPolicy.block)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Card(title: "Tunnel MTU",
                 subtitle: "The largest packet sent through the tunnel at once. Automatic suits almost every network; if sites load halfway and hang (a phone hotspot, some hotel or provider networks), try 1400 or 1280.") {
                MTUPicker(mtu: $profile.mtu)
            }
            Card(title: "Protection While Reconnecting",
                 subtitle: "The kill switch is set per route, in Routes. While the VPN itself restarts (a few seconds after a crash or a network change), everything outside the tunnel is blocked if any route through servers has its kill switch on.") {
                Label(profile.protectionMode == .off
                      ? "Off: no route through servers has a kill switch"
                      : "On: at least one route through servers has a kill switch",
                      systemImage: profile.protectionMode == .off ? "lock.open" : "lock.shield")
                    .foregroundStyle(profile.protectionMode == .off ? .orange : .green)
                Text("After a restart of the Mac the network is always clean: nothing is blocked and the VPN does not start by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// The common values in a menu, and any other in a field next to it
/// (`Custom…`), checked against `Profile.mtuRange`.
struct MTUPicker: View {
    @Binding var mtu: Int?
    @State private var custom = false
    @State private var text = ""

    static let presets = [1500, 1420, 1400, 1280]

    private enum Choice: Hashable {
        case automatic, value(Int), custom
    }

    private var choice: Binding<Choice> {
        Binding(
            get: {
                if custom { return .custom }
                guard let m = mtu else { return .automatic }
                return Self.presets.contains(m) ? .value(m) : .custom
            },
            set: { new in
                switch new {
                case .automatic: custom = false; mtu = nil
                case .value(let v): custom = false; mtu = v
                case .custom:
                    custom = true
                    text = mtu.map(String.init) ?? ""
                }
            })
    }

    private var valid: Bool { Int(text).map(Profile.mtuRange.contains) ?? false }

    var body: some View {
        HStack(spacing: 10) {
            Picker("", selection: choice) {
                Text("Automatic").tag(Choice.automatic)
                Divider()
                ForEach(Self.presets, id: \.self) { Text(String($0)).tag(Choice.value($0)) }
                Divider()
                Text("Custom…").tag(Choice.custom)
            }
            .labelsHidden()
            .fixedSize()
            if choice.wrappedValue == .custom {
                TextField("", text: $text, prompt: Text("1280–9000"))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .onChange(of: text) { _, t in
                        if let v = Int(t), Profile.mtuRange.contains(v) { mtu = v }
                    }
                if !text.isEmpty, !valid {
                    Text("Enter a number from \(Profile.mtuRange.lowerBound) to \(Profile.mtuRange.upperBound)")
                        .font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onAppear {
            if let m = mtu, !Self.presets.contains(m) { custom = true; text = String(m) }
        }
    }
}
