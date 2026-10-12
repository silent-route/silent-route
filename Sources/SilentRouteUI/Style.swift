import SwiftUI
import VPNCore

extension View {
    /// Liquid Glass on macOS 26; the closest material look on 14–15.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 16) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            self.background(.regularMaterial, in: .rect(cornerRadius: cornerRadius))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(.separator.opacity(0.6), lineWidth: 0.5))
        }
    }
}

/// How each state looks, in one place: menu bar icon, dot colour, wording.
struct PhaseLook {
    let status: VPNStatus
    let helper: AppModel.HelperState

    var symbol: String {
        guard helper == .ready else { return "globe.badge.chevron.backward" }
        switch status.phase {
        // The same planet on and off; connected only turns it blue.
        case .connected, .connecting, .stopping: return "globe"
        case .reconnecting: return "exclamationmark.arrow.triangle.2.circlepath"
        case .off: return status.killSwitchOn ? "lock.shield" : "globe"
        }
    }

    /// The planet's colour: blue while connected, otherwise as the state.
    var iconColor: Color {
        helper == .ready && status.phase == .connected ? .blue : (color == .green ? .secondary : color)
    }

    /// Connected: the status item shows the planet in blue instead of the
    /// usual menu bar template.
    var iconIsBlue: Bool { helper == .ready && status.phase == .connected }

    var color: Color {
        guard helper == .ready else { return .orange }
        switch status.phase {
        case .connected: return .green
        case .connecting, .stopping: return .yellow
        case .reconnecting: return .orange
        case .off: return status.killSwitchOn ? .orange : .secondary
        }
    }

    var title: String {
        switch helper {
        case .notInstalled: return "Helper not installed"
        case .broken: return "Helper not responding"
        case .unknown: return "…"
        case .ready: break
        }
        switch status.phase {
        case .connected: return "Connected"
        case .connecting: return "Connecting…"
        case .reconnecting: return "Reconnecting…"
        case .stopping: return "Disconnecting…"
        case .off: return status.killSwitchOn ? "Off — internet blocked" : "Off"
        }
    }

    /// One line under the title: why the state is what it is.
    var detail: String? {
        if case .broken(let why) = helper { return why }
        guard helper == .ready else { return nil }
        switch status.phase {
        case .reconnecting:
            var s = "Traffic is blocked until the tunnel is back"
            if status.reconnectAttempts > 0 { s += " · attempt \(status.reconnectAttempts)" }
            return s
        case .off where status.killSwitchOn:
            return "Blocking stays on until you connect or use Emergency Restore"
        default:
            return status.lastError.map(Text.sentence)
        }
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 9
    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5))
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .binary
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        f.zeroPadsFractionDigits = false
        f.allowsNonnumericFormatting = false     // "0 bytes", never "Zero bytes"
        return f.string(fromByteCount: n)
    }

    static func speed(_ bytesPerSecond: Int64) -> String { bytes(bytesPerSecond) + "/s" }

    /// 0:42, 12:05, 1:02:33
    static func uptime(since: Date, now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(since)))
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

enum Plural {
    static func count(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }
}

extension Text {
    /// Messages from the core start lowercase (they are also used inside
    /// sentences in the CLI); shown alone they start with a capital.
    static func sentence(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }
}

extension TunnelProtocol {
    var isProxy: Bool { if case .proxy = self { true } else { false } }
}

extension Tunnel {
    var kindSymbol: String { proto.isProxy ? "arrow.left.arrow.right.circle" : "lock.circle" }
    var address: String { "\(server.host):\(String(server.port))" }
}
