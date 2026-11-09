import AppKit
@testable import SilentRouteUI
import SwiftUI
import VPNCore
import VPNIPC

// Renders the UI offscreen into PNGs for layout review — no screen-recording
// permission needed. Debug builds only (uses @testable import).
//
//   swift run ui-snapshots [output-dir]      default: build/snapshots

struct FakeBackend: HelperBackend {
    var isInstalled: Bool { true }
    func send(_ request: IPC.Request) async throws -> IPC.Response { IPC.Response() }
}

// MARK: Sample data (fictitious servers)

let nl = Tunnel(name: "Netherlands", server: Endpoint(host: "nl.example.org", port: 443),
                proto: .hysteria2(Hysteria2(password: "x", tls: TLS(serverName: "nl.example.org"))))
let de = Tunnel(name: "Germany Reality", server: Endpoint(host: "203.0.113.10", port: 443),
                proto: .vless(VLESS(uuid: UUID(), flow: "xtls-rprx-vision",
                                    tls: TLS(serverName: "www.example.com", fingerprint: "chrome",
                                             reality: .init(publicKey: String(repeating: "A", count: 43), shortID: "ab")))))
let lv = Tunnel(name: "Backup Proxy", server: Endpoint(host: "198.51.100.7", port: 8000),
                proto: .proxy(Proxy(kind: .socks5, username: "u", password: "p")))

let ai = Route(name: "Claude and OpenAI", conditions: Conditions(
    destinations: [.domainSuffix("claude.ai"), .domainSuffix("anthropic.com"), .domainSuffix("openai.com"), .domainSuffix("chatgpt.com")],
    apps: [.bundle(path: "/Applications/Claude.app")]), target: .servers([de.id]))
let streaming = Route(name: "Streaming", conditions: Conditions(destinations: [.domainSuffix("video.example"), .domainKeyword("stream")]),
                  target: .servers([lv.id, nl.id, de.id]), killSwitch: false)
let home: Profile = {
    var p = Profile(name: "Home", tunnels: [nl, de, lv])
    p.routes = [
        Route(name: "Domestic", conditions: Conditions(destinations: [.geoIP("cn"), .domainSuffix("cn")]), target: .direct),
        ai, streaming,
        Route(name: "Torrents", enabled: false,
              conditions: Conditions(apps: [.processName("transmission")], ports: [PortRange(6881, 6889)]), target: .direct),
        Route(name: "Ads", conditions: Conditions(destinations: [.domainKeyword("adservice")]), target: .block),
    ]
    p.defaultRoute = Route.everythingElse(servers: [nl.id, lv.id])
    return p
}()
let work = Profile.example(name: "Work", tunnels: [nl])
let empty = Profile(name: "Draft")
let library = ProfileLibrary(profiles: [home, work, empty], activeID: home.id)

/// Netherlands is down: "Everything else" runs through the backup proxy; Streaming is on
/// its first server, the proxy; Claude/OpenAI on Germany.
let connected = VPNStatus(phase: .connected, connectedSince: Date().addingTimeInterval(-4330), killSwitchOn: true,
                          servers: [ServerState(id: nl.id, latencyMs: nil), ServerState(id: de.id, latencyMs: 84),
                                    ServerState(id: lv.id, latencyMs: 132)],
                          routes: [RouteState(id: home.defaultRoute.id, via: .server(lv.id)),
                                   RouteState(id: ai.id, via: .server(de.id)),
                                   RouteState(id: streaming.id, via: .server(lv.id))])
let reconnecting = VPNStatus(phase: .reconnecting, killSwitchOn: true, lastError: "no server answers", reconnectAttempts: 3)
let speed = Speed(down: 2_516_582, up: 184_320)

@MainActor func model(_ helper: AppModel.HelperState = .ready, _ status: VPNStatus = VPNStatus(phase: .off),
                      _ lib: ProfileLibrary = library, speed: Speed? = nil, notice: AppModel.Notice? = nil) -> AppModel {
    AppModel(preview: FakeBackend(), helper: helper, status: status, library: lib, speed: speed,
             session: speed.map { _ in Speed(down: 1_932_735_283, up: 88_080_384) }, notice: notice,
             history: speed == nil ? SpeedHistory() : sampleHistory())
}

