import Foundation

extension WindowsCore {
    nonisolated public struct OpeningChanged: Error, CustomStringConvertible {
        public var description: String { "The design changed while it was opening." }
    }

    /// Values the worker can prepare without changing the open tab, files or sharing session.
    nonisolated public struct PreparedOpen: Sendable {
        let url: URL
        let document: BezzleDocument
        let shared: SharedSession.Prepared?
        fileprivate let revision: OpeningRevision
        fileprivate let replica: String

        var isCurrent: Bool {
            let current = OpeningRevision(of: url)
            guard current.document == revision.document, current.package == revision.package, current.link == revision.link,
                  current.sharedFolder == revision.sharedFolder, current.room == revision.room else { return false }
            if current.parts == revision.parts { return true }
            guard let folder = shared?.folder, folder.opened.first == nil,
                  !folder.seen.people.isEmpty || SyncedPlaces.service(of: url) != nil,
                  revision.parts.isSubset(of: current.parts) else { return false }
            // The folder watcher will take in others' new parts, but does not read our own.
            return !current.parts.subtracting(revision.parts).contains { $0.hasPrefix(replica + "/") }
        }
    }

    public static func prepareOpen(_ url: URL) async throws -> PreparedOpen {
        try await DesignOpening.shared.prepare(url, replica: replica)
    }
}

private nonisolated struct OpeningRevision: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let identity: FileIdentity?
        let modified: Date?
        let size: Int?

        init(_ url: URL) {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            identity = FileIdentity(of: url)
            modified = attributes?[.modificationDate] as? Date
            size = (attributes?[.size] as? NSNumber)?.intValue
        }
    }

    let document: File
    let package: FileIdentity?
    let link: ShareLink?
    let sharedFolder: Bool
    let room: File?
    /// Shares write new part names and keep existing parts immutable.
    let parts: Set<String>

    init(of url: URL) {
        document = File(WindowsCore.documentFile(in: url))
        package = FolderCopy.isPackage(url) ? FileIdentity(of: url) : nil
        link = Linking.link(of: url)
        sharedFolder = FolderCopy.applies(to: url)
        room = sharedFolder || link != nil ? File(FolderShare.roomURL(of: url)) : nil
        var parts: Set<String> = []
        if room != nil {
            let fm = FileManager.default
            let people = FolderShare.people(of: url)
            for replica in (try? fm.contentsOfDirectory(atPath: people.path)) ?? [] {
                let names = (try? fm.contentsOfDirectory(atPath: people.appendingPathComponent(replica).path)) ?? []
                for name in names where FolderShare.Part(fileName: name) != nil { parts.insert(replica + "/" + name) }
            }
        }
        self.parts = parts
    }
}

/// One worker per application keeps multiple large opens from decoding at once.
private actor DesignOpening {
    static let shared = DesignOpening()

    func prepare(_ url: URL, replica: String) throws -> WindowsCore.PreparedOpen {
        try Task.checkCancellation()
        let revision = OpeningRevision(of: url)
        let document = try WindowsCore.readDocument(WindowsCore.documentFile(in: url))
        try Task.checkCancellation()
        let shared = revision.sharedFolder || revision.link != nil
            ? try SharedSession.prepare(url, replica: replica, file: document, link: revision.link) : nil
        try Task.checkCancellation()
        return WindowsCore.PreparedOpen(url: url, document: document, shared: shared, revision: revision, replica: replica)
    }
}
