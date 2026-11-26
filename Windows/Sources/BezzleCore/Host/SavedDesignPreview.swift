import Foundation

extension WindowsCore {
    /// The saved file a worker is allowed to draw, even if its editor is already closed.
    nonisolated public struct SavedPreview: Equatable, Sendable {
        public let url: URL
        private let identity: FileIdentity
        private let modified: Date
        private let size: Int

        init?(of url: URL) {
            let file = url.appendingPathComponent("document.json")
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let size = values.fileSize,
                  let identity = FileIdentity(of: file) else { return nil }
            self.url = url
            self.identity = identity
            self.modified = modified
            self.size = size
        }

        public static func == (a: SavedPreview, b: SavedPreview) -> Bool {
            a.identity == b.identity && a.modified == b.modified && a.size == b.size &&
                a.url.standardizedFileURL.path.caseInsensitiveCompare(b.url.standardizedFileURL.path) == .orderedSame
        }
    }

    /// Local packages can be drawn from disk. Shared previews still use the editor's live state.
    public static var savedPreview: SavedPreview? {
        guard sharing == nil, let url = designURL else { return nil }
        return savedPreview(of: url)
    }

    public static func savedPreview(of url: URL) -> SavedPreview? {
        guard canRenderFromDisk(url) else { return nil }
        return SavedPreview(of: url)
    }

    public static func savedPreviewIsCurrent(_ revision: SavedPreview) -> Bool {
        savedPreview(of: revision.url) == revision && DesignPreview.isCurrent(for: revision.url)
    }

    /// Draws the saved package preview in a worker. An empty drawing produces an empty result.
    public static func renderSavedPreview(of url: URL) throws -> Data {
        let doc = try read(url)
        let assets = Assets(folder: url.appendingPathComponent("images"))
        if let jpeg = DesignPreview.jpeg(of: doc, assets: assets) { return jpeg }
        if let bounds = doc.contentBounds, bounds.width > 0, bounds.height > 0 {
            throw CoreError("Could not render the saved package preview")
        }
        return Data()
    }

    /// Keeps the returned preview only while it still describes the saved file.
    public static func keepSavedPreview(_ jpeg: Data, for revision: SavedPreview) -> Bool {
        guard SavedPreview(of: revision.url) == revision, canRenderFromDisk(revision.url) else { return false }
        DesignPreview.store(jpeg.isEmpty ? nil : jpeg, in: revision.url, keepingDate: false)
        return true
    }

    private static func canRenderFromDisk(_ url: URL) -> Bool {
        Linking.link(of: url) == nil && !FolderCopy.applies(to: url)
    }
}