/// Forty minutes of a session, with a short reconnect in the middle.
func sampleHistory() -> SpeedHistory {
    var h = SpeedHistory()
    let now = Date()
    for i in 0..<2400 {
        let t = Double(i)
        let time = now.addingTimeInterval(t - 2400)
        if (1300..<1310).contains(i) {
            if i == 1300 { h.pause(at: time) }
            continue
        }
        h.add(Speed(down: Int64(900_000 + 700_000 * sin(t / 90) + Double((i * 7919) % 300_000)),
                    up: Int64(90_000 + 40_000 * cos(t / 70))), at: time)
    }
    return h
}

@MainActor func sampleMonitor() -> TrafficMonitor {
    let now = Date()
    func app(_ path: String) -> TrafficMonitor.AppRef { TrafficMonitor.app(path + " (user)") }
    let conns: [TrafficMonitor.Connection] = [
        .init(id: "1", app: app("/Applications/Safari.app/Contents/MacOS/Safari"), host: "www.youtube.com", port: "443", network: "TCP",
              route: "Everything else", exit: "Backup Proxy", viaFallback: true, start: now.addingTimeInterval(-340),
              download: 182_000_000, upload: 2_400_000, downRate: 1_830_000, upRate: 41_000),
        .init(id: "2", app: app("/Applications/Telegram.app/Contents/MacOS/Telegram"), host: "149.154.167.51", port: "443", network: "TCP",
              route: "Streaming", exit: "Backup Proxy", viaFallback: false, start: now.addingTimeInterval(-3900),
              download: 12_300_000, upload: 1_100_000, downRate: 12_000, upRate: 3_000),
        .init(id: "3", app: app("/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper"),
              host: "claude.ai", port: "443", network: "TCP", route: "Claude and OpenAI", exit: "Germany Reality", viaFallback: false, start: now.addingTimeInterval(-1200), download: 4_200_000, upload: 800_000, downRate: 2_100, upRate: 900),
        .init(id: "4", app: app("/usr/bin/curl"), host: "ipinfo.io", port: "443", network: "TCP", route: "Everything else", exit: "Backup Proxy", viaFallback: true, start: now.addingTimeInterval(-3), download: 4_581, upload: 550),
        .init(id: "5", app: app("/Applications/Safari.app/Contents/MacOS/Safari"), host: "news.example.cn", port: "443", network: "UDP",
              route: "Domestic", exit: "Direct", viaFallback: false, start: now.addingTimeInterval(-61),
              download: 3_100_000, upload: 120_000, downRate: 88_000, upRate: 4_000),
    ]
    return TrafficMonitor(preview: conns)
}

/// Two fictitious sessions in a temporary folder.
func sampleLogs() -> LogStore {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("sr-snapshot-logs-\(UUID().uuidString)")
    let dir = base.appendingPathComponent(SessionLogFormat.unindexed)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let now = Date()
    let live = """
    # Silent Route session · profile: Home
    2026-10-14 12:03:09 [helper] VPN turned on
    2026-10-14 12:03:11 [helper] connected
    +0000 2026-10-14 12:40:02 WARN inbound/tun[tun-in]: link icmp connection from 172.19.0.5 to 192.0.2.1: icmp is not supported
    2026-10-14 13:10:44 [helper] the Mac woke from sleep
    +0000 2026-10-14 13:10:45 ERROR connection: open connection to 198.51.100.7:8000 using outbound/socks: i/o timeout
    2026-10-14 13:10:51 [helper] route “Streaming”: now through “Netherlands”
    2026-10-14 13:11:20 [helper] route “Streaming”: now through “Backup Proxy”

    """
    let old = "# Silent Route session · profile: Work\n2026-10-13 09:00:00 [helper] VPN turned on\n2026-10-13 11:30:00 [helper] session ended: turned off\n"
    try? live.write(to: dir.appendingPathComponent(SessionLogFormat.fileName(for: now.addingTimeInterval(-4330))), atomically: true, encoding: .utf8)
    try? old.write(to: dir.appendingPathComponent(SessionLogFormat.fileName(for: now.addingTimeInterval(-90_000))), atomically: true, encoding: .utf8)
    return LogStore(base: base)
}

// MARK: Rendering

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/snapshots")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

@MainActor
func render<V: View>(_ name: String, size: CGSize? = nil, _ view: V) {
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        let s = size ?? host.fittingSize
        window.setContentSize(s)
        host.frame = CGRect(origin: .zero, size: s)
        host.layoutSubtreeIfNeeded()
        // Let SwiftUI settle (async layout, .task, onAppear).
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = out.appendingPathComponent("\(name)-\(suffix).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
    }
}

