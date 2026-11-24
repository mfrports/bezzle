import AppKit
import CryptoKit
import Observation
import UniformTypeIdentifiers

/// Where designs live: new ones go in the designs folder, Documents › Bezzle unless another was
/// chosen, and any opened from elsewhere are remembered, so the home screen can show them all,
/// latest first.
@Observable
final class Library {
    static let shared = Library()

    struct Entry: Identifiable, Equatable {
        var url: URL
        var modified: Date
        /// How it is shared, if it is.
        var sharing: SharingMark?
        /// Which card it is on the home screen. A rename keeps it, so the card stays as it was,
        /// with its new name.
        var key: String
        var id: URL { url }
        var name: String { url.deletingPathExtension().lastPathComponent }
    }

    private(set) var entries: [Entry] = []
    /// The cards of designs renamed since Bezzle started, by the path each is now at. (A package's
    /// address may or may not end in a slash, so designs are told apart by path.)
    @ObservationIgnored private var keys: [String: String] = [:]

    /// The designs folder: new designs are made in it, and the home screen shows every design in
    /// it. Another can be chosen; see `use(_:moving:)`.
    private(set) var folder: URL

    /// Debug and test runs keep their designs somewhere of their own, never among the user's.
    private static func startingFolder() -> URL {
        if let path = ProcessInfo.processInfo.environment["BEZZLE_LIBRARY"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if Library.isolated {
            return FileManager.default.temporaryDirectory.appendingPathComponent("BezzleTests", isDirectory: true)
        }
        return chosenFolder() ?? standardFolder
    }

    private static var documents: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }

    /// Where designs are kept until another folder is chosen. In the sandbox, this is the
    /// Documents folder of Bezzle's own container.
    static var standardFolder: URL { documents.appendingPathComponent("Bezzle", isDirectory: true) }

    /// The folder chosen for designs, as a bookmark, which the sandbox needs to let Bezzle in
    /// again after it quits.
    static let folderKey = "designsFolder"

