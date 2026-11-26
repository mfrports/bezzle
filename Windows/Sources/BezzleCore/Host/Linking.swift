import Foundation

// From Bezzle/Store/Sharing.swift: sharing designs by link, through Bezzle's relay on Cloudflare
// (Relay/SHARING.md). Anyone with the link can work on the design, from Bezzle on a Mac, on
// Windows or in a browser, with no account of any kind. The computer that shared a design is its
// owner: only it can stop sharing it; the others then keep it as it last was, read only.
// The relay's requests and the link itself are the shared Model/RelayRooms.swift.

enum Linking {
    /// Where the relay is: Bezzle's own, or in tests one of their own (`BEZZLE_RELAY`), never the
    /// real one; none, and nothing is shared by link.
    nonisolated static let relay: URL? = {
        #if DEBUG
        // "off" for none at all, as PowerShell drops a variable set to nothing.
        if let given = ProcessInfo.processInfo.environment["BEZZLE_RELAY"] { return given.isEmpty || given == "off" ? nil : URL(string: given) }
        #endif
        return URL(string: "https://bezzle-live.bezzle-live.workers.dev")
    }()

    nonisolated(unsafe) static var server: ShareServer? = relay.map { RelayServer(base: $0) }

    // MARK: Which design is which

    /// Each shared design's room, with where the design is on this computer.
    private static var index: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "sharedRooms") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "sharedRooms") }
    }

    /// A path to compare: Windows does not tell capitals from small letters in its paths.
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    static func url(of room: String) -> URL? {
        index[room].map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Whether the design at `url` is this computer's copy of `room`. A copy of it made in Explorer
    /// is not, while the copy this computer has is still there.
    static func claim(_ room: String, at url: URL) -> Bool {
        let path = key(url)
        if let known = index[room], known != path, FileManager.default.fileExists(atPath: known),
           link(of: URL(fileURLWithPath: known))?.keys?.room == room { return false }
        index[room] = path
        return true
    }

    /// What this computer keeps of each room it has a part in, never in the design: the token its
    /// records are written with, and for those it shared, the owner's.
    private static var tokens: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: "shareTokens") as? [String: [String: String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "shareTokens") }
    }

    /// The token this computer writes its records in `room` with, made the first time.
    static func writer(for room: String) -> String {
        if let token = tokens[room]?["writer"] { return token }
        let token = ShareKeys.newSecret().base64URL
        tokens[room, default: [:]]["writer"] = token
        return token
    }

    static func ownerToken(for room: String) -> String? { tokens[room]?["owner"] }

    /// This computer shared the design whose room this is, and can stop sharing it with `token`.
    static func own(_ room: String, with token: String) { tokens[room, default: [:]]["owner"] = token }

    static func owns(_ room: String) -> Bool { ownerToken(for: room) != nil }

    private static func forget(_ room: String) {
        tokens[room] = nil
        index[room] = nil
    }

    // MARK: The design's link, in its package

    nonisolated private static func linkFile(_ design: URL) -> URL { FolderShare.sharing(of: design).appendingPathComponent("share.json") }

    nonisolated static func link(of design: URL) -> ShareLink? {
        (try? Data(contentsOf: linkFile(design))).flatMap { FolderShare.decode(ShareLink.self, from: $0) }
    }

    static func write(_ link: ShareLink, to design: URL) throws {
        try WindowsCore.makeFolder(FolderShare.sharing(of: design), in: design)
        guard let data = FolderShare.encode(link) else { throw WindowsCore.CoreError("The link could not be kept.") }
        try data.write(to: linkFile(design), options: .atomic)
    }

    static func unlink(_ design: URL) { try? FileManager.default.removeItem(at: linkFile(design)) }
}

extension WindowsCore {
    /// Why sharing could not be done, in words for the person sharing.
    nonisolated public struct ShareProblem: Swift.Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// The open design's link, for Copy Link: shared first if it is not yet, once everything in it
    /// is on the relay (the Mac's Sharing.copyLink). `progress` counts the pictures sent.
    public static func shareLink(progress: @escaping (Int, Int) -> Void = { _, _ in }) async throws -> String {
        guard let server = Linking.server else { throw ShareProblem(String(localized: "This copy of Bezzle cannot share designs.")) }
        guard !isReadOnly else { throw ShareProblem(String(localized: "This design is no longer shared with you. Save a copy of it to share that.")) }
        try save()
        try makePackage()
        guard let url = designURL else { throw ShareProblem(String(localized: "The design could not be shared.")) }
        if let session = sharing, let link = session.link, let cloud = session.cloud, let page = link.page {
            try await cloud.sendEverything(progress: progress)
            return page.absoluteString
        }
        let secret = ShareKeys.newSecret()
        guard let keys = ShareKeys(secret: secret) else { throw ShareProblem(String(localized: "The design could not be shared.")) }
        let owner = ShareKeys.newSecret().base64URL
        try await server.create(keys.room, hashes: ["read": CloudRoom.hash(keys.readToken), "write": CloudRoom.hash(keys.writeToken), "owner": CloudRoom.hash(owner)])
        Linking.own(keys.room, with: owner)
        let title = url.deletingPathExtension().lastPathComponent
        let link = ShareLink(secret: secret.base64URL, title: title, ownerName: myName)
        try Linking.write(link, to: url)
        _ = Linking.claim(keys.room, at: url)
        let session: SharedSession
        if let open = sharing {
            session = open
            session.shared(link)
        } else {
            guard let doc = previewBase ?? design, let made = SharedSession.open(url, replica: replica, file: doc) else {
                throw ShareProblem(String(localized: "The design could not be shared."))
            }
            _ = made.document()
            sharing = made
            made.start(with: doc)
            session = made
        }
        guard let cloud = session.cloud, let page = link.page else { throw ShareProblem(String(localized: "The design could not be shared.")) }
        try await cloud.sendMeta(ShareMeta(title: title, owner: myName, made: nowMilliseconds))
        try await cloud.sendEverything(progress: progress)
        return page.absoluteString
    }

