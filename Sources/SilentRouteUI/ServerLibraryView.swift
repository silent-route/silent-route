import SwiftUI
import VPNCore

/// Servers kept on their own, to add to any profile: a profile takes a
/// copy, so changing one here leaves the profiles as they are.
struct ServerLibraryView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Server Library").font(.largeTitle.weight(.bold))
                    Text("Servers and proxies to add to any profile (Servers › Add Server › From Library). Add them here by hand or from a profile. A profile takes a copy: changing one here leaves the profiles as they are.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ServerList(title: "Servers", subtitle: "Checked the way the VPN reaches them: directly.",
                           servers: Binding(get: { model.library.servers }, set: { model.setServers($0) }),
                           check: model.helper == .ready ? { [model] t in try await model.probe(t) } : nil,
                           issues: { t in Validation.check(Profile(name: "Library", tunnels: model.library.servers)).filter { $0.tunnel == t.id } },
                           addItems: { fromProfile }, rowItems: { _ in EmptyView() })
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Add Server › From Profile › a profile › its server: a copy here, as
    /// a profile's server menu does with Add to Library.
    @ViewBuilder
    private var fromProfile: some View {
        let profiles = model.library.profiles.filter { !$0.tunnels.isEmpty }
        Divider()
        Menu("From Profile") {
            ForEach(profiles) { p in
                Menu(p.name) {
                    ForEach(p.tunnels) { t in
                        Button("\(t.name) — \(t.proto.displayName)") { model.addToLibrary(t) }
                    }
                }
            }
        }
        .disabled(profiles.isEmpty)
    }
}
