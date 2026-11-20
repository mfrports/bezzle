import Foundation
import CBezzleHost

// A design's pictures given to Skia by name, as they are read: where one is an HEIC picture that
// Windows cannot read (CBezzleHost/heif.cpp: Windows reads HEIC only with Microsoft's HEIF Image
// Extensions and HEVC Video Extensions, and Bezzle brings no HEVC decoder of its own), it shows as
// the Mac shows a missing picture, a quiet grey, and the window says why (`heifNote`).

extension WindowsCore {
    /// Why Windows could not read a picture: it has no HEIF Image Extensions, no HEVC Video
    /// Extensions, or the file is damaged.
    public enum PictureTrouble: Int32, Sendable {
        case needsHEIF = 1
        case needsHEVC = 2
        case unreadable = 3
    }

    /// The HEIC pictures Windows could not read, by name (each picture's own UUID), and why.
    nonisolated(unsafe) static var unreadable: [String: PictureTrouble] = [:]

    /// Gives Skia one of a design's pictures by name, as its file's bytes; an HEIC picture Windows
    /// cannot read is noted. JPEGs from a package are decoded when their pixels are first needed.
    static func giveSkia(_ name: String, _ data: Data, fromPackage: Bool = false) {
        let added = data.withUnsafeBytes { bytes in
            if fromPackage { return bz_asset_add_from_package(name, bytes.baseAddress, Int32(bytes.count)) != 0 }
            return bz_asset_add(name, bytes.baseAddress, Int32(bytes.count)) != 0
        }
        if added {
            unreadable[name] = nil
        } else if data.withUnsafeBytes({ bz_heif_sniff($0.baseAddress, Int64($0.count)) }) != 0 {
            unreadable[name] = PictureTrouble(rawValue: bz_heif_problem()) ?? .unreadable
        }
    }

    /// Why HEIC pictures in the open design show grey, when some do and Windows lacks what reads
    /// them: the HEIF Image Extensions first, as without them the HEVC ones are no help.
    public static var heifNote: PictureTrouble? {
        guard !unreadable.isEmpty, let doc = previewBase ?? design else { return nil }
        let troubles = Set(SharedSession.pictures(in: doc.nodes).compactMap { unreadable[$0] })
        if troubles.contains(.needsHEIF) { return .needsHEIF }
        if troubles.contains(.needsHEVC) { return .needsHEVC }
        return nil
    }
}
