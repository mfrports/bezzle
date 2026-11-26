import Foundation

// Several designs open at once, a tab each, as on the Mac. The core keeps the state of one open
// design in its statics: the design and its file, its history, what a drag holds, what is offered,
// its versions. That one is the design `active`, the tab in front. Each other open design waits in
// a `Slot`, its state put there when another came to the front and put back when it comes to the
// front again: a few dozen assignments, so a tab comes to the front at once, as on the Mac, where
// each design has a store of its own. Work on a design that is not in front (saving it a moment
// after a change, an AI assistant working on it, quitting) is done in `using(slot)`, which lends it
// the statics for that long.

/// Is handed each value a design keeps in the core's statics, in turn (`WindowsCore.visitState`).
protocol SlotVisitor {
    mutating func visit<T>(_ value: inout T)
}

extension WindowsCore {
    /// An open design, in front or waiting: its state, while another is in front, and what is its
    /// own for good (its versions and the glide to them).
    @MainActor public final class Slot {
        /// Whether the design is still open; once closed it is never used again.
        public fileprivate(set) var isOpen = true
        /// Its state as it was when another came to the front; nil while it is in front, or before
        /// it first was (a design opening).
        fileprivate var parked: [Any]?
        fileprivate let versions = Versions()
        fileprivate let timeTable = TimeTable()
        /// The package as the file system knows it, whatever its name: found again by it when it
        /// was renamed or moved in Explorer while open (the Mac's bookmark).
        var identity: FileIdentity?

        init() {}

        public var isActive: Bool { WindowsCore.active === self }

        /// Where the design is kept, in front or not.
        public var url: URL? {
            if isActive { return WindowsCore.designURL }
            return parked.flatMap { $0[WindowsCore.urlIndex] as? URL }
        }
    }

    /// The open design whose state the core's statics hold: the tab in front, or the one an AI
    /// assistant or a save is working on for a moment. Nil with no design open.
    public private(set) static var active: Slot?
    /// What the statics hold with no design open, as they were before any opened.
    private static var blank: [Any]?
    private static let idleVersions = Versions()
    private static let idleTimeTable = TimeTable()

    /// Every value one open design keeps in the statics, in one place: what `take` and `put` go
    /// through. A new one belongs here.
    private static func visitState<V: SlotVisitor>(_ v: inout V) {
        v.visit(&designURL)
        // From where its artboards are looked at, before the design, which is handed them as it is put back.
        v.visit(&sceneLooks)
        v.visit(&design)
        v.visit(&assets)
        v.visit(&rasterPackage)
        v.visit(&previewBase)
        v.visit(&fronts)
        v.visit(&showingVersion)
        v.visit(&sharing)
        // Sharing's own: how often the design changed (its room takes in by it), whether a picture
        // came, and who hears of the share's news: each tab's window.
        v.visit(&designVersion)
        // Since when it has been away from where it was, in a synced folder (`save`).
        v.visit(&missingSince)
        v.visit(&pictureCame)
        v.visit(&shareNews)
        v.visit(&Editing.gestureStart)
        v.visit(&Editing.gestureBase)
        v.visit(&Editing.undos)
        v.visit(&Editing.redos)
        v.visit(&Editing.lastEcho)
        v.visit(&Editing.lastStep)
        v.visit(&Editing.lastSettled)
        v.visit(&typing)
        v.visit(&moving)
        v.visit(&pushing)
        v.visit(&pushedFrom)
        v.visit(&pushLevels)
        v.visit(&pushedTo)
        v.visit(&pulling)
        v.visit(&adapting)
        v.visit(&offered)
        v.visit(&copyEcho)
        v.visit(&styleOffered)
        v.visit(&deckOffered)
        v.visit(&pendingStyleOffer)
        v.visit(&stylesFromList)
        v.visit(&finder)
        v.visit(&invited)
        v.visit(&openShadow)
        v.visit(&measure)
        // Its pictures being cut out, and why one could not be.
        v.visit(&cuttingOut)
        v.visit(&cutoutTrouble)
        // Its pictures being vectorized, and those it has made shapes and remembers (Vectors.swift).
        v.visit(&vectorizing)
        v.visit(&traced)
        v.visit(&vectorWanted)
        v.visit(&vectorPreviewed)
        v.visit(&vectorReveals)
        v.visit(&retracing)
        v.visit(&vectorShowing)
        visitHolding(&v)
    }