    /// Whether the open design is one this computer shared, which it can stop sharing.
    public static var canStopSharing: Bool {
        guard let room = sharing?.cloud?.keys.room else { return false }
        return Linking.owns(room)
    }

    /// Stops sharing the open design, which this computer shared: its room on the relay goes,
    /// with everything in it, and the others keep it as it last was. Here it goes on as a design
    /// of its own (the Mac's Sharing.stopSharing).
    public static func stopSharing() async throws {
        guard let session = sharing, let cloud = session.cloud, let owner = Linking.ownerToken(for: cloud.keys.room),
              let server = Linking.server else { return }
        do {
            try await server.unshare(cloud.keys.room, write: cloud.keys.writeToken, owner: owner)
        } catch ShareError.gone {
            // Gone already.
        }
        Linking.forgetRoom(cloud.keys.room)
        session.unshared(own: true)
    }

    /// Whether `text` is a design's link: `bezzle://share/2.<secret>`, or Bezzle's page on the web.
    public static func isShareLink(_ text: String) -> Bool {
        URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(CloudRoom.secret(from:)) != nil
    }

    /// A design's link was opened: the design comes from the relay into `folder` (the designs
    /// folder), its pictures following once it is open; one here already is just found. Returns
    /// where it is, to open (the Mac's Sharing.accept).
    public static func acceptLink(_ text: String, into folder: URL, arriving: @escaping (_ title: String, _ owner: String?) -> Void = { _, _ in }) async throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), let secret = CloudRoom.secret(from: url),
              let keys = ShareKeys(link: secret) else { throw ShareProblem(String(localized: "This link does not lead to a design.")) }
        if let known = Linking.url(of: keys.room), Linking.link(of: known)?.keys?.room == keys.room { return known }
        // In the designs folder already, there through a folder a sync service keeps in step from a
        // computer that opened the link before: found, not made again beside it as "Poster 2".
        let listed = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let there = FolderShare.design(sharedAs: secret, among: listed) {
            _ = Linking.claim(keys.room, at: there)
            return there
        }
        guard let server = Linking.server else { throw ShareProblem(String(localized: "This copy of Bezzle cannot share designs.")) }
        let arrived: CloudRoom.Arrived
        do {
            let fetched = try await CloudRoom.fetch(keys, from: server, progress: CloudRoom.Progress(), fully: true, replica: replica)
            if let meta = fetched.meta { arriving(meta.title, meta.owner) }
            arrived = try CloudRoom.arrived(fetched)
        } catch ShareError.gone {
            throw ShareProblem(String(localized: "This design is no longer shared."))
        } catch ShareError.missing {
            throw ShareProblem(String(localized: "This link does not lead to a design."))
        } catch {
            throw ShareProblem(String(localized: "Bezzle could not reach the design. Check the connection and open the link again."))
        }
        return try make(arrived, secret: secret, keys: keys, in: folder)
    }

    /// Makes the design that came from a link in `folder`.
    private static func make(_ arrived: CloudRoom.Arrived, secret: String, keys: ShareKeys, in folder: URL) throws -> URL {
        let title = arrived.meta?.title.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-") ?? ""
        let name = title.isEmpty ? String(localized: "Shared Design") : title
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(name).bezzle")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(i).bezzle")
            i += 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
        try encoder.encode(arrived.state.flatDesign().document()).write(to: url.appendingPathComponent("document.json"), options: .atomic)
        try Linking.write(ShareLink(secret: secret, title: arrived.meta?.title, ownerName: arrived.meta?.owner), to: url)
        _ = Linking.claim(keys.room, at: url)
        guard FolderCopy.open(url, replica: replica, seed: arrived.state, file: nil) != nil else {
            throw ShareProblem(String(localized: "The design could not be kept."))
        }
        CloudCopy.keep(arrived.progress, of: url, replica: replica)
        return url
    }

    /// Sends and takes in what there is in the open design's room now, and shows what came if
    /// nothing holds it back: for the headless checks. True when the design shown changed.
    @discardableResult public static func syncShareNow() async -> Bool {
        if let cloud = sharing?.cloud { await cloud.syncNow() }
        return lookAtShare()
    }

    /// Why the relay could not be reached, if it could not, for the window to say.
    public static var shareProblem: String? { sharing?.cloud?.problem }
}

extension Linking {
    /// Forgets the room: its tokens, and which design it was.
    static func forgetRoom(_ room: String) { forget(room) }
}
