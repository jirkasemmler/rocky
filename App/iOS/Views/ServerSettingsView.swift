import RockyCore
import SwiftUI

/// Settings → "Server": connect to the optional Rocky server (D-24), sync status.
struct ServerSettingsSection: View {
    @Environment(TrainingStore.self) private var store
    @Environment(ServerSyncService.self) private var server
    @State private var url = ""
    @State private var token = ""
    @State private var confirmDisconnect = false

    var body: some View {
        Section {
            if let connected = store.syncState.serverURL, server.isConfigured {
                LabeledContent("Server", value: connected.replacingOccurrences(of: "https://", with: ""))
                LabeledContent("Katalog", value: store.catalog.revision == 0 ? "vestavěný" : "revize \(store.catalog.revision)")
                LabeledContent("Poslední synchronizace", value: lastSyncText)
                if let error = store.syncState.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                if !store.syncState.outbox.isEmpty {
                    Text("Čeká na odeslání: \(store.syncState.outbox.count)").font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    Task { await server.syncNow() }
                } label: {
                    HStack {
                        Text("Synchronizovat teď")
                        if server.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(server.isSyncing)
                .accessibilityIdentifier("syncNow")
                Button("Odpojit", role: .destructive) { confirmDisconnect = true }
            } else {
                TextField("https://rocky.tvuj-tailnet.ts.net", text: $url)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURL")
                SecureField("Token zařízení", text: $token)
                    .accessibilityIdentifier("serverToken")
                Button {
                    Task { await server.connect(serverURL: url, token: token) }
                } label: {
                    HStack {
                        Text("Připojit")
                        if server.isSyncing { Spacer(); ProgressView() }
                    }
                }
                .disabled(!Self.isAllowedURL(url) || token.isEmpty || server.isSyncing)
                if let status = server.statusText {
                    Text(status).font(.footnote).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("Server")
        } footer: {
            Text("Volitelné. Vlastní server Rocky v tvé síti Tailscale: spravuje cviky a obrázky a zálohuje tréninky. Bez serveru vše funguje jen v telefonu.")
        }
        .confirmationDialog("Odpojit server?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Odpojit", role: .destructive) { server.disconnect() }
        } message: {
            Text("Data v telefonu zůstanou. Katalog cviků zůstane v poslední stažené verzi.")
        }
    }

    /// HTTPS, or plain HTTP to this machine (development / simulator).
    static func isAllowedURL(_ text: String) -> Bool {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("https://") || t.hasPrefix("http://127.0.0.1") || t.hasPrefix("http://localhost")
    }

    private var lastSyncText: String {
        guard let date = store.syncState.lastSyncAt else { return "zatím ne" }
        return Format.shortDateTime.string(from: date)
    }
}
