import Charts
import SwiftUI
import VPNCore

/// Live traffic, like Activity Monitor's Network tab: speed over the last
/// two minutes, then traffic by app or connection by connection, each with
/// the exit it leaves through.
struct MonitorView: View {
    let model: AppModel
    let monitor: TrafficMonitor
    @State private var view: Mode
    @State private var search = ""
    @AppStorage("monitorChartRange") private var range: ChartRange = .session
    @State private var appOrder = [KeyPathComparator(\AppRow.downRate, order: .reverse)]
    @State private var connOrder = [KeyPathComparator(\ConnectionRow.downRate, order: .reverse)]
    @State private var appSelection = Set<AppRow.ID>()
    @State private var connSelection = Set<ConnectionRow.ID>()
    @State private var pins = MonitorPins.load()
    @State private var adding: RouteSubject?

    init(model: AppModel, monitor: TrafficMonitor, mode: Mode = .apps) {
        self.model = model
        self.monitor = monitor
        _view = State(initialValue: mode)
    }

    /// Download purple, upload teal-blue: system colours, so they suit the
    /// light and the dark appearance alike.
    static let downColor = Color.purple
    static let upColor = Color.teal

    /// How much of the session the chart shows.
    enum ChartRange: String, CaseIterable, Identifiable {
        case minutes = "2 Min", hour = "1 Hour", session = "Session"
        var id: Self { self }
        var seconds: TimeInterval? {
            switch self {
            case .minutes: 120
            case .hour: 3600
            case .session: nil
            }
        }
    }

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
        .sheet(item: $adding) { AddToRouteSheet(model: model, subject: $0) }
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
                figure("Download:", Format.speed(model.speed?.down ?? 0), Self.downColor)
                figure("Upload:", Format.speed(model.speed?.up ?? 0), Self.upColor)
                figure("Connections:", "\(monitor.connections.count)")
                Divider().gridCellUnsizedAxes(.horizontal)
                figure("Data received:", Format.bytes(monitor.downloadTotal))
                figure("Data sent:", Format.bytes(monitor.uploadTotal))
                Divider().gridCellUnsizedAxes(.horizontal)
                // The chart's span: a small pop-up with the figures, so
                // nothing comes between the list and the chart.
                GridRow {
                    Text("Chart:").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("Chart", selection: $range) {
                        ForEach(ChartRange.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .gridColumnAlignment(.trailing)
                    .help("How much of this VPN session the chart shows — it is recorded from the moment the VPN was turned on")
                }
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

    /// The session's speed, recorded from the moment the VPN was turned on
    /// — also while Monitor was closed. A fixed span (two minutes, an hour)
    /// fills in from the right as data arrives, as in Activity Monitor.
    private var chart: some View {
        let points = model.history.points(within: range.seconds)
        let end = points.last?.time ?? .now
        let start = range.seconds.map { end.addingTimeInterval(-$0) } ?? points.first?.time ?? end.addingTimeInterval(-120)
        return Chart {
            ForEach(points) { s in
                AreaMark(x: .value("Time", s.time), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                    .foregroundStyle(LinearGradient(colors: [Self.downColor.opacity(0.35), Self.downColor.opacity(0.05)],
                                                    startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value("Speed", s.down), series: .value("Direction", "Download"))
                    .foregroundStyle(Self.downColor)
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Time", s.time), y: .value("Speed", s.up), series: .value("Direction", "Upload"))
                    .foregroundStyle(Self.upColor)
                    .interpolationMethod(.monotone)
            }
        }
        .chartXScale(domain: start...max(end, start.addingTimeInterval(1)))
        .chartYAxis {
            AxisMarks(position: .leading) { v in
                AxisGridLine()
                AxisValueLabel { if let b = v.as(Int64.self) { Text(Format.speed(b)) } }
            }
        }
        // Times along the bottom: for an hour or a session, when things
        // happened is the point.
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .overlay {
            if points.count < 2 { Text("Collecting…").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func matches(_ text: String...) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || text.contains { $0.lowercased().contains(q) }
    }

    // MARK: Lists

    private var appRows: [AppRow] {
        let rows = AppRow.rows(monitor.apps, pins: pins.apps).filter { matches($0.name, $0.via) }
        return MonitorOrder.arranged(rows, pin: \.pin, by: appOrder,
                                     tieBreak: [KeyPathComparator(\.download, order: .reverse), KeyPathComparator(\.name), KeyPathComparator(\.id)])
    }

    private var connectionRows: [ConnectionRow] {
        let rows = ConnectionRow.rows(monitor.connections, pins: pins.destinations)
            .filter { matches($0.appName, $0.destination, $0.exit, $0.route) }
        return MonitorOrder.arranged(rows, pin: \.pin, by: connOrder,
                                     tieBreak: [KeyPathComparator(\.start, order: .reverse), KeyPathComparator(\.id)])
    }

    /// Every column sorts, as in Activity Monitor: a click on its header,
    /// again to reverse. Pinned rows stay on top in their own order.
    private var appsTable: some View {
        Table(appRows, selection: $appSelection, sortOrder: $appOrder) {
            TableColumn("App", value: \.name) { a in
                HStack(spacing: 6) {
                    ProcessIcon(app: a.app)
                    Text(a.name).lineLimit(1)
                    if a.pin != nil { PinMark() }
                }
                .help(a.app.path)
                .dimmed(!a.isLive)
            }
            .width(min: 140, ideal: 200)
            TableColumn("Via", value: \.via) { a in Text(a.via).foregroundStyle(.secondary).lineLimit(1).dimmed(!a.isLive) }
            TableColumn("Conn.", value: \.connections) { a in live(a.isLive, "\(a.connections)") }.width(50)
            TableColumn("↓ Speed", value: \.downRate) { a in live(a.isLive, Format.speed(a.downRate)) }.width(90)
            TableColumn("↑ Speed", value: \.upRate) { a in live(a.isLive, Format.speed(a.upRate)) }.width(90)
            TableColumn("Received", value: \.download) { a in live(a.isLive, Format.bytes(a.download), secondary: true) }.width(80)
            TableColumn("Sent", value: \.upload) { a in live(a.isLive, Format.bytes(a.upload), secondary: true) }.width(80)
        }
        .contextMenu(forSelectionType: AppRow.ID.self) { ids in
            appMenu(appRows.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let r = appRows.first(where: { ids.contains($0.id) }), canAdd(r.app) {
                adding = RouteSubject(app: r.app)
            }
        }
    }

    private var connectionsTable: some View {
        Table(connectionRows, selection: $connSelection, sortOrder: $connOrder) {
            TableColumn("App", value: \.appName) { c in
                HStack(spacing: 6) {
                    ProcessIcon(app: c.app)
                    Text(c.appName).lineLimit(1)
                    if c.pin != nil { PinMark() }
                }
                .help(c.app.path)
                .dimmed(!c.isLive)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Destination", value: \.destination) { c in
                Text(c.destination).lineLimit(1)
                    .help(c.live.map { "\($0.network) \(c.destination)" } ?? "\(c.host) — no connection now")
                    .dimmed(!c.isLive)
            }
            .width(min: 150, ideal: 230)
            TableColumn("Route", value: \.route) { c in Text(c.route).lineLimit(1).help(c.route) }
                .width(min: 80, ideal: 120)
            TableColumn("Via", value: \.exit) { c in
                HStack(spacing: 4) {
                    Text(c.exit).lineLimit(1)
                        .foregroundStyle(c.exit == "Direct" ? Color.secondary : Color.primary)
                    if c.live?.viaFallback == true {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(.orange).help("Not the route's first server — it is down")
                    }
                }
            }
            .width(min: 90, ideal: 120)
            TableColumn("↓ Speed", value: \.downRate) { c in live(c.isLive, Format.speed(c.downRate)) }.width(85)
            TableColumn("↑ Speed", value: \.upRate) { c in live(c.isLive, Format.speed(c.upRate)) }.width(85)
            TableColumn("Time", value: \.start) { c in
                live(c.isLive, c.isLive ? Format.uptime(since: c.start, now: Date()) : "", secondary: true)
            }
            .width(60)
        }
        .contextMenu(forSelectionType: ConnectionRow.ID.self) { ids in
            connectionMenu(connectionRows.filter { ids.contains($0.id) })
        } primaryAction: { ids in
            if ids.count == 1, let r = connectionRows.first(where: { ids.contains($0.id) }) {
                adding = RouteSubject(app: r.app, host: r.host)
            }
        }
    }

    /// A figure; a dash for a pinned row with nothing live.
    private func live(_ isLive: Bool, _ text: String, secondary: Bool = false) -> some View {
        Text(isLive ? text : "—")
            .monospacedDigit()
            .foregroundStyle(secondary || !isLive ? .secondary : .primary)
            .dimmed(!isLive)
    }

    private func canAdd(_ app: TrafficMonitor.AppRef) -> Bool { RouteAddition.matcher(for: app) != nil }

    // MARK: Menus

    @ViewBuilder
    private func appMenu(_ rows: [AppRow]) -> some View {
        if rows.count == 1, let r = rows.first {
            Button("Add to Route…") { adding = RouteSubject(app: r.app) }.disabled(!canAdd(r.app))
            Divider()
        }
        pinItems(rows.map { ($0.id, $0.pin) }, count: pins.apps.items.count,
                 pin: { for r in rows { pins.apps.pin(r.app) } },
                 unpin: { for r in rows { pins.apps.unpin(r.id) } },
                 move: { id, by in pins.apps.move(id, by: by) })
        if rows.count == 1, let path = rows.first?.app.path, !path.isEmpty {
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
        }
    }

    @ViewBuilder
    private func connectionMenu(_ rows: [ConnectionRow]) -> some View {
        if rows.count == 1, let r = rows.first {
            Button("Add to Route…") { adding = RouteSubject(app: r.app, host: r.host) }
            Divider()
        }
        // One pin per app and site, however many connections are selected.
        let pinIDs = Array(Set(rows.map(\.pinID)))
        pinItems(pinIDs.map { id in (id, pins.destinations.index(of: id)) }, count: pins.destinations.items.count,
                 pin: { for r in rows { pins.destinations.pin(.init(app: r.app, host: r.host)) } },
                 unpin: { for id in pinIDs { pins.destinations.unpin(id) } },
                 move: { id, by in pins.destinations.move(id, by: by) })
        if rows.count == 1, let r = rows.first {
            Divider()
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(r.host, forType: .string)
            }
        }
        let open = rows.filter(\.isLive)
        if !open.isEmpty {
            Divider()
            Button(open.count > 1 ? "Close \(open.count) Connections" : "Close Connection", role: .destructive) {
                for r in open { monitor.close(r.id) }
            }
        }
    }

    /// Pin to Top, or Unpin when all of them are pinned; Move Up and Move
    /// Down among the pinned for a single pinned one.
    @ViewBuilder
    private func pinItems(_ items: [(id: String, pin: Int?)], count: Int, pin: @escaping () -> Void,
                          unpin: @escaping () -> Void, move: @escaping (String, Int) -> Void) -> some View {
        if !items.isEmpty && items.allSatisfy({ $0.pin != nil }) {
            Button("Unpin") { changePins(unpin) }
            if items.count == 1, let only = items.first, let i = only.pin {
                Button("Move Up") { changePins { move(only.id, -1) } }.disabled(i == 0)
                Button("Move Down") { changePins { move(only.id, 1) } }.disabled(i >= count - 1)
            }
        } else if !items.isEmpty {
            Button("Pin to Top") { changePins(pin) }
        }
    }

    private func changePins(_ change: () -> Void) {
        change()
        pins.save()
    }
}

/// Marks a pinned row.
private struct PinMark: View {
    var body: some View {
        Image(systemName: "pin.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(45))
            .help("Pinned to the top")
    }
}

private extension View {
    /// A pinned row with nothing live: there, but faded.
    func dimmed(_ on: Bool) -> some View { opacity(on ? 0.45 : 1) }
}

struct ProcessIcon: View {
    let app: TrafficMonitor.AppRef
    var size: CGFloat = 16
    var body: some View {
        if let b = app.bundlePath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: b)).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: app.executable.isEmpty ? "gearshape" : "terminal")
                .font(.system(size: size * 0.8))
                .frame(width: size, height: size).foregroundStyle(.secondary)
        }
    }
}
