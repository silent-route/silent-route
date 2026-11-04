import AppKit
import Network
import SwiftUI
import VPNCore
import WebKit

/// The login page of a hotel or café Wi-Fi, while the VPN waits behind its
/// kill switch. This window's traffic — and nothing else on the Mac — goes
/// out directly, through sing-box's login-page proxy (localhost, with a
/// per-start password only the VPN's owner gets). It keeps no cookies or
/// history. Once the servers answer, the VPN carries on as before.
@MainActor
public final class CaptiveLoginWindow: NSObject, NSWindowDelegate {
    public static let shared = CaptiveLoginWindow()
    private var window: NSWindow?

    public func show(model: AppModel) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        Task {
            guard let proxy = await model.captiveProxy() else {
                model.notice = .init("The Wi-Fi login is no longer pending", isError: false)
                return
            }
            let host = NSHostingController(rootView: CaptiveLoginView(model: model, proxy: proxy) { [weak self] in
                self?.window?.close()
            })
            let w = NSWindow(contentViewController: host)
            w.title = "Wi-Fi Login"
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            w.setContentSize(NSSize(width: 820, height: 640))
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
            w.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    public func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

struct CaptiveLoginView: View {
    let model: AppModel
    let proxy: SingBoxConfig.LocalProxy
    let close: () -> Void
    @State private var address = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "lock.shield").foregroundStyle(.secondary)
                Text(address.isEmpty ? "Loading the login page…" : address)
                    .lineLimit(1).truncationMode(.middle)
                    .foregroundStyle(.secondary).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(10)
            Divider()
            if model.status.captivePortal || model.status.phase != .connected {
                Label("Only this window reaches the network directly. Everything else stays blocked until you have logged in and Silent Route is connected again.",
                      systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            } else {
                Label("You're online, and Silent Route is connected again. You can close this window.", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(.green)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            LoginWebView(proxy: proxy, address: $address)
        }
    }
}

/// A web view whose every connection goes through the login-page proxy.
struct LoginWebView: NSViewRepresentable {
    let proxy: SingBoxConfig.LocalProxy
    @Binding var address: String

    /// Apple's own check page: a network that wants a login redirects it to
    /// its login page.
    static let start = URL(string: "http://captive.apple.com/hotspot-detect.html")!

    func makeNSView(context: Context) -> WKWebView {
        let store = WKWebsiteDataStore.nonPersistent()
        let socks = ProxyConfiguration(socksv5Proxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxy.port)!))
        socks.applyCredential(username: proxy.username, password: proxy.password)
        store.proxyConfigurations = [socks]
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.load(URLRequest(url: Self.start))
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(address: $address) }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var address: Binding<String>
        init(address: Binding<String>) { self.address = address }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            address.wrappedValue = webView.url?.absoluteString ?? ""
        }
    }
}

/// "This Wi-Fi needs a login", where the VPN's state is shown.
struct CaptiveBanner: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This Wi-Fi needs a login", systemImage: "wifi.exclamationmark")
                .font(.callout.weight(.semibold))
            Text("Everything stays blocked until you log in. Only the login window goes out directly.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Login Page") { CaptiveLoginWindow.shared.show(model: model) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
