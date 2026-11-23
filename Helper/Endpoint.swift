// Where the running editor listens and the checks made before trusting it (mcp/PROTOCOL.md §1, mcp/endpoint.js),
// plus the raw POSIX pieces the helper needs (socket connect, full writes, own executable path).

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct Endpoint: Sendable {
    let dir: String
    let socket: String
    let token: String

    /// /tmp/nano-cortex-<uid>, or NANO_MCP_DIR (made absolute and normalized, as path.resolve does).
    static func current() -> Endpoint {
        let env = ProcessInfo.processInfo.environment
        let dir: String
        if let custom = env["NANO_MCP_DIR"], !custom.isEmpty {
            dir = resolvePath(custom)
        } else {
            dir = "/tmp/nano-cortex-\(getuid())"
        }
        return Endpoint(dir: dir, socket: dir + "/editor.sock", token: dir + "/token")
    }
}

/// Node's path.resolve(p): absolute against the working directory, "." and ".." removed lexically.
func resolvePath(_ p: String) -> String {
    let absolute = p.hasPrefix("/") ? p : FileManager.default.currentDirectoryPath + "/" + p
    var parts: [Substring] = []
    for c in absolute.split(separator: "/", omittingEmptySubsequences: true) {
        if c == "." { continue }
        if c == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
        parts.append(c)
    }
    return "/" + parts.joined(separator: "/")
}

/// Node's error text for a failed lstat ("EACCES: permission denied, lstat '<path>'").
private func lstatErrorMessage(_ code: Int32, _ path: String) -> String {
    let known: [Int32: (String, String)] = [
        EACCES: ("EACCES", "permission denied"),
        EPERM: ("EPERM", "operation not permitted"),
        ENOTDIR: ("ENOTDIR", "not a directory"),
        ELOOP: ("ELOOP", "too many symbolic links encountered"),
        ENAMETOOLONG: ("ENAMETOOLONG", "name too long"),
        EIO: ("EIO", "i/o error"),
    ]
    let (name, text) = known[code] ?? ("E\(code)", String(cString: strerror(code)).lowercased())
    return "\(name): \(text), lstat '\(path)'"
}

/// nil when `dir` is a private folder of this user, else why not (the same texts as endpoint.js).
func checkPrivateDir(_ dir: String) -> String? {
    var st = stat()
    if lstat(dir, &st) != 0 {
        let e = errno
        if e == ENOENT { return "the folder \(dir) does not exist" }
        return "cannot read \(dir): " + lstatErrorMessage(e, dir)
    }
    let type = st.st_mode & S_IFMT
    if type == S_IFLNK { return "\(dir) is a symbolic link" }
    if type != S_IFDIR { return "\(dir) is not a folder" }
    if st.st_uid != getuid() { return "\(dir) belongs to another user" }
    if (st.st_mode & 0o077) != 0 {
        return "\(dir) is not private (mode \(String(UInt32(st.st_mode & 0o777), radix: 8)), expected 700)"
    }
    return nil
}

/// The editor's token: a regular file of this user that others cannot read, holding 64 lowercase hex characters.
func readToken(_ file: String) -> String? {
    var st = stat()
    guard lstat(file, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG, st.st_uid == getuid(), (st.st_mode & 0o077) == 0,
          let data = FileManager.default.contents(atPath: file) else { return nil }
    let t = jsTrim(String(decoding: data, as: UTF8.self))
    let u = Array(t.utf8)
    guard u.count == 64, u.allSatisfy({ ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9")) || ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "f")) })
    else { return nil }
    return t
}

// MARK: - POSIX helpers

/// A new AF_UNIX stream socket (close-on-exec, no SIGPIPE), or nil.
func makeUnixSocket() -> Int32? {
    #if canImport(Darwin)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return nil }
    _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    #if canImport(Darwin)
    var one: Int32 = 1
    _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    #endif
    return fd
}

/// Connects `fd` to the socket at `path` (blocking). false when the path does not fit or nothing listens.
func connectUnix(_ fd: Int32, _ path: String) -> Bool {
    var addr = sockaddr_un()
    let bytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: addr.sun_path)
    guard bytes.count < capacity else { return false }
    addr.sun_family = sa_family_t(AF_UNIX)
    #if canImport(Darwin)
    addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    #endif
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        raw.copyBytes(from: bytes)
        raw[bytes.count] = 0
    }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    let r = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) }
    }
    return r == 0
}

/// Writes every byte (retrying on EINTR and short writes). false when the other side is gone.
@discardableResult
func writeAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    bytes.withUnsafeBytes { raw -> Bool in
        guard var p = raw.baseAddress else { return true }
        var left = raw.count
        while left > 0 {
            let n = write(fd, p, left)
            if n < 0 {
                if errno == EINTR { continue }
                return false
            }
            left -= n
            p += n
        }
        return true
    }
}

/// Diagnostics go to stderr only (stdout carries nothing but protocol messages).
func logError(_ text: String) {
    writeAll(2, Array(("nano-cortex-mcp: " + text + "\n").utf8))
}

/// The real path (symlinks resolved) of this executable.
func executablePath() -> String? {
    #if canImport(Darwin)
    var size: UInt32 = 0
    _ = _NSGetExecutablePath(nil, &size)
    var buf = [CChar](repeating: 0, count: Int(size) + 1)
    guard _NSGetExecutablePath(&buf, &size) == 0 else { return nil }
    guard let real = realpath(buf, nil) else { return buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } }
    defer { free(real) }
    return String(cString: real)
    #else
    guard let real = realpath("/proc/self/exe", nil) else { return nil }
    defer { free(real) }
    return String(cString: real)
    #endif
}
