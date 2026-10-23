// Who the dev remote answers (DevRemote.swift, Debug builds only; this file is pure and compiled into the unit tests).
//
// The listener is bound to 127.0.0.1, but a web page in any browser on this Mac can still make the browser call it
// (`<img src="http://127.0.0.1:4850/save">` is enough, every route is a GET) or point its own domain at 127.0.0.1
// (DNS rebinding). curl and the test harnesses send none of the headers a browser adds, so they are the callers that
// stay. DECISIONS #34.
import Foundation

enum DevRemoteRequest {
    /// The request line and the header fields of one HTTP request (the body is never read).
    struct Head: Equatable {
        let method: String
        let target: String
        let headers: [Header]
    }
    struct Header: Equatable {
        let name: String    // as received
        let value: String   // trimmed
        init(_ name: String, _ value: String) { self.name = name; self.value = value }
    }

    /// A request head longer than this is refused (400) instead of read on.
    static let maxHead = 65536

    /// A browser attaches `Origin` to cross-origin and POST requests and the `Sec-Fetch-*` family to every request it
    /// makes, image loads and no-cors fetches included; a page can neither remove nor set them.
    static let browserHeaders: Set<String> = ["origin", "sec-fetch-site", "sec-fetch-mode", "sec-fetch-dest"]

    private static let endOfHead = Data([13, 10, 13, 10])   // CRLF CRLF

    /// True once the blank line that ends the header block has arrived (within `maxHead` bytes). The listener reads
    /// until then, not just the first packet: a head split across packets must not let a later `Origin` line go unseen.
    static func headComplete(_ data: Data) -> Bool {
        guard let end = data.range(of: endOfHead) else { return false }
        return end.upperBound - data.startIndex <= maxHead
    }

    /// The head of the request in `data` (up to the blank line), or nil when it is incomplete or has no usable request
    /// line. Header names are matched case-insensitively and are trimmed, so `Origin :` or ` Origin:` still count.
    static func parse(_ data: Data) -> Head? {
        guard headComplete(data), let end = data.range(of: endOfHead), let text = String(data: data[data.startIndex..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = text.components(separatedBy: "\r\n")
        guard let first = lines.first else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return nil }
        var headers: [Header] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append(Header(name, value))
        }
        return Head(method: String(parts[0]), target: String(parts[1]), headers: headers)
    }

    /// True for a plain local client (curl, a script); false when the request carries `Origin` or any `Sec-Fetch-Site` /
    /// `-Mode` / `-Dest` header, or when its `Host` is not exactly `127.0.0.1:<port>` or `localhost:<port>` (one Host
    /// header, none missing).
    static func allows(headers: [Header], port: UInt16) -> Bool {
        if headers.contains(where: { browserHeaders.contains($0.name.lowercased()) }) { return false }
        let hosts = headers.filter { $0.name.lowercased() == "host" }
        guard hosts.count == 1 else { return false }
        return ["127.0.0.1:\(port)", "localhost:\(port)"].contains(hosts[0].value.lowercased())
    }

    static func response(status: Int, body: String) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden"][status] ?? "OK"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)".utf8)
    }
    static let refusedBody = #"{"ok":false,"error":"browser requests are refused"}"#
    static let badRequestBody = #"{"ok":false,"error":"bad request"}"#
}
