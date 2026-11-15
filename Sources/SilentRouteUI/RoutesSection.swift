import SwiftUI
import UniformTypeIdentifiers
import VPNCore

/// The routes of a profile: named groups of traffic, each with where it
/// goes. Checked top to bottom; "Everything else" is always last.
struct RoutesSection: View {
    @Binding var profile: Profile
    let liveServers: [ServerState]
    let liveRoutes: [RouteState]
    @State private var editing: EditRequest?

    struct EditRequest: Identifiable {
        var id: UUID { route.id }
        var route: Route
        var isNew: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Routes").font(.headline)
                    Text("Each route is a group of traffic — sites, addresses, apps, ports — and where it goes. Checked top to bottom; the first match wins.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 16)
                Button {
                    let first = profile.tunnels.first.map { [$0.id] } ?? []
                    editing = EditRequest(route: Route(name: "", target: first.isEmpty ? .direct : .servers(first)), isNew: true)
                } label: { Label("Add Route…", systemImage: "plus") }
            }

            ForEach(Array(profile.routes.enumerated()), id: \.element.id) { i, r in
                RouteCard(profile: $profile, route: r, index: i, isDefault: false,
                          liveServers: liveServers, live: liveRoutes.first { $0.id == r.id },
                          edit: { editing = EditRequest(route: r, isNew: false) })
            }
            RouteCard(profile: $profile, route: profile.defaultRoute, index: profile.routes.count, isDefault: true,
                      liveServers: liveServers, live: liveRoutes.first { $0.id == profile.defaultRoute.id },
                      edit: { editing = EditRequest(route: profile.defaultRoute, isNew: false) })
        }
        .sheet(item: $editing) { req in
            RouteEditor(route: req.route, profile: profile, isNew: req.isNew,
                        isDefault: req.route.id == profile.defaultRoute.id) { result in
                if let result {
                    if result.id == profile.defaultRoute.id {
                        profile.defaultRoute = result
                    } else if let i = profile.routes.firstIndex(where: { $0.id == result.id }) {
                        profile.routes[i] = result
                    } else {
                        profile.routes.append(result)
                    }
                }
                editing = nil
            }
        }
    }
}

/// One route: what goes in, where it goes now, its kill switch.
struct RouteCard: View {
    @Binding var profile: Profile
    let route: Route
    let index: Int
    let isDefault: Bool
    let liveServers: [ServerState]
    let live: RouteState?
    let edit: () -> Void

