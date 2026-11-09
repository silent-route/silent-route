import SwiftUI
import VPNCore

/// What Monitor's Add to Route… starts from: an app, or a connection — an
/// app talking to a host.
struct RouteSubject: Identifiable, Hashable {
    var app: TrafficMonitor.AppRef
    /// For a connection: where it goes.
    var host: String?
    var id: String { app.id + "\u{1F}" + (host ?? "") }
}

/// Monitor's Add to Route…: the app, or the site a connection goes to, into
/// a route of a profile — an existing route or a new one, in an existing
/// profile or a new one. Saved as soon as it is added, as a profile is.
struct AddToRouteSheet: View {
    let model: AppModel
    let subject: RouteSubject
    @Environment(\.dismiss) private var dismiss

    enum Kind: String, Hashable { case site, app }
    enum Choice: Hashable { case existing(UUID), new }
    enum SendTo: Hashable { case server(Tunnel.ID), direct, block }

    @State private var kind: Kind
    @State private var destination: Destination?
    @State private var profileChoice: Choice
    @State private var newProfileName = ""
    @State private var routeChoice: Choice = .new
    @State private var routeName = ""
    @State private var sendTo: SendTo = .direct
    @State private var error: String?
    @State private var saving = false

    private let destinations: [Destination]

    init(model: AppModel, subject: RouteSubject) {
        self.model = model
        self.subject = subject
        let ds = subject.host.map(RouteAddition.destinations(forHost:)) ?? []
        destinations = ds
        // A connection is about where it goes; an app row, about the app.
        _kind = State(initialValue: ds.isEmpty ? .app : .site)
        _destination = State(initialValue: RouteAddition.suggested(ds))
        let lib = model.library
        _profileChoice = State(initialValue: (lib.activeID ?? lib.profiles.first?.id).map(Choice.existing) ?? .new)
    }

    // MARK: What is chosen

    private var item: RouteAddition.Item? {
        switch kind {
        case .site: destination.map(RouteAddition.Item.destination)
        case .app: RouteAddition.matcher(for: subject.app).map(RouteAddition.Item.app)
        }
    }

    private var profile: Profile? {
        if case .existing(let id) = profileChoice { model.library.profile(id) } else { nil }
    }

    private var route: Route? {
        if case .existing(let id) = routeChoice { profile?.routes.first { $0.id == id } } else { nil }
    }

    private var servers: [Tunnel] { profile?.tunnels ?? [] }

    private var target: Route.Target {
        switch sendTo {
        case .server(let id): .servers([id])
        case .direct: .direct
        case .block: .block
        }
    }

    private var routeNameOrSuggestion: String {
        let n = routeName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? RouteAddition.suggestedName(item) : n
    }

    private var profileNameOrDefault: String {
        let n = newProfileName.trimmingCharacters(in: .whitespaces)
        return model.library.freeName(n.isEmpty ? AppModel.defaultProfileName : n)
    }

    /// What stops Add.
    private var problem: String? {
        guard let item else {
            return kind == .app ? "This traffic has no app to match: macOS did not say which program sent it."
                                : "This host cannot become a rule."
        }
        if case .existing = profileChoice, profile == nil { return "The profile is gone — choose another." }
        if case .existing = routeChoice {
            guard let route else { return "The route is gone — choose another." }
            if RouteAddition.contains(route, item) { return "Already in this route." }
        }
        return nil
    }

    struct Note: Hashable {
        var text: String
        var warning: Bool
    }

    /// Worth knowing before adding; nothing stops it.
    private var notes: [Note] {
        var out: [Note] = []
        if let route, let item {
            if RouteAddition.narrows(route, item) {
                out.append(Note(text: kind == .app
                    ? "This route also has sites, ports or a protocol, and a connection must match all of them: it will then take only this app's traffic to those, not all of it."
                    : "This route also has apps, ports or a protocol, and a connection must match all of them: it will then take only those apps' traffic to this site.",
                    warning: true))
            }
            if !route.enabled { out.append(Note(text: "This route is turned off: turn it on in the profile for it to work.", warning: true)) }
        }
        if routeChoice == .new {
            out.append(Note(text: "The new route goes to the top of the list, so it is checked before the others.", warning: false))
        }
        if let p = profile, p.id == model.library.activeID, model.isOn {
            out.append(Note(text: "This profile is in use: the change applies right away, and open connections restart.", warning: false))
        }
        return out
    }

