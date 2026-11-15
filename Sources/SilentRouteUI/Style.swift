import SwiftUI
import VPNCore

extension View {
    /// A group in the content layer, drawn as System Settings draws its
    /// grouped sections: a light fill and a hairline. Liquid Glass belongs
    /// to the controls and navigation above the content, never to the
    /// content itself (Apple's Human Interface Guidelines, Materials).
    func contentCard(cornerRadius: CGFloat = 12) -> some View {
        background(Color.primary.opacity(0.035), in: .rect(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// How each state looks, in one place: menu bar icon, dot colour, wording.
struct PhaseLook {
    let status: VPNStatus
    let helper: AppModel.HelperState
    /// Turned on by another user of this Mac.
    var otherUser = false

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
        if otherUser, status.phase != .off { return "On — another user's VPN" }
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
        if otherUser, status.phase != .off {
            return "Another user of this Mac turned it on. You can turn it off; only they can change what it runs."
        }
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
    /// Short and of nearly constant width, so live numbers don't make
    /// their row jump: "900 B", "12 KB", "2.4 MB", "1.1 GB".
    static func bytes(_ n: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(max(0, n))
        var unit = 0
        while value >= 1000, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        let number = unit > 0 && value < 10
            ? value.formatted(.number.precision(.fractionLength(1)))
            : value.formatted(.number.precision(.fractionLength(0)).grouping(.never))
        return "\(number) \(units[unit])"
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

/// Children in a row, wrapping onto the next line when the row is full —
/// like words in a paragraph.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for i in row.items {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (i, v) in subviews.enumerated() {
            let size = v.sizeThatFits(.unspecified)
            let needed = row.items.isEmpty ? size.width : row.width + spacing + size.width
            if !row.items.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(i)
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}
