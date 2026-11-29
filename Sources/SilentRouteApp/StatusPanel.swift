import AppKit
import SilentRouteUI
import SwiftUI

/// The menu bar panel, placed the way macOS places its own (Wi-Fi, Control
/// Center): a plain rounded panel just under the menu bar, no arrow. It
/// grows to the right of its icon, or to the left when there is no room,
/// and never past the screen's edge. A click elsewhere or Esc closes it.
@MainActor
final class StatusPanel: NSPanel, NSWindowDelegate {
    /// Gap between the menu bar and the panel, and the margin it keeps from
    /// the screen's sides.
    private static let gap: CGFloat = 5
    private static let margin: CGFloat = 6
    static var cornerRadius: CGFloat {
        if #available(macOS 26, *) { 18 } else { 11 }
    }

    private let host: NSHostingView<AnyView>
    /// The Liquid Glass behind the content (macOS 26), for Transparency.
    private var glass: NSView?
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
    private var appSwitch: NSObjectProtocol?
    private var spaceSwitch: NSObjectProtocol?
    private var anchor: NSRect = .zero
    private var placing = false

    init(rootView: some View) {
        host = NSHostingView(rootView: AnyView(rootView))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        // Above windows, below the menus its pickers open.
        level = .statusBar
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
        // Opens on the desktop in front, and stays on it: one on every
        // desktop would show on the next one during a swipe, until the
        // switch is over and it closes.
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let (background, glass) = Self.background(around: host)
        contentView = background
        self.glass = glass
        delegate = self
    }

    override var canBecomeKey: Bool { true }

    var isOpen: Bool { isVisible }

    func toggle(below button: NSStatusBarButton) {
        isOpen ? dismiss() : show(below: button)
    }

    func show(below button: NSStatusBarButton) {
        guard let bw = button.window else { return }
        self.button = button
        anchor = bw.convertToScreen(button.convert(button.bounds, to: nil))
        applyTransparency()
        place()
        makeKeyAndOrderFront(nil)
        refreshShadow()
        button.highlight(true)
        watchOutsideClicks()
    }

    func dismiss() {
        guard isVisible else { return }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        if let o = appSwitch { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        if let o = spaceSwitch { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        appSwitch = nil
        spaceSwitch = nil
        orderOut(nil)
        button?.highlight(false)
    }

    // MARK: Placement

    /// Sizes the panel to its content and puts it under the icon.
    private func place() {
        guard !placing else { return }
        placing = true
        defer { placing = false }
        let size = host.fittingSize
        let screen = (NSScreen.screens.first { $0.frame.intersects(anchor) } ?? NSScreen.main)?.frame ?? .zero
        var x = anchor.minX                                     // grow to the right of the icon…
        if x + size.width > screen.maxX - Self.margin {
            x = anchor.maxX - size.width                        // …or to its left
        }
        x = min(max(x, screen.minX + Self.margin), screen.maxX - Self.margin - size.width)
        let y = anchor.minY - Self.gap - size.height
        setFrame(NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height), display: true)
    }

    /// Content grew or shrank (a notice, the restore confirmation): keep
    /// the top edge under the menu bar.
    func windowDidResize(_ notification: Notification) {
        if isVisible { place(); refreshShadow() }
    }

    /// The window's shadow follows the shape of what is drawn: worked out
    /// before the glass has rendered, it is a rectangle, and its dark
    /// corners show outside the rounded panel. Once drawn, it is redone.
    private func refreshShadow() {
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    func refit() {
        if isVisible { place() }
    }

    // MARK: Closing

    private func watchOutsideClicks() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        // Like the system's own menus: switching to another app (⌘Tab, the
        // Dock, Mission Control) closes it, not only a click elsewhere.
        if let o = appSwitch { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        appSwitch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            MainActor.assumeIsolated { self?.dismiss() }
        }
        // Another desktop (a swipe, Mission Control): close too.
        if let o = spaceSwitch { NSWorkspace.shared.notificationCenter.removeObserver(o) }
        spaceSwitch = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        // Other apps' windows and the desktop.
        if let g = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                     handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) { monitors.append(g) }
        // Our own other windows; the status button toggles by itself.
        if let l = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
                                                    handler: { [weak self] event in
            let window = event.window.map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self else { return }
                if window != ObjectIdentifier(self), window != self.button?.window.map(ObjectIdentifier.init) {
                    self.dismiss()
                }
            }
            return event
        }) { monitors.append(l) }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    /// Another window took the keyboard (ours or another app's): close, as a
    /// menu does. Menus the panel's own pickers open do not take it.
    func windowDidResignKey(_ notification: Notification) { dismiss() }

    // MARK: Background

    /// Settings › General › Transparency: the clear variant of Liquid Glass
    /// for "More" — the panel floats over the desktop, which is where Apple
    /// allows it.
    private func applyTransparency() {
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.style = Preferences.transparency == .more ? .clear : .regular
        }
        refreshShadow()
    }

    /// Liquid Glass on macOS 26; the menu material with rounded corners on
    /// 14–15. The glass sits in a container clipped to the same rounded
    /// shape, so nothing it draws reaches past the corners.
    private static func background(around content: NSView) -> (NSView, glass: NSView?) {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            let clip = NSView()
            clip.wantsLayer = true
            clip.layer?.backgroundColor = NSColor.clear.cgColor
            clip.layer?.cornerRadius = cornerRadius
            clip.layer?.cornerCurve = .continuous
            clip.layer?.masksToBounds = true
            glass.translatesAutoresizingMaskIntoConstraints = false
            clip.addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                glass.topAnchor.constraint(equalTo: clip.topAnchor),
                glass.bottomAnchor.constraint(equalTo: clip.bottomAnchor),
            ])
            return (clip, glass)
        }
        let fx = NSVisualEffectView()
        fx.material = .popover
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.maskImage = roundedMask(cornerRadius)
        content.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            content.topAnchor.constraint(equalTo: fx.topAnchor),
            content.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        return (fx, nil)
    }

    private static func roundedMask(_ r: CGFloat) -> NSImage {
        let edge = 2 * r + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        image.resizingMode = .stretch
        return image
    }
}
