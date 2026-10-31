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
                ContentUnavailableView("Another User's VPN", systemImage: "person.2",
                                       description: Text("Another user of this Mac turned the VPN on. Its traffic is shown only to them."))
            } else if model.status.phase == .connected || !monitor.connections.isEmpty {
                content
            } else {
                ContentUnavailableView("Not Connected", systemImage: "chart.xyaxis.line",
                                       description: Text("Turn the VPN on to see live traffic: which apps talk to which sites, by which route and server."))
            }
        }
        .navigationTitle("Monitor")
    }

    /// Laid out as Activity Monitor's Network tab: the list, edge to edge,
    /// takes the window; the totals and the chart sit in a panel below.
    private var content: some View {
        VStack(spacing: 0) {
            if let p = monitor.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                Divider()
            }
            Group {
                switch view {
                case .apps: appsTable
                case .connections: connectionsTable
                }
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            Divider()
            summary
        }
        // The view switch and the search field in the toolbar, as there.
        .searchable(text: $search, placement: .toolbar, prompt: "Filter")
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $view) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Traffic by app, or each connection")
            }
        }
    }

    /// The figures in a column of label and value, the chart beside them in
    /// a thin frame — larger than Activity Monitor's, since here it is the
    /// main way to see the connection at a glance.
    private var summary: some View {
        HStack(alignment: .center, spacing: 24) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                figure("Download:", Format.speed(monitor.current?.down ?? 0), .blue)
                figure("Upload:", Format.speed(monitor.current?.up ?? 0), .orange)
                figure("Connections:", "\(monitor.connections.count)")
                Divider().gridCellUnsizedAxes(.horizontal)
                figure("Data received:", Format.bytes(monitor.downloadTotal))
                figure("Data sent:", Format.bytes(monitor.uploadTotal))
            }
            .font(.callout)
            .fixedSize()
            chart
                .frame(height: 170)
                .padding(10)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        .padding(16)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func figure(_ label: String, _ value: String, _ color: Color? = nil) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).monospacedDigit().foregroundStyle(color ?? .primary).gridColumnAlignment(.trailing)
                .frame(minWidth: 90, alignment: .trailing)
        }
    }

    /// Always the last two minutes, filling in from the right as data
    /// arrives (as in Activity Monitor) — never a few points stretched
    /// across the whole width.
    private var chart: some View {
        let end = monitor.samples.last?.time ?? .now
        return Chart {
            ForEach(monitor.samples) { s in
                AreaMark(x: .value("Time", s.time), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                    .foregroundStyle(.blue.opacity(0.25))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                    .foregroundStyle(.blue)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value("Speed", s.up), series: .value("Direction", "Upload"))
                    .foregroundStyle(.orange)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: end.addingTimeInterval(-TrafficMonitor.window)...end)
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
