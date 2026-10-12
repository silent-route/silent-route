import SwiftUI
import VPNCore

extension AppModel {
    /// The SF Symbol for the status item.
    public var statusSymbol: String { PhaseLook(status: status, helper: helper).symbol }
    /// The status item tints the planet blue while connected.
    public var statusIconIsBlue: Bool { PhaseLook(status: status, helper: helper).iconIsBlue }
}

/// The menu bar icon.
public struct MenuBarIcon: View {
    let model: AppModel
    public init(model: AppModel) { self.model = model }
    public var body: some View {
        Image(systemName: PhaseLook(status: model.status, helper: model.helper).symbol)
            .accessibilityLabel("Silent Route")
    }
}

/// The menu bar panel: on/off, a short status, the profile, and the way out
/// when something is wrong.
public struct MenuBarView: View {
    let model: AppModel
    /// Shows the main window (the app owns it, so it can be opened from
    /// the status item whatever state SwiftUI's scenes are in).
    let openMain: () -> Void
    @State private var confirmPanic = false
    private let updater = Updater.shared
    @AppStorage(Preferences.quitKey) private var quit = Preferences.Quit.disconnect

    public init(model: AppModel, openMain: @escaping () -> Void = {}) {
        self.model = model
        self.openMain = openMain
    }

    public var body: some View {
        let look = PhaseLook(status: model.status, helper: model.helper)
        VStack(alignment: .leading, spacing: 0) {
            header(look)
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 12)

            if model.helper == .ready {
                Divider()
                profilePicker
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            } else if model.helper != .unknown {
                Divider()
                Button {
                    Task { await model.installHelper() }
                } label: {
                    Label(model.helper == .notInstalled ? "Install Helper…"
                          : model.helperOutdated ? "Update Helper…" : "Reinstall Helper…", systemImage: "arrow.down.app")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy)
                .padding(14)
            }

            if model.helperOutdated && model.helper == .ready {
                Divider()
                Button { Task { await model.installHelper() } } label: {
                    Label("Update Helper to This Version…", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(model.busy)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }

            if let n = model.notice {
                Divider()
                Text(n.text)
                    .font(.callout)
                    .foregroundStyle(n.isError ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }

            if let r = updater.available, model.helper != .notInstalled {
                Divider()
                Button { Task { await updater.install() } } label: {
                    Label("Update to \(r.version)…", systemImage: "arrow.down.circle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 14).padding(.vertical, 10)
            } else if case .installing(let step) = updater.state {
                Divider()
                ProgressView { Text(step).font(.callout) }
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 14).padding(.vertical, 10)
            }

            Divider()
            VStack(spacing: 2) {
                MenuRow(title: "Open Silent Route", symbol: "macwindow", shortcut: .init("o"), action: openMain)
                if confirmPanic {
                    panicConfirmation
                } else {
                    MenuRow(title: "Emergency Restore…", symbol: "cross.case", shortcut: .emergencyRestore) {
                        confirmPanic = true
                    }
                    .disabled(model.helper != .ready)
                }
                MenuRow(title: quitTitle, symbol: "power", shortcut: .init("q")) { NSApp.terminate(nil) }
                    .help(quit == .keepRunning
                          ? "The VPN keeps running without the app"
                          : "The VPN turns off and the network goes back to normal")
            }
            .padding(6)
        }
        .frame(width: 300)
    }

    private var quitTitle: String {
        quit == .keepRunning || !model.isOn ? "Quit" : "Disconnect and Quit"
    }

    private func header(_ look: PhaseLook) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: look.symbol)
                    .font(.system(size: 22, weight: .regular))
                    .foregroundStyle(look.iconColor)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Silent Route").font(.headline)
                    HStack(spacing: 5) {
                        StatusDot(color: look.color, size: 7)
                        Text(statusLine(look)).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { model.isOn }, set: { on in Task { await model.setOn(on) } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(model.helper != .ready || model.busy || model.library.active == nil
                              || model.status.phase == .stopping)
            }
            if let d = look.detail {
                Text(d)
                    .font(.caption)
                    .foregroundStyle(model.status.phase == .reconnecting ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.status.phase == .connected {
                HStack(spacing: 14) {
                    if let since = model.status.connectedSince {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Label(Format.uptime(since: since, now: ctx.date), systemImage: "clock")
                        }
                    }
                    if let s = model.speed {
                        Label(Format.speed(s.down), systemImage: "arrow.down")
                        Label(Format.speed(s.up), systemImage: "arrow.up")
                    }
                }
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .labelStyle(CompactLabel())
                if let t = model.sessionBytes {
                    Text("This session: ↓ \(Format.bytes(t.down))  ↑ \(Format.bytes(t.up))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Traffic since the VPN connected")
                }
            }
        }
    }

    private func statusLine(_ look: PhaseLook) -> String {
        var parts = [look.title]
        if model.helper == .ready, let p = model.activeProfile, model.status.phase != .off || !model.status.killSwitchOn {
            parts.append(p.name)
        }
        return parts.joined(separator: " · ")
    }

    private var profilePicker: some View {
        HStack {
            Text("Profile").foregroundStyle(.secondary)
            Spacer()
            if model.library.profiles.isEmpty {
                Button("Create…", action: openMain)
            } else {
                Picker("Profile", selection: Binding(
                    get: { model.library.activeID ?? model.library.profiles[0].id },
                    set: { id in Task { await model.activate(id) } })) {
                    ForEach(model.library.profiles) { p in Text(p.name).tag(p.id) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .disabled(model.busy || [.connecting, .stopping].contains(model.status.phase))
            }
        }
    }

    private var panicConfirmation: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Turn the VPN off, lift all blocking and repair routing?")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { confirmPanic = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Restore", role: .destructive) {
                    confirmPanic = false
                    Task { await model.panic() }
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(8)
        .background(.red.opacity(0.08), in: .rect(cornerRadius: 8))
    }
}

/// A key combination shown on a menu row and bound to it.
struct Shortcut {
    var key: KeyEquivalent
    var modifiers: EventModifiers = .command
    /// What the row shows, as in a menu: ⌘O, ⇧⌘⌫.
    var label: String

    init(_ ch: Character) {
        key = KeyEquivalent(ch)
        label = "⌘" + String(ch).uppercased()
    }

    init(key: KeyEquivalent, modifiers: EventModifiers, label: String) {
        self.key = key
        self.modifiers = modifiers
        self.label = label
    }

    /// ⇧⌘⌫ — the same in the menu bar panel and the app's menu.
    static let emergencyRestore = Shortcut(key: .delete, modifiers: [.command, .shift], label: "⇧⌘⌫")
}

/// A full-width row that highlights on hover, like a menu item.
struct MenuRow: View {
    let title: String
    let symbol: String
    var shortcut: Shortcut? = nil
    let action: () -> Void
    @State private var hover = false
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer()
                if let shortcut { Text(shortcut.label).foregroundStyle(.tertiary).font(.callout) }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(hover && enabled ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .modifier(ShortcutIfAny(shortcut: shortcut))
    }
}

private struct ShortcutIfAny: ViewModifier {
    let shortcut: Shortcut?
    func body(content: Content) -> some View {
        if let shortcut {
            content.keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            content
        }
    }
}
