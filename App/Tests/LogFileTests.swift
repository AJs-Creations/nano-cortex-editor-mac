// The Activity log file (LogFile.swift): capped, one rotated file kept. And Developer tools default to off (DevTools.swift).
import XCTest

final class LogFileTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appending(path: "logfile-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func size(_ url: URL) -> Int { ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? -1 }

    func testRotatesPastTheCapAndKeepsOneOldFile() {
        let url = dir.appending(path: "activity.log")
        let log = RotatingLogFile(url: url, limit: 1000)
        XCTAssertEqual(log.rotatedURL.lastPathComponent, "activity.1.log")
        let line = String(repeating: "x", count: 99)   // 100 bytes with the newline
        for _ in 0..<10 { log.append(line) }
        XCTAssertEqual(size(url), 1000, "exactly at the cap: no rotation yet")
        XCTAssertFalse(FileManager.default.fileExists(atPath: log.rotatedURL.path))
        log.append(line)
        XCTAssertEqual(size(log.rotatedURL), 1000, "the full file moved to activity.1.log")
        XCTAssertEqual(size(url), 100, "a fresh file holds the new line")
        for i in 0..<25 { log.append("line \(i) " + String(repeating: "y", count: 80)) }
        log.close()
        XCTAssertLessThanOrEqual(size(url), 1000)
        XCTAssertLessThanOrEqual(size(log.rotatedURL), 1000)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.sorted() ?? []
        XCTAssertEqual(files, ["activity.1.log", "activity.log"], "only one old file is kept")
        let last = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").last.map(String.init) ?? ""
        XCTAssertTrue(last.hasPrefix("line 24 "), "the newest line is at the end of the current file")
    }

    func testAnExistingLargeFileRotatesOnTheNextLine() throws {
        let url = dir.appending(path: "activity.log")
        try Data(repeating: 65, count: 1500).write(to: url)   // left over from a previous launch
        let log = RotatingLogFile(url: url, limit: 1000)
        log.append("after relaunch")
        log.close()
        XCTAssertEqual(size(log.rotatedURL), 1500)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "after relaunch\n")
    }

    func testEnsureExistsRecreatesADeletedFile() throws {
        let url = dir.appending(path: "Logs/activity.log")
        let log = RotatingLogFile(url: url, limit: 1000)
        log.ensureExists()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Show Log File creates it (and its folder)")
        log.append("one")
        try FileManager.default.removeItem(at: url)
        log.ensureExists()
        log.append("two")
        log.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "two\n")
    }

    func testDeveloperToolsAreOffByDefault() throws {
        let suite = "devtools-tests-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DevTools.key, "ui.devTools")
        XCTAssertFalse(DevTools.isOn(in: d), "fresh install, or settings saved before the switch existed")
        d.set(true, forKey: DevTools.key)
        XCTAssertTrue(DevTools.isOn(in: d))
        d.set(false, forKey: DevTools.key)
        XCTAssertFalse(DevTools.isOn(in: d))
    }
}
