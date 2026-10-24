// A Cortex Cloud capture download: `{payload: base64(gzip(tar[<hash>.cns, <hash>.json]))}`
// (PROTOCOL-NOTES §5). This unpacks it into the .cns bytes and the CaptureRecord the
// upload message needs.

import Foundation
import zlib

public enum BundleError: Error, Equatable { case badBase64, badGzip, noCns(files: [String]), badJSON }

public struct CaptureBundle: Equatable, Sendable {
    public var cns: [UInt8]
    public var record: CaptureRecord
    public var sizeKB: Double { Double(cns.count) / 1024 }

    /// `payload` is the download reply's base64; `name` and `cloudId` fill in when the JSON lacks them.
    public static func parse(payloadBase64 payload: String, name: String? = nil, cloudId: String? = nil) throws -> CaptureBundle {
        guard let gz = Data(base64Encoded: payload, options: .ignoreUnknownCharacters) else { throw BundleError.badBase64 }
        let files = Tar.entries(try Gzip.decompress(gz))
        guard let cnsName = files.keys.first(where: { $0.hasSuffix(".cns") }), let cns = files[cnsName] else { throw BundleError.noCns(files: files.keys.sorted()) }
        var meta: [String: Any] = [:]
        if let jsonName = files.keys.first(where: { $0.hasSuffix(".json") }), let data = files[jsonName] {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw BundleError.badJSON }
            meta = obj
        }
        func str(_ k: String) -> String? { meta[k] as? String }
        let record = CaptureRecord(
            hash: str("hash") ?? String(cnsName.dropLast(4)), name: str("name") ?? name ?? String(cnsName.dropLast(4)), cloudUUID: str("cloudUUID") ?? cloudId ?? "",
            authorId: str("authorId") ?? "", authorName: str("authorName") ?? "", description: CaptureText.stored(str("description")),
            deviceType: str("deviceType") ?? "default", tags: (meta["tags"] as? [String]) ?? [],
            gainType: (meta["gainType"] as? NSNumber).map { UInt64(truncating: $0) },
            instrumentType: str("instrumentType") ?? "instrument_not_set", version: (meta["version"] as? String) ?? (meta["version"] as? NSNumber).map { "\($0)" } ?? "1")
        return CaptureBundle(cns: [UInt8](cns), record: record)
    }
}

public enum Gzip {
    /// Inflates a gzip (or zlib) stream with the system zlib.
    public static func decompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        var status = inflateInit2_(&stream, 15 + 32, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))   // 32: auto-detect gzip/zlib header
        guard status == Z_OK else { throw BundleError.badGzip }
        defer { inflateEnd(&stream) }
        var out = Data()
        let chunk = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: chunk)
        try data.withUnsafeBytes { (inPtr: UnsafeRawBufferPointer) in
            stream.next_in = UnsafeMutablePointer(mutating: inPtr.bindMemory(to: Bytef.self).baseAddress!)
            stream.avail_in = uInt(data.count)
            repeat {
                try buffer.withUnsafeMutableBufferPointer { buf in
                    stream.next_out = buf.baseAddress
                    stream.avail_out = uInt(chunk)
                    status = inflate(&stream, Z_NO_FLUSH)
                    guard status == Z_OK || status == Z_STREAM_END || status == Z_BUF_ERROR else { throw BundleError.badGzip }
                    out.append(buf.baseAddress!, count: chunk - Int(stream.avail_out))
                }
            } while status != Z_STREAM_END && stream.avail_in > 0 || stream.avail_out == 0
        }
        guard status == Z_STREAM_END else { throw BundleError.badGzip }
        return out
    }
}

public enum Tar {
    /// Minimal POSIX/ustar reader: regular files by basename.
    public static func entries(_ data: Data) -> [String: Data] {
        var files: [String: Data] = [:]
        let bytes = [UInt8](data)
        var off = 0
        while off + 512 <= bytes.count {
            let nameBytes = bytes[off..<off + 100].prefix { $0 != 0 }
            guard !nameBytes.isEmpty, let name = String(bytes: nameBytes, encoding: .utf8) else { break }
            let sizeField = String(bytes: bytes[off + 124..<off + 136].prefix { $0 != 0 && $0 != 0x20 }, encoding: .ascii) ?? "0"
            let size = Int(sizeField, radix: 8) ?? 0
            let type = bytes[off + 156]
            if type == 0 || type == 0x30, off + 512 + size <= bytes.count {
                files[(name as NSString).lastPathComponent] = Data(bytes[off + 512..<off + 512 + size])
            }
            off += 512 + (size + 511) / 512 * 512
        }
        return files
    }
}