    /// The folder chosen for designs, opened until Bezzle quits; nil when none was chosen, or when
    /// it can't be reached now, on a disk that isn't plugged in, say, or after it went to the
    /// Trash. Its bookmark is kept for when it can be reached again.
    private static func chosenFolder() -> URL? {
        guard let data = settings.data(forKey: folderKey) else { return nil }
        var stale = false
        guard let url = (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale))
                ?? (try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale))
        else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder), isFolder.boolValue,
              !url.pathComponents.contains(where: { $0 == ".Trash" || $0 == ".Trashes" }) else { return nil }
        if stale, let fresh = bookmark(of: url) { settings.set(fresh, forKey: folderKey) }
        return url.standardizedFileURL
    }

    private static func bookmark(of url: URL) -> Data? {
        (try? url.bookmarkData(options: .withSecurityScope)) ?? (try? url.bookmarkData())
    }

    /// The app was called Vellum before. The first time it starts as Bezzle, Documents › Vellum
    /// becomes Documents › Bezzle, and the settings kept under the old name come across.
    static func moveInFromVellum() {
        guard !isolated else { return }
        moveDesigns(from: documents.appendingPathComponent("Vellum", isDirectory: true),
                    to: documents.appendingPathComponent("Bezzle", isDirectory: true))
        let defaults = UserDefaults.standard
        let key = "settingsFromVellum"
        guard let id = Bundle.main.bundleIdentifier, !defaults.bool(forKey: key),
              let old = defaults.persistentDomain(forName: "com.erik.Vellum") else { return }
        // Anything already set under the new name wins.
        let current = defaults.persistentDomain(forName: id) ?? [:]
        defaults.setPersistentDomain(old.merging(current) { $1 }.merging([key: true]) { $1 }, forName: id)
    }

    /// Moves an old library folder to where the library now is, its designs renamed to the new
    /// extension, unless a library is there already.
    static func moveDesigns(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        do {
            try fm.moveItem(at: old, to: new)
        } catch {
            NSLog("Bezzle could not move %@ to %@: %@", old.path, new.path, error.localizedDescription)
            return
        }
        for url in (try? fm.contentsOfDirectory(at: new, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == BezzleDocument.oldFileExtension {
            let renamed = url.deletingPathExtension().appendingPathExtension(BezzleDocument.fileExtension)
            if !fm.fileExists(atPath: renamed.path) { try? fm.moveItem(at: url, to: renamed) }
        }
    }

    /// Unit tests and debug runs with a library of their own also keep their own list of recent designs.
    static var isolated: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil || ProcessInfo.processInfo.environment["BEZZLE_LIBRARY"] != nil
    }

    /// Settings and remembered choices, kept apart from the user's own for test and debug runs.
    static let settings: UserDefaults = isolated ? UserDefaults(suiteName: "com.erik.Bezzle.tests") ?? .standard : .standard
    private var defaults: UserDefaults { Library.settings }
    private let recentsKey = "recentDesigns"
    /// How many designs from outside the designs folder the home screen keeps showing; the ones
    /// opened longest ago go first. Enough for a designs folder's worth left where it was.
    private let recentsLimit = 200

    private init() {
        folder = Self.startingFolder()
        FileAccess.reopen()
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refresh()
    }

    // MARK: The designs folder

    /// The designs folder's name as the Finder shows it, in the user's language.
    var folderName: String { FileManager.default.displayName(atPath: folder.path) }

    /// The designs kept in `folder` itself, not those in folders inside it.
    private static func designs(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { BezzleDocument.fileExtensions.contains($0.pathExtension) }
            .map(\.standardizedFileURL)
    }

    /// Asks which folder to keep designs in from now on, and whether the designs kept until now go
    /// there too.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = folder.deletingLastPathComponent()
        panel.prompt = String(localized: "Keep Designs Here")
        panel.message = String(localized: "Choose where Bezzle keeps your designs.")
        guard panel.runModal() == .OK, let chosen = panel.url, !isFolder(chosen) else { return }
        let designs = Self.designs(in: folder)
        guard !designs.isEmpty else { return use(chosen, moving: true) }
        let place = FileManager.default.displayName(atPath: chosen.path)
        let alert = NSAlert()
        alert.messageText = designs.count == 1
            ? String(localized: "Move “\(designs[0].deletingPathExtension().lastPathComponent)” to “\(place)”?")
            : String(localized: "Move your \(designs.count) designs to “\(place)”?")
        alert.informativeText = String(localized: "Designs left where they are stay on the home screen.")
        alert.addButton(withTitle: String(localized: "Move"))
        alert.addButton(withTitle: String(localized: "Leave Them"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: use(chosen, moving: true)
        case .alertSecondButtonReturn: use(chosen, moving: false)
        default: break
        }
    }

    /// Whether the design at `url` is kept in the designs folder itself, so the home screen finds
    /// it there. One in a folder inside it is remembered, as one from anywhere else is.
    func holds(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path
    }

    /// Whether `url` is the designs folder now.
    private func isFolder(_ url: URL) -> Bool {
        url.standardizedFileURL.path == folder.standardizedFileURL.path || Self.sameFile(url, folder)
    }

    /// Keeps designs in `new` from now on, after Bezzle quits too: new designs are made there,
    /// and the home screen shows every design in it. With `moving`, the designs in the folder
    /// until now go there as well, those open in tabs included, each keeping its card on the home
    /// screen; any that can't be moved stay where they are. Otherwise all of them stay where they
    /// are, and on the home screen as designs opened from elsewhere are.
    func use(_ new: URL, moving: Bool) {
        guard !isFolder(new) else { return }
        let designs = Self.designs(in: folder)
        if let bookmark = Self.bookmark(of: new) { Library.settings.set(bookmark, forKey: Self.folderKey) }
        useForNow(new)
        for design in designs where !(moving && carry(design, into: folder)) {
            remember(design)
        }
        refresh()
    }

    /// Makes `new` the designs folder until Bezzle quits; `use` also keeps it for next time.
    func useForNow(_ new: URL) {
        folder = new.standardizedFileURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        refresh()
    }

    /// Moves a design into `into` under its name, or the next one free there; false when it can't.
    private func carry(_ url: URL, into: URL) -> Bool {
        let target = freeURL(named: url.deletingPathExtension().lastPathComponent, in: into)
        if let store = Tabs.shared.designs.lazy.compactMap(\.store).first(where: { $0.isAt(url) }) {
            return store.move(to: target)
        }
        // A tab just closed may still be writing it.
        DocumentStore.finishSaving()
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            NSLog("Bezzle could not move %@ to %@: %@", url.path, into.path, error.localizedDescription)
            return false
        }
        if let room = SharingFiles.link(of: target)?.keys?.room { _ = Sharing.shared.claim(room, at: target) }
        renamed(from: url, to: target)
        return true
    }

    /// Reads the folder and the remembered designs again.
    func refresh() {
        let fm = FileManager.default
        var urls = Set((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { BezzleDocument.fileExtensions.contains($0.pathExtension) }.map(\.standardizedFileURL) ?? [])
        for path in defaults.stringArray(forKey: recentsKey) ?? [] where fm.fileExists(atPath: path) {
            urls.insert(URL(fileURLWithPath: path).standardizedFileURL)
        }
        entries = urls.map { url in
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return Entry(url: url, modified: date, sharing: Self.mark(of: url), key: keys[url.path] ?? url.path)
        }.sorted { $0.modified > $1.modified }
        foldCopies(of: entries.map(\.url))
    }

    @ObservationIgnored private var folding = false

    /// In a folder iCloud Drive, Google Drive or the like keep in step, a copy of a design the
    /// service made as the design was written on two computers at once ("Poster 2") is taken into
    /// the design and put in the Trash (`FolderSync.foldCopies`), away from the main thread; the
    /// list is read again if any was.
    private func foldCopies(of urls: [URL]) {
        guard !folding, !BezzleApp.isTesting else { return }
        let synced = urls.filter { SyncedFolders.service(of: $0) != nil && FolderSync.isShared($0) }
        guard !synced.isEmpty else { return }
        folding = true
        let open = FolderSync.openHere()
        DispatchQueue.global(qos: .utility).async {
            var any = false
            for url in synced {
                if FolderSync.foldCopies(beside: url, open: open) { any = true }
            }
            DispatchQueue.main.async { [weak self] in
                self?.folding = false
                if any { self?.refresh() }
            }
        }
    }

    /// A design was saved or opened: it moves to the front.
    func touched(_ url: URL) {
        remember(url)
        if let i = entries.firstIndex(where: { $0.url == url.standardizedFileURL }) {
            entries[i].modified = Date()
            entries.sort { $0.modified > $1.modified }
        } else {
            refresh()
        }
    }

    /// Gives the design at `url` a new name, renaming its file beside where it is, and returns
    /// where it now is; nil when it keeps its name. One open in a tab is renamed there, so the tab
    /// goes on showing it.
    @discardableResult
    func rename(_ url: URL, to name: String) -> URL? {
        // Someone else's design shared with this Mac keeps the name it was shared under.
        guard Self.mark(of: url)?.renamable ?? true else { return nil }
        if let store = Tabs.shared.designs.lazy.compactMap(\.store).first(where: { $0.isAt(url) }) {
            let before = store.url
            store.rename(to: name)
            return store.url == before ? nil : store.url
        }
        guard let target = renamedURL(url, to: name) else { return nil }
        // A tab just closed may still be writing it.
        DocumentStore.finishSaving()
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            NSLog("Bezzle could not rename %@: %@", url.path, error.localizedDescription)
            return nil
        }
        // A shared design is found again where it now is, by what comes in from the others.
        if let room = SharingFiles.link(of: target)?.keys?.room { _ = Sharing.shared.claim(room, at: target) }
        renamed(from: url, to: target)
        return target
    }

    /// Where the design at `url` goes when it is called `name`: beside where it is, under that
    /// name, or the next one free. Nil when that is no new name.
    func renamedURL(_ url: URL, to name: String) -> URL? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        guard !clean.isEmpty, clean != url.deletingPathExtension().lastPathComponent else { return nil }
        let folder = url.deletingLastPathComponent()
        // Only its letters' case changing, the disk may take the new name for the old one's.
        let exact = folder.appendingPathComponent(clean).appendingPathExtension(BezzleDocument.fileExtension)
        if Self.sameFile(exact, url) { return exact }
        return freeURL(named: clean, in: folder)
    }

    private static func sameFile(_ a: URL, _ b: URL) -> Bool {
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: key).fileResourceIdentifier else { return false }
        return x.isEqual(y)
    }

    func renamed(from old: URL, to new: URL) {
        let old = old.standardizedFileURL.path, new = new.standardizedFileURL
        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == old }
        defaults.set(paths, forKey: recentsKey)
        keys[new.path] = keys.removeValue(forKey: old) ?? old
        remember(new)
        refresh()
        moveThumbnail(from: old, to: entries.first { $0.url.path == new.path }?.url ?? new)
    }

    private func remember(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !holds(url) else { return }
        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(recentsLimit)), forKey: recentsKey)
        FileAccess.keep(url)
    }

    /// Whether the design at `url` may go to the Trash: one this Mac shared stops being shared with
    /// it, so the person is asked first. Taking one off the home screen asks nothing, as its file
    /// stays and so does its share.
    func mayTrash(_ url: URL) -> Bool {
        guard holds(url), let room = SharingFiles.link(of: url)?.keys?.room, Sharing.shared.owns(room) else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Move “\(url.deletingPathExtension().lastPathComponent)” to the Trash and stop sharing it?")
        alert.informativeText = String(localized: "The link stops working. Everyone who has the design keeps it as it is now, read only.")
        alert.addButton(withTitle: String(localized: "Move to Trash"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Takes a design off the home screen; one in the designs folder goes to the Trash.
    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        if holds(url) {
            // One this Mac shared stops being shared, and the others keep it as it last was.
            Sharing.shared.stopSharing(designAt: url)
            NSWorkspace.shared.recycle([url])
        }
        var paths = defaults.stringArray(forKey: recentsKey) ?? []
        paths.removeAll { $0 == path }
        defaults.set(paths, forKey: recentsKey)
        entries.removeAll { $0.url == url.standardizedFileURL }
    }

    /// A file name in `folder` that is not taken yet: "Untitled", then "Untitled 2"…
    func freeURL(named name: String, in folder: URL? = nil) -> URL {
        let dir = folder ?? self.folder
        var candidate = dir.appendingPathComponent(name).appendingPathExtension(BezzleDocument.fileExtension)
        var i = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(name) \(i)").appendingPathExtension(BezzleDocument.fileExtension)
            i += 1
        }
        return candidate
    }

    /// Makes a new design on disk, with one artboard of `size` if given, and returns where it is.
    /// With a `slide` size, the artboard is a carousel of that many slides as one starts with.
    func create(artboard size: CGSize?, name: String? = nil, slide: CGSize? = nil) -> URL? {
        var doc = BezzleDocument()
        if let size {
            var board = Node(kind: .artboard, name: name ?? String(localized: "Artboard"), frame: CGRect(origin: .zero, size: size))
            if let slide {
                board.slideSize = slide
                board.frame.size = board.carouselSize(count: Carousel.startingCount)
            }
            doc.nodes = [board]
        }
        let url = freeURL(named: String(localized: "Untitled"))
        do {
            try DesignFile.write(doc, to: url)
            refresh()
            return url
        } catch {
            NSLog("Bezzle could not create %@: %@", url.path, error.localizedDescription)
            return nil
        }
    }

    /// How a design not open is shared, for its card: by link, or through the synced folder it
    /// is kept in.
    static func mark(of url: URL) -> SharingMark? {
        SharingFiles.leaveICloud(url)
        if let link = SharingFiles.link(of: url) {
            if link.ended { return .ended }
            if let room = link.keys?.room { return Sharing.shared.owns(room) ? .shared : .sharedBy(link.ownerName) }
        }
        return FolderSync.mark(of: url)
    }

    /// Makes a copy of a design next to it.
    /// Copies a design beside it, named "… copy" in the person's language; the copy made.
    @discardableResult
    func duplicate(_ url: URL) -> URL {
        let target = freeURL(named: String(localized: "\(url.deletingPathExtension().lastPathComponent) copy"), in: url.deletingLastPathComponent())
        try? FileManager.default.copyItem(at: url, to: target)
        // Its own file may lag behind what everyone's files in its folder have.
        if FolderSync.isShared(url), var doc = FolderSync.document(of: url) {
            doc.viewport = (try? DesignFile.read(url))?.viewport
            try? DesignFile.write(doc, to: target)
        }
        // A copy is a design of its own, never shared.
        SharingFiles.forget(target)
        remember(target)
        refresh()
        return target
    }

    // MARK: Thumbnails

    private var thumbnails: [URL: (Date, CGImage?)] = [:]

    /// Whether the home screen is showing. Thumbnails are only made for it, and a design being
    /// worked on, saved every moment, has its thumbnail made again at most every few seconds:
    /// for a large design, making one takes a while.
    var homeShowing = false
    @ObservationIgnored private var madeAt: [URL: Date] = [:]
    /// Designs whose thumbnails are being made.
    @ObservationIgnored private var making: Set<URL> = []

    /// The design's thumbnail; nil for an empty design, or while it is first made. A thumbnail is
    /// made in the background, as reading a large design and its pictures takes seconds, and
    /// kept on disk, so the home screen has it at once the next time.
    /// How large a design's picture on the home screen is made, in the proportions its tables have there.
    nonisolated static let thumbnailSize = CGSize(width: 480, height: 300)

    func thumbnail(for entry: Entry, size: CGSize) -> CGImage? {
        seekPreview(entry.url)
        if let (date, image) = thumbnails[entry.url], date == entry.modified { return image }
        if let (_, image) = thumbnails[entry.url], !homeShowing || Date().timeIntervalSince(madeAt[entry.url] ?? .distantPast) < 10 {
            return image
        }
        if !making.contains(entry.url) {
            if let kept = Self.keptThumbnail(entry) {
                thumbnails[entry.url] = (entry.modified, kept)
                return kept
            }
            makeThumbnail(entry, size: size)
        }
        return thumbnails[entry.url]?.1
    }

    /// A renamed design, at `new` from `old` (a path), keeps its thumbnail, on the screen and on disk.
    private func moveThumbnail(from old: String, to new: URL) {
        if let was = madeAt.keys.first(where: { $0.path == old }) { madeAt[new] = madeAt.removeValue(forKey: was) }
        guard let was = thumbnails.keys.first(where: { $0.path == old }), let (date, image) = thumbnails.removeValue(forKey: was) else { return }
        thumbnails[new] = (date, image)
        if let image { Self.keep(image, for: new, modified: date) }
        let name = Self.thumbnailName(was), folder = Self.thumbnailFolder
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            for file in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix(name + "-") {
                try? fm.removeItem(at: file)
            }
        }
    }

    /// Whether the design's thumbnail is being made for the first time, so there is none to show yet.
    func isMakingThumbnail(for entry: Entry) -> Bool { making.contains(entry.url) && thumbnails[entry.url] == nil }

    private func makeThumbnail(_ entry: Entry, size: CGSize) {
        let url = entry.url, modified = entry.modified
        making.insert(url)
        madeAt[url] = Date()
        Task.detached(priority: .userInitiated) {
            let doc = try? DesignFile.read(url)
            let assets = doc.map { Assets.previews(Self.pictureSizes(in: $0, thumbnail: size, scale: 2), design: url) }
            // Drawn here as well, off the main thread: a large design takes a while to draw, and
            // the home screen goes on answering meanwhile.
            let image = doc.flatMap { Renderer.thumbnail(of: $0, size: size, assets: assets, cover: true) }
            await Library.shared.finishThumbnail(url, modified: modified, image: image)
        }
    }

    private func finishThumbnail(_ url: URL, modified: Date, image: CGImage?) {
        making.remove(url)
        thumbnails[url] = (modified, image)
        if let image { Self.keep(image, for: url, modified: modified) }
    }

    /// How many pixels each picture in the design takes along its longer side when the design is
    /// drawn as its thumbnail of `size`. The thumbnail draws the canvas at one scale,
    /// and nothing in a design is scaled on the way down, so a layer's frame says it all.
    nonisolated static func pictureSizes(in doc: BezzleDocument, thumbnail size: CGSize, scale: CGFloat) -> [String: Int] {
        guard let bounds = doc.contentBounds, bounds.width > 0, bounds.height > 0 else { return [:] }
        let fit = Renderer.thumbnailPlacement(of: doc, bounds: bounds, in: size, cover: true).scale * scale
        var sizes: [String: Int] = [:]
        func visit(_ n: Node) {
            for image in n.paintedPictures where image.size.width > 0 && image.size.height > 0 {
                // Covering its layer, it may reach past it the long way.
                let cover = max(n.frame.width / image.size.width, n.frame.height / image.size.height) * max(image.scale, 1)
                let pixels = Int((max(image.size.width, image.size.height) * cover * fit).rounded(.up))
                sizes[image.shown] = max(sizes[image.shown] ?? 0, min(max(pixels, 16), 2048))
            }
            n.children.forEach(visit)
            n.mask?.forEach(visit)
        }
        doc.nodes.forEach(visit)
        return sizes
    }

    // MARK: The Finder's pictures

    /// Designs looked at for a picture for the Finder since Bezzle started.
    @ObservationIgnored private var previewsSought: Set<URL> = []

    /// A design on the home screen without a current picture for the Finder, made before Bezzle
    /// kept them, brought in from elsewhere or changed while closed, is given one in the
    /// background. One open in a tab makes its own as it is worked on. See `DesignPreview`.
    /// Not one in a synced folder: there the computer that changes a design makes its picture,
    /// and one made here too was another computer writing it, which iCloud Drive keeps as a
    /// second design and Google Drive as a second picture.
    private func seekPreview(_ url: URL) {
        guard !BezzleApp.isTesting, previewsSought.insert(url).inserted, SyncedFolders.service(of: url) == nil,
              !Tabs.shared.designs.contains(where: { $0.store?.url.standardizedFileURL == url.standardizedFileURL }) else { return }
        DesignPreview.catchingUp.async {
            guard DesignFile.isPackage(url), !DesignPreview.isCurrent(for: url), let doc = try? DesignFile.read(url) else { return }
            DesignPreview.write(doc, assets: Assets(design: url), to: url, keepingDate: true)
        }
    }

    // Kept on disk, in the caches folder, under the design's path and when it last changed.

    private nonisolated static let thumbnailFolder: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent(Bundle.main.bundleIdentifier ?? "Bezzle", isDirectory: true)
            .appendingPathComponent("Thumbnails", isDirectory: true)
    }()

    private nonisolated static func thumbnailName(_ url: URL) -> String {
        Insecure.SHA1.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func thumbnailFile(_ url: URL, modified: Date) -> URL {
        // Its size in the name, so ones kept at another size are made again.
        thumbnailFolder.appendingPathComponent("\(thumbnailName(url))-\(Int64(modified.timeIntervalSince1970 * 1000))-\(Int(thumbnailSize.width))x\(Int(thumbnailSize.height)).png")
    }

    private static func keptThumbnail(_ entry: Entry) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(thumbnailFile(entry.url, modified: entry.modified) as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Writes it in the background, in place of any made before.
    private static func keep(_ image: CGImage, for url: URL, modified: Date) {
        let file = thumbnailFile(url, modified: modified), name = thumbnailName(url)
        Task.detached(priority: .utility) {
            let fm = FileManager.default
            try? fm.createDirectory(at: thumbnailFolder, withIntermediateDirectories: true)
            for old in (try? fm.contentsOfDirectory(at: thumbnailFolder, includingPropertiesForKeys: nil)) ?? []
            where old.lastPathComponent.hasPrefix(name + "-") {
                try? fm.removeItem(at: old)
            }
            guard let out = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(out, image, nil)
            CGImageDestinationFinalize(out)
        }
    }
}

/// Artboard sizes to start from.
struct Preset: Identifiable, Hashable {
    /// What a size is for, broadly: a screen, a post, or paper and slides.
    enum Kind: CaseIterable {
        case devices, social, print

        var title: LocalizedStringResource {
            switch self {
            case .devices: "Devices"
            case .social: "Social media"
            case .print: "Print & slides"
            }
        }
    }

    /// The families sizes come in: a maker's devices or a platform's formats, in the order they
    /// are offered.
    enum Group: String, CaseIterable {
        case iPhone, android, iPad, mac, web, watch
        case instagram, tiktok, youtube, facebook, linkedin, x, pinterest
        case print, slides

        var title: LocalizedStringResource {
            switch self {
            case .iPhone: "iPhone"
            case .android: "Android"
            case .iPad: "iPad"
            case .mac: "Mac"
            case .web: "Web"
            case .watch: "Apple Watch"
            case .instagram: "Instagram"
            case .tiktok: "TikTok"
            case .youtube: "YouTube"
            case .facebook: "Facebook"
            case .linkedin: "LinkedIn"
            case .x: "X"
            case .pinterest: "Pinterest"
            case .print: "Print"
            case .slides: "Slides"
            }
        }

        var kind: Kind {
            switch self {
            case .iPhone, .android, .iPad, .mac, .web, .watch: .devices
            case .instagram, .tiktok, .youtube, .facebook, .linkedin, .x, .pinterest: .social
            case .print, .slides: .print
            }
        }

        static func all(of kind: Kind) -> [Group] { allCases.filter { $0.kind == kind } }
    }

    /// Shown in the user's language.
    let title: LocalizedStringResource
    let size: CGSize
    let group: Group
    /// The English name, which the AI is told and which stays the same whatever the language.
    var name: String { title.key }
    var id: String { name }

    static func == (a: Preset, b: Preset) -> Bool { a.name == b.name && a.size == b.size }
    func hash(into hasher: inout Hasher) { hasher.combine(name) }

    /// Devices at the size their screens are drawn in, in points, newest first (as of autumn
    /// 2026); Android phones at their usual resolution, as wide as their browsers measure. Platforms' formats as they ask for them, in pixels; print in
    /// points, as a PDF has them.
    static let all: [Preset] = [
        // Open, the Duo is a book held sideways, its inner screen wider than tall (164.6 × 117.8 mm).
        Preset(title: "iPhone Duo, open", size: CGSize(width: 890, height: 626), group: .iPhone),
        Preset(title: "iPhone Duo, closed", size: CGSize(width: 466, height: 678), group: .iPhone),
        Preset(title: "iPhone 18 Pro Max", size: CGSize(width: 440, height: 956), group: .iPhone),
        Preset(title: "iPhone 18 Pro", size: CGSize(width: 402, height: 874), group: .iPhone),
        Preset(title: "iPhone Air", size: CGSize(width: 420, height: 912), group: .iPhone),
        Preset(title: "iPhone 17", size: CGSize(width: 402, height: 874), group: .iPhone),
        Preset(title: "iPhone 17e", size: CGSize(width: 390, height: 844), group: .iPhone),
        Preset(title: "iPhone 16", size: CGSize(width: 393, height: 852), group: .iPhone),
        Preset(title: "Samsung Galaxy S26 Ultra", size: CGSize(width: 384, height: 832), group: .android),
        Preset(title: "Samsung Galaxy S26", size: CGSize(width: 360, height: 780), group: .android),
        Preset(title: "Google Pixel 11 Pro XL", size: CGSize(width: 448, height: 997), group: .android),
        Preset(title: "Google Pixel 11", size: CGSize(width: 412, height: 923), group: .android),
        Preset(title: "iPad Pro 13″", size: CGSize(width: 1032, height: 1376), group: .iPad),
        Preset(title: "iPad Pro 11″", size: CGSize(width: 834, height: 1210), group: .iPad),
        Preset(title: "iPad Air 13″", size: CGSize(width: 1024, height: 1366), group: .iPad),
        Preset(title: "iPad Air 11″", size: CGSize(width: 820, height: 1180), group: .iPad),
        Preset(title: "iPad", size: CGSize(width: 820, height: 1180), group: .iPad),
        Preset(title: "iPad mini", size: CGSize(width: 744, height: 1133), group: .iPad),
        Preset(title: "MacBook Air 13″", size: CGSize(width: 1470, height: 956), group: .mac),
        Preset(title: "MacBook Air 15″", size: CGSize(width: 1710, height: 1112), group: .mac),
        Preset(title: "MacBook Pro 14″", size: CGSize(width: 1512, height: 982), group: .mac),
        Preset(title: "MacBook Pro 16″", size: CGSize(width: 1728, height: 1117), group: .mac),
        Preset(title: "iMac 24″", size: CGSize(width: 2240, height: 1260), group: .mac),
        Preset(title: "Studio Display", size: CGSize(width: 2560, height: 1440), group: .mac),
        Preset(title: "Desktop", size: CGSize(width: 1920, height: 1080), group: .web),
        Preset(title: "Laptop", size: CGSize(width: 1440, height: 900), group: .web),
        Preset(title: "Laptop, small", size: CGSize(width: 1280, height: 832), group: .web),
        Preset(title: "Web tablet", size: CGSize(width: 768, height: 1024), group: .web),
        Preset(title: "Apple Watch 46 mm", size: CGSize(width: 208, height: 248), group: .watch),
        Preset(title: "Apple Watch 42 mm", size: CGSize(width: 187, height: 223), group: .watch),
        Preset(title: "Apple Watch Ultra 3", size: CGSize(width: 211, height: 257), group: .watch),
        Preset(title: "Instagram post, 4:5", size: CGSize(width: 1080, height: 1350), group: .instagram),
        Preset(title: "Instagram post, square", size: CGSize(width: 1080, height: 1080), group: .instagram),
        Preset(title: "Instagram post, landscape", size: CGSize(width: 1080, height: 566), group: .instagram),
        Preset(title: "Instagram story & reel", size: CGSize(width: 1080, height: 1920), group: .instagram),
        Preset(title: "TikTok video", size: CGSize(width: 1080, height: 1920), group: .tiktok),
        Preset(title: "YouTube thumbnail", size: CGSize(width: 1280, height: 720), group: .youtube),
        Preset(title: "YouTube Shorts", size: CGSize(width: 1080, height: 1920), group: .youtube),
        Preset(title: "YouTube banner", size: CGSize(width: 2560, height: 1440), group: .youtube),
        Preset(title: "Facebook post", size: CGSize(width: 1080, height: 1350), group: .facebook),
        Preset(title: "Facebook link", size: CGSize(width: 1200, height: 630), group: .facebook),
        Preset(title: "Facebook story", size: CGSize(width: 1080, height: 1920), group: .facebook),
        Preset(title: "Facebook cover", size: CGSize(width: 851, height: 315), group: .facebook),
        Preset(title: "LinkedIn post", size: CGSize(width: 1200, height: 627), group: .linkedin),
        Preset(title: "LinkedIn post, square", size: CGSize(width: 1080, height: 1080), group: .linkedin),
        Preset(title: "LinkedIn banner", size: CGSize(width: 1584, height: 396), group: .linkedin),
        Preset(title: "X post", size: CGSize(width: 1600, height: 900), group: .x),
        Preset(title: "X header", size: CGSize(width: 1500, height: 500), group: .x),
        Preset(title: "Pinterest pin", size: CGSize(width: 1000, height: 1500), group: .pinterest),
        Preset(title: "Business card", size: CGSize(width: 241, height: 156), group: .print),
        Preset(title: "Postcard", size: CGSize(width: 298, height: 420), group: .print),
        Preset(title: "A5", size: CGSize(width: 420, height: 595), group: .print),
        Preset(title: "A4", size: CGSize(width: 595, height: 842), group: .print),
        Preset(title: "A3", size: CGSize(width: 842, height: 1191), group: .print),
        Preset(title: "US Letter", size: CGSize(width: 612, height: 792), group: .print),
        Preset(title: "US Legal", size: CGSize(width: 612, height: 1008), group: .print),
        Preset(title: "Slide", size: CGSize(width: 1920, height: 1080), group: .slides),
        Preset(title: "Slide, 4:3", size: CGSize(width: 1024, height: 768), group: .slides),
    ]

    /// The size an artboard is when nothing says otherwise.
    static let standard = all.first { $0.name == "iPhone 18 Pro" } ?? all[0]

    static func all(in group: Group) -> [Preset] { all.filter { $0.group == group } }

    /// The size an artboard's size is, if any; two of the same size go by the first.
    static func matching(_ size: CGSize) -> Preset? { all.first { $0.size == size } }
}
