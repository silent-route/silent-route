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
        Image(systemName: PhaseLook(status: model.status, helper: model.helper, otherUser: model.otherUsersVPN).symbol)
            .accessibilityLabel("Silent Route")
    }
}

/// The top of the menu bar item's menu (`StatusMenu`): the state, the
/// switch, and while connected the time and traffic. The rest of the menu
/// is plain menu items.
public struct MenuBarHeader: View {
    let model: AppModel

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        header(PhaseLook(status: model.status, helper: model.helper, otherUser: model.otherUsersVPN))
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(width: StatusMenu.width, alignment: .leading)
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
                    .disabled(!model.switchEnabled || model.busy || model.status.phase == .stopping)
            }
            if let d = look.detail {
                Text(d)
                    .font(.caption)
                    .foregroundStyle(model.status.phase == .reconnecting ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.status.phase == .connected {
                HStack(spacing: 14) {
                    if let since = model.uptimeSince {
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
        if model.helper == .ready, !model.otherUsersVPN, let p = model.activeProfile,
           model.status.phase != .off || !model.status.killSwitchOn {
            parts.append(p.name)
        }
        return parts.joined(separator: " · ")
    }
}
