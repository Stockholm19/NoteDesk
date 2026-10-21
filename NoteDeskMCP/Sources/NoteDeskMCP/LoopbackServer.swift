#if os(macOS)
import Foundation
import MCP
import NIOCore
import NIOPosix
import NIOHTTP1

/// Shared revocation boundary. No data is sent after close(), including in-flight replies.
public final class AccessGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private var channels: [ObjectIdentifier: any Channel] = [:]
    private var window = Date()
    private var requests = 0
    private let token: [UInt8]
    public let port: Int
    public init(token: String, port: Int) { self.token = Array(token.utf8); self.port = port }
    public var isActive: Bool { lock.withLock { active } }
    func register(_ channel: any Channel) -> Bool {
        lock.withLock {
            guard active, channels.count < 16 else { return false }
            channels[ObjectIdentifier(channel)] = channel
            return true
        }
    }
    func remove(_ channel: any Channel) { lock.withLock { _ = channels.removeValue(forKey: ObjectIdentifier(channel)) } }
    public func close() {
        let all = lock.withLock { active = false; let all = Array(channels.values); channels.removeAll(); return all }
        for channel in all { channel.close(promise: nil) }
    }
    public func check(headers: [(String, String)], path: String) -> Int? {
        lock.withLock {
            guard active else { return 503 }
            if Date().timeIntervalSince(window) >= 60 { window = Date(); requests = 0 }
            requests += 1
            guard requests <= 120 else { return 429 }
            guard path == "/mcp" else { return 404 }
            var values: [String: String] = [:]
            for (key, value) in headers {
                let key = key.lowercased()
                guard values[key] == nil else { return 400 } // no ambiguous duplicate headers
                values[key] = value
            }
            guard values["host"] == "127.0.0.1:\(port)" else { return 403 }
            if let origin = values["origin"], origin != "http://127.0.0.1:\(port)" { return 403 }
            guard let auth = values["authorization"], auth.hasPrefix("Bearer ") else { return 401 }
            let candidate = Array(auth.dropFirst(7).utf8)
            guard candidate.count == token.count, token.count >= 43 else { return 401 }
            var difference: UInt8 = 0
            for i in token.indices { difference |= token[i] ^ candidate[i] }
            return difference == 0 ? nil : 401
        }
    }
}

/// NIO parses HTTP on its own event loop, never on the UI actor. One request per TCP
/// connection, Content-Length responses, connection close; chunked requests are decoded by NIO.
public actor LoopbackServer {
    private var group: MultiThreadedEventLoopGroup?
    private var listener: (any Channel)?
    public init() {}
    public func start(gate: AccessGate, reader: @escaping MCPProtocol.Reader) async throws {
        guard group == nil, gate.isActive else { return }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group
        do {
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.backlog, value: 16)
                .childChannelInitializer { channel in
                    channel.pipeline.configureHTTPServerPipeline(withPipeliningAssistance: false, withErrorHandling: true)
                        .flatMap { channel.pipeline.addHandler(HTTPHandler(gate: gate, reader: reader)) }
                }
                .bind(host: "127.0.0.1", port: gate.port).get()
            if gate.isActive { listener = channel } else { try? await channel.close().get(); await stop() }
        } catch { await stop(); throw error }
    }
    public func stop() async {
        let channel = listener; listener = nil
        let old = group; group = nil
        try? await channel?.close().get()
        try? await old?.shutdownGracefully()
    }
}

/// All mutable handler state is confined to the channel's event loop.
private final class HTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let gate: AccessGate
    let reader: MCPProtocol.Reader
    var head: HTTPRequestHead?
    var body = Data()
    var finished = false
    var timeout: Scheduled<Void>?
    var task: Task<Void, Never>?
    init(gate: AccessGate, reader: @escaping MCPProtocol.Reader) { self.gate = gate; self.reader = reader }
    func channelActive(context: ChannelHandlerContext) {
        guard gate.register(context.channel) else { context.close(promise: nil); return }
        let channel = context.channel
        timeout = context.eventLoop.scheduleTask(in: .seconds(10)) { channel.close(promise: nil) }
    }
    func channelInactive(context: ChannelHandlerContext) {
        timeout?.cancel(); task?.cancel(); gate.remove(context.channel)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !finished else { return }
        switch unwrapInboundIn(data) {
        case .head(let h):
            guard head == nil else { reply(.error(statusCode: 400, .invalidRequest("Bad request")), channel: context.channel); return }
            let bytes = h.headers.reduce(0) { $0 + $1.name.utf8.count + $1.value.utf8.count }
            guard bytes <= 8192, h.uri.utf8.count <= 256 else { reply(.error(statusCode: 431, .invalidRequest("Headers too large")), channel: context.channel); return }
            if let status = gate.check(headers: h.headers.map { ($0.name, $0.value) }, path: h.uri) {
                reply(.error(statusCode: status, .invalidRequest("Request refused")), channel: context.channel); return
            }
            guard h.method == .POST else {
                reply(.error(statusCode: 405, .invalidRequest("Method not allowed"), extraHeaders: ["Allow": "POST"]), channel: context.channel); return
            }
            if let length = h.headers.first(name: "content-length"), (Int(length) ?? Int.max) > 65_536 {
                reply(.error(statusCode: 413, .invalidRequest("Body too large")), channel: context.channel); return
            }
            head = h
        case .body(var b):
            guard body.count + b.readableBytes <= 65_536 else {
                reply(.error(statusCode: 413, .invalidRequest("Body too large")), channel: context.channel); return
            }
            body.append(contentsOf: b.readBytes(length: b.readableBytes) ?? [])
        case .end(let trailers):
            guard let head, trailers == nil else { reply(.error(statusCode: 400, .invalidRequest("Bad request")), channel: context.channel); return }
            finished = true
            let request = HTTPRequest(method: head.method.rawValue, headers: Dictionary(uniqueKeysWithValues: head.headers.map { ($0.name.lowercased(), $0.value) }), body: body)
            let channel = context.channel
            task = Task { [reader, gate] in
                let response = await MCPProtocol.respond(request, reader: reader)
                guard !Task.isCancelled, gate.isActive else { channel.close(promise: nil); return }
                channel.eventLoop.execute { self.reply(response, channel: channel) }
            }
        }
    }
    func reply(_ response: HTTPResponse, channel: any Channel) {
        finished = true
        guard gate.isActive else { channel.close(promise: nil); return }
        let data = response.bodyData ?? Data()
        guard data.count <= 512_000 else { channel.close(promise: nil); return }
        var headers = HTTPHeaders(response.headers.map { ($0.key, $0.value) })
        headers.replaceOrAdd(name: "Content-Length", value: String(data.count))
        headers.replaceOrAdd(name: "Connection", value: "close")
        headers.replaceOrAdd(name: "Cache-Control", value: "no-store")
        headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        if response.statusCode == 401 { headers.replaceOrAdd(name: "WWW-Authenticate", value: "Bearer") }
        channel.write(HTTPServerResponsePart.head(.init(version: .http1_1, status: .init(statusCode: response.statusCode), headers: headers)), promise: nil)
        if !data.isEmpty {
            var buffer = channel.allocator.buffer(capacity: data.count); buffer.writeBytes(data)
            channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil)).whenComplete { _ in channel.close(promise: nil) }
    }
}

#endif