    private var issues: [Validation.Issue] {
        Validation.check(profile).filter { $0.route == route.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if !isDefault {
                    Toggle("", isOn: binding(\.enabled)).toggleStyle(.checkbox).labelsHidden()
                        .help("Turn the route on or off without deleting it")
                } else {
                    Image(systemName: "asterisk.circle").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if !isDefault { Text("\(index + 1).").foregroundStyle(.tertiary).monospacedDigit() }
                        Text(route.name.isEmpty ? "Untitled" : route.name).font(.headline)
                    }
                    Text(isDefault ? "Traffic no route above claims" : RouteSummary.conditions(route.conditions))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if !isDefault {
                    // Order matters (first match wins): arrows as in a
                    // route's server list.
                    Button { move(by: -1) } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(.borderless).disabled(index == 0)
                        .help("Move up: checked earlier")
                    Button { move(by: 1) } label: { Image(systemName: "chevron.down") }
                        .buttonStyle(.borderless).disabled(index == profile.routes.count - 1)
                        .help("Move down: checked later")
                }
                // Everything about the route in one place, as in Apple's
                // apps; a double-click on the card edits it too.
                Menu {
                    Button("Edit…", action: edit)
                    if !isDefault {
                        Button("Duplicate") {
                            var copy = route
                            copy.id = UUID()
                            copy.name += " Copy"
                            profile.routes.insert(copy, at: index + 1)
                        }
                        Divider()
                        Button("Delete", role: .destructive) { profile.routes.removeAll { $0.id == route.id } }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Edit, duplicate or delete this route")
            }

            PathView(profile: profile, route: route, liveServers: liveServers, live: live)

            if case .servers = route.target {
                HStack(spacing: 14) {
                    Toggle(isOn: binding(\.killSwitch)) { Text("Kill switch").font(.callout) }
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .help("When no server in the list answers: block this traffic (on) or let it go directly, without VPN (off).")
                    Spacer()
                }
                if profile.chain(of: route).count > 1 {
                    Label("Moving to the next server changes your IP address mid-session. Sites with strict security checks may sign you out or flag the account.",
                          systemImage: "exclamationmark.shield")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            ForEach(issues, id: \.self) { i in
                Label(Text.sentence(i.message.replacingOccurrences(of: "route \"\(route.name)\"", with: "this route")),
                      systemImage: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(i.severity == .error ? .red : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .contentCard()
        .contentShape(.rect(cornerRadius: 14))
        .onTapGesture(count: 2, perform: edit)
        .opacity(route.enabled || isDefault ? 1 : 0.55)
        .contextMenu { Button("Edit…", action: edit) }
    }

    private func binding<T>(_ kp: WritableKeyPath<Route, T>) -> Binding<T> {
        Binding(get: { route[keyPath: kp] }, set: { v in
            if isDefault {
                profile.defaultRoute[keyPath: kp] = v
            } else if let i = profile.routes.firstIndex(where: { $0.id == route.id }) {
                profile.routes[i][keyPath: kp] = v
            }
        })
    }

    private func move(by d: Int) {
        guard let i = profile.routes.firstIndex(where: { $0.id == route.id }), profile.routes.indices.contains(i + d) else { return }
        profile.routes.swapAt(i, i + d)
    }
}

/// Where a route's traffic goes, as a row: server 1 → server 2 → … → Block
/// or Direct; or just Direct, or Block. While connected each server shows
/// whether it answers, and the step carrying the traffic is highlighted.
struct PathView: View {
    let profile: Profile
    let route: Route
    let liveServers: [ServerState]
    let live: RouteState?

    // Wraps instead of scrolling sideways: a scroll view would take the
    // card's clicks (its double-click opens the editor), and a long chain
    // stays readable at any width.
    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            switch route.target {
            case .direct:
                terminal(direct: true, active: live != nil, label: "Direct, without VPN")
            case .block:
                terminal(direct: false, active: live != nil, label: "Block")
            case .servers:
                let chain = profile.chain(of: route)
                ForEach(Array(chain.enumerated()), id: \.element) { i, id in
                    if i > 0 { arrow }
                    node(id, carrying: live?.via == .server(id))
                }
                if chain.isEmpty { Text("No servers").foregroundStyle(.red) }
                arrow
                terminal(direct: !route.killSwitch,
                         active: live?.via == .blocked || live?.via == .direct,
                         label: route.killSwitch ? "Block" : "Direct")
            }
        }
        .padding(.vertical, 2)
    }

    private var arrow: some View {
        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
    }

    private func node(_ id: Tunnel.ID, carrying: Bool) -> some View {
        let t = profile.tunnel(id)
        let s = liveServers.first { $0.id == id }
        let color: Color = s == nil ? .secondary.opacity(0.6) : (s?.latencyMs != nil ? .green : .red)
        return HStack(spacing: 5) {
            StatusDot(color: color, size: 7)
            Image(systemName: t?.kindSymbol ?? "questionmark.circle").font(.caption).foregroundStyle(.secondary)
            Text(t?.name ?? "?").font(.callout.weight(carrying ? .semibold : .regular)).lineLimit(1)
            if let ms = s?.latencyMs { Text("\(ms) ms").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
            else if s != nil { Text("down").font(.caption).foregroundStyle(.red) }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(carrying ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05), in: .capsule)
        .overlay(Capsule().strokeBorder(carrying ? Color.accentColor : .clear, lineWidth: 1.2))
    }

    private func terminal(direct: Bool, active: Bool, label: String) -> some View {
        let color: Color = direct ? .orange : .red
        return Label(label, systemImage: direct ? "arrow.up.right" : "nosign")
            .font(.callout.weight(active ? .semibold : .regular))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(color.opacity(active ? 0.18 : 0.07), in: .capsule)
            .overlay(Capsule().strokeBorder(active ? color : .clear, lineWidth: 1.2))
    }
}

enum RouteSummary {
    static func conditions(_ c: Conditions) -> String {
        var parts: [String] = []
        if !c.destinations.isEmpty { parts.append(list(c.destinations.map(RuleText.text))) }
        if !c.apps.isEmpty { parts.append("apps: " + list(c.apps.map(appName))) }
        if !c.ports.isEmpty { parts.append("ports " + RuleText.text(c.ports)) }
        if let n = c.network { parts.append(n == .tcp ? "TCP only" : "UDP only") }
        return parts.isEmpty ? "nothing yet" : parts.joined(separator: " · ")
    }

    static func list(_ items: [String]) -> String {
        items.count <= 3 ? items.joined(separator: ", ") : items.prefix(3).joined(separator: ", ") + " and \(items.count - 3) more"
    }

    static func appName(_ a: AppMatcher) -> String {
        if a == .webKitNetworking { return "Apple web content" }
        return switch a {
        case .bundle(let path): URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        case .executable(let path): URL(fileURLWithPath: path).lastPathComponent
        case .processName(let n): n
        }
    }
}

/// One route in a sheet: what goes in, and where it goes.
struct RouteEditor: View {
    @State var route: Route
    let profile: Profile
    let isNew: Bool
    let isDefault: Bool
    let done: (Route?) -> Void
    @State private var destinations = ""
    @State private var ports = ""
    @State private var processName = ""
    @State private var localNetwork = false

    enum Kind: String, CaseIterable, Identifiable {
        case servers = "Through servers", direct = "Direct", block = "Block"
        var id: Self { self }
    }

    init(route: Route, profile: Profile, isNew: Bool, isDefault: Bool, done: @escaping (Route?) -> Void) {
        _route = State(initialValue: route)
        self.profile = profile
        self.isNew = isNew
        self.isDefault = isDefault
        self.done = done
        _destinations = State(initialValue: RuleText.text(route.conditions.destinations.filter { $0 != .localNetwork }))
        _localNetwork = State(initialValue: route.conditions.destinations.contains(.localNetwork))
        _ports = State(initialValue: RuleText.text(route.conditions.ports))
    }

    private var parsedDest: (values: [Destination], errors: [RuleText.LineError]) { RuleText.destinations(destinations) }
    private var parsedPorts: (values: [PortRange], errors: [RuleText.LineError]) { RuleText.ports(ports) }

    private var result: Route {
        var r = route
        if !isDefault {
            r.conditions.destinations = parsedDest.values + (localNetwork ? [.localNetwork] : [])
            r.conditions.ports = parsedPorts.values
        }
        return r
    }

    private var problems: [String] {
        var out: [String] = []
        if !isDefault {
            out += (parsedDest.errors + parsedPorts.errors).map { "\($0.line): \($0.reason)" }
            if result.conditions.isEmpty { out.append("Add at least one thing to match: sites, apps, ports or protocol") }
            if result.name.trimmingCharacters(in: .whitespaces).isEmpty { out.append("Give the route a name") }
        }
        if case .servers(let ids) = result.target, ids.isEmpty { out.append("Choose at least one server") }
        return out
    }

    private var kind: Binding<Kind> {
        Binding(get: {
            switch route.target {
            case .servers: .servers
            case .direct: .direct
            case .block: .block
            }
        }, set: { k in
            switch k {
            case .servers: route.target = .servers(route.servers.isEmpty ? (profile.tunnels.first.map { [$0.id] } ?? []) : route.servers)
            case .direct: route.target = .direct
            case .block: route.target = .block
            }
        })
    }

    /// Splits the start of TLS connections (where the site's name is seen)
    /// into pieces, so that filtering on that name misses it. For traffic
    /// that goes direct; through a tunnel it is encrypted anyway.
    private var fragmentToggle: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("Fragment TLS handshakes", isOn: $route.fragmentTLS)
            Text("Splits the first packet of secure connections, where the site's name is visible, into pieces. Useful for traffic that goes direct; through a server it is encrypted already. Some sites may connect a little slower.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isDefault ? "Everything Else" : (isNew ? "New Route" : "Edit Route"))
                .font(.title3.weight(.semibold)).padding([.horizontal, .top], 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !isDefault {
                        TextField("Name", text: $route.name, prompt: Text("e.g. Claude and OpenAI"))
                            .textFieldStyle(.roundedBorder)
                    }

                    section("Send To") {
                        Picker("", selection: kind) {
                            ForEach(Kind.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 380)
                        if case .servers = route.target { serverList }
                        if route.target != .block { fragmentToggle.padding(.top, 4) }
                    }

                    if !isDefault {
                        section("Sites and Addresses", hint: "One per line: youtube.com (with subdomains), =exact.example.com, keyword:tube, list:blocked-sites (one of the profile's lists, in Network), 10.0.0.0/8, 1.2.3.4") {
                            TextEditor(text: $destinations)
                                .font(.body.monospaced())
                                .frame(minHeight: 100)
                                .scrollContentBackground(.hidden)
                                .padding(6)
                                .background(.background.opacity(0.7), in: .rect(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                            localNetworkToggle.padding(.top, 4)
                        }
                        section("Apps", hint: "Everything these programs send, including their helper processes") { apps }
                        section("Ports and Protocol") {
                            HStack {
                                TextField("443, 8000-8100", text: $ports).textFieldStyle(.roundedBorder).frame(maxWidth: 220)
                                Picker("", selection: $route.conditions.network) {
                                    Text("TCP and UDP").tag(Network?.none)
                                    Text("TCP only").tag(Network?.some(.tcp))
                                    Text("UDP only").tag(Network?.some(.udp))
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                        }
                        Text("The route takes everything these apps send, and every connection to these sites and addresses, from any app. Ports and a protocol, if given, narrow both to them.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(problems, id: \.self) { p in
                        Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Done") { done(result) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!problems.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 580, height: isDefault ? 500 : 740)
    }

    // MARK: Server list

    private var serverList: some View {
        let ids = route.servers
        let others = profile.tunnels.filter { !ids.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("In order: the first that answers carries the traffic.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(ids.enumerated()), id: \.element) { i, id in
                    let t = profile.tunnel(id)
                    HStack(spacing: 8) {
                        Text("\(i + 1).").monospacedDigit().foregroundStyle(.tertiary).frame(width: 22, alignment: .trailing)
                        Image(systemName: t?.kindSymbol ?? "questionmark.circle").foregroundStyle(.secondary)
                        Text(t?.name ?? "Deleted server").foregroundStyle(t == nil ? .red : .primary)
                        Text(t.map { $0.proto.displayName } ?? "").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { moveServer(i, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(i == 0)
                        Button { moveServer(i, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(i == ids.count - 1)
                        Button { setServers(ids.filter { $0 != id }) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    if i < ids.count - 1 { Divider() }
                }
            }
            .background(.background.opacity(0.6), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack {
                Menu {
                    ForEach(others) { t in
                        Button("\(t.name) — \(t.proto.displayName)") { setServers(ids + [t.id]) }
                    }
                } label: { Label("Add Server to List", systemImage: "plus") }
                    .fixedSize()
                    .disabled(others.isEmpty)
                if profile.tunnels.isEmpty {
                    Text("Add servers in the Servers section first.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Kill switch — block this traffic when no server in the list answers", isOn: $route.killSwitch)
            if !route.killSwitch {
                Text("Without kill switch, this traffic goes directly — with your real IP address — when no server answers.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if ids.count > 1 {
                Label("Moving to the next server changes your IP address mid-session. Sites with strict security checks may sign you out or flag the account.",
                      systemImage: "exclamationmark.shield")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setServers(_ ids: [Tunnel.ID]) { route.target = .servers(ids) }

    private func moveServer(_ i: Int, by d: Int) {
        var ids = route.servers
        guard ids.indices.contains(i + d) else { return }
        ids.swapAt(i, i + d)
        setServers(ids)
    }

    // MARK: Pieces

    /// Every local network at once, wherever the Mac is: no list of
    /// addresses to keep.
    private var localNetworkToggle: some View {
        Toggle(isOn: $localNetwork) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "network").frame(width: 18, height: 18).foregroundStyle(.secondary)
                    Text("Local network addresses")
                }
                Text("The router, printers, a NAS, other computers nearby: 192.168.x.x, 10.x.x.x, 172.16–31.x.x and other private and link-local addresses, on whatever network the Mac joins.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if localNetwork, profile.lan == .allow {
                    Label("While Local Network is “Reachable directly” (Network), these addresses go directly before any route is checked.",
                          systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func section<C: View>(_ title: String, hint: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            content()
        }
    }

    /// Apple's web content, as a setting of its own: the one thing that
    /// decides where the pages of Safari, Mail, the App Store… go. Choosing
    /// an app never turns it on or off.
    private var appleWebContent: Binding<Bool> {
        Binding(get: { route.conditions.apps.contains(.webKitNetworking) }, set: { on in
            route.conditions.apps.removeAll { $0 == .webKitNetworking }
            if on { route.conditions.apps.append(.webKitNetworking) }
        })
    }

    private var apps: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(route.conditions.apps.filter { $0 != .webKitNetworking }, id: \.self) { a in
                HStack {
                    AppIcon(matcher: a)
                    Text(RouteSummary.appName(a))
                    if a.isSafari {
                        Label("Web pages follow Apple web content below", systemImage: "info.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(appKind(a)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { route.conditions.apps.removeAll { $0 == a } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                Button("Choose App…", action: pickApp)
                TextField("", text: $processName, prompt: Text("or a process name: curl, ssh"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                    .onSubmit(addProcess)
                Button("Add", action: addProcess).disabled(processName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Toggle(isOn: appleWebContent) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        AppIcon(matcher: .webKitNetworking)
                        Text("Apple web content")
                    }
                    Text("Web pages shown by Apple's apps — Safari, Mail, the App Store and others — load through one shared system process (com.apple.WebKit.Networking), so they cannot be told apart: this setting decides for all of them, whichever apps are listed above.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)
            if appleWebContent.wrappedValue {
                // As the kill switch's warning: what it can do to the Mac.
                Label(route.target == .block
                      ? "Blocked, Apple's apps can no longer load web pages: Mail's messages, the App Store, sign-in and help windows. Turning the VPN off or Emergency Restore puts everything back."
                      : "Apple's apps — Mail, the App Store, sign-in and help windows — then load their pages this way, and stop if it does not answer. Nothing on the Mac is changed: turning the VPN off or Emergency Restore puts everything back.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func appKind(_ a: AppMatcher) -> String {
        if a == .webKitNetworking { return "Safari, Mail, the App Store…" }
        return switch a {
        case .bundle: "app"
        case .executable(let p): p
        case .processName: "process"
        }
    }

    private func addProcess() {
        let n = processName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        let m: AppMatcher = n.hasPrefix("/") ? .executable(path: n) : .processName(n)
        if !route.conditions.apps.contains(m) { route.conditions.apps.append(m) }
        processName = ""
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let m = AppMatcher.bundle(path: url.path)
            if !route.conditions.apps.contains(m) { route.conditions.apps.append(m) }
        }
    }
}

struct AppIcon: View {
    let matcher: AppMatcher
    var body: some View {
        if matcher == .webKitNetworking {
            Image(systemName: "globe").frame(width: 18, height: 18).foregroundStyle(.secondary)
        } else if case .bundle(let path) = matcher {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
        } else {
            Image(systemName: "terminal").frame(width: 18, height: 18).foregroundStyle(.secondary)
        }
    }
}
