import SwiftUI
import VPNCore
import VPNRuntime

/// Edits one profile. Its unsaved changes are a draft the model keeps
/// (Drafts.swift): leaving the page keeps them, and nothing reaches the
/// helper until Save.
struct ProfileEditor: View {
    let model: AppModel
    let saved: Profile
    /// The page shown: the window's, so that switching to another profile
    /// stays on the same page (DNS stays DNS).
    @Binding var section: Section

    enum Section: String, CaseIterable, Identifiable {
        case routes = "Routes", servers = "Servers", dns = "DNS", network = "Network"
        var id: Self { self }
    }

    init(model: AppModel, saved: Profile, section: Binding<Section>) {
        self.model = model
        self.saved = saved
        _section = section
    }

    /// On a page of its own (snapshots).
    init(model: AppModel, saved: Profile, section: Section = .routes) {
        self.init(model: model, saved: saved, section: .constant(section))
    }

    /// The profile with its unsaved changes; editing it changes the draft.
    private var draft: Binding<Profile> {
        let model = self.model
        let saved = self.saved
        return Binding(get: { model.drafts[saved.id] ?? saved }, set: { model.edit($0) })
    }
    private var current: Profile { draft.wrappedValue }
    private var dirty: Bool { model.hasUnsavedChanges(saved.id) }
    private var saveError: String? { model.saveErrors[saved.id] }

