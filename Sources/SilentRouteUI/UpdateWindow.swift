import AppKit
import SwiftUI

/// The small window an update shows: its progress (with a way to stop it),
/// the VPN coming back after the relaunch, or a helper that could not be
/// updated (with a way to get the network back).
public struct UpdateWindowView: View {
    let updater: Updater
    let model: AppModel
    @State private var confirming = false

    public init(updater: Updater, model: AppModel) {
        self.updater = updater
        self.model = model
    }

    /// Whether there is anything to show.
    @MainActor public static func wanted(_ updater: Updater) -> Bool {
        updater.stage != nil || updater.helperFailure != nil || updater.resuming
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 10) {
                if let failure = updater.helperFailure {
                    failed(failure)
                } else if updater.stage != nil {
                    if confirming { confirmStop } else { installing }
                } else {
                    if confirming { confirmOff } else { reconnecting }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: updater.stage) { _, new in if new != .helper { confirming = false } }
    }

    // MARK: Installing

    @ViewBuilder
    private var installing: some View {
        Text("Updating Silent Route").font(.headline)
        Text(stepText).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ProgressView().progressViewStyle(.linear)
        if updater.stage == .helper && model.isOn && !updater.stopping {
            Text("While the helper is replaced, traffic outside the VPN stays blocked. The VPN comes back by itself.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack {
            Spacer()
            switch updater.stage {
            case .preparing:
                Button("Cancel") { updater.cancel() }
                    .keyboardShortcut(.cancelAction)
            case .helper where model.isOn && !updater.stopping:
                Button("Cancel…") { confirming = true }
                    .keyboardShortcut(.cancelAction)
            default:
                EmptyView()
            }
        }
    }

    private var stepText: String {
        if case .installing(let step) = updater.state { return step }
        return "Preparing…"
    }

    @ViewBuilder
    private var confirmStop: some View {
        Text("Stop the Update?").font(.headline)
        Text("The VPN turns off and the network goes back to normal: your traffic is no longer protected by the VPN. The helper being replaced right now finishes first — this takes a few seconds.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Continue Update") { confirming = false }
                .keyboardShortcut(.cancelAction)
            Button("Stop and Restore Network", role: .destructive) {
                confirming = false
                updater.cancel()
            }
        }
    }

    // MARK: After the relaunch

    @ViewBuilder
    private var reconnecting: some View {
        Text("Silent Route Is Updated").font(.headline)
        Text("Reconnecting the VPN… Until it is back, traffic outside the VPN stays blocked.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        ProgressView().progressViewStyle(.linear)
        HStack {
            Button("Turn VPN Off…") { confirming = true }
            Spacer()
            Button("Hide") { updater.resuming = false }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var confirmOff: some View {
        Text("Turn the VPN Off?").font(.headline)
        Text("The network goes back to normal: your traffic is no longer protected by the VPN.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        HStack {
            Spacer()
            Button("Keep Waiting") { confirming = false }
                .keyboardShortcut(.cancelAction)
            Button("Turn Off", role: .destructive) {
                confirming = false
                Task {
                    await model.setOn(false)
                    updater.resuming = false
                }
            }
        }
    }

    // MARK: Failure

    @ViewBuilder
    private func failed(_ f: Updater.HelperFailure) -> some View {
        Text("The Helper Could Not Be Updated").font(.headline)
        Text(f.helperRunning
             ? "The previous version is running again, so nothing has changed. If the VPN does not come back, restore the network: the VPN turns off and nothing stays blocked."
             : "No helper is running now. If the VPN was on, traffic outside it stays blocked until you restore the network or restart the Mac. Restoring turns the VPN off; macOS asks for your password.")
            .font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(f.message)
            .font(.caption).foregroundStyle(.secondary)
            .lineLimit(4)
            .textSelection(.enabled)
        HStack {
            if updater.restoring { ProgressView().controlSize(.small) }
            Spacer()
            Button("Close") { updater.dismissHelperFailure() }
                .keyboardShortcut(.cancelAction)
                .disabled(updater.restoring)
            Button("Restore Network") { Task { await updater.restoreNetwork() } }
                .keyboardShortcut(.defaultAction)
                .disabled(updater.restoring)
        }
    }
}
