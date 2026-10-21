import XCTest
import Foundation
import MCP
@testable import NoteDeskMCP

final class MCPTests: XCTestCase, @unchecked Sendable {
    let token = String(repeating: "x", count: 44)
    func headers(_ extra: [(String, String)] = []) -> [(String, String)] { [("Host", "127.0.0.1:18473"), ("Authorization", "Bearer \(token)")] + extra }
    func testSecurity() {
        let gate = AccessGate(token: token, port: 18473)
        XCTAssertNil(gate.check(headers: headers(), path: "/mcp"))
        XCTAssertEqual(gate.check(headers: [], path: "/mcp"), 403)
        XCTAssertEqual(gate.check(headers: [("Host", "127.0.0.1:18473")], path: "/mcp"), 401)
        XCTAssertEqual(gate.check(headers: headers([("Origin", "https://evil.example")]), path: "/mcp"), 403)
        XCTAssertEqual(gate.check(headers: headers([("Origin", "null")]), path: "/mcp"), 403)
        XCTAssertEqual(gate.check(headers: headers([("host", "evil.example")]), path: "/mcp"), 400)
        XCTAssertEqual(gate.check(headers: headers(), path: "/mcp?token=x"), 404)
        gate.close()
        XCTAssertEqual(gate.check(headers: headers(), path: "/mcp"), 503)
    }
    func testRateLimitAndPermissions() {
        let gate = AccessGate(token: token, port: 18473)
        for _ in 0..<120 { XCTAssertNil(gate.check(headers: headers(), path: "/mcp")) }
        XCTAssertEqual(gate.check(headers: headers(), path: "/mcp"), 429)
        XCTAssertFalse(ReadPolicy.permits(notebook: "a", allowed: [], encrypted: false, trashed: false))
        XCTAssertFalse(ReadPolicy.permits(notebook: nil, allowed: ["a"], encrypted: false, trashed: false))
        XCTAssertFalse(ReadPolicy.permits(notebook: "a", allowed: ["a"], encrypted: true, trashed: false))
        XCTAssertFalse(ReadPolicy.permits(notebook: "a", allowed: ["a"], encrypted: false, trashed: true))
        XCTAssertTrue(ReadPolicy.permits(notebook: "a", allowed: ["a"], encrypted: false, trashed: false))
    }
    func testSanitizerAndArguments() throws {
        let text = ReadPolicy.safeText("<script>secret</script><img src='http://nas/webapi/entry.cgi?_sid=secret'>hello https://nas/a?_sid=secret")
        XCTAssertFalse(text.contains("secret")); XCTAssertTrue(text.contains("hello"))
        XCTAssertThrowsError(try ReadRequest(name: "delete_note", arguments: [:]))
        XCTAssertThrowsError(try ReadRequest(name: "get_note", arguments: [:]))
        XCTAssertThrowsError(try ReadRequest(name: "search_notes", arguments: ["limit": .int(51)]))
        XCTAssertThrowsError(try ReadRequest(name: "search_notes", arguments: ["offset": .bool(true)]))
        XCTAssertThrowsError(try ReadRequest(name: "get_sync_status", arguments: ["password": .string("x")]))
    }
    func request(_ body: String, version: String = "2025-11-25") -> HTTPRequest {
        HTTPRequest(method: "POST", headers: ["Accept": "application/json, text/event-stream", "Content-Type": "application/json", "MCP-Protocol-Version": version], body: Data(body.utf8))
    }
    func testProtocol() async throws {
        let reader: MCPProtocol.Reader = { _ in .json("{\"ok\":true}") }
        let initResponse = await MCPProtocol.respond(request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#), reader: reader)
        XCTAssertEqual(initResponse.statusCode, 200)
        XCTAssertTrue(String(decoding: initResponse.bodyData!, as: UTF8.self).contains("protocolVersion"))
        let notification = await MCPProtocol.respond(request(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#), reader: reader)
        XCTAssertEqual(notification.statusCode, 202)
        let list = await MCPProtocol.respond(request(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#), reader: reader)
        let listText = String(decoding: list.bodyData!, as: UTF8.self)
        for name in ["list_notebooks", "search_notes", "get_note", "get_sync_status"] { XCTAssertTrue(listText.contains(name)) }
        let call = await MCPProtocol.respond(request(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_sync_status","arguments":{}}}"#), reader: reader)
        XCTAssertTrue(String(decoding: call.bodyData!, as: UTF8.self).contains("ok"))
        let denied = await MCPProtocol.respond(request(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_note","arguments":{"id":"abc"}}}"#), reader: { _ in .unavailable })
        XCTAssertTrue(String(decoding: denied.bodyData!, as: UTF8.self).contains("isError"))
        for (body, code) in [(#"{"jsonrpc":"2.0","id":4,"method":"unknown"}"#, "-32601"), (#"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"delete_note"}}"#, "-32602")] {
            let response = await MCPProtocol.respond(request(body), reader: reader)
            XCTAssertTrue(String(decoding: response.bodyData!, as: UTF8.self).contains(code))
        }
        let bad = await MCPProtocol.respond(request("{"), reader: reader)
        XCTAssertEqual(bad.statusCode, 400)
        let version = await MCPProtocol.respond(request(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#, version: "1900-01-01"), reader: reader)
        XCTAssertEqual(version.statusCode, 400)
    }
    func testMalformedEnvelopesAndHTTPValidation() async {
        let reader: MCPProtocol.Reader = { _ in XCTFail("Must not read store"); return .unavailable }
        for body in ["[]", "null", #"{"jsonrpc":"1.0","id":1,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":1.2,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
                     #"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#] {
            let response = await MCPProtocol.respond(request(body), reader: reader)
            XCTAssertEqual(response.statusCode, 400)
            XCTAssertTrue(String(decoding: response.bodyData!, as: UTF8.self).contains("-32600"))
        }
        for method in ["GET", "DELETE"] {
            let response = await MCPProtocol.respond(HTTPRequest(method: method), reader: reader)
            XCTAssertEqual(response.statusCode, 405)
        }
        let data = Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8)
        let accept = await MCPProtocol.respond(HTTPRequest(method: "POST", headers: ["Accept": "application/json", "Content-Type": "application/json"], body: data), reader: reader)
        XCTAssertEqual(accept.statusCode, 406)
        let type = await MCPProtocol.respond(HTTPRequest(method: "POST", headers: ["Accept": "application/json, text/event-stream", "Content-Type": "text/plain"], body: data), reader: reader)
        XCTAssertEqual(type.statusCode, 415)
        let future = await MCPProtocol.respond(request(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#), reader: reader)
        XCTAssertEqual(future.statusCode, 200)
        XCTAssertFalse(String(decoding: future.bodyData!, as: UTF8.self).contains("2099-01-01"))
    }
    func testConcurrentSameIDs() async {
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let response = await MCPProtocol.respond(self.request(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#), reader: { _ in .unavailable })
                    XCTAssertEqual(response.statusCode, 200)
                }
            }
        }
    }
    func testLiveLoopbackOnlyWithSyntheticData() async throws {
        let port = 28473
        let gate = AccessGate(token: token, port: port)
        let server = LoopbackServer()
        try await server.start(gate: gate, reader: { _ in .json("{}") })
        var r = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/mcp")!)
        r.httpMethod = "POST"; r.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#.utf8)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        r.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
        let (_, denied) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((denied as? HTTPURLResponse)?.statusCode, 401)
        r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        r.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let (_, origin) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((origin as? HTTPURLResponse)?.statusCode, 403)
        r.setValue(nil, forHTTPHeaderField: "Origin")
        r.httpBody = Data(repeating: 65, count: 65_537)
        let (_, oversized) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((oversized as? HTTPURLResponse)?.statusCode, 413)
        r.httpBody = nil; r.httpMethod = "GET"
        let (_, get) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((get as? HTTPURLResponse)?.statusCode, 405)
        gate.close(); await server.stop()
        r.timeoutInterval = 1
        do { _ = try await URLSession.shared.data(for: r); XCTFail("Listener must be stopped") }
        catch { /* expected connection refusal */ }
    }
}
