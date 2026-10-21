#if os(macOS)
import Foundation
import CoreFoundation
import MCP

/// Only value types cross into the application's MainActor read service.
public struct ReadRequest: Sendable {
    public let name: String
    public let query: String
    public let id: String
    public let offset: Int
    public let limit: Int

    public init(name: String, arguments: [String: Value]) throws {
        let allowed: Set<String>
        switch name {
        case "list_notebooks": allowed = ["offset", "limit"]
        case "search_notes": allowed = ["query", "offset", "limit"]
        case "get_note": allowed = ["id", "offset", "limit"]
        case "get_sync_status": allowed = []
        default: throw MCPError.invalidParams("Unknown tool")
        }
        guard Set(arguments.keys).isSubset(of: allowed) else { throw MCPError.invalidParams("Unknown argument") }
        func string(_ key: String, required: Bool = false) throws -> String {
            guard let v = arguments[key] else {
                if required { throw MCPError.invalidParams("Missing \(key)") }
                return ""
            }
            guard case .string(let text) = v, text.utf8.count <= 512 else { throw MCPError.invalidParams("Invalid \(key)") }
            if required && text.isEmpty { throw MCPError.invalidParams("Empty \(key)") }
            return text
        }
        func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            guard let v = arguments[key] else { return fallback }
            guard case .int(let n) = v, range.contains(n) else { throw MCPError.invalidParams("Invalid \(key)") }
            return n
        }
        self.name = name
        query = try string("query")
        id = try string("id", required: name == "get_note")
        offset = try integer("offset", default: 0, range: 0...1_000_000)
        limit = try integer("limit", default: name == "get_note" ? 8_000 : 25, range: 1...(name == "get_note" ? 16_000 : 50))
    }
}

public enum ReadReply: Sendable {
    case json(String)
    case unavailable
}

public enum ReadPolicy {
    public static func permits(notebook: String?, allowed: Set<String>, encrypted: Bool, trashed: Bool) -> Bool {
        guard let notebook else { return false }
        return !encrypted && !trashed && allowed.contains(notebook)
    }

    /// Never render HTML or expose attachment attributes/session URLs. Deliberately lossy plain text.
    public static func safeText(_ source: String) -> String {
        var text = source
        for pattern in ["(?is)<(script|style)[^>]*>.*?</\\1\\s*>", "(?s)<[^>]*>"] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        // Decode only basic entities; do not reconstitute escaped markup/URLs after redaction.
        for (a, b) in [("&nbsp;", " "), ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'")] {
            text = text.replacingOccurrences(of: a, with: b)
        }
        // Redact entire tokens containing NAS download paths or session/auth parameters, including escaped URLs.
        text = text.replacingOccurrences(of: #"(?i)\S*(?:_sid|synotoken|webapi/|webapi%2f|entry\.cgi|authToken|access_token)\S*"#, with: "[redacted]", options: .regularExpression)
        return text
    }
}

public enum MCPProtocol {
    public typealias Reader = @Sendable (ReadRequest) async -> ReadReply

    public static var tools: [Tool] {
        let offset: Value = .object(["type": .string("integer"), "minimum": .int(0), "maximum": .int(1_000_000)])
        func tool(_ name: String, _ description: String, _ extra: [String: Value] = [:], required: [String] = [], paged: Bool = true) -> Tool {
            var props = extra
            if paged {
                props["offset"] = offset
                props["limit"] = .object(["type": .string("integer"), "minimum": .int(1), "maximum": .int(name == "get_note" ? 16_000 : 50)])
            }
            return Tool(name: name, description: description,
                inputSchema: .object(["type": .string("object"), "properties": .object(props), "required": .array(required.map { .string($0) }), "additionalProperties": .bool(false)]),
                annotations: .init(readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false))
        }
        let string: Value = .object(["type": .string("string"), "maxLength": .int(512)])
        return [
            tool("list_notebooks", "List only explicitly allowed local notebooks. Offset pagination."),
            tool("search_notes", "Search local titles and briefs, not full bodies. Excludes locked, trashed and unallowed notes. Continue using next_offset even for an empty page. Cache may be stale.", ["query": string]),
            tool("get_note", "Read allowed local note as sanitized plain text. id is local UUID; offset/limit count text characters. Body may be missing or stale. No attachments.", ["id": string], required: ["id"]),
            tool("get_sync_status", "Coarse local sync state only; no credentials, server URLs, global counts or raw error messages.", paged: false)
        ]
    }

    /// A fresh SDK server/transport per HTTP request avoids cross-client request-ID collisions
    /// and initialization state sharing. This is deliberately stateless (no session header).
    public static func respond(_ request: HTTPRequest, reader: @escaping Reader) async -> HTTPResponse {
        // The SDK's transport classifier alone accepts malformed envelopes (e.g. bool IDs).
        // Reject these before registering a response waiter that could otherwise never resolve.
        if request.method.uppercased() == "POST", let invalid = validateEnvelope(request.body) { return invalid }
        let server = Server(name: "NoteDesk", version: "1.0", capabilities: .init(tools: .init(listChanged: false)))
        let transport = StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            AcceptHeaderValidator(mode: .sseRequired), ContentTypeValidator(), ProtocolVersionValidator()
        ]))
        await server.withMethodHandler(ListTools.self) { _ in .init(tools: tools) }
        await server.withMethodHandler(CallTool.self) { params in
            let call = try ReadRequest(name: params.name, arguments: params.arguments ?? [:])
            switch await reader(call) {
            case .json(let text): return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
            case .unavailable: return .init(content: [.text(text: "Unavailable: access disabled, notebook not allowed, note absent/locked/trashed, or local read failed.", annotations: nil, _meta: nil)], isError: true)
            }
        }
        do { try await server.start(transport: transport) }
        catch { return .error(statusCode: 503, .internalError("Server unavailable")) }
        let response = await withTaskCancellationHandler {
            await transport.handleRequest(request)
        } onCancel: {
            Task { await transport.disconnect() }
        }
        await server.stop()
        return response
    }
    private static func validateEnvelope(_ body: Data?) -> HTTPResponse? {
        guard let body, let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]) else {
            return .error(statusCode: 400, .parseError("Invalid JSON"))
        }
        func invalid() -> HTTPResponse { .error(statusCode: 400, .invalidRequest("Invalid JSON-RPC envelope; batches are not supported")) }
        guard let json = object as? [String: Any], json["jsonrpc"] as? String == "2.0" else { return invalid() }
        if let id = json["id"] {
            if let n = id as? NSNumber {
                guard CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite,
                      abs(n.doubleValue) <= 9_007_199_254_740_991, n.doubleValue.rounded() == n.doubleValue else { return invalid() }
            } else if !(id is String) { return invalid() }
        }
        if let method = json["method"] {
            guard method is String, json["result"] == nil, json["error"] == nil else { return invalid() }
            if let params = json["params"], !(params is [String: Any]) { return invalid() }
        } else {
            guard json["id"] != nil, (json["result"] != nil) != (json["error"] != nil) else { return invalid() }
        }
        return nil
    }

}

#endif
