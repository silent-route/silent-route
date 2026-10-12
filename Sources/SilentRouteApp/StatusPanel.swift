import AppKit
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
    private weak var button: NSStatusBarButton?
    private var monitors: [Any] = []
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
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        contentView = Self.background(around: host)
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
        place()
        makeKeyAndOrderFront(nil)
        button.highlight(true)
        watchOutsideClicks()
    }

    func dismiss() {
        guard isVisible else { return }
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
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
        if isVisible { place() }
    }

    func refit() {
        if isVisible { place() }
    }

    // MARK: Closing

    private func watchOutsideClicks() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
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

    // MARK: Background

    /// Liquid Glass on macOS 26; the menu material with rounded corners on 14–15.
    private static func background(around content: NSView) -> NSView {
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = cornerRadius
            glass.contentView = content
            return glass
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
        return fx
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
