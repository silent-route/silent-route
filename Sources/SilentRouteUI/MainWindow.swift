import SwiftUI
import UniformTypeIdentifiers
import VPNCore

/// The full window: Monitor and the profiles on the left, the selection on
/// the right.
public struct MainWindow: View {
    let model: AppModel
    @State private var selection: Item?
    @State private var importing = false
    @State private var exporting: ProfileDocument?
    @State private var deleting: Profile?
    @State private var dropTargeted = false
    @State private var monitor = TrafficMonitor()
    @State private var settingsOpen = false
    @State private var windowVisible = true
    /// The page of the profile shown, kept when another profile is chosen.
    /// (Not SceneStorage: this window is not a SwiftUI scene, and there it
    /// never changes.)
    @AppStorage("profileSection") private var profileSection: ProfileEditor.Section = .routes

    enum Item: Hashable {
        case monitor
        case logs
        case servers
        case profile(Profile.ID)
    }

    public init(model: AppModel, selection: Profile.ID? = nil, showMonitor: Bool = false, showLogs: Bool = false,
                showServers: Bool = false) {
        self.model = model
        _selection = State(initialValue: showServers ? .servers : showLogs ? .logs : showMonitor ? .monitor : selection.map(Item.profile))
    }

    /// For the snapshot tool: the Monitor page with given data.
    init(model: AppModel, monitor: TrafficMonitor) {
        self.model = model
        _selection = State(initialValue: .monitor)
        _monitor = State(initialValue: monitor)
    }

    private var windowTitle: String {
        switch selection {
        case .monitor: "Monitor"
        case .logs: "Logs"
        case .servers: "Server Library"
        case .profile: "Profile"
        case nil: "Silent Route"
        }
    }