    /// Where `designURL` is in what `visitState` goes through.
    fileprivate static let urlIndex = 0

    private struct Taking: SlotVisitor {
        var values: [Any] = []
        mutating func visit<T>(_ value: inout T) { values.append(value) }
    }

    private struct Putting: SlotVisitor {
        let values: [Any]
        var at = 0
        mutating func visit<T>(_ value: inout T) {
            value = values[at] as! T
            at += 1
        }
    }

    private static func take() -> [Any] {
        var taking = Taking()
        visitState(&taking)
        return taking.values
    }

    private static func put(_ values: [Any]) {
        var putting = Putting(values: values)
        visitState(&putting)
    }

    /// Puts the design in front aside, in its slot, and `slot`'s state in the statics: the core
    /// works on that design from now on. Nil leaves none open.
    public static func activate(_ slot: Slot?) {
        guard slot !== active else { return }
        if blank == nil { blank = take() }
        if let active, active.isOpen { active.parked = take() }
        put(slot?.parked ?? blank ?? [])
        slot?.parked = nil
        versions = slot?.versions ?? idleVersions
        timeTable = slot?.timeTable ?? idleTimeTable
        active = slot
    }

    /// Does `body` with `slot`'s design as the one the core works on, then goes back to the one
    /// that was. For a design not in front: saving it, an AI assistant's work on it.
    @discardableResult
    public static func using<T>(_ slot: Slot, _ body: () throws -> T) rethrows -> T {
        let before = active
        activate(slot)
        defer { activate(before?.isOpen == true ? before : nil) }
        return try body()
    }

    /// Opens the design at `url` beside those open already, in a slot of its own, which becomes
    /// the one the core works on (`open`).
    public static func openSlot(_ url: URL) throws -> Slot {
        try openSlot(url, prepared: nil)
    }

    /// Installs a design whose document and sharing state were prepared on the opening worker.
    public static func openSlot(_ prepared: PreparedOpen) throws -> Slot {
        try openSlot(prepared.url, prepared: prepared)
    }

    private static func openSlot(_ url: URL, prepared: PreparedOpen?) throws -> Slot {
        let before = active
        let slot = Slot()
        activate(slot)
        do {
            _ = try open(url, prepared: prepared)
        } catch {
            slot.isOpen = false
            active = nil
            put(blank ?? [])
            activate(before)
            throw error
        }
        slot.identity = FileIdentity(of: url)
        return slot
    }

    /// Lets an open design go, once it is saved (`close`); the design that was in front stays so,
    /// unless it was this one.
    public static func closeSlot(_ slot: Slot) {
        guard slot.isOpen else { return }
        let before = active === slot ? nil : active
        activate(slot)
        close()
        slot.isOpen = false
        slot.parked = nil
        active = nil
        put(blank ?? [])
        versions = idleVersions
        timeTable = idleTimeTable
        activate(before)
    }
}

// MARK: - Renaming and moving, and following the file

extension WindowsCore {
    /// Whether the open design may be given a new name here: not someone else's, shared with this
    /// computer, which keeps the name it was shared under (the Mac's mayRename).
    public static var mayRename: Bool {
        switch shareMark {
        case .sharedBy?, .ended?: false
        default: true
        }
    }

