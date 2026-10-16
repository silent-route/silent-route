import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VPNCore

/// Session logs: the kept sessions on the left, the chosen one on the
/// right. Read through the helper (the files are root's), only while the
/// page is open; the running session follows along.
struct LogsView: View {
    let model: AppModel
    @State private var sessions: [LogSession] = []
    @State private var selected: LogSession.ID?
    @State private var text = ""
    @State private var problemsOnly = false
    @State private var search = ""
    @State private var loaded = false
    @State private var saving: LogDocument?

    var body: some View {
        HStack(spacing: 0) {
            sessionList
                .frame(width: 250)
            Divider()
            content
        }
        .navigationTitle("Logs")
        .task { await refreshList(selectNewest: true) }
        .task(id: selected) { await follow() }
        .fileExporter(isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }),
                      document: saving, contentType: .plainText,
                      defaultFilename: selected.map { $0.replacingOccurrences(of: ".log", with: "") } ?? "Silent Route log") { _ in }
    }

    // MARK: Sessions

    private var sessionList: some View {
        Group {
            if loaded && sessions.isEmpty {
                ContentUnavailableView("No sessions yet", systemImage: "doc.text",
                                       description: Text("Each time you turn the VPN on, its session is logged here. The last 30 are kept, and only you can see yours — other users of this Mac see only their own."))
            } else {
                List(sessions, selection: $selected) { s in
                    SessionRow(session: s).tag(s.id)
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: Text

    private var content: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $problemsOnly) {
                    Text("All").tag(false)
                    Text("Problems").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Problems: errors, warnings, reconnects and failovers")
                TextField("", text: $search, prompt: Text("Filter"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 220)
                Spacer()
                Menu {
                    Button("Copy") { copy(redacted: false) }
                    Button("Copy Without Addresses") { copy(redacted: true) }
                    Divider()
                    Button("Save…") { saving = LogDocument(text: text) }
                    Button("Save Without Addresses…") { saving = LogDocument(text: LogRedactor.redact(text)) }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .fixedSize()
                .disabled(text.isEmpty)
                .help("“Without addresses” hides IP addresses, host names and the names of your profiles, routes and servers — for sharing a log safely")
            }
            .padding(10)
            Divider()
            if selected == nil {
                ContentUnavailableView("Choose a session", systemImage: "doc.text.magnifyingglass")
            } else {
                LogTextView(text: shown)
            }
        }
    }

    /// The text after the two filters.
    private var shown: String {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard problemsOnly || !q.isEmpty else { return text }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                (!problemsOnly || Self.isProblem(line)) && (q.isEmpty || line.lowercased().contains(q))
            }
            .joined(separator: "\n")
    }

    static func isProblem(_ line: Substring) -> Bool {
        line.contains("ERROR") || line.contains("WARN") || line.contains("FATAL") || line.contains("session ended")
            || (line.contains("[helper]") && ["reconnect", "failed", "no server", "blocked", "going direct", "now through", "woke"]
                .contains { line.contains($0) })
    }

    private func copy(redacted: Bool) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(redacted ? LogRedactor.redact(shown) : shown, forType: .string)
    }

    // MARK: Loading

    private func refreshList(selectNewest: Bool) async {
        if let list = await model.sessionLogs() { sessions = list }
        loaded = true
        if selectNewest, selected == nil { selected = sessions.first?.id }
    }

    /// Loads the chosen session; while it is still going, keeps it fresh.
    private func follow() async {
        guard let id = selected else { text = ""; return }
        text = await model.logText(id) ?? ""
        while !Task.isCancelled, sessions.first(where: { $0.id == id })?.ended == nil {
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            if let t = await model.logText(id), t != text { text = t }
            await refreshList(selectNewest: false)
        }
    }
}

private struct SessionRow: View {
    let session: LogSession

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(session.started.formatted(.relative(presentation: .named, unitsStyle: .wide)).capitalizedFirst
                     + ", " + session.started.formatted(date: .omitted, time: .shortened))
                    .lineLimit(1)
                if session.ended == nil {
                    Text("Live").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.green, in: .capsule)
                }
            }
            Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 2)
    }

    private var details: String {
        var parts: [String] = []
        if !session.profile.isEmpty { parts.append(session.profile) }
        if let end = session.ended { parts.append(Self.duration(end.timeIntervalSince(session.started))) }
        parts.append(Format.bytes(Int64(session.bytes)))
        return parts.joined(separator: " · ")
    }

    static func duration(_ t: TimeInterval) -> String {
        let f = DateComponentsFormatter()
        f.allowedUnits = t >= 3600 ? [.hour, .minute] : t >= 60 ? [.minute] : [.second]
        f.unitsStyle = .abbreviated
        return f.string(from: max(1, t)) ?? ""
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// A log is long: an NSTextView handles megabytes where SwiftUI's Text does
/// not. Errors red, warnings orange, the helper's own lines bold. Stays at
/// the bottom when it was there, so a live session reads like a tail.
struct LogTextView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        if let tv = scroll.documentView as? NSTextView {
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textContainerInset = NSSize(width: 8, height: 8)
            tv.isAutomaticLinkDetectionEnabled = false
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, context.coordinator.last != text else { return }
        let atBottom = scroll.contentView.bounds.maxY >= tv.bounds.height - 40
        context.coordinator.last = text
        tv.textStorage?.setAttributedString(Self.styled(text))
        if atBottom || context.coordinator.first {
            tv.scrollToEndOfDocument(nil)
            context.coordinator.first = false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var last: String?
        var first = true
    }

    static func styled(_ text: String) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let bold = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        let out = NSMutableAttributedString()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            if line.contains("ERROR") || line.contains("FATAL") {
                attrs[.foregroundColor] = NSColor.systemRed
            } else if line.contains("WARN") {
                attrs[.foregroundColor] = NSColor.systemOrange
            } else if line.hasPrefix("#") {
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
            } else if line.contains("[helper]") {
                attrs[.font] = bold
            } else {
                attrs[.foregroundColor] = NSColor.secondaryLabelColor
            }
            out.append(NSAttributedString(string: String(line) + "\n", attributes: attrs))
        }
        return out
    }
}

/// A log as a plain-text file, for Save….
struct LogDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