    private var selectedProfile: Profile.ID? {
        if case .profile(let id) = selection { id } else { nil }
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
        } detail: {
            // On the detail column, so they sit on its trailing side.
            detail
                .toolbar { toolbar }
                // The title says what kind of page this is — Monitor, Logs,
                // Profile — not its name, which a profile shows large right
                // below. One modifier for every page, so switching never
                // leaves the previous page's title behind.
                .navigationTitle(windowTitle)
                // SwiftUI fills the title in only after the first change;
                // the window gets it from the start.
                .background(WindowTitle(windowTitle))
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.silentRouteProfile, .json],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { for u in urls { if let id = await model.importFile(u) { selection = .profile(id) } } }
        }
        .fileExporter(isPresented: Binding(get: { exporting != nil }, set: { if !$0 { exporting = nil } }),
                      document: exporting, contentType: .silentRouteProfile,
                      defaultFilename: exporting?.profile.name ?? "Profile") { result in
            if case .failure(let e) = result { model.notice = .init("Not saved: \(e.localizedDescription)", isError: true) }
        }
        .confirmationDialog("Delete the profile “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let p = deleting { Task { await model.delete(p.id) } }
            }
        } message: {
            Text("Its exits and rules are deleted too. This cannot be undone — export it to a file first if you may need it.")
        }
        // Whole profiles only: a dropped or pasted .srprofile. Links are
        // added in the Add Exit sheet, where it is clear what they become.
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            importFiles(providers)
            return true
        }
        .overlay { if dropTargeted { dropHint } }
        .onPasteCommand(of: [.fileURL, .silentRouteProfile, .json]) { providers in pasteProfiles(providers) }
        .onAppear {
            if selection == nil {
                selection = (model.library.activeID ?? model.library.profiles.first?.id).map(Item.profile)
            }
        }
        .onChange(of: model.library.profiles.map(\.id)) { _, ids in
            if case .profile(let s) = selection, ids.contains(s) { return }
            if selection == .monitor || selection == .logs || selection == .servers { return }
            selection = (model.library.activeID ?? ids.first).map(Item.profile)
        }
        .onReceive(NotificationCenter.default.publisher(for: WindowCommand.notification)) { note in
            if let c = (note.object as? String).flatMap(WindowCommand.init(rawValue:)) { perform(c) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in updateSettingsOpen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in updateSettingsOpen() }
        // Settings is ordered out rather than closed, and its key and
        // occlusion changes arrive while it is still on screen: look again
        // once each change has settled.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in updateSettingsOpen() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            updateSettingsOpen(closing: note.object as? NSWindow)
        }
        // Live traffic is read only while someone can see it: the Monitor
        // page, in a window that is on screen.
        .background(WindowVisibility { windowVisible = $0 })
        .onChange(of: selection) { _, _ in updateMonitor() }
        .onChange(of: windowVisible) { _, _ in updateMonitor() }
        .onChange(of: model.library.active) { _, p in monitor.setProfile(p) }
    }

    private func updateMonitor() {
        if selection == .monitor && windowVisible {
            monitor.setProfile(model.library.active)
            monitor.start { [model] in await model.apiCredentials() }
        } else {
            monitor.stop()
        }
    }

    /// SwiftUI's Settings window, by the identifier it gives it.
    private func updateSettingsOpen(closing: NSWindow? = nil) {
        settingsOpen = Self.settingsVisible(except: closing)
        for delay in [0.05, 0.3] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { settingsOpen = Self.settingsVisible() }
        }
    }

    private static func settingsVisible(except closing: NSWindow? = nil) -> Bool {
        NSApp.windows.contains { w in
            w !== closing && w.isVisible && w.occlusionState.contains(.visible)
                && (w.identifier?.rawValue.contains("Settings") ?? false)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $selection) {
            Label("Monitor", systemImage: "chart.xyaxis.line").tag(Item.monitor)
            Label("Logs", systemImage: "doc.text").tag(Item.logs)
            Label("Server Library", systemImage: "server.rack").tag(Item.servers)
            Section("Profiles") {
                // The standard sidebar look, as in Finder, Mail and Notes:
                // the system's own selection, no card around the rows.
                ForEach(model.library.profiles) { p in
                    ProfileRow(profile: p, isActive: p.id == model.library.activeID,
                               status: model.otherUsersVPN ? VPNStatus(phase: .off) : model.status)
                        .tag(Item.profile(p.id))
                        .help(p.id == model.library.activeID ? "Active profile"
                                                             : "Press Return or double-click to make this profile active")
                }
                if model.library.profiles.isEmpty && model.helper == .ready {
                    Button("New Profile") { Task { if let id = await model.newProfile() { selection = .profile(id) } } }
                        .buttonStyle(.link)
                }
            }
        }
        .listStyle(.sidebar)
        // Return or a double-click on a profile makes it active (the list's
        // primary action, as opening a file in Finder); right-click menus.
        .contextMenu(forSelectionType: Item.self) { items in
            if items.count == 1, case .profile(let id)? = items.first, let p = model.library.profile(id) {
                contextMenu(p)
            }
        } primaryAction: { items in
            guard items.count == 1, case .profile(let id)? = items.first, id != model.library.activeID else { return }
            Task { await model.activate(id) }
        }
        // At the top: the switch is the most important control, and the
        // bottom of a sidebar is where a window moved down hides things.
        .safeAreaInset(edge: .top) { ConnectionCard(model: model).padding(.horizontal, 10).padding(.bottom, 6) }
    }

    @ViewBuilder
    private func contextMenu(_ p: Profile) -> some View {
        if p.id != model.library.activeID {
            Button("Make Active") { Task { await model.activate(p.id) } }
        }
        Button("Duplicate") { Task { if let id = await model.duplicate(p) { selection = .profile(id) } } }
        Button("Export…") { exporting = ProfileDocument(profile: p) }
        Divider()
        Button("Delete…", role: .destructive) { deleting = p }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.helper {
        case .notInstalled, .broken:
            HelperSetupView(model: model)
        case .unknown:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            switch selection {
            case .monitor:
                MonitorView(model: model, monitor: monitor)
            case .logs:
                LogsView(model: model)
            case .servers:
                ServerLibraryView(model: model)
            case .profile(let id):
                if let p = model.library.profile(id) {
                    ProfileEditor(model: model, saved: p, section: $profileSection).id(id)
                } else {
                    noSelection
                }
            case nil:
                noSelection
            }
        }
    }

    private var noSelection: some View {
        ContentUnavailableView("No Profile Selected", systemImage: "globe",
                               description: Text("Create one with +, or import a .srprofile file: choose it, drop it here, or paste it with ⌘V."))
    }

    /// All on the trailing side, Apple's place for actions: the leading
    /// edge is for the sidebar button and the title. Each one is also in
    /// the menu bar (File, and the app menu for Settings).
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Menu {
                Button("New Profile") { newProfile() }
                Button("Import Profile…") { importing = true }
            } label: {
                Label("Add", systemImage: "plus")
            }
            .disabled(model.helper != .ready)
            .help("New profile, or import one from a file")
        }
        ToolbarItem(placement: .automatic) {
            if let id = selectedProfile, let p = model.library.profile(id) {
                Button { exporting = ProfileDocument(profile: p) } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Save this profile to a .srprofile file")
            }
        }
        ToolbarItem(placement: .automatic) {
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
            // Its look follows the Settings window, not the pointer: dimmed
            // while Settings is open, crisp when it is closed.
            .opacity(settingsOpen ? 0.45 : 1)
            .help("Settings (⌘,)")
        }
    }

    private func newProfile() {
        Task { if let id = await model.newProfile() { selection = .profile(id) } }
    }

    /// Menu bar commands (File, View) for this window.
    private func perform(_ command: WindowCommand) {
        switch command {
        case .newProfile: if model.helper == .ready { newProfile() }
        case .importProfile: if model.helper == .ready { importing = true }
        case .exportProfile:
            if let id = selectedProfile, let p = model.library.profile(id) { exporting = ProfileDocument(profile: p) }
        case .showMonitor: selection = .monitor
        case .showLogs: selection = .logs
        case .showActiveProfile:
            if let id = model.library.activeID { selection = .profile(id) }
        }
    }

    // MARK: Import by drop and paste

    private var dropHint: some View {
        RoundedRectangle(cornerRadius: 14)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.06), in: .rect(cornerRadius: 14))
            .overlay(Label("Drop to import the profile", systemImage: "square.and.arrow.down")
                .font(.title3).padding()
                .background(.regularMaterial, in: .rect(cornerRadius: 12)))
            .padding(8)
            .allowsHitTesting(false)
    }

    private func importFiles(_ providers: [NSItemProvider]) {
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in if let id = await model.importFile(url) { selection = .profile(id) } }
            }
        }
    }

    /// ⌘V: a copied .srprofile file, or a profile's JSON copied as text.
    private func pasteProfiles(_ providers: [NSItemProvider]) {
        let pb = NSPasteboard.general
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            Task { for u in urls { if let id = await model.importFile(u) { selection = .profile(id) } } }
        } else if let text = pb.string(forType: .string) {
            Task { if let id = await model.importProfileText(text) { selection = .profile(id) } }
        }
    }
}

