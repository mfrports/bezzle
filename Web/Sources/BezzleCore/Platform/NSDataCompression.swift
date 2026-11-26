import Foundation
import LZFSE

// Apple's Foundation compresses data; here LZFSE is Apple's own reference code (Sources/LZFSE),
// which is what shared designs are packed with. zlib, which only the icon library uses, is the host's
// where it has one (`inflate`).
nonisolated public extension NSData {
    enum CompressionAlgorithm: Int, Sendable { case lzfse, lz4, lzma, zlib }

    struct Unsupported: Error {}
    struct Corrupt: Error {}

    /// Raw DEFLATE unpacked by the host, where it has one (Windows, through its zlib): what the
    /// icon library is packed with. The browser has none yet.
    nonisolated(unsafe) static var inflate: ((Data) -> Data?)?

    func decompressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        if algorithm == .zlib, let inflate = Self.inflate {
            guard let out = inflate(self as Data) else { throw Corrupt() }
            return out as NSData
        }
        guard algorithm == .lzfse else { throw Unsupported() }
        return try (self as Data).decompressedLZFSE() as NSData
    }

    func compressed(using algorithm: CompressionAlgorithm) throws -> NSData {
        guard algorithm == .lzfse else { throw Unsupported() }
        let input = [UInt8](self as Data)
        let capacity = input.count + input.count / 8 + 4096
        var out = [UInt8](repeating: 0, count: capacity)
        let scratch = UnsafeMutableRawPointer.allocate(byteCount: lzfse_encode_scratch_size(), alignment: 16)
        defer { scratch.deallocate() }
        let n = out.withUnsafeMutableBufferPointer { o in
            input.withUnsafeBufferPointer { i in lzfse_encode_buffer(o.baseAddress!, capacity, i.baseAddress!, input.count, scratch) }
        }
        guard n > 0 else { throw Corrupt() }
        return Data(out[0..<n]) as NSData
    }
}

nonisolated extension Data {
    /// Keeps a large archive in contiguous buffers through decompression.
    func decompressedLZFSE() throws -> Data {
        guard !isEmpty else { return Data() }
        let limit = 1 << 30
        guard count <= limit / 8 else { throw NSData.Corrupt() }
        var capacity = Swift.max(count * 8, 4096)
        while true {
            var out = Data(count: capacity)
            let n = out.withUnsafeMutableBytes { output in
                withUnsafeBytes { source in
                    lzfse_decode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, output.count,
                                        source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil)
                }
            }
            if n == 0 { throw NSData.Corrupt() }
            if n < capacity {
                return out.withUnsafeBytes { Data(bytes: $0.baseAddress!, count: n) }
            }
            // A full buffer may have truncated the result. Check before multiplying on 32-bit hosts.
            if capacity > limit / 4 { throw NSData.Corrupt() }
            capacity *= 4
        }
    }
}

nonisolated public extension NSMutableAttributedString {
    convenience init() { self.init(string: "") }
}
