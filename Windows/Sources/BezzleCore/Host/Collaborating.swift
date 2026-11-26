import Foundation
import CBezzleHost

// A shared design on Windows, as the Mac's Collaboration and FolderSync keep one: what is done
// here is taken in as changes of this computer's own (`SharedDesign.absorb`), written to files
// only it writes in the design's package (sharing/people/<replica>/), and everyone else's files
// are read and merged in, property by property, never put over the design whole. The files are
// read and written by the same shared code as on the Mac (Model/FolderParts.swift); what is here
// is the Mac's bookkeeping around it, ported: which design shows, when others' changes show, and
// telling a copy of a design made in Explorer.

extension WindowsCore {
    /// This computer's name among those sharing a design, which its changes, its files, its notes
    /// and its versions carry: lowercase letters and digits, as `FolderShare.isReplica` wants,
    /// made once and kept with Bezzle's own settings (the Mac's Sharing.replica).
    public static let replica: String = {
        #if DEBUG
        // Two test copies on one computer share their settings; each says who it is.
        if let id = ProcessInfo.processInfo.environment["BEZZLE_REPLICA"], FolderShare.isReplica(id) { return id }
        #endif
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Bezzle", isDirectory: true)
        let file = folder?.appendingPathComponent("replica.txt")
        var id = file.flatMap { try? String(contentsOf: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if id.isEmpty, let folder, let file {
            id = UUID().uuidString
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? id.write(to: file, atomically: true, encoding: .utf8)
        }
        return shareReplica(of: id)
    }()

    /// A replica as sharing writes it: the first Windows copies made theirs a UUID, as typed.
    static func shareReplica(of id: String) -> String {
        String(id.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(32))
    }

    /// The name this computer goes by among those sharing a design: the person's first name, as
    /// the Mac's LiveRoom.myName gives the short form of theirs.
    public static let myName: String = {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["BEZZLE_LIVE_NAME"], !name.isEmpty { return name }
        #endif
        let full = ProcessInfo.processInfo.fullUserName.trimmingCharacters(in: .whitespaces)
        let name = full.isEmpty ? ProcessInfo.processInfo.userName : full
        return name.split(separator: " ").first.map(String.init) ?? (name.isEmpty ? "Me" : name)
    }()

    /// The open design's share, while it is shared.
    nonisolated(unsafe) static var sharing: SharedSession?

    /// How the open design is shared, for the window to show (the Mac's SharingMark).
    nonisolated public enum ShareMark: Equatable, Sendable {
        /// Shared from this computer, by link.
        case shared
        /// Someone else's, shared with this computer by link, by its owner's name.
        case sharedBy(String?)
        /// Someone else's, no longer shared: read only.
        case ended
        /// Kept in a folder that OneDrive, Google Drive or the like keeps in step, where others work on it too.
        case inFolder(String)
    }

    public static var shareMark: ShareMark? { sharing?.mark }

    /// Whether the design is shared through the folder it is kept in, with its files in it.
    public static var isSharedThroughFolder: Bool { sharing?.folder != nil }

    /// Whether it can only be looked at: someone else's design no longer shared with this computer.
    public static var isReadOnly: Bool { sharing?.isReadOnly == true }

    /// Whether the open design has a layer, as after others' changes came, which may take some away.
    public static func has(layer id: UUID) -> Bool { design?.path(of: id) != nil }

    /// The open design as it is shared, which its own file may lag behind: a design in a synced
    /// folder, or one with people's files in it.
    static func openShared(_ url: URL, file doc: BezzleDocument, prepared: SharedSession.Prepared? = nil) -> BezzleDocument {
        sharing?.close()
        sharing = nil
        guard let session = SharedSession.open(url, replica: replica, file: doc, prepared: prepared?.folder) else { return doc }
        if let prepared {
            sharing = session
            session.start(prepared)
            return prepared.document
        }
        var shown = session.document()
        shown.viewport = doc.viewport
        sharing = session
        session.start(with: shown)
        return shown
    }

    /// Looks for what the others did since the last look: in the design's folder, everyone's files.
    /// True when the design shown changed (to draw it again, and save it a moment later), as it
    /// does once nothing is being dragged.
    @discardableResult public static func lookAtShare() -> Bool {
        guard let session = sharing else { return false }
        // Only a design in a folder others write in too has anything to look for.
        if let folder = session.folder, folder.watched {
            // Renamed or moved, as by someone else in the folder: the design goes on where it is now.
            if !FileManager.default.fileExists(atPath: session.url.appendingPathComponent("document.json").path) { follow() }
            // A copy the folder's service made beside it, written on another computer as this one
            // wrote: taken in first, so that what it brings is read now.
            folder.foldCopies(open: openDesigns(), using: SharedSession.pictures(in: (previewBase ?? design)?.nodes ?? []))
            let found = FolderShare.look(folder.url, replica: session.replica, seen: folder.seen, opening: false)
            let took = folder.take(found)
            if !took.changes.isEmpty {
                session.receive(took.changes, from: .folder, current: previewBase ?? design)
                session.persist()
            }
            if took.roomChanged { session.roomChanged() }
            if !took.pictures.isEmpty { arrivals.arrived(pictures: took.pictures, of: folder.url) }
            for name in took.pictures { pictureArrived(name, in: folder.url) }
            for (version, data) in took.versions { versions.arrived(version, data: data) }
        }
        return showOthersIfIdle()
    }

    /// Shows what others changed, if that waited for a drag or a preview to end and they have.
    @discardableResult public static func showOthersIfIdle() -> Bool {
        guard let session = sharing, Editing.gestureStart == nil, previewBase == nil, let doc = design,
              let next = session.toShow(current: doc) else { return false }
        return showChangesFromOthers(next)
    }

    /// Shows the design with what others changed: `next` holds everything done here as well. It is
    /// not a step of the undo history, and undoing afterwards leaves it in place (DocumentStore's
    /// showChangesFromOthers).
    static func showChangesFromOthers(_ next: BezzleDocument) -> Bool {
        guard let old = design else { return false }
        var next = next
        next.viewport = old.viewport
        next.keepMasks(since: old)
        next.reconcileComponents()
        next.fitGroups(since: old)
        // Artboards nobody changed stay as they were, sharing their storage.
        var kept: [UUID: Node] = [:]
        for n in old.nodes { kept[n.id] = n }
        next.nodes = next.nodes.map { n in kept[n.id].flatMap { $0 == n ? $0 : nil } ?? n }
        guard next != old else { return false }
        if let start = Editing.gestureStart { Editing.gestureStart = FlatDesign.apply(from: old, to: next, onto: start) }
        takingOthers = true
        design = next
        takingOthers = false
        return true
    }

    /// While what others did is shown: not a change made on this computer (`SharedSession.changedHere`).
    nonisolated(unsafe) static var takingOthers = false

    /// Whether the open design is in a folder OneDrive, Google Drive, iCloud Drive or the like keep
    /// in step with other computers: this computer writes in it only what it did itself.
    public static var inSyncedFolder: Bool { sharing?.folder?.service != nil }

    /// Whether this computer writes the design's versions and picture when it is closed: always, but
    /// in a synced folder only when the design was changed here (the Mac's writesWhenClosed).
    public static var writesWhenClosed: Bool { !inSyncedFolder || sharing?.editedHere == true }

    /// The designs open in tabs, by `openKey`, so that a copy open here is never put away.
    nonisolated(unsafe) public static var openDesigns: () -> Set<String> = { [] }

    /// How a design's path is told apart in `openDesigns`.
    public static func openKey(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    /// A picture someone else added came, through the folder or the relay: Skia learns it, to draw it.
    static func pictureArrived(_ name: String, in design: URL) {
        guard let file = arrivals.picture(name, of: design), let data = try? Data(contentsOf: file) else { return }
        // Asked for again the next time it is drawn: one not there yet is not kept as missing.
        giveSkia(name, data)
        // One shown by its glimpse until now is drawn as itself from now on, coming into focus.
        glimpseDone(name)
        sharing?.live?.arrived(name)
        pictureCame = true
        tellShareNews()
    }

    /// Whether a picture came since the window last drew the design for one (`tookPictures`).
    nonisolated(unsafe) static var pictureCame = false

    /// Whether a picture came since the last time this was asked: the window draws the design again.
    public static func tookPictures() -> Bool {
        defer { pictureCame = false }
        return pictureCame
    }

    /// Finds the design's package again when it is no longer where it was, as when someone else in
    /// the synced folder renamed it: in the same folder, the one design with the same room (the
    /// Mac's DocumentStore.follow, without its bookmark). True when it was found elsewhere.
    @discardableResult static func follow() -> Bool {
        guard let session = sharing, let url = designURL,
              !FileManager.default.fileExists(atPath: url.appendingPathComponent("document.json").path) else { return false }
        let folder = url.deletingLastPathComponent()
        let seed = session.folder?.room.seed
        let found = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { candidate in
            guard candidate.pathExtension.lowercased() == "bezzle",
                  FileManager.default.fileExists(atPath: candidate.appendingPathComponent("document.json").path) else { return false }
            if let seed, FolderShare.room(of: candidate)?.seed == seed { return true }
            return false
        }
        guard found.count == 1, let there = found.first else { return false }
        designURL = there
        assets = Assets(folder: there.appendingPathComponent("images"))
        session.moved(to: there)
        return true
    }

    /// Makes a folder in the package of a design that is there, never the package itself: a design
    /// moved away while open must not begin again where it was (the Mac's DesignFile.makeFolder).
    static func makeFolder(_ folder: URL, in design: URL) throws {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: design.path, isDirectory: &isFolder), isFolder.boolValue else { throw CoreError("\(design.path) is gone") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    nonisolated static var nowMilliseconds: Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
}

// MARK: - The design as everyone has it

/// Where changes taken in came from (the Mac's Collaboration.Source).
enum ShareSource {
    /// The synced folder, which keeps them in their own files already.
    case folder
    /// The room's records on the relay.
    case cloud
    /// Someone in the live room, a moment after they made them.
    case relay
}

/// An open design that is shared, as the Mac's Collaboration keeps it: it takes in what is done
/// here, and shows what the others did, keeping everything done here.
final class SharedSession {
    private(set) var url: URL
    let replica: String
    private(set) var state: SharedDesign
    /// Where the design keeps its parts.
    let folder: FolderCopy?
    /// The design's share by link, while it has one or had one (`sharing/share.json`).
    private(set) var link: ShareLink?
    /// The design's room on the relay, while it is shared by link.
    private(set) var cloud: CloudCopy?
    /// The design's live room, while there is a relay to meet on.
    private(set) var live: LiveTogether?
    /// The pictures each artboard and loose layer of `baseDoc` shows.
    private var basePictures: [UUID: Set<String>] = [:]
    /// The layers as this computer last showed them, to tell what was changed here since.
    private var base = FlatDesign()
    /// The design `base` was made from, while it is (see the Mac's Collaboration.baseDoc).
    private var baseDoc: BezzleDocument?
    private var decoded: [UUID: (layer: SharedLayer, node: Node)] = [:]
    /// Others' changes taken in but not shown yet, while a drag or a preview is going on.
    private var unshown = false
    /// Who changed each layer not shown yet, by their replica, for the layers to light up.
    private var unshownAuthors: [UUID: String] = [:]
    /// Others' changes from elsewhere than the folder, to keep with this computer's parts.
    private var toKeep: [SharedDesign] = []
    /// The latest change made here.
    private(set) var changedUpTo: Int64 = 0
    /// Whether the design was changed on this computer since it was last written, rather than only
    /// by what others did; and whether it was at all since it was opened (the Mac's
    /// DocumentStore.changedHere and editedHere). Set by `WindowsCore.design` as it changes.
    nonisolated(unsafe) var changedHere = false
    nonisolated(unsafe) var editedHere = false

    init(url: URL, state: SharedDesign, folder: FolderCopy?, link: ShareLink?, replica: String) {
        self.url = url
        self.state = state
        self.folder = folder
        self.link = link
        self.replica = replica
        changedUpTo = state.clock.time
        if let keys = link?.keys { cloud = CloudCopy(keys: keys, replica: replica) }
    }

    /// The shared design at `url`, if it is one: shared by link, kept in a synced folder, or with
    /// people's files. A copy of a design shared by link, as Explorer makes, is not shared: it
    /// becomes a design of its own.
    static func open(_ url: URL, replica: String, file: BezzleDocument, prepared: FolderCopy.Prepared? = nil) -> SharedSession? {
        guard FolderCopy.isPackage(url) else { return nil }
        var link = Linking.link(of: url)
        if let keys = link?.keys, !Linking.claim(keys.room, at: url) {
            Linking.unlink(url)
            link = nil
        }
        guard link != nil || FolderCopy.applies(to: url),
              let opened = FolderCopy.open(url, replica: replica, file: file, prepared: prepared) else { return nil }
        return SharedSession(url: url, state: opened.state, folder: opened.copy, link: link, replica: replica)
    }

    /// The design as it is shown is taken in, its room looked at, and its live room joined (the
    /// Mac's attach).
    func start(with doc: BezzleDocument) {
        takeIn(doc)
        cloud?.start(for: self)
        openLive()
    }

    /// The initial model and the baseline used to tell later edits apart from it.
    nonisolated struct Prepared: Sendable {
        let folder: FolderCopy.Prepared
        let document: BezzleDocument
        let state: SharedDesign
        let base: FlatDesign
        let decoded: [UUID: (layer: SharedLayer, node: Node)]
        let pictures: [UUID: Set<String>]
        let readOnly: Bool
        let changed: Bool
    }

    nonisolated static func prepare(_ url: URL, replica: String, file: BezzleDocument, link: ShareLink?) throws -> Prepared {
        let folder = FolderCopy.prepare(url, replica: replica, file: file)
        try Task.checkCancellation()
        var state = folder.opened.state
        var decoded: [UUID: (layer: SharedLayer, node: Node)] = [:]
        let before = state.flatDesign(reusing: &decoded)
        try Task.checkCancellation()
        var document = before.document()
        document.viewport = file.viewport
        try Task.checkCancellation()
        let readOnly = link?.ended == true
        let base = readOnly ? before : FlatDesign(document)
        let changed = !readOnly && state.absorb(base, since: before, by: replica, at: WindowsCore.nowMilliseconds)
        var pictures: [UUID: Set<String>] = [:]
        if !readOnly {
            for node in document.nodes { pictures[node.id] = Self.pictures(in: [node]) }
        }
        return Prepared(folder: folder, document: document, state: state, base: base, decoded: decoded,
                        pictures: pictures, readOnly: readOnly, changed: changed)
    }

    fileprivate func start(_ prepared: Prepared) {
        state = prepared.state
        base = prepared.base
        decoded = prepared.decoded
        baseDoc = prepared.readOnly ? nil : prepared.document
        basePictures = prepared.pictures
        if prepared.changed {
            changedUpTo = state.clock.time
            cloud?.changed()
        }
        if !prepared.readOnly { cloud?.offer(shownPictures) }
        cloud?.start(for: self)
        openLive()
    }

    func close() {
        live?.leave()
        live = nil
        cloud?.stop()
    }

    /// The keys the live room is found by and sealed with: the share's, or the synced folder's.
    var liveKeys: ShareKeys? { cloud?.keys ?? folder?.roomKeys }

    /// The latest of this computer's changes that everyone can have, from the room's records or the folder.
    var sentUpTo: Int64 { cloud?.sentUpTo ?? folder?.writtenUpTo ?? 0 }

    private func openLive() {
        live?.leave()
        live = nil
        guard !isReadOnly, let relay = Linking.relay, let keys = liveKeys else { return }
        live = LiveTogether(session: self, keys: keys, relay: relay)
    }

    /// The live room is another now: the design was shared, or no longer is.
    func roomChanged() { openLive() }

    var mark: WindowsCore.ShareMark? {
        guard let link else { return folder?.mark }
        if link.ended { return .ended }
        guard let room = link.keys?.room else { return folder?.mark }
        return Linking.owns(room) ? .shared : .sharedBy(link.ownerName)
    }

    /// Whether it can only be looked at: someone else's design this computer no longer shares.
    var isReadOnly: Bool { link?.ended == true }

    func moved(to url: URL) {
        self.url = url
        if let room = cloud?.keys.room { _ = Linking.claim(room, at: url) }
        folder?.moved(to: url)
    }

    /// This computer shared the design: its room on the relay is `link`'s.
    func shared(_ link: ShareLink) {
        self.link = link
        cloud?.stop()
        cloud = link.keys.map { CloudCopy(keys: $0, replica: replica) }
        cloud?.start(for: self)
        roomChanged()
    }

    /// Its owner gave the design another name, or theirs.
    func retitled(_ link: ShareLink) { self.link = link }

    /// The design is no longer shared by link. This computer's own goes on as a design of its
    /// own; someone else's stays as it last was, read only.
    func unshared(own: Bool) {
        cloud?.stop()
        cloud = nil
        if own {
            link = nil
            Linking.unlink(url)
        } else if var ended = link {
            ended.ended = true
            link = ended
            try? Linking.write(ended, to: url)
        }
        roomChanged()
        WindowsCore.tellShareNews()
    }

    /// The pictures layers show, in their looks and their masks.
    nonisolated static func pictures(in nodes: [Node]) -> Set<String> {
        var names = Set<String>()
        func visit(_ n: Node) {
            for image in n.paintedPictures { names.formUnion(image.assets) }
            n.children.forEach(visit)
            n.mask?.forEach(visit)
        }
        nodes.forEach(visit)
        return names
    }

    /// The design as it is shared, which is what this computer shows.
    func document() -> BezzleDocument {
        base = state.flatDesign(reusing: &decoded)
        baseDoc = nil
        return base.document()
    }

    /// Takes in what was changed here since last time: only the artboards and loose layers that
    /// changed, while the layers as last shown are known to be those of the design taken in last.
    func takeIn(_ doc: BezzleDocument) {
        guard !isReadOnly else { return }
        if let before = baseDoc {
            let (old, new) = FlatDesign.changes(from: before, to: doc)
            absorb(new, since: old)
            base.replace(old, with: new)
        } else {
            let now = FlatDesign(doc)
            absorb(now, since: base)
            base = now
        }
        var shown: [UUID: Set<String>] = [:]
        var was: [UUID: Node] = [:]
        for node in baseDoc?.nodes ?? [] { was[node.id] = node }
        for node in doc.nodes {
            if was[node.id] == node, let kept = basePictures[node.id] { shown[node.id] = kept } else { shown[node.id] = Self.pictures(in: [node]) }
        }
        baseDoc = doc
        basePictures = shown
        let pictures = shownPictures
        cloud?.offer(pictures)
        live?.offer(pictures)
    }

    /// The pictures the design shows, as last taken in.
    var shownPictures: Set<String> { basePictures.values.reduce(into: Set<String>()) { $0.formUnion($1) } }

    private func absorb(_ now: FlatDesign, since was: FlatDesign) {
        if state.absorb(now, since: was, by: replica, at: WindowsCore.nowMilliseconds) {
            changedUpTo = state.clock.time
            cloud?.changed()
            live?.relay()
        }
    }

    /// Takes in changes from the others; what was done here (`current`) is taken in first, so it
    /// is kept as it is. They show once nothing holds them back (`toShow`).
    func receive(_ changes: [SharedDesign], from source: ShareSource, current: BezzleDocument?) {
        if let current { takeIn(current) }
        var came = false
        for c in changes where !c.isEmpty {
            let layers = state.merge(c)
            if source != .folder { toKeep.append(c) }
            guard !layers.isEmpty else { continue }
            unshown = true
            came = true
            let authors = c.authors
            for id in layers { if let by = authors[id] { unshownAuthors[id] = by } }
        }
        if source == .relay { cloud?.relayed(changes) }
        // Shown as soon as nothing holds them back, as the Mac shows them.
        if came { WindowsCore.tellShareNews() }
    }

    /// The design with what others changed, if there is anything not shown yet.
    func toShow(current doc: BezzleDocument) -> BezzleDocument? {
        guard unshown else { return nil }
        unshown = false
        takeIn(doc)
        let map = state.flatDesign(reusing: &decoded)
        base = map
        baseDoc = nil
        // What each of them changed lights up for a moment in their pencil, as on the Mac.
        live?.glow(unshownAuthors)
        unshownAuthors = [:]
        return map.document()
    }

    /// Writes what changed to the design's parts, ahead of its own file. In a folder a sync
    /// service keeps in step, only when the design was changed on this computer, or `force`d as
    /// it is written or closed (`WindowsCore.save(closing:)`): what others did comes in their own
    /// files, and a computer only looking on that wrote what reached it wrote the design at every
    /// change made on another, at once with it, which the service keeps as two ("Poster 2"). What
    /// came over the relay waits in `toKeep` meanwhile, and is kept then (the Mac's
    /// Collaboration.persist).
    func persist(force: Bool = false) {
        if !force, let folder, folder.service != nil, !changedHere { return }
        folder?.persist(state, keeping: toKeep)
        toKeep = []
    }
}

// MARK: - This computer's files in the folder

/// A shared design's parts in its package, as the Mac's FolderSync keeps them: this computer's
/// own changes in files in its own folder there, now and then the whole design, and everyone
/// else's files read as the folder brings them.
final class FolderCopy {
    /// Everyone else whose files are in the design, as their files say who they are.
    private(set) var people: [FolderShare.Person] = []
    /// The secret of the folder's live room, which everyone with the folder has.
    private(set) var room: FolderShare.Room
    /// The service keeping the folder in step, by name; nil on this computer alone.
    private(set) var service: String?
    private(set) var url: URL
    let replica: String
    /// The latest of this computer's changes its files hold.
    private(set) var writtenUpTo: Int64
    /// This computer's own files of changes and wholes, by name.
    private var own: [String]
    private(set) var seen: FolderShare.Seen
    /// Who this computer last said it was, in its `me.json`.
    private var introduced: FolderShare.Person?

    private init(url: URL, replica: String, room: FolderShare.Room, seen: FolderShare.Seen, own: [String], writtenUpTo: Int64) {
        self.url = url
        self.replica = replica
        self.room = room
        self.seen = seen
        self.own = own
        self.writtenUpTo = writtenUpTo
        service = SyncedPlaces.service(of: url)
        people = Self.sorted(seen.people)
    }

    nonisolated static func isPackage(_ url: URL) -> Bool {
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) && isFolder.boolValue
    }

    /// Whether a design keeps its changes in parts: one in a synced folder, or one that has been
    /// or is shared, whose parts go on being written wherever it is.
    nonisolated static func applies(to design: URL) -> Bool {
        guard isPackage(design) else { return false }
        return FolderShare.isShared(design) || SyncedPlaces.service(of: design) != nil
    }

    /// The design's own file as it is, with when it was written, for the first of the parts.
    nonisolated private static func ownFile(_ url: URL, _ doc: BezzleDocument) -> (doc: BezzleDocument, modified: Int64)? {
        let file = url.appendingPathComponent("document.json")
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
        return (doc, Int64(modified.timeIntervalSince1970 * 1000))
    }

    /// The design as everyone's files have it, with what is needed to keep it in step; the first
    /// time, from `seed` or its own file (`FolderShare.opening`).
    nonisolated struct Prepared: Sendable {
        let seen: FolderShare.Seen
        let opened: FolderShare.Opening
        let initialPart: Data?
    }

    nonisolated static func prepare(_ url: URL, replica: String, seed: SharedDesign? = nil, file: BezzleDocument?) -> Prepared {
        let found = FolderShare.look(url, replica: replica, seen: FolderShare.Seen(), opening: true)
        let opened = FolderShare.opening(found, seed: seed, file: { file.flatMap { ownFile(url, $0) } }, by: replica)
        return Prepared(seen: found.seen, opened: opened, initialPart: opened.first == nil ? nil : FolderShare.pack(opened.state))
    }

    static func open(_ url: URL, replica: String, seed: SharedDesign? = nil, file: BezzleDocument?, prepared: Prepared? = nil) -> (copy: FolderCopy, state: SharedDesign)? {
        let mine = FolderShare.folder(of: replica, in: url)
        do {
            // In the design while it is there, never its package made anew: one made again while
            // a sync service had it away for a moment is a second design of the same name to it.
            try WindowsCore.makeFolder(mine, in: url)
        } catch {
            NSLog("Bezzle could not make room for its files in %@: %@", url.path, "\(error)")
            return nil
        }
        let prepared = prepared ?? prepare(url, replica: replica, seed: seed, file: file)
        let opened = prepared.opened
        if let whole = opened.first {
            guard let data = prepared.initialPart, (try? data.write(to: mine.appendingPathComponent(whole.fileName), options: .atomic)) != nil else {
                NSLog("Bezzle could not write the first of its files in %@", url.path)
                return nil
            }
        }
        var room = prepared.seen.room
        if room?.isValid != true || !claim(room!, at: url) {
            // None yet, or this is a copy of the design made in Explorer, which is a design of its
            // own, with a room of its own.
            let fresh = FolderShare.Room.fresh(at: WindowsCore.nowMilliseconds)
            try? FolderShare.encode(fresh)?.write(to: FolderShare.roomURL(of: url), options: .atomic)
            _ = claim(fresh, at: url)
            room = fresh
        }
        var seen = prepared.seen
        seen.room = room
        let copy = FolderCopy(url: url, replica: replica, room: room!, seen: seen, own: opened.own, writtenUpTo: opened.writtenUpTo)
        copy.introduce(since: WindowsCore.nowMilliseconds)
        return (copy, opened.state)
    }

    // MARK: Telling a copy

    /// Each folder room's design on this computer, by its secret, to tell a copy made in Explorer.
    private static var rooms: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "folderRooms") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "folderRooms") }
    }

    /// A path to compare: Windows does not tell capitals from small letters in its paths.
    private static func key(_ url: URL) -> String { url.standardizedFileURL.path.lowercased() }

    /// Whether the design at `url` is this computer's design with `room`, rather than a copy of
    /// one that is still there.
    private static func claim(_ room: FolderShare.Room, at url: URL) -> Bool {
        let path = key(url)
        if let known = rooms[room.seed], known != path, FileManager.default.fileExists(atPath: known),
           FileManager.default.fileExists(atPath: FolderShare.roomURL(of: URL(fileURLWithPath: known)).path) { return false }
        rooms[room.seed] = path
        return true
    }

    // MARK: Who is who

    /// Says who works on the design from this computer, when that is new or has changed.
    private func introduce(since: Int64? = nil) {
        let file = FolderShare.folder(of: replica, in: url).appendingPathComponent(FolderShare.personFile)
        if introduced == nil {
            introduced = (try? Data(contentsOf: file)).flatMap { FolderShare.decode(FolderShare.Person.self, from: $0) }
        }
        let me = Self.me(replica: replica, since: introduced?.since ?? since ?? WindowsCore.nowMilliseconds)
        guard introduced != me, let data = FolderShare.encode(me) else { return }
        introduced = me
        try? data.write(to: file, options: .atomic)
    }

    static func me(replica: String, since: Int64 = 0) -> FolderShare.Person {
        FolderShare.Person(replica: replica, name: WindowsCore.myName, app: "windows", since: since)
    }

    /// The others, apart from this person's other computers.
    var others: [FolderShare.Person] {
        let me = Self.me(replica: replica)
        return people.filter { !$0.isSamePerson(as: me) }
    }

    var mark: WindowsCore.ShareMark? {
        guard let service, !others.isEmpty else { return nil }
        return .inFolder(service)
    }

    private static func sorted(_ people: [String: FolderShare.Person]) -> [FolderShare.Person] {
        people.values.sorted { $0.since != $1.since ? $0.since < $1.since : $0.replica < $1.replica }
    }

    func moved(to url: URL) {
        self.url = url
        _ = Self.claim(room, at: url)
        service = SyncedPlaces.service(of: url)
    }

    // MARK: Keeping in step

    /// What a look through the folder found that is new, the rest kept for the next look.
    struct Took {
        var changes: [SharedDesign] = []
        var pictures: [String] = []
        var versions: [(DesignVersion, Data)] = []
        var roomChanged = false
    }

    func take(_ found: FolderShare.Found) -> Took {
        seen = found.seen
        if found.peopleChanged { people = Self.sorted(seen.people) }
        var took = Took(changes: found.changes, pictures: found.pictures, versions: found.versions)
        if let room = found.seen.room, room.isValid, room != self.room {
            self.room = room
            _ = Self.claim(room, at: url)
            took.roomChanged = true
        }
        return took
    }

    /// Writes what was changed here since this computer's last file, with what came from
    /// elsewhere than the folder (`kept`), and now and then the whole design, ahead of the
    /// design's own file.
    func persist(_ state: SharedDesign, keeping kept: [SharedDesign] = []) {
        introduce()
        guard let writing = FolderShare.writing(state, by: replica, since: writtenUpTo, keeping: kept, own: own) else { return }
        let from = writtenUpTo
        writtenUpTo = state.clock.time
        own = writing.names
        let folder = FolderShare.folder(of: replica, in: url)
        do {
            try WindowsCore.makeFolder(folder, in: url)
            try FolderShare.write(writing, into: folder)
        } catch {
            NSLog("Bezzle could not write its changes to %@: %@", folder.path, "\(error)")
            // Written again with the next save.
            writtenUpTo = min(writtenUpTo, from)
            own = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { FolderShare.Part(fileName: $0) != nil }
        }
    }

    /// Whether anyone else writes in the folder, so that it is worth looking through.
    var watched: Bool { service != nil || !people.isEmpty }

    /// When copies the folder's service made beside the design were last looked for.
    private var copiesLookedFor: Date?

    /// Takes copies the folder's service made beside the design back into it and sends them to the
    /// Recycle Bin, every 20 seconds at most, but none open here (`open`, by path); true when any
    /// was (the Mac's FolderSync.foldCopies, `FolderShare.fold`). In a service that keeps each file
    /// apart, so too what it kept twice inside the design as two computers wrote one name, but
    /// pictures the design shows by such a name (`using`; `FolderShare.foldCopiesInside`).
    @discardableResult
    func foldCopies(open: Set<String>, using: Set<String> = []) -> Bool {
        guard let service else { return false }
        if let last = copiesLookedFor, Date().timeIntervalSince(last) < 20 { return false }
        copiesLookedFor = Date()
        var folded = false
        for copy in FolderShare.copiesFromTheService(of: url) where !open.contains(WindowsCore.openKey(copy)) {
            do {
                try FolderShare.fold(copy, into: url) { copy in
                    guard WindowsCore.recycle(copy) else { throw WindowsCore.CoreError("\(copy.path) could not go to the Recycle Bin") }
                }
                folded = true
                NSLog("Bezzle took %@ into %@, a copy the folder's sync service made of it, and sent it to the Recycle Bin", copy.lastPathComponent, url.lastPathComponent)
            } catch {
                NSLog("Bezzle could not take %@ into %@: %@", copy.path, url.path, "\(error)")
            }
        }
        if service != "iCloud Drive" {
            let taken = FolderShare.foldCopiesInside(url, using: using) { copy in
                guard WindowsCore.recycle(copy) else { throw WindowsCore.CoreError("\(copy.path) could not go to the Recycle Bin") }
            }
            if !taken.isEmpty {
                NSLog("Bezzle took back into %@ what the folder's sync service kept twice in it: %@", url.lastPathComponent, taken.joined(separator: ", "))
            }
        }
        return folded
    }

    /// The keys of the folder's live room, made from its secret.
    var roomKeys: ShareKeys? { Data(hex: room.seed).flatMap { ShareKeys(secret: $0) } }
}
