import Foundation
import CryptoKit
import Compression

/// File hashing used by OpenSubtitles: the OSDb "moviehash" for videos and MD5 for subtitles.
enum OSHash {
    static let chunkSize = 65536

    struct MovieHash {
        let moviehash: String
        let moviebytesize: String
    }

    /// OSDb hash: file size + sum of the 64-bit little-endian words of the first and last 64 KiB (mod 2^64).
    static func movieHash(of url: URL) throws -> MovieHash {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()

        var hash: UInt64 = size

        func sum(_ data: Data) {
            data.withUnsafeBytes { raw in
                let count = raw.count / 8
                for i in 0..<count {
                    let word = raw.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)
                    hash = hash &+ UInt64(littleEndian: word)
                }
            }
        }

        try handle.seek(toOffset: 0)
        sum(try handle.read(upToCount: chunkSize) ?? Data())

        let tailOffset = size > UInt64(chunkSize) ? size - UInt64(chunkSize) : 0
        try handle.seek(toOffset: tailOffset)
        sum(try handle.read(upToCount: chunkSize) ?? Data())

        let hex = String(hash, radix: 16)
        return MovieHash(moviehash: String(repeating: "0", count: max(0, 16 - hex.count)) + hex,
                         moviebytesize: String(size))
    }

    static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var md5 = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            md5.update(data: chunk)
        }
        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// zlib-compressed (RFC 1950, like Node's zlib.deflate) and base64 encoded file content.
    static func subtitleContent(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return zlibCompress(data).base64EncodedString()
    }

    static func zlibCompress(_ input: Data) -> Data {
        let raw = (try? (input as NSData).compressed(using: .zlib)) as Data? ?? Data()
        var out = Data([0x78, 0x9C])
        out.append(raw)
        var adler = adler32(input).bigEndian
        out.append(Data(bytes: &adler, count: 4))
        return out
    }

    static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}
