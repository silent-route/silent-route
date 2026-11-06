import SwiftUI
import VPNCore

/// Add or edit one server (tunnel or proxy). The kind is chosen first; a pasted link fills the
/// fields, but only a link of that kind — a tunnel link pasted into the
/// proxy form is refused with a reason, never quietly turned into something.
struct AddServerSheet: View {
    @State private var draft: ServerDraft
    let isNew: Bool
    let profile: Profile
    let done: (Tunnel?) -> Void
    @State private var linkText = ""
    @State private var linkError: String?
    @State private var linkWarnings: [String] = []

    init(draft: ServerDraft, isNew: Bool, profile: Profile, done: @escaping (Tunnel?) -> Void) {
        _draft = State(initialValue: draft)
        self.isNew = isNew
        self.profile = profile
        self.done = done
    }

    private var built: Result<Tunnel, ServerDraft.Problem> {
        do { return .success(try draft.build()) } catch { return .failure(error) }
    }

    private var issues: [Validation.Issue] {
        guard case .success(let t) = built else { return [] }
        var p = profile
        p.tunnels = [t]
        p.routes = []
        p.defaultRoute = Route.everythingElse(servers: [t.id])
        return Validation.check(p).filter { $0.tunnel == t.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Text(isNew ? "Add Server" : "Edit Server").font(.title3.weight(.semibold))
                if isNew {
                    Picker("", selection: $draft.kind) {
                        Label("Tunnel", systemImage: "lock.circle").tag(ServerDraft.Kind.tunnel)
                        Label("Proxy", systemImage: "arrow.left.arrow.right.circle").tag(ServerDraft.Kind.proxy)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: draft.kind) { linkText = ""; linkError = nil; linkWarnings = [] }
                }
                pasteField
            }
            .padding([.horizontal, .top], 20)
            .padding(.bottom, 8)

            Form {
                Section("General") {
                    TextField("Name", text: $draft.name, prompt: Text("e.g. Netherlands"))
                    if draft.kind == .tunnel {
                        Picker("Protocol", selection: $draft.proto) {
                            ForEach(ServerDraft.Proto.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } else {
                        Picker("Type", selection: $draft.proxyType) {
                            ForEach(ServerDraft.ProxyType.allCases) { Text($0.rawValue).tag($0) }
                        }
                    }
                    TextField("Server", text: $draft.host, prompt: Text("host name or IP address"))
                    TextField("Port", text: $draft.port, prompt: Text(defaultPortHint))
                }
                if draft.kind == .proxy { proxyFields } else { tunnelFields }
                if draft.supportsMux { multiplexSection }
            }
            .formStyle(.grouped)

            footer
        }
        .frame(width: 520, height: 680)
        .onPasteCommand(of: [.plainText]) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s else { return }
                    Task { @MainActor in linkText = s; applyLink() }
                }
            }
        }
    }

    private var defaultPortHint: String {
        switch draft.kind {
        case .tunnel: "443"
        case .proxy: draft.proxyType == .socks5 ? "1080" : draft.proxyType == .https ? "443" : "8080"
        }
    }

    // MARK: Paste

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                TextField("", text: $linkText, prompt: Text(draft.kind == .tunnel
                    ? "Paste a link to fill the form: vless://, hysteria2://, trojan://, ss://, vmess://"
                    : "Paste a proxy: socks5://…, http://…, host:port:user:pass, user:pass@host:port…"))
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyLink)
                    .onChange(of: linkText) { _, new in if new.contains("://") || new.contains("@") { applyLink() } }
                Button("Fill") { applyLink() }.disabled(linkText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let linkError {
                Label(linkError, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
            }
            ForEach(linkWarnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func applyLink() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let kind: LinkParser.Kind = draft.kind == .tunnel ? .tunnel : .proxy
        let proxyKind: Proxy.Kind = draft.proxyType == .socks5 ? .socks5 : .http
        do {
            let r = try LinkParser.parse(text, expecting: kind, proxyKind: proxyKind, id: draft.id)
            var filled = ServerDraft(r.tunnel)
            filled.id = draft.id
            if !draft.name.trimmingCharacters(in: .whitespaces).isEmpty && !isNew { filled.name = draft.name }
            draft = filled
            linkError = nil
            linkWarnings = r.warnings
        } catch {
            linkError = Text.sentence("\(error)")
            linkWarnings = []
        }
    }

    // MARK: Fields

    @ViewBuilder
    private var proxyFields: some View {
        Section("Authentication") {
            TextField("Username", text: $draft.username, prompt: Text("optional"))
            SecureField("Password", text: $draft.password, prompt: Text("optional"))
        }
        if draft.proxyType == .socks5 {
            Section {
                Toggle("UDP through this proxy", isOn: $draft.proxyUDP)
                Text("Off by default, as in most clients. Each UDP connection — browsers use it for many sites (HTTP/3) — takes a connection of its own to the proxy, and many proxies limit those or carry UDP badly. Off, browsers use TCP instead; UDP of routes through this proxy does not get through. Turn it on for calls or games that need UDP, if the proxy supports it.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if draft.proxyType == .https {
            Section("TLS") {
                TextField("Server name (SNI)", text: $draft.sni, prompt: Text("defaults to the server"))
                Toggle("Allow insecure certificate", isOn: $draft.insecure)
            }
        }
    }

    @ViewBuilder
    private var tunnelFields: some View {
        switch draft.proto {
        case .hysteria2:
            Section("Hysteria2") {
                SecureField("Password", text: $draft.password)
                SecureField("Obfuscation password", text: $draft.obfsPassword, prompt: Text("salamander, optional"))
                TextField("Port hopping", text: $draft.portHopping, prompt: Text("e.g. 20000:30000, optional"))
            }
            tlsSection(choice: false)
        case .vless:
            Section("VLESS") {
                TextField("UUID", text: $draft.uuid)
                Picker("Flow", selection: $draft.flow) {
                    Text("None").tag("")
                    Text("xtls-rprx-vision").tag("xtls-rprx-vision")
                }
            }
            tlsSection(choice: true)
            transportSection
        case .trojan:
            Section("Trojan") { SecureField("Password", text: $draft.password) }
            tlsSection(choice: true)
            transportSection
        case .shadowsocks:
            Section("Shadowsocks") {
                Picker("Method", selection: $draft.ssMethod) {
                    ForEach(LinkParser.ssMethods.sorted(), id: \.self) { Text($0).tag($0) }
                }
                SecureField("Password", text: $draft.password)
            }
        case .vmess:
            Section("VMess") {
                TextField("UUID", text: $draft.uuid)
                Picker("Encryption", selection: $draft.vmessSecurity) {
                    ForEach(["auto", "aes-128-gcm", "chacha20-poly1305", "none", "zero"], id: \.self) { Text($0).tag($0) }
                }
            }
            tlsSection(choice: true)
            transportSection
        }
    }

    /// Advanced, off by default: only for servers set up for it.
    private var multiplexSection: some View {
        Section {
            Toggle("Multiplexing (MUX)", isOn: $draft.muxOn)
            if draft.muxOn {
                Picker("Protocol", selection: $draft.muxKind) {
                    ForEach(Multiplex.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Stepper("Connections: \(draft.muxConnections)", value: $draft.muxConnections, in: 1...16)
                Toggle("Padding", isOn: $draft.muxPadding)
            }
        } header: {
            Text("Advanced")
        } footer: {
            Text("Carries many connections inside a few to the server: fewer handshakes, and padding blurs the shape of the traffic. The server must have multiplexing enabled with the same protocol, or nothing connects. One slow connection can hold up the others.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func tlsSection(choice: Bool) -> some View {
        Section("Security") {
            if choice {
                Picker("Security", selection: $draft.security) {
                    ForEach(ServerDraft.Security.allCases.filter { draft.proto == .vless || $0 != .reality }) { Text($0.rawValue).tag($0) }
                }
            }
            if draft.tlsOn {
                TextField("Server name (SNI)", text: $draft.sni, prompt: Text("defaults to the server"))
                Picker("Fingerprint", selection: $draft.fingerprint) {
                    Text("Default").tag("")
                    ForEach(["chrome", "firefox", "safari", "edge", "ios", "randomized"], id: \.self) { Text($0).tag($0) }
                }
                TextField("ALPN", text: $draft.alpn, prompt: Text("e.g. h2,http/1.1, optional"))
                if draft.security == .reality && choice {
                    TextField("Reality public key", text: $draft.realityKey)
                    TextField("Reality short ID", text: $draft.realityShortID, prompt: Text("optional"))
                } else {
                    Toggle("Allow insecure certificate", isOn: $draft.insecure)
                }
            }
        }
    }

    private var transportSection: some View {
        Section("Transport") {
            Picker("Transport", selection: $draft.transport) {
                ForEach(ServerDraft.TransportKind.allCases) { Text($0.rawValue).tag($0) }
            }
            switch draft.transport {
            case .tcp: EmptyView()
            case .grpc: TextField("Service name", text: $draft.serviceName)
            case .ws, .httpUpgrade, .http:
                TextField("Path", text: $draft.path, prompt: Text("/"))
                TextField("Host", text: $draft.transportHost, prompt: Text("optional"))
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    if case .failure(let p) = built {
                        Label(p.message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(issues, id: \.self) { i in
                        Label(Text.sentence(i.message.replacingOccurrences(of: "server \"\(draft.name)\": ", with: "")),
                              systemImage: i.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(i.severity == .error ? .red : .orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Cancel") { done(nil) }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") {
                    if case .success(let t) = built { done(t) }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
            .padding(16)
        }
    }

    private var canSave: Bool {
        guard case .success = built else { return false }
        return !issues.contains { $0.severity == .error }
    }
}
