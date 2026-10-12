import AppKit
import SwiftUI

/// The app's own settings, kept in UserDefaults. Profiles (everything about
/// the network) live in the helper; these are only about the app.
public enum Preferences {
    public static let appearanceKey = "appearance"
    public static let quitKey = "quitBehavior"
    public static let checkUpdatesKey = "checkForUpdates"
    public static let notificationsKey = "notifications"

    public enum Appearance: String, CaseIterable, Identifiable, Sendable {
        case system, light, dark
        public var id: Self { self }
        var title: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }
    }

    /// What quitting the app does to the VPN.
    public enum Quit: String, CaseIterable, Identifiable, Sendable {
        /// Turn the VPN off and leave the network as it was (asks first).
        case disconnect
        /// The helper keeps the VPN running without the app.
        case keepRunning
        public var id: Self { self }
    }

    /// Which events become macOS notifications.
    public enum Notifications: String, CaseIterable, Identifiable, Sendable {
        /// A route moves to a backup server, goes direct, is blocked, or
        /// comes back.
        case routes
        /// The above, plus connecting, disconnecting and losing the
        /// connection.
        case all
        public var id: Self { self }
    }

    @MainActor public static var notifications: Notifications {
        UserDefaults.standard.string(forKey: notificationsKey).flatMap(Notifications.init) ?? .routes
    }

    @MainActor public static var appearance: Appearance {
        UserDefaults.standard.string(forKey: appearanceKey).flatMap(Appearance.init) ?? .system
    }

    @MainActor public static var quit: Quit {
        UserDefaults.standard.string(forKey: quitKey).flatMap(Quit.init) ?? .disconnect
    }

    @MainActor public static var checkForUpdates: Bool {
        UserDefaults.standard.object(forKey: checkUpdatesKey) as? Bool ?? true
    }

    /// Applies the chosen theme to every window, the menu bar panel included.
    @MainActor public static func applyAppearance(_ a: Appearance = appearance) {
        switch a {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}
