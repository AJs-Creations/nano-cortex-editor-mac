// The Activity log on disk (`~/Library/Logs/Nano Cortex Editor/activity.log`), written for every user whether or not
// Developer tools are on, so a bug report can attach it (Help → Show Log File). One handle stays open; past `limit`
// bytes the file moves to `activity.1.log` (replacing the previous one) and a new one starts. DECISION #21.
// Pure Foundation: compiled into the unit-test bundle too.

import Foundation

final class RotatingLogFile {
    let url: URL
    let limit: UInt64
    private var handle: FileHandle?
    private var size: UInt64 = 0

    /// `activity.log` → `activity.1.log`.
    var rotatedURL: URL { url.deletingPathExtension().appendingPathExtension("1").appendingPathExtension(url.pathExtension) }

    init(url: URL, limit: UInt64 = 2 * 1024 * 1024) {
        self.url = url
        self.limit = limit
    }
    deinit { try? handle?.close() }

    /// Appends one line (a newline is added). Rotates first when the line would take the file past `limit`.
    func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        if handle == nil { open() }
        if size > 0, size + UInt64(data.count) > limit { rotate() }
        guard let handle else { return }
        do { try handle.write(contentsOf: data); size += UInt64(data.count) } catch { close() }
    }

    /// Creates the file if it is missing (also after someone deleted it while the handle was open), so it can be revealed.
    func ensureExists() {
        if !FileManager.default.fileExists(atPath: url.path) { close() }
        if handle == nil { open() }
    }

    func close() { try? handle?.close(); handle = nil; size = 0 }

    private func open() {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        size = (try? handle?.seekToEnd()) ?? 0
    }

    private func rotate() {
        close()
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: url, to: rotatedURL)
        open()
    }
}
