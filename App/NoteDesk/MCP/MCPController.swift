#if os(macOS)
import Foundation
import Observation
import Security
import AppKit
import SwiftData
import NoteDeskMCP

/// MainActor owns configuration and the existing SwiftData context. Network I/O lives in NIO.
@MainActor @Observable
final class MCPController {
    static let port = 18473
    static let endpoint = "http://127.0.0.1:18473/mcp"
    private(set) var enabled: Bool
    private(set) var allowed: Set<String>
    private(set) var status = "Выключен"
    private var gate: AccessGate?
    private var server: LoopbackServer?
    private var transition: Task<Void, Never>?
    private weak var engine: SyncEngine?
    private let context: ModelContext
    private let defaults: UserDefaults
    private var generation = 0

    init(context: ModelContext, engine: SyncEngine, defaults: UserDefaults = .standard) {
        self.context = context; self.engine = engine; self.defaults = defaults
        enabled = defaults.bool(forKey: "mcp.enabled")
        allowed = Set(defaults.stringArray(forKey: "mcp.allowed") ?? [])
    }
    func setEnabled(_ value: Bool) {
        enabled = value; defaults.set(value, forKey: "mcp.enabled"); reconcile()
    }
    func setAllowed(_ id: String, _ value: Bool) {
        if value { allowed.insert(id) } else { allowed.remove(id) }
        defaults.set(Array(allowed).sorted(), forKey: "mcp.allowed")
        // Revoke pending responses before changing the listener generation.
        reconcile()
    }
    func logout() {
        allowed = []; defaults.removeObject(forKey: "mcp.allowed")
        enabled = false; defaults.set(false, forKey: "mcp.enabled")
        reconcile() // called BEFORE the NAS logout await
        MCPToken.delete()
    }
    func reconcile() {
        gate?.close(); gate = nil
        generation += 1
        let revision = generation
        let old = server; server = nil
        let previous = transition
        let shouldStart = enabled && engine?.isLoggedIn == true
        status = shouldStart ? "Запуск…" : (enabled ? "Ожидает входа" : "Выключен")
        transition = Task { [weak self] in
            await previous?.value
            await old?.stop()
            guard let self, revision == self.generation, shouldStart else { return }
            do {
                let token = try MCPToken.loadOrCreate()
                let gate = AccessGate(token: token, port: Self.port)
                let server = LoopbackServer()
                self.gate = gate; self.server = server
                try await server.start(gate: gate) { [weak self] request in
                    guard gate.isActive else { return .unavailable }
                    return await self?.read(request, revision: revision) ?? .unavailable
                }
                guard revision == self.generation else { gate.close(); await server.stop(); return }
                self.status = "Работает (только этот Mac)"
            } catch {
                guard revision == self.generation else { return }
                self.gate?.close(); self.gate = nil
                self.status = "Не удалось запустить: проверьте Keychain и порт 18473"
            }
        }
    }
    func copyToken() {
        do { copy(try MCPToken.loadOrCreate()) }
        catch { status = "Токен недоступен в Keychain" }
    }
    func copyConfiguration() {
        do {
            let token = try MCPToken.loadOrCreate()
            let config: [String: Any] = ["mcpServers": ["notedesk": [
                "command": "npx",
                "args": ["-y", "mcp-remote", Self.endpoint, "--transport", "http-only", "--header", "Authorization:Bearer ${NOTEDESK_MCP_TOKEN}", "--silent"],
                "env": ["NOTEDESK_MCP_TOKEN": token]
            ]]]
            let data = try JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])
            copy(String(decoding: data, as: UTF8.self))
        } catch { status = "Не удалось скопировать конфигурацию" }
    }
    private func copy(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        // Mark sensitive/transient for clipboard managers that honor these conventions.
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let change = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(60))
            if pasteboard.changeCount == change { pasteboard.clearContents() }
        }
    }
    private func read(_ request: ReadRequest, revision: Int) -> ReadReply {
        guard revision == generation, enabled, engine?.isLoggedIn == true,
              engine?.persistence.hasFailure == false, gate?.isActive == true else { return .unavailable }
        return MCPReadService(context: context).read(request, allowed: allowed, sync: syncSnapshot())
    }
    private func syncSnapshot() -> [String: Any] {
        guard let engine else { return ["state": "unavailable"] }
        let state: String
        switch engine.phase {
        case .loggedOut: state = "logged_out"
        case .idle: state = "idle"
        case .syncing: state = "syncing"
        case .error: state = "error_cache_may_be_stale"
        }
        return ["state": state, "last_success": engine.lastSync.map { ISO8601DateFormatter().string(from: $0) } as Any? ?? NSNull(), "source": "local_cache", "freshness": "not_guaranteed", "allowed_notebooks": allowed.count]
    }
}

/// Independent Keychain item, never mixed with Account / DSM session credentials.
private enum MCPToken {
    static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app.notedesk.mcp", kSecAttrAccount as String: "bearer-v1"] }
    struct Failure: Error {}
    static func loadOrCreate() throws -> String {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8), value.utf8.count >= 43 { return value }
        guard status == errSecItemNotFound else { throw Failure() }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw Failure() }
        let value = Data(bytes).base64EncodedString()
        var item = query; item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw Failure() }
        return value
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}
#endif