    // MARK: View

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProcessIcon(app: subject.app, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add to Route").font(.title3.weight(.semibold))
                    Text(subject.host.map { "\(subject.app.name) → \($0)" } ?? subject.app.name)
                        .font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 4)

            Form {
                Section {
                    if subject.host != nil {
                        Picker("Match", selection: $kind) {
                            Text("Site").tag(Kind.site)
                            Text("App").tag(Kind.app)
                        }
                        .pickerStyle(.segmented)
                    }
                    switch kind {
                    case .site:
                        Picker("Site", selection: $destination) {
                            ForEach(destinations, id: \.self) { d in
                                Text(RouteAddition.describe(d)).tag(Destination?.some(d))
                            }
                        }
                        .disabled(destinations.isEmpty)
                    case .app:
                        LabeledContent("App") {
                            Text(subject.app.path.isEmpty ? subject.app.name : subject.app.path)
                                .lineLimit(1).truncationMode(.middle)
                                .help(subject.app.path)
                        }
                    }
                } footer: {
                    Text(kind == .app ? "Everything this app sends, including its helper processes."
                                      : "Connections to this site from any app.")
                        .font(.caption).foregroundStyle(.secondary)
                }

                Section("Route") {
                    Picker("Profile", selection: $profileChoice) {
                        ForEach(model.library.profiles) { p in
                            Text(p.id == model.library.activeID ? "\(p.name) (active)" : p.name).tag(Choice.existing(p.id))
                        }
                        if !model.library.profiles.isEmpty { Divider() }
                        Text("New Profile").tag(Choice.new)
                    }
                    if profileChoice == .new {
                        TextField("Profile name", text: $newProfileName,
                                  prompt: Text(model.library.freeName(AppModel.defaultProfileName)))
                    }
                    Picker("Route", selection: $routeChoice) {
                        ForEach(profile?.routes ?? []) { r in
                            Text(r.enabled ? r.name : "\(r.name) (off)").tag(Choice.existing(r.id))
                        }
                        if !(profile?.routes.isEmpty ?? true) { Divider() }
                        Text("New Route").tag(Choice.new)
                    }
                    if routeChoice == .new {
                        TextField("Route name", text: $routeName, prompt: Text(RouteAddition.suggestedName(item)))
                        Picker("Send to", selection: $sendTo) {
                            ForEach(servers) { t in
                                Label(t.name, systemImage: t.kindSymbol).tag(SendTo.server(t.id))
                            }
                            if !servers.isEmpty { Divider() }
                            Label("Direct, without VPN", systemImage: "arrow.up.right").tag(SendTo.direct)
                            Label("Block", systemImage: "nosign").tag(SendTo.block)
                        }
                    } else if let route {
                        LabeledContent("Already matches") {
                            Text(RouteSummary.conditions(route.conditions)).lineLimit(2).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 500, height: 520)
        .onAppear { profileChanged() }
        .onChange(of: profileChoice) { _, _ in profileChanged() }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let error {
                        Label(Text.sentence(error), systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                    } else if let problem {
                        Label(problem, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                    ForEach(notes, id: \.self) { n in
                        Label(n.text, systemImage: n.warning ? "exclamationmark.triangle.fill" : "info.circle")
                            .foregroundStyle(n.warning ? Color.orange : Color.secondary)
                    }
                }
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { Task { await add() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(problem != nil || saving || model.busy)
            }
            .padding(16)
        }
    }

    // MARK: Actions

    /// Another profile has other routes and servers: start from a new route
    /// through its first server, if it has one.
    private func profileChanged() {
        routeChoice = .new
        sendTo = servers.first.map { .server($0.id) } ?? .direct
        error = nil
    }

    private func add() async {
        guard problem == nil, let item else { return }
        saving = true
        defer { saving = false }
        // The library as it is now, not as it was when the sheet opened.
        let base = profile ?? Profile.blank(name: profileNameOrDefault)
        let to: RouteAddition.Target = route.map { .existing($0.id) } ?? .new(name: routeNameOrSuggestion, target: target)
        guard let updated = RouteAddition.apply(item, to: to, in: base) else {
            error = "The route is gone — choose another."
            return
        }
        if let e = await model.save(updated) {
            error = e
            return
        }
        let routeName = route?.name ?? routeNameOrSuggestion
        model.notice = .init("Added to the route “\(routeName)” of “\(updated.name)”", isError: false)
        dismiss()
    }
}
