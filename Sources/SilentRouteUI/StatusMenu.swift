import AppKit
import Observation
import SwiftUI

/// The menu bar item's menu. A real menu, as the system's own (Wi-Fi,
/// Bluetooth) are: macOS highlights the item, places the menu, keeps the
/// menu bar over a full-screen app while it is open, and takes the keyboard
/// — on every version, including macOS 26, where the item's button is drawn
/// by another process and a window of ours could not do any of it.
///
/// The header (state, switch, traffic) is a view; the rest are menu items,
/// rebuilt before the menu opens and whenever what they show changes while
/// it is open.
@MainActor
public final class StatusMenu: NSObject, NSMenuDelegate {
    /// The header's width; the menu is as wide.
    static let width: CGFloat = 300

    public let menu = NSMenu()
    private let model: AppModel
    private let openMain: () -> Void
    private let emergencyRestore: () -> Void
    private let header = NSMenuItem()
    private let headerView: NSHostingView<MenuBarHeader>
    /// Bumped on every rebuild: a change seen by an older one is stale.
    private var generation = 0
    /// The items' signatures as last put in the menu.
    private var shown: [String] = []

    public init(model: AppModel, openMain: @escaping () -> Void, emergencyRestore: @escaping () -> Void) {
        self.model = model
        self.openMain = openMain
        self.emergencyRestore = emergencyRestore
        headerView = NSHostingView(rootView: MenuBarHeader(model: model))
        super.init()
        headerView.sizingOptions = [.intrinsicContentSize]
        headerView.frame.size = headerView.fittingSize
        header.view = headerView
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
    }

    /// Closes the menu if it is open (a window or an alert takes over).
    public func close() { menu.cancelTracking() }

    public func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    // MARK: Items

    private func rebuild() {
        generation += 1
        let mine = generation
        let items = withObservationTracking {
            build()
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == mine else { return }
                self.rebuild()
            }
        }
        // The header grows and shrinks with what it shows (the traffic
        // while connected); the menu takes its new height.
        let size = headerView.fittingSize
        if headerView.frame.size != size {
            headerView.frame.size = size
            if menu.items.first === header { menu.itemChanged(header) }
        }
        // The state changes often (a server's latency); the items are
        // replaced only when what they show does, so the one under the
        // pointer stays highlighted.
        let shown = items.map(Self.signature)
        guard menu.items.first !== header || shown != self.shown else { return }
        self.shown = shown
        if menu.items.first !== header { menu.items = [header] }
        while menu.items.count > 1 { menu.removeItem(at: 1) }
        for i in items { menu.addItem(i) }
    }

    /// What an item shows and does, to tell whether it changed.
    private static func signature(_ i: NSMenuItem) -> String {
        "\(i.isSeparatorItem)|\(i.title)|\(i.representedObject.map { "\($0)" } ?? "")|\(i.state.rawValue)|\(i.isEnabled)|\(i.keyEquivalent)|\(i.toolTip ?? "")"
    }

    private func build() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func section(_ new: [NSMenuItem]) {
            guard !new.isEmpty else { return }
            items.append(.separator())
            items += new
        }
        let changing = model.busy || [.connecting, .stopping].contains(model.status.phase)

        switch model.helper {
        case .ready:
            var profiles: [NSMenuItem] = [.sectionHeader(title: "Profile")]
            if model.library.profiles.isEmpty {
                profiles.append(item("Create Profile…") { [weak self] in self?.openMain() })
            } else {
                let active = model.library.activeID ?? model.library.profiles[0].id
                for p in model.library.profiles {
                    let i = item(p.name) { [weak self] in Task { await self?.model.activate(p.id) } }
                    i.representedObject = p.id
                    i.state = p.id == active ? .on : .off
                    i.isEnabled = !changing
                    profiles.append(i)
                }
            }
            section(profiles)
            if model.helperOutdated {
                section([item("Update Helper to This Version…", symbol: "arrow.triangle.2.circlepath", enabled: !model.busy) { [weak self] in
                    Task { await self?.model.installHelper() }
                }])
            }
        case .unknown:
            break
        case .notInstalled, .broken:
            let title = model.helper == .notInstalled ? "Install Helper…" : model.helperOutdated ? "Update Helper…" : "Reinstall Helper…"
            section([item(title, symbol: "arrow.down.app", enabled: !model.busy) { [weak self] in
                Task { await self?.model.installHelper() }
            }])
        }

        if model.captivePending {
            section([
                text("This Wi-Fi needs a login", symbol: "wifi.exclamationmark",
                     detail: "Everything stays blocked until you log in. Only the login window goes out directly."),
                item("Open Login Page…") { [weak self] in
                    guard let self else { return }
                    CaptiveLoginWindow.shared.show(model: self.model)
                },
            ])
        }

        if let n = model.notice {
            section([text(n.text, color: n.isError ? .systemRed : .secondaryLabelColor)])
        }

        let updater = Updater.shared
        if Preferences.checkForUpdates, let r = updater.available, model.helper != .notInstalled {
            section([item("Update to \(r.version)…", symbol: "arrow.down.circle") { Task { await updater.install() } }])
        } else if case .installing(let step) = updater.state {
            section([view(title: step, ProgressView { Text(step).font(.callout) }.progressViewStyle(.linear))])
        }

        let quit = Preferences.quit
        let quitItem = item(quit == .keepRunning || !model.isOn ? "Quit" : "Disconnect and Quit", symbol: "power", key: "q") {
            NSApp.terminate(nil)
        }
        quitItem.toolTip = quit == .keepRunning ? "The VPN keeps running without the app"
            : "The VPN turns off and the network goes back to normal"
        let restore = item("Emergency Restore…", symbol: "cross.case", key: "\u{8}", enabled: model.canTurnOff) { [weak self] in
            self?.emergencyRestore()
        }
        restore.keyEquivalentModifierMask = [.command, .shift]
        section([
            item("Open Silent Route", symbol: "macwindow", key: "o") { [weak self] in self?.openMain() },
            restore,
            quitItem,
        ])
        return items
    }

    private func item(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true,
                      _ action: @escaping @MainActor () -> Void) -> NSMenuItem {
        let i = ActionItem(title: title, action: action)
        i.keyEquivalent = key
        if let symbol { i.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        i.isEnabled = enabled
        return i
    }

    /// Text to read, not to choose: as wide as the menu, wrapped.
    private func text(_ title: String, symbol: String? = nil, detail: String? = nil, color: NSColor = .labelColor) -> NSMenuItem {
        view(title: "\(title)|\(detail ?? "")|\(color)", VStack(alignment: .leading, spacing: 4) {
            if let symbol {
                Label(title, systemImage: symbol).font(.callout.weight(.semibold))
            } else {
                Text(title).font(.callout).foregroundStyle(Color(nsColor: color))
            }
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true))
    }

    private func view(title: String = "", _ content: some View) -> NSMenuItem {
        let host = NSHostingView(rootView: content
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(width: Self.width, alignment: .leading))
        host.frame.size = host.fittingSize
        let i = NSMenuItem()
        i.title = title
        i.view = host
        return i
    }
}

/// A menu item that runs a closure.
@MainActor
private final class ActionItem: NSMenuItem {
    private let run: @MainActor () -> Void

    init(title: String, action: @escaping @MainActor () -> Void) {
        run = action
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { run() }
}