/// A whole window, toolbar included, as the app hosts it.
@MainActor
func renderWindow<V: View>(_ name: String, size: CGSize, then step: (@MainActor () -> Void)? = nil, _ view: V) {
    for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        let host = NSHostingController(rootView: view)
        host.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.appearance = NSAppearance(named: appearance)
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let step {
            step()
            for _ in 0..<12 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        }
        guard let frame = window.contentView?.superview,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { continue }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        let url = out.appendingPathComponent("\(name)-\(suffix).png")
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print(url.path)
        window.orderOut(nil)
    }
}

MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)

    render("menu-off", MenuBarView(model: model()))
    render("menu-connected", MenuBarView(model: model(.ready, connected, speed: speed)))
    render("menu-reconnecting", MenuBarView(model: model(.ready, reconnecting)))
    render("menu-not-installed", MenuBarView(model: model(.notInstalled)))

    let win = CGSize(width: 1000, height: 700)
    render("window-routes", size: win, MainWindow(model: model(.ready, connected, speed: speed), selection: home.id))
    render("logs", size: CGSize(width: 900, height: 420), LogsView(model: model(.ready, connected), store: sampleLogs()))
    renderWindow("full-routes", size: win, MainWindow(model: model(.ready, connected, speed: speed), selection: home.id))
    renderWindow("full-monitor", size: win, MainWindow(model: model(.ready, connected, speed: speed), monitor: sampleMonitor()))
    renderWindow("full-monitor-then-profile", size: win, then: { WindowCommand.showActiveProfile.post() },
                 MainWindow(model: model(.ready, connected, speed: speed), monitor: sampleMonitor()))
    renderWindow("full-settings", size: CGSize(width: 600, height: 480), SettingsView(model: model(.ready, connected)))
    // Pinned: an app with traffic, and a site nothing goes to now.
    var pins = MonitorPins()
    pins.apps.pin(TrafficMonitor.app("/usr/bin/curl"))
    pins.destinations.pin(.init(app: TrafficMonitor.app("/Applications/Telegram.app/Contents/MacOS/Telegram"), host: "web.telegram.org"))
    pins.save()
    defer { UserDefaults.standard.removeObject(forKey: MonitorPins.defaultsKey) }
    renderWindow("full-monitor-pinned", size: win, MainWindow(model: model(.ready, connected, speed: speed), monitor: sampleMonitor()))
    render("monitor-connections-pinned", size: CGSize(width: 820, height: 560),
           MonitorView(model: model(.ready, connected, speed: speed), monitor: sampleMonitor(), mode: .connections))
    render("add-to-route-site", AddToRouteSheet(model: model(.ready, connected),
        subject: RouteSubject(app: TrafficMonitor.app("/Applications/Safari.app/Contents/MacOS/Safari"), host: "rr3.googlevideo.com")))
    render("add-to-route-app", AddToRouteSheet(model: model(.ready, connected),
        subject: RouteSubject(app: TrafficMonitor.app("/Applications/Telegram.app/Contents/MacOS/Telegram"))))
    render("window-monitor", size: win, MainWindow(model: model(.ready, connected, speed: speed), monitor: sampleMonitor()))
    for section in [ProfileEditor.Section.servers, .dns, .network] {
        render("editor-\(section)", size: CGSize(width: 760, height: 640),
               ProfileEditor(model: model(.ready, connected), saved: home, section: section))
    }
    render("editor-empty", size: CGSize(width: 760, height: 480), ProfileEditor(model: model(), saved: empty))
    render("window-not-installed", size: win, MainWindow(model: model(.notInstalled, VPNStatus(phase: .off), ProfileLibrary())))
    render("add-tunnel", AddServerSheet(draft: ServerDraft(de), isNew: false, profile: home) { _ in })
    render("add-proxy", AddServerSheet(draft: ServerDraft(kind: .proxy), isNew: true, profile: home) { _ in })
    render("settings", SettingsView(model: model(.ready, connected)))
    render("update-helper", UpdateWindowView(updater: .preview(stage: .helper, step: "Updating the helper — enter your password if macOS asks…"),
                                             model: model(.ready, connected)))
    render("update-failed", UpdateWindowView(updater: .preview(failure: "the new helper does not answer — restoring the previous version"),
                                             model: model(.ready, connected)))
    render("update-resuming", UpdateWindowView(updater: .preview(resuming: true), model: model(.ready, reconnecting)))
    render("route-editor", RouteEditor(route: streaming, profile: home, isNew: false, isDefault: false) { _ in })
}
