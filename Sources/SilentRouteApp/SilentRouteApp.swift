import AppKit
import Observation
import SilentRouteUI
import SwiftUI

// The app: a normal window plus a menu bar control. The VPN itself lives in
// the root helper, so a crash of the app never touches the connection.
// Quitting turns the VPN off (after asking) unless Settings say to keep it
// running.
//
// The window and the status item are AppKit-owned (SwiftUI inside): the
// status item must open on both mouse buttons, which MenuBarExtra does not
// do, and the window must be openable from it at any time.

@main
struct SilentRouteApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings {
            SettingsView(model: delegate.model)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { delegate.checkForUpdates() }
            }
            // File: what the toolbar's Add and Export do.
            CommandGroup(replacing: .newItem) {
                Button("New Profile") { delegate.command(.newProfile) }
                    .keyboardShortcut("n")
                Button("Import Profile…") { delegate.command(.importProfile) }
                    .keyboardShortcut("o")
                Divider()
                Button("Export Profile…") { delegate.command(.exportProfile) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
            }
            // View: the sidebar's pages.
            CommandGroup(before: .sidebar) {
                Button("Monitor") { delegate.command(.showMonitor) }
                    .keyboardShortcut("1")
                Button("Logs") { delegate.command(.showLogs) }
                    .keyboardShortcut("2")
                Button("Active Profile") { delegate.command(.showActiveProfile) }
                    .keyboardShortcut("3")
                Divider()
            }
            CommandMenu("VPN") {
                VPNMenu(model: delegate.model)
            }
            CommandGroup(before: .windowList) {
                Button("Silent Route") { delegate.showMainWindow() }
                    .keyboardShortcut("0")
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Silent Route Help") { delegate.openHelp() }
            }
        }
    }
}

/// The VPN menu: the switch, with a label that says what it will do.
private struct VPNMenu: View {
    let model: AppModel

