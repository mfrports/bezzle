import Foundation

/// How a shared design's changes are kept: by each computer that has it, in files or records of its
/// own that nobody else ever writes, merged by everyone into the same design (see `SharedDesign`),
/// in whatever order they come and however late. Nothing is ever written over, so no edit is lost.
///
/// The same parts are kept in two places:
///
/// - **In the design's package**, in `sharing/people/<replica>/` for each computer: `me.json` (who),
///   `c-<upTo>.lzfse` (changes, its own and any it took in from the relay), `w-<upTo>.lzfse` (the
///   whole design as it had it) and `versions.json`. A design kept in a folder that Google Drive,
///   Dropbox or the like keep in step is so never written over when several people have it open,
///   as each writes only in its own folder. To iCloud Drive the package is one item all the same,
///   so on the Mac only the computer that changes the design writes in it (`DocumentStore.save`).
///   `sharing/room.json` holds the secret of its live room.
/// - **On the relay**, for a design shared by link, as sealed records: `c.<replica>.<upTo>`,
///   `w.<replica>.<upTo>`, `m.<replica>`, and the rest in Relay/SHARING.md.
///
/// Everything here works on names, bytes and times handed in, so that the browser's Bezzle uses it
/// as it is; `FolderSync` and `CloudShare` do the reading and writing on the Mac.
nonisolated enum FolderShare {
    /// The folder of people, in the design's `sharing` folder.
    static let peopleFolder = "people"
    static let roomFile = "room.json"
    static let personFile = "me.json"
    static let versionsFile = "versions.json"

    /// How many parts of changes a copy writes before folding them into a whole.
    static let foldAfter = 24

    // MARK: Parts

    /// One of a copy's parts: changes, or the whole design as it had it.
    struct Part: Hashable, Comparable, Sendable {
        enum Kind: String, Sendable {
            case changes = "c"
            case whole = "w"
        }

        var kind: Kind
        /// Milliseconds since 1970: no earlier than the latest change it holds, and later than
        /// the copy's part before it.
        var upTo: Int64

        init(_ kind: Kind, upTo: Int64) {
            self.kind = kind
            self.upTo = upTo
        }

        /// Fifteen digits, so that names sort as their times do for a long while yet.
        var digits: String {
            let plain = String(upTo)
            return String(repeating: "0", count: max(0, 15 - plain.count)) + plain
        }

        /// As a file in the copy's folder in the package.
        var fileName: String { "\(kind.rawValue)-\(digits).lzfse" }

        /// As a record on the relay.
        func record(of replica: String) -> String { "\(kind.rawValue).\(replica).\(digits)" }

        init?(fileName name: String) {
            guard name.hasSuffix(".lzfse") else { return nil }
            let parts = name.dropLast(".lzfse".count).split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 2, let part = Self.parse(parts[0], parts[1]) else { return nil }
            self = part
        }

        /// A record's part and whose it is.
        static func record(_ key: String) -> (replica: String, part: Part)? {
            let parts = key.split(separator: ".", omittingEmptySubsequences: false)
            guard parts.count == 3, FolderShare.isReplica(parts[1]), let part = parse(parts[0], parts[2]) else { return nil }
            return (String(parts[1]), part)
        }

        private static func parse(_ kind: Substring, _ digits: Substring) -> Part? {
            guard let kind = Kind(rawValue: String(kind)), digits.count == 15,
                  digits.allSatisfy({ $0.isASCII && $0.isNumber }), let upTo = Int64(digits) else { return nil }
            return Part(kind, upTo: upTo)
        }

        /// By time; of a change and a whole up to the same time, the change first.
        static func < (a: Part, b: Part) -> Bool {
            a.upTo != b.upTo ? a.upTo < b.upTo : (a.kind == .changes && b.kind == .whole)
        }
    }

    /// What a copy's id may be: lowercase letters and digits, as many as 32.
    static func isReplica<S: StringProtocol>(_ text: S) -> Bool {
        (1...32).contains(text.count) && text.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
    }

    static func parts(files names: [String]) -> [Part] { names.compactMap(Part.init(fileName:)).sorted() }

    /// Of a copy's parts, which to read, given those of them read already and those that would
    /// not open: its newest whole that opens, and every part of changes after it, not read yet.
    /// Changes up to that whole are in it.
    ///
    /// One following the copy along needs no whole: a copy deletes only its parts from before the
    /// whole before its newest, so whoever read that one, or the changes written with it, finds
    /// every change since still there. A whole that would not open is passed over for the one
    /// before; a part of changes that would not open is tried again, as there is nothing else to
    /// take it from.
    static func toRead(_ parts: [Part], read: Set<Part>, failed: Set<Part> = []) -> [Part] {
        let all = parts.sorted()
        func unread(after time: Int64) -> [Part] { all.filter { $0.kind == .changes && $0.upTo > time && !read.contains($0) } }
        guard let whole = all.last(where: { $0.kind == .whole && !failed.contains($0) }) else { return unread(after: .min) }
        if read.contains(whole) { return unread(after: whole.upTo) }
        let previous = all.last { $0.kind == .whole && $0.upTo < whole.upTo }
        let following = !read.isEmpty && all.contains(Part(.changes, upTo: whole.upTo))
            && (previous.map { read.contains($0) || read.contains(Part(.changes, upTo: $0.upTo)) } ?? true)
        if following { return unread(after: previous?.upTo ?? .min) }
        return [whole] + unread(after: whole.upTo)
    }

    /// Whether a copy whose parts are these folds its changes into a whole now.
    static func shouldFold(_ parts: [Part]) -> Bool {
        let since = parts.filter { $0.kind == .whole }.max()?.upTo ?? .min
        return parts.filter { $0.kind == .changes && $0.upTo > since }.count >= foldAfter
    }

    /// The parts a copy deletes of its own once it has written a whole up to `upTo`: all those from
    /// before the whole it wrote last, which stays, so that there are always two.
    static func folded(_ parts: [Part], into upTo: Int64) -> [Part] {
        guard let previous = parts.filter({ $0.kind == .whole && $0.upTo < upTo }).max() else { return [] }
        return parts.filter { $0.upTo < previous.upTo }
    }

    /// The time the next part a copy writes goes by: no earlier than everything in it, and later
    /// than its parts so far, so that no two of its parts ever share a name.
    static func nextUpTo(_ clock: Int64, after parts: [Part]) -> Int64 {
        max(clock, (parts.map(\.upTo).max() ?? 0) + 1)
    }

    // MARK: Packing

    /// A shared design as its parts keep it: JSON, packed with LZFSE, as the relay's records are.
    static func pack(_ design: SharedDesign) -> Data? {
        guard let json = try? JSONEncoder().encode(design) else { return nil }
        return try? (json as NSData).compressed(using: .lzfse) as Data
    }

    static func unpack(_ data: Data) -> SharedDesign? {
        #if os(Windows)
        guard let json = try? data.decompressedLZFSE() else { return nil }
        #else
        guard let json = try? (data as NSData).decompressed(using: .lzfse) as Data else { return nil }
        #endif
        return try? JSONDecoder().decode(SharedDesign.self, from: json)
    }

    // MARK: The first share

    /// The design as its own file has it, taken in as everything's first change, stamped with the
    /// time that file was written (`modified`, in milliseconds since 1970): whatever anyone changes
    /// after it, here or elsewhere, wins. Two computers that both start from a copy of the same file
    /// make the same design of it.
    static func first(_ doc: BezzleDocument, modified: Int64, by replica: String) -> SharedDesign {
        var design = SharedDesign()
        design.absorb(FlatDesign(doc), since: FlatDesign(), by: replica, at: max(1, modified))
        return design
    }

    // MARK: Who is who

    /// Who works on the design from one computer, as its `me.json` or `m.` record has it.
    struct Person: Codable, Equatable, Sendable {
        var replica: String
        var name: String
        /// "mac", "web" or "windows": only said, never acted on.
        var app: String
        /// When they first worked on it, in milliseconds since 1970.
        var since: Int64

        init(replica: String, name: String, app: String = "mac", since: Int64) {
            self.replica = replica
            self.name = name
            self.app = app
            self.since = since
        }

        /// Whether this is the same person as `other`: the same computer, or one of the same name,
        /// as one person's own Macs are.
        func isSamePerson(as other: Person) -> Bool {
            replica == other.replica || name == other.name
        }
    }

    /// The live room of a design kept in a synced folder: the secret everything said in it is
    /// sealed with, which everyone with the folder has.
    struct Room: Codable, Equatable, Sendable {
        /// 32 random bytes, as hex.
        var seed: String
        /// When it was made, in milliseconds since 1970.
        var made: Int64

        /// A new room; `bytes` are random, 32 of them.
        init(bytes: [UInt8], made: Int64) {
            seed = bytes.map { String(format: "%02x", $0) }.joined()
            self.made = made
        }

        static func fresh(at time: Int64) -> Room {
            var random = SystemRandomNumberGenerator()
            return Room(bytes: (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &random) }, made: time)
        }

        var isValid: Bool { seed.count == 64 && seed.allSatisfy(\.isHexDigit) }
    }

    static func encode<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }
}

