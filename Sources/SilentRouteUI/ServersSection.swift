import SwiftUI
import VPNCore
import VPNRuntime

/// The servers of a profile — tunnels and proxies. Only how to connect;
/// where traffic goes is decided by the routes. Servers can also come from
/// the library, and go to it.
struct ServersSection: View {
    var check: (@Sendable (Tunnel) async throws -> Probe.Report)? = nil
    @Binding var profile: Profile
    /// Live health, only for the running profile.
    let live: [ServerState]
    /// The server library, to add from; nil without a helper.
    var library: [Tunnel]? = nil
    var addToLibrary: ((Tunnel) -> Void)? = nil

    var body: some View {
        ServerList(title: "Servers",
                   subtitle: "Tunnels and proxies this profile can use. Routes decide which traffic goes through which of them.",
                   servers: $profile.tunnels, check: check, live: live,
                   detail: { t in
                       let usedBy = profile.allRoutes.filter { $0.servers.contains(t.id) }.map(\.name)
                       return usedBy.isEmpty ? "not used by any route" : "used by \(usedBy.joined(separator: ", "))"
                   },
                   issues: { t in Validation.check(profile).filter { $0.tunnel == t.id } },
                   remove: remove,
                   addItems: {
                       if let library {
                           Divider()
                           Menu("From Library") {
                               ForEach(library) { t in
                                   Button("\(t.name) — \(t.proto.displayName)") { profile.tunnels.append(ServerCopy.copy(t, among: profile.tunnels)) }
                               }
                           }
                           .disabled(library.isEmpty)
                       }
                   },
                   rowItems: { t in
                       if let addToLibrary { Button("Add to Library") { addToLibrary(t) } }
                   })
    }

    private func remove(_ t: Tunnel) {
        let id = t.id
        profile.tunnels.removeAll { $0.id == id }
        // Taken out of every route's list; a route left with no server goes
        // direct rather than vanish, and shows that in its card.
        func drop(_ r: inout Route) {
            guard case .servers(let ids) = r.target else { return }
            let rest = ids.filter { $0 != id }
            r.target = rest.isEmpty ? .direct : .servers(rest)
        }
        for i in profile.routes.indices { drop(&profile.routes[i]) }
        drop(&profile.defaultRoute)
    }
}

/// Servers moving between lists (the library and profiles).
enum ServerCopy {
    /// A server from elsewhere (the library, another list), as a new one
    /// here: its own id, and a name not taken yet.
    static func copy(_ t: Tunnel, among others: [Tunnel]) -> Tunnel {
        var t = t
        t.id = UUID()
        t.name = freeName(t.name, among: others)
        return t
    }

    static func freeName(_ name: String, among others: [Tunnel]) -> String {
        guard others.contains(where: { $0.name == name }) else { return name }
        var n = 2
        while others.contains(where: { $0.name == "\(name) \(n)" }) { n += 1 }
        return "\(name) \(n)"
    }
}

/// A list of servers with its title and Add menu: check, edit (also by a
/// double-click), copy the link, delete. A profile's servers and the
/// library's are this list.
struct ServerList<AddItems: View, RowItems: View>: View {
    let title: String
    let subtitle: String
    @Binding var servers: [Tunnel]
    /// The helper's check (direct, past the tunnel and the kill switch),
    /// when it is there; otherwise a local sing-box.
    var check: (@Sendable (Tunnel) async throws -> Probe.Report)?
    var live: [ServerState] = []
    /// What else to say about a server, after its address.
    var detail: (Tunnel) -> String? = { _ in nil }
    var issues: (Tunnel) -> [Validation.Issue]
    var remove: ((Tunnel) -> Void)? = nil
    @ViewBuilder var addItems: () -> AddItems
    @ViewBuilder var rowItems: (Tunnel) -> RowItems
    @State private var editing: EditRequest?
    @State private var probes: [Tunnel.ID: ProbeState] = [:]

    struct EditRequest: Identifiable {
        var id = UUID()
        var draft: ServerDraft
        var isNew: Bool
    }

