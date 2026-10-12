import Foundation
import UserNotifications
import VPNCore

/// A macOS notification whenever a route's traffic leaves its first server:
/// to the next one in its list, directly (no VPN), or blocked — and when it
/// is back on the first. With "all events" chosen in Settings, also when
/// the VPN connects, disconnects or loses its connection.
@MainActor
final class RouteNotifier {
    static let shared = RouteNotifier()
    private var asked = false

    func update(from old: VPNStatus, to new: VPNStatus, profile: Profile?) {
        if Preferences.notifications == .all, old.phase != new.phase {
            connection(from: old, to: new, profile: profile)
        }
        guard let profile, old.phase == .connected, new.phase == .connected else { return }
        let before = Dictionary(old.routes.map { ($0.id, $0.via) }, uniquingKeysWith: { a, _ in a })
        for r in new.routes {
            guard let was = before[r.id], was != r.via, let route = profile.route(r.id) else { continue }
            let first = profile.chain(of: route).first
            let firstName = first.flatMap(profile.tunnel)?.name ?? "its first server"
            switch r.via {
            case .server(let id) where id == first:
                post("\(route.name): back on \(firstName)", "Its traffic goes through \(firstName) again.")
            case .server(let id):
                let name = profile.tunnel(id)?.name ?? "another server"
                post("\(route.name): switched to \(name)", "\(firstName) is not answering. Your IP address for this traffic has changed.")
            case .direct:
                post("\(route.name): going direct", "No server in its list answers; its traffic now goes without VPN.")
            case .blocked:
                post("\(route.name): blocked", "No server in its list answers; the kill switch blocks its traffic until one does.")
            }
        }
    }

    /// Connecting, disconnecting, losing the connection. A profile switch
    /// passes through reconnecting too; it carries no error and stays quiet.
    private func connection(from old: VPNStatus, to new: VPNStatus, profile: Profile?) {
        let name = profile.map { "“\($0.name)”" } ?? "the profile"
        switch (old.phase, new.phase) {
        case (.reconnecting, .connected):
            post("VPN reconnected", "Connected again with \(name).")
        case (_, .connected):
            post("VPN connected", "Traffic follows the routes of \(name).")
        case (.connected, .reconnecting) where new.lastError != nil:
            post("VPN connection lost",
                 new.killSwitchOn ? "Reconnecting. Traffic is blocked until the connection is back."
                                  : "Reconnecting.")
        case (.connected, .off), (.reconnecting, .off), (.stopping, .off):
            post("VPN disconnected",
                 new.killSwitchOn ? "The internet stays blocked until you connect or use Emergency Restore."
                                  : "Traffic goes directly, without VPN.")
        default:
            break
        }
    }

    private func post(_ title: String, _ body: String) {
        // Notifications need an app bundle; the snapshot tool has none.
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        if !asked {
            asked = true
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
