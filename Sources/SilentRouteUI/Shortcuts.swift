import AppKit
import Carbon.HIToolbox
import SwiftUI

/// A key with modifiers, as Settings lets the user choose it. Stored as
/// text ("shift+cmd+s"); the key is the one a US keyboard has there, as
/// the Mac's menus match ⌘ shortcuts on any keyboard layout.
public struct KeyShortcut: Hashable, Sendable {
    /// One printable character, lowercase: "s", "1", ",".
    public var key: String
    public var control = false
    public var option = false
    public var shift = false
    public var command = false

    public init?(_ text: String) {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, Self.isValidKey(key) else { return nil }
        self.key = key
        for m in parts.dropLast() {
            switch m {
            case "ctrl": control = true
            case "opt": option = true
            case "shift": shift = true
            case "cmd": command = true
            default: return nil
            }
        }
        // Without ⌘ or ⌃ it would be typed into text fields instead.
        guard command || control else { return nil }
    }

    public var text: String {
        ([control ? "ctrl" : nil, option ? "opt" : nil, shift ? "shift" : nil, command ? "cmd" : nil]
            .compactMap { $0 } + [key]).joined(separator: "+")
    }

    /// As menus show it: ⌃⌥⇧⌘S.
    public var symbols: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + key.uppercased()
    }

    var keyboardShortcut: KeyboardShortcut {
        var m: SwiftUI.EventModifiers = []
        if control { m.insert(.control) }
        if option { m.insert(.option) }
        if shift { m.insert(.shift) }
        if command { m.insert(.command) }
        return KeyboardShortcut(KeyEquivalent(Character(key)), modifiers: m)
    }

    static func isValidKey(_ key: String) -> Bool {
        guard key.count == 1, let c = key.unicodeScalars.first, key.unicodeScalars.count == 1 else { return false }
        return c.isASCII && c.value > 0x20 && c.value < 0x7f && key == key.lowercased()
    }

    /// A key typed in the recorder; nil for keys a shortcut cannot use
    /// (arrows, function keys, Space…).
    @MainActor static func from(_ event: NSEvent) -> KeyShortcut? {
        guard let key = asciiKey(event.keyCode) else { return nil }
        let f = event.modifierFlags
        var parts: [String] = []
        if f.contains(.control) { parts.append("ctrl") }
        if f.contains(.option) { parts.append("opt") }
        if f.contains(.shift) { parts.append("shift") }
        if f.contains(.command) { parts.append("cmd") }
        return KeyShortcut((parts + [key]).joined(separator: "+"))
    }

    /// The character of a key on the user's ASCII keyboard layout (on a
    /// Greek keyboard, the S key is "s", not "σ").
    @MainActor static func asciiKey(_ code: UInt16) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let layout = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(layout).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base, code, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let key = String(utf16CodeUnits: chars, count: length).lowercased()
        return isValidKey(key) ? key : nil
    }
}

/// Menu commands whose shortcuts the user may change.
public enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case saveProfile, revertProfile
    public var id: Self { self }

    public var title: String {
        switch self {
        case .saveProfile: "Save Profile"
        case .revertProfile: "Revert Profile"
        }
    }

    public var defaultShortcut: KeyShortcut {
        switch self {
        case .saveProfile: KeyShortcut("shift+cmd+s")!
        case .revertProfile: KeyShortcut("shift+cmd+r")!
        }
    }

    public var defaultsKey: String { "shortcut." + rawValue }

    /// The user's choice: the default until they change it, nil once they
    /// remove it (stored as "").
    @MainActor public var shortcut: KeyShortcut? { Self.shortcut(from: UserDefaults.standard.string(forKey: defaultsKey), for: self) }

    static func shortcut(from stored: String?, for action: ShortcutAction) -> KeyShortcut? {
        guard let stored else { return action.defaultShortcut }
        if stored.isEmpty { return nil }
        return KeyShortcut(stored) ?? action.defaultShortcut
    }

    /// The app's other shortcuts, and macOS's standard ones in every app:
    /// a choice must not take one of them.
    static let taken: [String: String] = [
        "cmd+n": "New Profile", "cmd+o": "Import Profile", "shift+cmd+e": "Export Profile",
        "cmd+1": "Monitor", "cmd+2": "Logs", "cmd+3": "Active Profile", "cmd+0": "the Silent Route window",
        "shift+cmd+t": "Turn VPN On/Off", "cmd+,": "Settings",
        "cmd+q": "Quit", "cmd+h": "Hide", "opt+cmd+h": "Hide Others", "cmd+w": "Close", "cmd+m": "Minimize",
        "cmd+z": "Undo", "shift+cmd+z": "Redo", "cmd+x": "Cut", "cmd+c": "Copy", "cmd+v": "Paste",
        "cmd+a": "Select All", "cmd+f": "Find", "ctrl+cmd+f": "Full Screen", "ctrl+cmd+s": "Show Sidebar",
        "cmd+`": "switching windows", "shift+cmd+/": "Help",
    ]

    /// Who already has this shortcut, if anyone.
    @MainActor func conflict(_ s: KeyShortcut) -> String? {
        if let name = Self.taken[s.text] { return name }
        return Self.allCases.first { $0 != self && $0.shortcut == s }?.title
    }
}