struct ProfileRow: View {
    let profile: Profile
    let isActive: Bool
    let status: VPNStatus

    var body: some View {
        HStack(spacing: 8) {
            // The same planet for every profile; blue while this one is connected.
            Image(systemName: "globe")
                .foregroundStyle(isActive && status.phase == .connected ? Color.blue
                                 : isActive ? Color.primary : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile.name).lineLimit(1)
                Text("\(Plural.count(profile.tunnels.count, "server", "servers")) · \(Plural.count(profile.routes.count + 1, "route", "routes"))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if isActive && status.phase != .off {
                StatusDot(color: PhaseLook(status: status, helper: .ready).color, size: 8)
            }
        }
        .padding(.vertical, 2)
    }
}

/// Connection state and the switch, at the top of the sidebar.
struct ConnectionCard: View {
    let model: AppModel

    var body: some View {
        let look = PhaseLook(status: model.status, helper: model.helper, otherUser: model.otherUsersVPN)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusDot(color: look.color)
                VStack(alignment: .leading, spacing: 0) {
                    Text(look.title).font(.callout.weight(.medium)).lineLimit(2)
                    if let p = model.activeProfile, model.helper == .ready, !model.otherUsersVPN {
                        Text(p.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Toggle("", isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setOn(on) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(!model.switchEnabled || model.busy || model.status.phase == .stopping)
            }
            if model.status.phase == .connected {
                // Fixed rows and columns: the numbers change every second,
                // the layout never does.
                VStack(alignment: .leading, spacing: 3) {
                    if let since = model.uptimeSince {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Label(Format.uptime(since: since, now: ctx.date), systemImage: "clock")
                        }
                    }
                    HStack(spacing: 8) {
                        Label(model.speed.map { Format.speed($0.down) } ?? "—", systemImage: "arrow.down")
                            .frame(width: 78, alignment: .leading)
                        Label(model.speed.map { Format.speed($0.up) } ?? "—", systemImage: "arrow.up")
                            .frame(width: 78, alignment: .leading)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .labelStyle(CompactLabel())
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            if let n = model.notice {
                Text(n.text).font(.caption).foregroundStyle(n.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineLimit(4)
            }
            if model.captivePending {
                CaptiveBanner(model: model)
            }
            if model.helperOutdated {
                Button("Update Helper…") { Task { await model.installHelper() } }
                    .controlSize(.small)
                    .disabled(model.busy)
                    .help("The helper came from another build of the app. Your profiles are kept.")
            }
        }
        .padding(10)
        .contentCard(cornerRadius: 10)
    }
}

/// Shown instead of the editor until the helper answers.
struct HelperSetupView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(.tint)
            Text(model.helper == .notInstalled ? "Silent Route needs its helper"
                 : model.helperOutdated ? "Update the Silent Route helper" : "The Silent Route helper is not responding")
                .font(.title2.weight(.semibold))
            Text("""
            It runs in the background as part of the system: it brings the tunnel up, keeps the kill switch, \
            and restores the network if something goes wrong. It is installed once; macOS asks for an administrator password.
            """)
            .multilineTextAlignment(.center)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 440)
            if case .broken(let why) = model.helper {
                Text(why).font(.caption).foregroundStyle(model.helperOutdated ? Color.secondary : Color.red).multilineTextAlignment(.center).frame(maxWidth: 440)
            }
            Button {
                Task { await model.installHelper() }
            } label: {
                // The ellipsis: macOS asks for a password in another window.
                Text(model.helper == .notInstalled ? "Install Helper…" : model.helperOutdated ? "Update Helper…" : "Reinstall Helper…")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(model.busy)
            if let n = model.notice {
                Text(n.text).font(.callout).foregroundStyle(n.isError ? .red : .secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A profile as a file. Export only: import reads files directly so that a
/// broken or foreign file gets a clear message.
struct ProfileDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.silentRouteProfile]
    let profile: Profile

    init(profile: Profile) { self.profile = profile }

    init(configuration: ReadConfiguration) throws {
        guard let d = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        profile = try JSONDecoder().decode(Profile.self, from: d)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return FileWrapper(regularFileWithContents: try enc.encode(profile))
    }
}

/// Reports whether the hosting window is on screen: not closed, not
/// minimised, not on another desktop, not fully covered.
private struct WindowVisibility: NSViewRepresentable {
    let changed: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = Watcher()
        view.changed = changed
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { (view as? Watcher)?.changed = changed }

    final class Watcher: NSView {
        var changed: ((Bool) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Selector-based: removed with the view, no bookkeeping.
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(occlusionChanged),
                                                   name: NSWindow.didChangeOcclusionStateNotification, object: window)
            report()
        }

        @objc private func occlusionChanged(_ note: Notification) { report() }

        private func report() {
            let visible = window.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false
            DispatchQueue.main.async { [weak self] in self?.changed?(visible) }
        }
    }
}

/// Sets the hosting window's title.
private struct WindowTitle: NSViewRepresentable {
    let title: String
    init(_ title: String) { self.title = title }
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        let title = self.title
        DispatchQueue.main.async { view.window?.title = title }
    }
}

/// Commands from the menu bar that act on the main window.
public enum WindowCommand: String, Sendable {
    case newProfile, importProfile, exportProfile, showMonitor, showLogs, showActiveProfile

    public static let notification = Notification.Name("SilentRouteWindowCommand")

    @MainActor public func post() {
        NotificationCenter.default.post(name: Self.notification, object: rawValue)
    }
}

struct CompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}
