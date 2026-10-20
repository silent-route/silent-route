import Charts
import SwiftUI
import VPNCore

/// Live traffic, like Activity Monitor's Network tab: speed over the last
/// two minutes, then traffic by app or connection by connection, each with
/// the exit it leaves through.
struct MonitorView: View {
    let model: AppModel
    let monitor: TrafficMonitor
    @State private var view: Mode = .apps
    @State private var search = ""
    @State private var connOrder = [KeyPathComparator(\TrafficMonitor.Connection.downRate, order: .reverse)]

    enum Mode: String, CaseIterable, Identifiable {
        case apps = "Apps", connections = "Connections"
        var id: Self { self }
    }

    var body: some View {
        Group {
            if model.otherUsersVPN {
                ContentUnavailableView("Another user's VPN", systemImage: "person.2",
                                       description: Text("Another user of this Mac turned the VPN on. Its traffic is shown only to them."))
            } else if model.status.phase == .connected || !monitor.connections.isEmpty {
                content
            } else {
                ContentUnavailableView("Not connected", systemImage: "chart.xyaxis.line",
                                       description: Text("Turn the VPN on to see live traffic: which apps talk to which sites, by which route and server."))
            }
        }
        .navigationTitle("Monitor")
    }

    private var content: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                stat("Download", Format.speed(monitor.current?.down ?? 0), "arrow.down", .blue)
                stat("Upload", Format.speed(monitor.current?.up ?? 0), "arrow.up", .orange)
                stat("Connections", "\(monitor.connections.count)", "link", .secondary)
                stat("This session", "↓ \(Format.bytes(monitor.downloadTotal))  ↑ \(Format.bytes(monitor.uploadTotal))", "sum", .secondary)
            }
            chart
                .frame(height: 140)
                .padding(14)
                .glassCard(cornerRadius: 14)
            HStack {
                Picker("", selection: $view) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                TextField("", text: $search, prompt: Text("Filter by app, site, route or server"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            if let p = monitor.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
            Group {
                switch view {
                case .apps: appsTable
                case .connections: connectionsTable
                }
            }
            // The table draws its own square header and rows: clip them to
            // the card's rounded shape.
            .clipShape(.rect(cornerRadius: 14))
            .glassCard(cornerRadius: 14)
        }
        .padding(20)
    }

    private func stat(_ title: String, _ value: String, _ symbol: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(color == .secondary ? Color.secondary : color)
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .glassCard(cornerRadius: 12)
    }

    private var chart: some View {
        Chart {
            ForEach(monitor.samples) { s in
                AreaMark(x: .value("Time", s.time), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                    .foregroundStyle(.blue.opacity(0.25))
                LineMark(x: .value("Time", s.time), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                    .foregroundStyle(.blue)
                LineMark(x: .value("Time", s.time), y: .value("Speed", s.up), series: .value("Direction", "Upload"))
                    .foregroundStyle(.orange)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let b = v.as(Int64.self) { Text(Format.speed(b)) } }
            }
        }
        .chartXAxis(.hidden)
        .overlay {
            if monitor.samples.count < 2 { Text("Collecting…").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func matches(_ text: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || text.contains { $0.lowercased().contains(q) }
    }

    private var appsTable: some View {
        let rows = monitor.apps.filter { matches($0.app.name, $0.exits.joined(separator: " ")) }
        return Table(rows) {
            TableColumn("App") { a in
                HStack(spacing: 6) {
                    ProcessIcon(app: a.app)
                    Text(a.app.name).lineLimit(1)
                }
                .help(a.app.executable)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Via") { a in Text(a.exits.joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1) }
            TableColumn("Conn.") { a in Text("\(a.connections)").monospacedDigit() }.width(50)
            TableColumn("↓ Speed") { a in Text(Format.speed(a.downRate)).monospacedDigit() }.width(90)
            TableColumn("↑ Speed") { a in Text(Format.speed(a.upRate)).monospacedDigit() }.width(90)
            TableColumn("Received") { a in Text(Format.bytes(a.download)).monospacedDigit().foregroundStyle(.secondary) }.width(80)
            TableColumn("Sent") { a in Text(Format.bytes(a.upload)).monospacedDigit().foregroundStyle(.secondary) }.width(80)
        }
        .scrollContentBackground(.hidden)
    }

    private var connectionsTable: some View {
        let rows = monitor.connections
            .filter { matches($0.app.name, $0.host, $0.exit, $0.route) }
            .sorted(using: connOrder)
        return Table(rows, sortOrder: $connOrder) {
            TableColumn("App", value: \.app.name) { c in
                HStack(spacing: 6) {
                    ProcessIcon(app: c.app)
                    Text(c.app.name).lineLimit(1)
                }
            }
            .width(min: 110, ideal: 150)
            TableColumn("Destination", value: \.host) { c in
                Text("\(c.host):\(c.port)").lineLimit(1).textSelection(.enabled)
                    .help("\(c.network) \(c.host):\(c.port)")
            }
            .width(min: 150, ideal: 230)
            TableColumn("Route", value: \.route) { c in Text(c.route).lineLimit(1).help(c.route) }
                .width(min: 80, ideal: 120)
            TableColumn("Via", value: \.exit) { c in
                HStack(spacing: 4) {
                    Text(c.exit).lineLimit(1)
                        .foregroundStyle(c.exit == "Direct" ? Color.secondary : Color.primary)
                    if c.viaFallback {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange).help("Not the route's first server — it is down")
                    }
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("↓ Speed", value: \.downRate) { c in Text(Format.speed(c.downRate)).monospacedDigit() }.width(85)
            TableColumn("↑ Speed", value: \.upRate) { c in Text(Format.speed(c.upRate)).monospacedDigit() }.width(85)
            TableColumn("Time", value: \.start) { c in
                Text(Format.uptime(since: c.start, now: monitor.current?.time ?? Date())).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if ids.count == 1, let id = ids.first, let c = monitor.connections.first(where: { $0.id == id }) {
                Button("Copy Address") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(c.host, forType: .string)
                }
            }
            Button(ids.count > 1 ? "Close \(ids.count) Connections" : "Close Connection", role: .destructive) {
                for id in ids { monitor.close(id) }
            }
        }
        .scrollContentBackground(.hidden)
    }
}

struct ProcessIcon: View {
    let app: TrafficMonitor.AppRef
    var body: some View {
        if let b = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: b)).resizable().frame(width: 16, height: 16)
        } else {
            Image(systemName: app.executable.isEmpty ? "gearshape" : "terminal")
                .frame(width: 16, height: 16).foregroundStyle(.secondary)
        }
    }
}