    /// Where a design would go, renamed `name` in the folder it is in, as the Mac's
    /// Library.renamedURL: nil for no name or the same; the name as typed when only its letters'
    /// case changes; else the first of "name", "name 2"… that is free. Characters Windows does not
    /// allow in a name become dashes.
    public static func renamedURL(_ url: URL, to name: String) -> URL? {
        let clean = String(name.trimmingCharacters(in: .whitespacesAndNewlines).map { "\\/:*?\"<>|".contains($0) ? "-" : $0 })
        let old = url.deletingPathExtension().lastPathComponent
        guard !clean.isEmpty, clean != old else { return nil }
        let folder = url.deletingLastPathComponent()
        if clean.lowercased() == old.lowercased() { return folder.appendingPathComponent("\(clean).bezzle") }
        var target = folder.appendingPathComponent("\(clean).bezzle")
        var i = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(clean) \(i).bezzle")
            i += 1
        }
        return target
    }

    /// Gives the open design a new name, renaming its package; it goes on there. False when it
    /// may not or could not be renamed, and it stays as it was (the Mac's DocumentStore.rename).
    @discardableResult
    public static func renameDesign(to name: String) -> Bool {
        guard mayRename, let url = designURL, let target = renamedURL(url, to: name) else { return false }
        return moveDesign(to: target)
    }

    /// Moves the open design's package to `target`, saved first, and goes on with it there (the
    /// Mac's DocumentStore.move).
    @discardableResult
    public static func moveDesign(to target: URL) -> Bool {
        guard let url = designURL else { return false }
        try? save()
        do {
            // Only the letters' case changing: Windows takes the new name for the old one's, so
            // the package goes by way of a name of its own.
            if url.path.lowercased() == target.path.lowercased() {
                let between = url.deletingLastPathComponent().appendingPathComponent(".\(Foundation.UUID().uuidString).bezzle")
                try FileManager.default.moveItem(at: url, to: between)
                try FileManager.default.moveItem(at: between, to: target)
            } else {
                try FileManager.default.moveItem(at: url, to: target)
            }
        } catch {
            NSLog("Bezzle could not move %@ to %@: %@", url.path, target.path, "\(error)")
            return false
        }
        arrived(at: target)
        return true
    }

    /// Goes on with the open design where its package now is: its pictures, its share and its
    /// versions are read from there.
    static func arrived(at target: URL) {
        designURL = target
        assets = Assets(folder: target.appendingPathComponent("images"))
        sharing?.moved(to: target)
        active?.identity = FileIdentity(of: target)
    }

    /// Finds the open design's package again when it is no longer where it was, as when it was
    /// renamed or moved in Explorer while open: in the folder it was in, or the designs folder,
    /// the one package that is the same on disk (the Mac follows its bookmark). True when it was
    /// found elsewhere. A shared design is also found by its room (`follow`).
    @discardableResult
    static func followFile(alsoIn other: URL? = nil) -> Bool {
        guard let url = designURL, let identity = active?.identity,
              !FileManager.default.fileExists(atPath: url.appendingPathComponent("document.json").path),
              !FileManager.default.fileExists(atPath: url.path) else { return false }
        var folders = [url.deletingLastPathComponent()]
        if let other, !same(other, folders[0]) { folders.append(other) }
        for folder in folders {
            let found = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).filter { candidate in
                candidate.pathExtension.lowercased() == "bezzle" && FileIdentity(of: candidate) == identity
                    && FileManager.default.fileExists(atPath: candidate.appendingPathComponent("document.json").path)
            }
            if found.count == 1, let there = found.first {
                NSLog("Bezzle found %@ again at %@", url.path, there.path)
                arrived(at: there)
                return true
            }
        }
        return false
    }

    /// Where designs are kept, for finding one that was moved there: the app says.
    nonisolated(unsafe) public static var designsFolder: () -> URL? = { nil }

    /// Finds the open design again if its package is no longer where it was: a shared one by its
    /// room, any by what it is on disk. True when it was found elsewhere.
    @discardableResult
    public static func followDesign() -> Bool {
        follow() || followFile(alsoIn: designsFolder())
    }
}
