import XCTest
@testable import NanoCore

final class CaptureBundleTests: XCTestCase {
    /// A synthetic Cloud download: gzip tar of <hash>.cns (1289 made-up bytes ending in "NANO-TEST") + <hash>.json
    /// ("Test Capture" by "Tester"), built with Python's tarfile/gzip. Not a real capture.
    static let syntheticBundle = "H4sIAAUWyGoC/+3VZXDUUBAA4MPd3Y/g0CtJLictTlugyBXoFSul5JKXu5Q2d0RKSynu7u7u7u7u7u7ubklph8IffnSmw0z3+/OSfdm3szNvshbSSnCIpiwmE+JMVpZwGAmcNpIWhsMpM241mxGLGMSRtNXhY2IYFlmMCJFWjuIIzuFDeTOCpPsHXGWmqIRV9fdKUgSR9PwrTljMJqNOj+tSgSLJtKiW16VR6dJnyJgpc5as2bLnyJkrd568+fIXKFiocJGixYqXKFmqdBl9Waxc+QoVK1WuUrWal8G7Ok6QRspktlh9fGvUrFW7Tt169f38Axo0bBTYuEnTZrag5i1aBttDWrVu07ZdaPuwDuEdaYd6Zzini4/oFBkluD2dRUlWorvExHaN6xbfvUfPXr379O3Xf8DAQYOHDB02fMTIUaPHjB03fsLESZOnTJ02fcbMWbPnzJ03f8HCRYuXLF22fMXKVavXrF23fsPGTZu3bN22fcfOXbv37N23/8DBQ4ePHD12/MTJU6fPnD13/sLFS5evXL12/cbNW7fv3L13/8HDR4+fPH32/MXLV6/fvH33/sPHT5+/fP32/Qf0D/1D/2m3f1s9W5DBHhBsT6O/f0tK53+E5BZSNv9xE079Of9JHKdImP+pIQ5z0ZIL89VjKb0JmJceE+gopJ1lR5Ks96M9siIiLc5EuhU2JCTQX9skEhlIlcGoMlAqgykZLYlWZJdbDGS1HIX4HbElK4JELc4iiRF5j8y7BW2D42OSCrMommeQPdaTkEFHecJdiGa1HZl2SmosFJPVY7AwNeKkeSHxS0p95QVJFpUoJMhJ6U6FV++KlhyNRCmxGIHF6wAAAAAAAAAAAAAAAAAAAAAA4D/wE7oFPBoAKAAA"

    func testParsesCloudDownload() throws {
        let payload = Self.syntheticBundle
        let b = try CaptureBundle.parse(payloadBase64: payload, name: "ignored", cloudId: "ignored")
        XCTAssertEqual(b.cns.count, 1289)
        XCTAssertEqual(Array(b.cns.suffix(9)), Array("NANO-TEST".utf8))
        XCTAssertEqual(b.record.hash, "7281fea4755ef58d1b310a327cf0460866edecef2a8b95ccde73ee28f4f1fb94")
        XCTAssertEqual(b.record.name, "Test Capture")
        XCTAssertEqual(b.record.cloudUUID, "11111111-2222-3333-4444-555555555555")
        XCTAssertEqual(b.record.authorName, "Tester")
        XCTAssertEqual(b.record.deviceType, "amp_head")
        XCTAssertEqual(b.record.tags, ["test"])
        XCTAssertEqual(b.record.gainType, 4)
        XCTAssertEqual(b.record.instrumentType, "guitar")
        // The upload message built from it is well-formed and carries the cns.
        let parts = Messages.uploadCapture(cns: b.cns, record: b.record)
        XCTAssertGreaterThan(parts.count, 1)
    }
    func testRejectsGarbage() {
        XCTAssertThrowsError(try CaptureBundle.parse(payloadBase64: "@@@"))
        XCTAssertThrowsError(try CaptureBundle.parse(payloadBase64: Data("not gzip".utf8).base64EncodedString()))
    }
}
