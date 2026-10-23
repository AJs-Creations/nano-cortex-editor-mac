// Who the dev remote answers (DevRemoteRequest.swift, compiled into this bundle): plain local clients, never a browser.
import XCTest

final class DevRemoteRequestTests: XCTestCase {
    private let port: UInt16 = 4850

    /// A request head as the wire has it; `lines` are the header lines after the request line.
    private func head(_ lines: [String], target: String = "/state") -> Data {
        Data((["GET \(target) HTTP/1.1"] + lines).joined(separator: "\r\n").appending("\r\n\r\n").utf8)
    }
    private func allowed(_ extra: [String], host: String? = "127.0.0.1:4850", port: UInt16 = 4850) -> Bool? {
        let lines = (host.map { ["Host: \($0)"] } ?? []) + ["User-Agent: curl/8.7.1", "Accept: */*"] + extra
        guard let h = DevRemoteRequest.parse(head(lines)) else { return nil }
        return DevRemoteRequest.allows(headers: h.headers, port: port)
    }

    func testPlainCurlIsAllowed() {
        XCTAssertEqual(allowed([]), true)
        XCTAssertEqual(allowed([], host: "localhost:4850"), true)
        XCTAssertEqual(allowed([], host: "LocalHost:4850"), true)
        XCTAssertEqual(allowed(["host-extra: x", "X-Origin: mine"]), true, "only the exact names count")
    }

    func testAnyOriginIsRefused() {
        XCTAssertEqual(allowed(["Origin: https://example.com"]), false)
        XCTAssertEqual(allowed(["origin: null"]), false)
        XCTAssertEqual(allowed(["ORIGIN:"]), false)
        XCTAssertEqual(allowed(["Origin : https://example.com"]), false, "space before the colon")
        XCTAssertEqual(allowed([" Origin: https://example.com"]), false, "a leading space")
        XCTAssertEqual(allowed(["Origin: http://127.0.0.1:4850"]), false, "even the app's own origin: curl sends none")
    }

    func testAnySecFetchHeaderIsRefused() {
        XCTAssertEqual(allowed(["Sec-Fetch-Site: cross-site"]), false)
        XCTAssertEqual(allowed(["sec-fetch-mode: no-cors"]), false)
        XCTAssertEqual(allowed(["SEC-FETCH-DEST: image"]), false)
        XCTAssertEqual(allowed(["Sec-Fetch-Site: same-origin"]), false)
    }

    func testForeignOrMissingHostIsRefused() {
        for host in ["attacker.example:4850", "attacker.example", "127.0.0.1", "127.0.0.1:4851", "localhost", "127.0.0.1.attacker.example:4850",
                     "localhost.attacker.example:4850", "127.0.0.1:4850.attacker.example", "[::1]:4850", "0.0.0.0:4850", "", "127.0.0.1:4850, attacker.example"] {
            XCTAssertEqual(allowed([], host: host), false, "Host: \(host)")
        }
        XCTAssertEqual(allowed([], host: nil), false, "no Host header")
        XCTAssertEqual(allowed(["Host: attacker.example:4850"]), false, "a second Host header")
        XCTAssertEqual(allowed(["Host: 127.0.0.1:4850"]), false, "two Host headers, even equal")
    }

    func testThePortIsTheRemotesOwn() {
        XCTAssertEqual(allowed([], host: "127.0.0.1:4881", port: 4881), true)
        XCTAssertEqual(allowed([], host: "127.0.0.1:4850", port: 4881), false)
    }

    /// The head is read to its blank line, so a head split across packets (or a long URL pushing `Origin` past the first
    /// packet) is judged whole.
    func testHeadIsCompleteOnlyAtTheBlankLine() {
        let full = head(["Host: 127.0.0.1:4850", "Origin: https://example.com"])
        XCTAssertTrue(DevRemoteRequest.headComplete(full))
        for cut in [10, 40, full.count - 4, full.count - 1] {
            let part = full.prefix(cut)
            XCTAssertFalse(DevRemoteRequest.headComplete(Data(part)), "first \(cut) bytes")
            XCTAssertNil(DevRemoteRequest.parse(Data(part)), "first \(cut) bytes")
        }
    }

    func testAHeadOverTheCapIsNotComplete() {
        let long = Data(("GET /state?x=" + String(repeating: "a", count: DevRemoteRequest.maxHead) + " HTTP/1.1\r\nHost: 127.0.0.1:4850\r\n\r\n").utf8)
        XCTAssertFalse(DevRemoteRequest.headComplete(long))
        XCTAssertNil(DevRemoteRequest.parse(long))
        let fits = Data(("GET /state?x=" + String(repeating: "a", count: 40000) + " HTTP/1.1\r\nHost: 127.0.0.1:4850\r\n\r\n").utf8)
        XCTAssertTrue(DevRemoteRequest.headComplete(fits))
        XCTAssertNotNil(DevRemoteRequest.parse(fits))
    }

    func testParseReadsTheRequestLine() throws {
        let h = try XCTUnwrap(DevRemoteRequest.parse(head(["Host: 127.0.0.1:4850"], target: "/amp?knob=gain&v=150")))
        XCTAssertEqual(h.method, "GET")
        XCTAssertEqual(h.target, "/amp?knob=gain&v=150")
        XCTAssertEqual(h.headers, [DevRemoteRequest.Header("Host", "127.0.0.1:4850")])
        XCTAssertNil(DevRemoteRequest.parse(Data("\r\n\r\n".utf8)))
        XCTAssertNil(DevRemoteRequest.parse(Data("GET\r\nHost: 127.0.0.1:4850\r\n\r\n".utf8)))
        XCTAssertNil(DevRemoteRequest.parse(Data([0xFF, 0xFE, 13, 10, 13, 10])), "not UTF-8")
    }

    func testResponses() {
        let refused = String(decoding: DevRemoteRequest.response(status: 403, body: DevRemoteRequest.refusedBody), as: UTF8.self)
        XCTAssertTrue(refused.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        XCTAssertTrue(refused.hasSuffix("\r\n\r\n" + #"{"ok":false,"error":"browser requests are refused"}"#))
        XCTAssertTrue(String(decoding: DevRemoteRequest.response(status: 200, body: "{}"), as: UTF8.self).hasPrefix("HTTP/1.1 200 OK\r\n"))
        XCTAssertTrue(String(decoding: DevRemoteRequest.response(status: 400, body: DevRemoteRequest.badRequestBody), as: UTF8.self).hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    }
}