/// Click, then type the new shortcut. Esc keeps the old one, Delete
/// removes it.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    /// Nil until the user chooses: the default stays the default even if
    /// it changes in a later version.
    @AppStorage private var stored: String?
    @State private var recording = false
    @State private var monitor: Any?
    @State private var problem: String?

    init(_ action: ShortcutAction) {
        self.action = action
        _stored = AppStorage(action.defaultsKey)
    }

    private var current: KeyShortcut? { ShortcutAction.shortcut(from: stored, for: action) }

    var body: some View {
        LabeledContent(action.title) {
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    if current != action.defaultShortcut, !recording {
                        Button("Default") { stored = nil; problem = nil }
                            .controlSize(.small)
                            .help("Back to \(action.defaultShortcut.symbols)")
                    }
                    Button { recording ? stop() : start() } label: {
                        Text(recording ? "Type KeyShortcut…" : current?.symbols ?? "None")
                            .monospacedDigit()
                            .frame(minWidth: 96)
                    }
                    .help(recording ? "Type the new shortcut. Esc: keep it as it is. Delete: none."
                                    : "Click, then type a new shortcut")
                }
                if let problem {
                    Text(problem).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        problem = nil
        recording = true
        guard monitor == nil else { return }
        // Keys typed in Settings only: typing in another window ends it.
        let window = NSApp.keyWindow
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let taken = MainActor.assumeIsolated {
                guard event.window === window else {
                    stop()
                    return false
                }
                handle(event)
                return true
            }
            return taken ? nil : event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }

    private func handle(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch Int(event.keyCode) {
        case kVK_Escape where mods.isEmpty:
            stop()
            return
        case kVK_Delete where mods.isEmpty, kVK_ForwardDelete where mods.isEmpty:
            stored = ""
            problem = nil
            stop()
            return
        default:
            break
        }
        guard let s = KeyShortcut.from(event) else {
            problem = "Use ⌘ or ⌃ with a letter, digit or sign"
            return
        }
        if let owner = action.conflict(s) {
            problem = "\(s.symbols) is \(owner)’s shortcut"
            return
        }
        stored = s.text
        problem = nil
        stop()
    }
}

/// File › Save Profile and Revert Profile…: for the profile the window
/// shows, with the shortcuts chosen in Settings.
public struct ProfileEditCommands: View {
    let model: AppModel
    let perform: (WindowCommand) -> Void
    @AppStorage(ShortcutAction.saveProfile.defaultsKey) private var save: String?
    @AppStorage(ShortcutAction.revertProfile.defaultsKey) private var revert: String?

    public init(model: AppModel, perform: @escaping (WindowCommand) -> Void) {
        self.model = model
        self.perform = perform
    }

    public var body: some View {
        let edited = model.shownProfile.map(model.hasUnsavedChanges) ?? false
        Button("Save Profile") { perform(.saveProfile) }
            .keyboardShortcut(ShortcutAction.shortcut(from: save, for: .saveProfile)?.keyboardShortcut)
            .disabled(!edited || model.busy)
        Button("Revert Profile…") { perform(.revertProfile) }
            .keyboardShortcut(ShortcutAction.shortcut(from: revert, for: .revertProfile)?.keyboardShortcut)
            .disabled(!edited)
    }
}