    var body: some View {
        Button(model.isOn ? "Turn VPN Off" : "Turn VPN On") {
            let on = !model.isOn
            Task { await model.setOn(on) }
        }
        .keyboardShortcut("t", modifiers: [.command, .shift])
        .disabled(!model.switchEnabled || model.busy || model.status.phase == .stopping)
        Divider()
        Button("Emergency Restore…") { AppDelegate.shared?.confirmEmergencyRestore() }
            .keyboardShortcut(.delete, modifiers: [.command, .shift])
            .disabled(!model.canTurnOff)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static weak var shared: AppDelegate?
    let model = AppModel(backend: XPCBackend())
    private var statusItem: NSStatusItem?
    private var panel: StatusPanel?
    private var mainWindow: NSWindow?
    private var updateWindow: NSWindow?
    private var launchedAtLogin = false
    private var ready = false
    private var pendingOpens: [URL] = []
    private var quitting = false

    /// A menu command for the main window: shown first, so it is there to act.
    func command(_ c: WindowCommand) {
        let fresh = mainWindow == nil
        showMainWindow()
        // A window made just now carries it out once its view has appeared.
        c.post(waitingForWindow: fresh)
    }

    func openHelp() {
        if let url = Updater.shared.helpPage { NSWorkspace.shared.open(url) }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.shared = self
        // Only valid while the launch event is being handled.
        launchedAtLogin = Self.launchedAsLoginItem
        Preferences.applyAppearance()
        Preferences.applyLogFolderSettings()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model.startPolling()
        setUpStatusItem()
        // Started at login: stay in the menu bar, no window.
        if !launchedAtLogin { showMainWindow() }
        ready = true
        flushPendingOpens()
        Updater.shared.startAutomaticChecks()
        watchUpdates()
        finishSelfUpdate()
    }

    /// Closing the window keeps the app (and its menu bar icon) running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Clicking the Dock icon brings the window back: the update window
    /// while an update runs (other windows may cover it), else the main one.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = updateWindow, w.isVisible {
            w.makeKeyAndOrderFront(nil)
        } else {
            showMainWindow()
        }
        return true
    }

    // MARK: Quitting

    /// By default quitting turns the VPN off, after asking. Logout and
    /// shutdown don't ask; relaunching into an update leaves it as it is
    /// (the new version reconnects behind the kill switch).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitting || Updater.shared.relaunching || Preferences.quit == .keepRunning { return .terminateNow }
        let s = model.status
        guard model.canTurnOff, s.phase != .off || s.killSwitchOn else { return .terminateNow }
        if !Self.isSystemQuit {
            panel?.dismiss()
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Quit Silent Route?"
            alert.informativeText = "The VPN turns off and the network goes back to normal.\n\nTo keep the VPN running without the app, change this in Settings."
            alert.addButton(withTitle: "Disconnect and Quit")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        quitting = true
        // Wait for the helper, but never hang the quit on it.
        let reply = OneShot { sender.reply(toApplicationShouldTerminate: true) }
        Task {
            await model.setOn(false)
            reply.fire()
        }
        Task {
            try? await Task.sleep(for: .seconds(10))
            reply.fire()
        }
        return .terminateLater
    }

    /// Logout, restart or shutdown asked the app to quit.
    static var isSystemQuit: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent,
              e.eventClass == kCoreEventClass, e.eventID == kAEQuitApplication else { return false }
        return e.attributeDescriptor(forKeyword: kAEQuitReason) != nil
    }

    // MARK: Main window

    static let defaultWidth: CGFloat = 1040

    func showMainWindow() {
        panel?.dismiss()
        if mainWindow == nil {
            let host = NSHostingController(rootView: MainWindow(model: model).frame(minWidth: 780, minHeight: 540))
            host.sceneBridgingOptions = [.toolbars, .title]
            let w = NSWindow(contentViewController: host)
            w.title = "Silent Route"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.setContentSize(NSSize(width: Self.defaultWidth, height: 680))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("SilentRouteMain")
            if !w.setFrameUsingName("SilentRouteMain") {
                w.center()
            } else if w.contentRect(forFrameRect: w.frame).width == 1000 {
                // Still the earlier default size (never resized): the new
                // default, a little wider, about the same centre.
                var f = w.frame
                f.origin.x -= (Self.defaultWidth - 1000) / 2
                f.size.width += Self.defaultWidth - 1000
                w.setFrame(f, display: false)
            }
            mainWindow = w
        }
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Status item

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.target = self
        item.button?.action = #selector(statusItemClicked)
        // Both buttons open it: right-click is how many people reach a
        // menu bar item.
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        statusItem = item

        let root = MenuBarView(model: model) { [weak self] in self?.showMainWindow() }
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] _ in
                self?.panel?.refit()
            }
        panel = StatusPanel(rootView: root)
        updateIcon()
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem?.button else { return }
        panel?.toggle(below: button)
    }

    /// Re-renders the icon whenever the state it shows changes. Connected:
    /// the same planet, in blue.
    private func updateIcon() {
        let (symbol, blue) = withObservationTracking {
            (model.statusSymbol, model.statusIconIsBlue)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateIcon() }
        }
        var image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Silent Route")
        if blue {
            image = image?.withSymbolConfiguration(.init(paletteColors: [.systemBlue]))
            image?.isTemplate = false
        } else {
            image?.isTemplate = true
        }
        statusItem?.button?.image = image
    }

    // MARK: Emergency restore and updates from the menu

    func confirmEmergencyRestore() {
        guard model.canTurnOff else { return }
        panel?.dismiss()
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Emergency Restore?"
        alert.informativeText = "The VPN turns off, all blocking is lifted and routing is repaired."
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await model.panic() }
    }

    func checkForUpdates() {
        Task {
            let updater = Updater.shared
            await updater.check()
            NSApp.activate(ignoringOtherApps: true)
            switch updater.state {
            case .available(let r):
                let alert = NSAlert()
                alert.messageText = "Silent Route \(r.version) is available"
                alert.informativeText = "You have \(updater.currentVersion). Profiles are kept. macOS asks for an administrator password to update the helper."
                alert.addButton(withTitle: "Install and Relaunch")
                alert.addButton(withTitle: "Later")
                if alert.runModal() == .alertFirstButtonReturn { await updater.install() }
                if case .failed(let why) = updater.state { Self.inform(why) }
            case .upToDate:
                Self.inform("Silent Route \(updater.currentVersion) is the latest version.")
            case .failed(let why):
                Self.inform(why)
            default:
                break
            }
        }
    }

    private static func inform(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.runModal()
    }

    /// Relaunched by the updater. The helper was updated before the
    /// relaunch, and the VPN (if it was on) is coming back by itself: the
    /// update's window stays until it is. A helper still from another
    /// version (none was installed then, or that step failed) is updated now.
    private func finishSelfUpdate() {
        let key = Updater.pendingHelperUpdateKey
        guard UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.removeObject(forKey: key)
        Task {
            // Where the helper stands now, asked rather than waited for.
            await model.refresh()
            if model.helperOutdated { await model.installHelper() }
            if [.connecting, .reconnecting].contains(model.status.phase) { Updater.shared.resuming = true }
        }
    }

    // MARK: Update window

    /// Shown while an update runs, while the VPN comes back after it, and
    /// when the helper could not be updated.
    private func watchUpdates() {
        let (wanted, phase) = withObservationTracking {
            (UpdateWindowView.wanted(Updater.shared), model.status.phase)
        } onChange: { [weak self] in
            Task { @MainActor in self?.watchUpdates() }
        }
        let updater = Updater.shared
        if updater.resuming, phase == .connected || phase == .off {
            updater.resuming = false
            return
        }
        if wanted { showUpdateWindow() } else { updateWindow?.orderOut(nil) }
    }

    private func showUpdateWindow() {
        if updateWindow == nil {
            let host = NSHostingController(rootView: UpdateWindowView(updater: .shared, model: model))
            host.sizingOptions = .preferredContentSize
            // No close button: it closes when there is nothing left to show.
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.title = "Silent Route Update"
            w.isReleasedWhenClosed = false
            w.center()
            updateWindow = w
        }
        guard updateWindow?.isVisible == false else { return }
        panel?.dismiss()
        updateWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Files from Finder

    /// A .srprofile double-clicked in Finder, or dropped on the Dock icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        pendingOpens += urls
        if ready { flushPendingOpens() }
    }

    private func flushPendingOpens() {
        guard !pendingOpens.isEmpty else { return }
        let urls = pendingOpens
        pendingOpens = []
        showMainWindow()
        Task {
            for u in urls { _ = await model.importFile(u) }
        }
    }

    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return event.eventID == kAEOpenApplication
            && event.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

/// Runs its action once, however many times it is fired.
@MainActor
private final class OneShot {
    private var action: (() -> Void)?
    init(_ action: @escaping () -> Void) { self.action = action }
    func fire() {
        action?()
        action = nil
    }
}
