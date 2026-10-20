// Checks a Sparkle appcast against the archive it announces, with the PUBLIC key only (no private key needed):
//   swift scripts/verify-appcast.swift <appcast.xml> <archive.zip> <SUPublicEDKey> [<expected short version>]
// Passes when the appcast has exactly one item whose enclosure names the archive, whose length is the archive's size,
// and whose sparkle:edSignature is a valid Ed25519 signature of the archive under the public key; and, if given, the
// item's sparkle:shortVersionString is the expected version. release.yml runs it on every appcast it generates.

import Foundation
import CryptoKit

let args = CommandLine.arguments
guard args.count >= 4 else {
    FileHandle.standardError.write(Data("usage: verify-appcast.swift <appcast.xml> <archive.zip> <SUPublicEDKey> [<expected short version>]\n".utf8))
    exit(2)
}
let appcastURL = URL(fileURLWithPath: args[1]), archiveURL = URL(fileURLWithPath: args[2])
let expectedVersion = args.count > 4 ? args[4] : nil
let sparkleNS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
var failures: [String] = []
func check(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { failures.append(message()) } }

do {
    let doc = try XMLDocument(contentsOf: appcastURL, options: [])
    let items = doc.rootElement()?.elements(forName: "channel").first?.elements(forName: "item") ?? []
    check(items.count == 1, "expected one <item>, found \(items.count)")
    guard let item = items.first, let enclosure = item.elements(forName: "enclosure").first else {
        throw NSError(domain: "verify-appcast", code: 1, userInfo: [NSLocalizedDescriptionKey: "no <item>/<enclosure>"])
    }
    func value(_ name: String) -> String? { item.elements(forLocalName: name, uri: sparkleNS).first?.stringValue }
    func attr(_ name: String, ns: String? = nil) -> String? {
        ns.map { enclosure.attribute(forLocalName: name, uri: $0)?.stringValue } ?? enclosure.attribute(forName: name)?.stringValue
    }
    let data = try Data(contentsOf: archiveURL)
    let url = attr("url") ?? ""
    let length = attr("length") ?? ""
    let signature = attr("edSignature", ns: sparkleNS) ?? ""
    let shortVersion = value("shortVersionString") ?? ""
    print("item: version \(shortVersion) (\(value("version") ?? "?")), minimum macOS \(value("minimumSystemVersion") ?? "?")")
    print("enclosure: \(url)")
    print("length: \(length), archive: \(data.count) bytes")

    check(URL(string: url)?.lastPathComponent == archiveURL.lastPathComponent, "enclosure url doesn't name \(archiveURL.lastPathComponent)")
    check(url.hasPrefix("https://"), "enclosure url isn't https")
    check(Int(length) == data.count, "length \(length) != archive size \(data.count)")
    if let expectedVersion { check(shortVersion == expectedVersion, "shortVersionString \(shortVersion) != \(expectedVersion)") }

    guard let keyData = Data(base64Encoded: args[3]), let sig = Data(base64Encoded: signature) else {
        throw NSError(domain: "verify-appcast", code: 1, userInfo: [NSLocalizedDescriptionKey: "public key or signature is not base64"])
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyData)
    let valid = key.isValidSignature(sig, for: data)
    print("EdDSA signature: \(valid ? "valid" : "INVALID") for public key \(args[3])")
    check(valid, "the signature doesn't verify with the public key")
} catch {
    failures.append(error.localizedDescription)
}

if failures.isEmpty {
    print("appcast OK")
} else {
    failures.forEach { FileHandle.standardError.write(Data("error: \($0)\n".utf8)) }
    exit(1)
}
