import SwiftUI
import VPNCore

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
    private var isActive: Bool { saved.id == model.library.activeID }
    private var issues: [Validation.Issue] { Validation.check(draft) }
    /// Live state belongs to the profile that is running.
    private var running: Bool { isActive && model.status.phase == .connected && !model.otherUsersVPN }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 12)
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
            Divider()
            ScrollView {
                Group {
                    switch section {
                    case .routes: RoutesSection(profile: $draft, liveServers: running ? model.status.servers : [],
                                                liveRoutes: running ? model.status.routes : [])
                    case .servers: ServersSection(profile: $draft, live: running ? model.status.servers : [])
                    case .dns: DNSSection(dns: $draft.dns)
                    case .network: NetworkSection(profile: $draft)
                    }
                }
                .padding(20)
                .frame(maxWidth: 780, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            if dirty || saveError != nil { saveBar }
        }
        .onChange(of: saved) { old, new in
            // Changed elsewhere (menu bar, CLI): follow it unless mid-edit.
            if draft == old { draft = new }
        }
        .background {
            Button("") { Task { await save() } }.keyboardShortcut("s").hidden().disabled(!dirty)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            nameField
            Spacer(minLength: 12)
            if isActive {
                Label("Active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            } else {
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
        return HStack(spacing: 8) {
            Text("Name").foregroundStyle(.secondary)
            TextField("Name", text: text, prompt: Text(placeholder))
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .frame(maxWidth: 340)
                .help("The profile’s name, as the menu bar and the list show it")
        }
    }

    private var saveBar: some View {
        let errors = issues.filter { $0.severity == .error }
        let mustBeValid = isActive && model.status.phase != .off
        return VStack(alignment: .leading, spacing: 8) {
            if let saveError {
                Label(Text.sentence(saveError), systemImage: "xmark.octagon.fill").foregroundStyle(.red).font(.callout)
            }
            ForEach(errors, id: \.self) { i in
                Label(Text.sentence(i.message), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
            }
            HStack {
                Text(mustBeValid && !errors.isEmpty
                     ? "This profile is in use: it can only be saved without errors"
                     : "Unsaved changes")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { draft = saved; saveError = nil }
                Button("Save") { Task { await save() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.busy || (mustBeValid && !errors.isEmpty))
            }
        }
        .padding(12)
        .glassCard(cornerRadius: 14)
        .padding(12)
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
        .glassCard(cornerRadius: 14)
    }
}

// MARK: - DNS

struct DNSSection: View {
    @Binding var dns: DNSSettings
    @State private var direct = ""
    @State private var tunnel = ""
    @State private var suffixes = ""

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
            Card(title: "Always resolved directly", subtitle: "Domain zones, one per line: cn, lan, home.arpa…") {
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
    }

    private func load() {
        direct = dns.directServer.description.replacingOccurrences(of: "/32", with: "")
        tunnel = dns.tunnelServer.description.replacingOccurrences(of: "/32", with: "")
        suffixes = dns.directSuffixes.joined(separator: "\n")
    }

    private func apply() {
        if let d = IPNetwork(direct) { dns.directServer = d }
        if let t = IPNetwork(tunnel) { dns.tunnelServer = t }
        let list = suffixes.split(whereSeparator: \.isNewline).map { Validation.normalizeDomain(String($0)) }.filter { !$0.isEmpty }
        if list != dns.directSuffixes { dns.directSuffixes = list }
    }
}

// MARK: - Network

struct NetworkSection: View {
    @Binding var profile: Profile

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Card(title: "Local network", subtitle: "Printers, the router, AirDrop, a NAS, other computers at home or in the office.") {
                Picker("", selection: $profile.lan) {
                    Text("Reachable directly").tag(LANPolicy.allow)
                    Text("Like the rest of the internet — by this profile's rules").tag(LANPolicy.block)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Card(title: "Tunnel MTU",
                 subtitle: "The largest packet sent through the tunnel at once. Automatic suits almost every network; if sites load halfway and hang (a phone hotspot, some hotel or provider networks), try 1400 or 1280.") {
                Picker("", selection: $profile.mtu) {
                    Text("Automatic").tag(Int?.none)
                    ForEach([1500, 1420, 1400, 1280], id: \.self) { Text(String($0)).tag(Int?.some($0)) }
                    if let m = profile.mtu, ![1500, 1420, 1400, 1280].contains(m) {
                        Text("Custom: \(String(m))").tag(Int?.some(m))
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            Card(title: "Protection while reconnecting",
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