    /// Server checks through the helper, which reaches servers the way the
    /// VPN does (directly); nil without a helper.
    private var helperCheck: ServerChecks.Check? {
        guard model.helper == .ready else { return nil }
        let model = self.model
        return { t in try await model.probe(t) }
    }
    /// The profile's lists, as the helper keeps them; nil without a helper.
    private var helperLists: RuleListsCard.Lookup? {
        guard model.helper == .ready else { return nil }
        let model = self.model
        return { urls, update in try await model.ruleLists(urls, update: update) }
    }
    private var isActive: Bool { saved.id == model.library.activeID }
    private var issues: [Validation.Issue] { Validation.check(current, listsWithAddresses: listsWithAddresses) }
    /// The profile's lists that hold networks, as the helper has them.
    @State private var listsWithAddresses: Set<String> = []
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
                        case .routes: RoutesSection(profile: draft, liveServers: running ? model.status.servers : [],
                                                    liveRoutes: running ? model.status.routes : [],
                                                    listsWithAddresses: listsWithAddresses)
                        case .servers: ServersSection(checks: model.serverChecks, check: helperCheck, profile: draft,
                                                      live: running ? model.status.servers : [],
                                                      library: model.helper == .ready ? model.library.servers : nil,
                                                      addToLibrary: model.helper == .ready ? { model.addToLibrary($0) } : nil)
                        case .dns: DNSSection(dns: draft.dns)
                        case .network: NetworkSection(profile: draft, lists: helperLists)
                        }
                    }
                }
                // The width of the window, as in System Settings and Mail:
                // a page never sits in a narrow column in a wide window.
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // Which lists hold networks (for the routes' notes): as the helper
        // has them; a list not downloaded yet counts once it is.
        .task(id: current.lists.map(\.url)) {
            guard let lookup = helperLists else { listsWithAddresses = []; return }
            let infos = (try? await lookup(current.lists.map(\.url), false)) ?? []
            listsWithAddresses = Set(infos.filter { $0.hasAddresses == true }.map(\.url))
        }
        .toolbar {
            // Switching views of the main area: a segmented control in the
            // toolbar, centred (Apple's guidelines for macOS). Save and
            // Revert are the window's (MainWindow), at its trailing end.
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
                    Text("\(Plural.count(current.tunnels.count, "server", "servers")) · \(Plural.count(current.routes.count + 1, "route", "routes"))")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            Spacer(minLength: 12)
            if !isActive {
                // With unsaved changes, asks to save or discard them first.
                Button("Make Active") { Task { await model.activate(saved.id) } }
                    .disabled(model.busy)
                    .help("Switch to this profile — right away if the VPN is on")
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
        let draft = self.draft
        let text = Binding(
            get: { draft.wrappedValue.name == placeholder ? "" : draft.wrappedValue.name },
            set: { new in
                draft.wrappedValue.name = new.trimmingCharacters(in: .whitespaces).isEmpty ? placeholder : new
            })
        return TextField("Name", text: text, prompt: Text(placeholder))
            .textFieldStyle(.plain)
            .font(.largeTitle.weight(.bold))
            .frame(maxWidth: 480, alignment: .leading)
            .help("The profile’s name, as the menu bar and the list show it — click to rename")
    }

    private var errors: [Validation.Issue] { issues.filter { $0.severity == .error } }

    /// What is unsaved and what stops it from saving, at the top where it
    /// is read first.
    private var changesNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            if dirty {
                Label("Unsaved Changes", systemImage: "pencil.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.tint)
                Text(model.saveBlocked(saved.id)
                     ? "This profile is in use: it can only be saved without errors."
                     : "Save them with Save at the top right\(ShortcutAction.saveProfile.shortcut.map { " or \($0.symbols)" } ?? ""). They stay while you look at other pages; the VPN uses the profile once it is saved.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let saveError {
                Label(Text.sentence(saveError), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            ForEach(errors, id: \.self) { i in
                Label(Text.sentence(i.message), systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dirty ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 12))
        .contentCard(cornerRadius: 12)
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
        // Changed from outside the fields (Revert): show it.
        .onChange(of: dns) { _, new in if applied(to: new) != new { load() } }
    }

    private func load() {
        direct = dns.directServer.description.replacingOccurrences(of: "/32", with: "")
        tunnel = dns.tunnelServer.description.replacingOccurrences(of: "/32", with: "")
        suffixes = dns.directSuffixes.joined(separator: "\n")
        zones = dns.localZones.joined(separator: "\n")
    }

    private func apply() {
        let d = applied(to: dns)
        if d != dns { dns = d }
    }

    /// The settings with what the fields say; a field that is not valid
    /// yet leaves its setting as it is.
    private func applied(to base: DNSSettings) -> DNSSettings {
        var d = base
        if let s = IPNetwork(direct) { d.directServer = s }
        if let s = IPNetwork(tunnel) { d.tunnelServer = s }
        d.directSuffixes = suffixes.split(whereSeparator: \.isNewline).map { Validation.normalizeDomain(String($0)) }.filter { !$0.isEmpty }
        d.localZones = zones.split(whereSeparator: \.isNewline).map { Validation.normalizeDomain(String($0)) }.filter { !$0.isEmpty }
        return d
    }
}

// MARK: - Network

struct NetworkSection: View {
    @Binding var profile: Profile
    var lists: RuleListsCard.Lookup? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            RuleListsCard(profile: $profile, lookup: lists)
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
        // Changed from outside (Revert), or by the field: the menu follows.
        .onChange(of: mtu) { _, m in
            if let m, !Self.presets.contains(m) {
                custom = true
                if Int(text) != m { text = String(m) }
            } else if !(custom && Int(text) == m) {
                custom = false
            }
        }
    }
}

/// The profile's lists of sites or addresses: added by their web
/// address, kept up to date by the helper.
struct RuleListsCard: View {
    typealias Lookup = @Sendable ([String], Bool) async throws -> [RuleListInfo]
    @Binding var profile: Profile
    let lookup: Lookup?
    @State private var infos: [RuleListInfo] = []
    @State private var updating = false
    @State private var failure: String?
    @State private var editing: EditRequest?

    struct EditRequest: Identifiable {
        var id = UUID()
        var list: RuleList?
    }

    var body: some View {
        Card(title: "Lists",
             subtitle: "Lists of sites or addresses that someone keeps up to date, added by their web address: a sing-box rule-set (.srs or .json) or plain text, one site or address per line. Use one in a route as list:name. Checked for a new version every day; a VPN that is on picks it up without reconnecting.") {
            if !profile.lists.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(profile.lists.enumerated()), id: \.element.id) { i, l in
                        row(l, infos.first { $0.url == l.url })
                        if i < profile.lists.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            }
            HStack(spacing: 10) {
                Button { editing = EditRequest() } label: { Label("Add List…", systemImage: "plus") }
                if !profile.lists.isEmpty {
                    Button("Update Now") { Task { await load(update: true) } }
                        .disabled(lookup == nil || updating)
                        .help("Download the latest version of each list now")
                }
                if updating { ProgressView().controlSize(.small) }
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .task(id: profile.lists.map(\.url)) { await load(update: false) }
        .sheet(item: $editing) { req in
            RuleListEditor(list: req.list, taken: Set(profile.lists.map(\.name)).subtracting([req.list?.name].compactMap { $0 })) { result in
                if let result { save(result, replacing: req.list) }
                editing = nil
            }
        }
    }

    private func row(_ l: RuleList, _ info: RuleListInfo?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("list:" + l.name).font(.body.monospaced())
                Text(l.url).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 1) {
                if let updated = info?.updated {
                    Text(Self.updated(updated, bytes: info?.bytes)).foregroundStyle(.secondary)
                } else if info?.error == nil {
                    Text("Downloaded when saved").foregroundStyle(.secondary)
                }
                if let e = info?.error {
                    Text(Text.sentence(e)).foregroundStyle(info?.updated == nil ? .red : .orange)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)
            Menu {
                Button("Edit…") { editing = EditRequest(list: l) }
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(l.url, forType: .string)
                }
                Divider()
                Button("Delete", role: .destructive) { profile.lists.removeAll { $0.name == l.name } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = EditRequest(list: l) }
    }

    /// "Updated 3 hours ago · 52 KB".
    static func updated(_ date: Date, bytes: Int?) -> String {
        var s = "Updated " + date.formatted(.relative(presentation: .named))
        if let bytes { s += " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
        return s
    }

    /// A renamed list is renamed in the routes too.
    private func save(_ l: RuleList, replacing old: RuleList?) {
        guard let old, let i = profile.lists.firstIndex(of: old) else { profile.lists.append(l); return }
        profile.lists[i] = l
        guard old.name != l.name else { return }
        for r in profile.routes.indices {
            profile.routes[r].conditions.destinations = profile.routes[r].conditions.destinations.map {
                $0 == .list(old.name) ? .list(l.name) : $0
            }
        }
    }

    private func load(update: Bool) async {
        let urls = profile.lists.map(\.url).filter(RuleLists.isValidURL)
        guard let lookup, !urls.isEmpty else { infos = []; return }
        if update { updating = true }
        defer { if update { updating = false } }
        do {
            infos = try await lookup(urls, update)
            failure = nil
        } catch {
            failure = Text.sentence("\(error)")
        }
    }
}

/// One list: its name in routes, and where it is published.
struct RuleListEditor: View {
    let list: RuleList?
    let taken: Set<String>
    let done: (RuleList?) -> Void
    @State private var name: String
    @State private var url: String

    init(list: RuleList?, taken: Set<String>, done: @escaping (RuleList?) -> Void) {
        self.list = list
        self.taken = taken
        self.done = done
        _name = State(initialValue: list?.name ?? "")
        _url = State(initialValue: list?.url ?? "")
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespaces).lowercased() }
    private var cleanURL: String { url.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var problem: String? {
        if cleanName.isEmpty || cleanURL.isEmpty { return nil }
        if !RuleLists.isValidName(cleanName) { return "A name is letters, digits and “-”, like blocked-sites" }
        if taken.contains(cleanName) { return "Another list has this name" }
        if !RuleLists.isValidURL(cleanURL) { return "Enter an https:// address" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(list == nil ? "Add List" : "Edit List").font(.title3.weight(.semibold))
            Form {
                TextField("Name", text: $name, prompt: Text("blocked-sites"))
                TextField("Address", text: $url, prompt: Text("https://…"))
            }
            Text("In routes: list:\(cleanName.isEmpty ? "name" : cleanName)")
                .font(.caption.monospaced()).foregroundStyle(.secondary)
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(list == nil ? "Add" : "Done") { done(RuleList(name: cleanName, url: cleanURL)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(cleanName.isEmpty || cleanURL.isEmpty || problem != nil)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