    enum ProbeState: Equatable {
        case running
        case ok(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Menu {
                    Button("Tunnel…") { editing = EditRequest(draft: ServerDraft(kind: .tunnel), isNew: true) }
                    Button("Proxy…") { editing = EditRequest(draft: ServerDraft(kind: .proxy), isNew: true) }
                    addItems()
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .fixedSize()
            }

            if servers.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "server.rack").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("No Servers Yet").font(.headline)
                    Text("Add a tunnel or a proxy — by its link or field by field.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(30)
                .contentCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(servers) { t in
                        row(t)
                        if t.id != servers.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .contentCard()
            }
        }
        .sheet(item: $editing) { req in
            AddServerSheet(draft: req.draft, isNew: req.isNew, profile: Profile(name: title, tunnels: servers)) { result in
                if let t = result { save(t) }
                editing = nil
            }
        }
    }

    private func row(_ t: Tunnel) -> some View {
        let health = live.first { $0.id == t.id }
        let edit = { editing = EditRequest(draft: ServerDraft(t), isNew: false) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: t.kindSymbol).font(.title3).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(t.name).fontWeight(.medium).lineLimit(1)
                        if let health {
                            StatusDot(color: health.latencyMs != nil ? .green : .red, size: 7)
                            Text(health.latencyMs.map { "\($0) ms" } ?? "not answering")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(health.latencyMs != nil ? Color.secondary : Color.red)
                        }
                    }
                    Text(["\(t.proto.displayName) · \(t.address)", detail(t)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button { probe(t) } label: {
                    if probes[t.id] == .running { ProgressView().controlSize(.small) } else { Text("Check") }
                }
                .controlSize(.small)
                .disabled(probes[t.id] == .running)
                .help("Connect to this server on its own and see where traffic comes out. The current connection is not touched.")
                Menu {
                    Button("Edit…", action: edit)
                    if case .link(let l) = t.origin {
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(l, forType: .string)
                        }
                    }
                    rowItems(t)
                    Divider()
                    Button("Delete", role: .destructive) {
                        if let remove { remove(t) } else { servers.removeAll { $0.id == t.id } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
            }
            Group {
                switch probes[t.id] {
                case .ok(let text)?: Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .failed(let text)?: Label(text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                default: EmptyView()
                }
            }
            .font(.caption)
            .padding(.leading, 32)
            ForEach(issues(t), id: \.self) { i in
                Label(Text.sentence(i.message.replacingOccurrences(of: "server \"\(t.name)\": ", with: "")),
                      systemImage: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(i.severity == .error ? .red : .orange)
                    .padding(.leading, 32)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        // As a route's card: a double-click edits.
        .onTapGesture(count: 2, perform: edit)
        .contextMenu { Button("Edit…", action: edit) }
    }

    private func save(_ t: Tunnel) {
        if let i = servers.firstIndex(where: { $0.id == t.id }) {
            servers[i] = t
            return
        }
        var t = t
        t.name = ServerCopy.freeName(t.name, among: servers)
        servers.append(t)
    }

    private func probe(_ t: Tunnel) {
        probes[t.id] = .running
        Task {
            let result: ProbeState
            if let check = check ?? SingBoxLocator.path.map({ sb in { t in try await Probe.run(t, singBox: sb) } }) {
                do {
                    let r = try await check(t)
                    var text = "Exit: \([r.city, r.country].compactMap { $0 }.joined(separator: ", ")) · \(r.ip) · \(r.latencyMs) ms"
                    if !r.warnings.isEmpty { text += " · " + r.warnings.joined(separator: "; ") }
                    result = .ok(text)
                } catch {
                    result = .failed(Text.sentence("\(error)"))
                }
            } else {
                result = .failed("sing-box not found — install the helper first")
            }
            probes[t.id] = result
        }
    }
}

/// sing-box for probes: the installed, root-owned copy, else the one in the
/// app bundle for this CPU.
enum SingBoxLocator {
    static var path: String? {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
        let arch = machine == "arm64" ? "arm64" : "amd64"
        let candidates: [String?] = ["/Library/Application Support/Silent Route/bin/sing-box",
                                     Bundle.main.resourceURL?.appendingPathComponent("sing-box/sing-box-darwin-\(arch)").path]
        return candidates.compactMap { $0 }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