/// The records of a design's room on the relay, by their keys (see Relay/SHARING.md).
nonisolated enum ShareRecord: Hashable, Sendable {
    /// The design's name and who shared it; only they write it.
    case meta
    /// Who works on it from one computer.
    case person(String)
    /// One of a copy's parts.
    case part(String, FolderShare.Part)
    /// A picture, by the name the room's keys give it.
    case picture(String)
    /// A named version: what it is, and the design it keeps.
    case version(UUID)
    case versionDesign(UUID)

    var key: String {
        switch self {
        case .meta: "meta"
        case .person(let replica): "m.\(replica)"
        case .part(let replica, let part): part.record(of: replica)
        case .picture(let name): "p.\(name)"
        case .version(let id): "v.\(id.uuidString)"
        case .versionDesign(let id): "d.\(id.uuidString)"
        }
    }

    init?(key: String) {
        if key == "meta" {
            self = .meta
            return
        }
        if let (replica, part) = FolderShare.Part.record(key) {
            self = .part(replica, part)
            return
        }
        guard key.count > 2, key.dropFirst().first == "." else { return nil }
        let rest = String(key.dropFirst(2))
        switch key.first {
        case "m" where FolderShare.isReplica(rest): self = .person(rest)
        case "p" where rest.count == 64 && rest.allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }): self = .picture(rest)
        case "v": guard let id = UUID(uuidString: rest) else { return nil }; self = .version(id)
        case "d": guard let id = UUID(uuidString: rest) else { return nil }; self = .versionDesign(id)
        default: return nil
        }
    }
}

/// What the owner says of the design in its `meta` record.
nonisolated struct ShareMeta: Codable, Equatable, Sendable {
    var title: String
    var owner: String
    var made: Int64
}
