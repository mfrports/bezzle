import Foundation
import AppKit
import CBezzleHost

/// What the Windows app and its tools ask of the core: the fonts, a design, an artboard drawn.
/// The counterpart of the web core's Main.swift, called directly instead of through exports.
public enum WindowsCore {
    nonisolated public struct Board: Sendable {
        public let index: Int
        public let name: String
        public let frame: CGRect
        /// Its fill as six hex digits and an alpha, for drawing it in small.
        public var fill: (hex: String, alpha: Double) = ("FFFFFF", 1)
        public var id: UUID?
        public var hidden = false
        /// The part of the canvas its picture covers: its frame, or, when it does not clip what
        /// lies on it, as far as that reaches.
        public var drawn: CGRect = .zero
        /// A carousel's slides: how big each is, and how many.
        public var slide: CGSize?
        public var slides = 1
    }

    /// Where an artboard's picture reaches on the canvas: its frame, and when it shows what runs
    /// past its edges, as far as that paints, seen from where the canvas looks at it (`sceneLooks`).
    static func drawn(_ n: Node) -> CGRect {
        guard n.isArtboard, !n.clips else { return n.frame }
        var r = n.frame
        let eye = Eye.stage(n.frame.size).looking(sceneLooks[n.id])
        for c in n.children where !c.hidden { r = r.union(Renderer.reach(of: c, eye: eye).offsetBy(dx: n.frame.minX, dy: n.frame.minY)) }
        return r.integral
    }

    nonisolated(unsafe) static var design: BezzleDocument? {
        didSet {
            designVersion &+= 1
            // Changed here, unless it is what others did being shown (`showChangesFromOthers`).
            if !takingOthers, let sharing {
                sharing.changedHere = true
                sharing.editedHere = true
            }
            // A design brought back by Undo, shown ahead of a change or come from elsewhere is
            // looked at as this one is (`sceneLooks`, Host/Looking.swift), as the Mac's store hands on.
            let looking = sceneLooks.isEmpty ? nil : sceneLooks
            if design != nil, design?.looks != looking { design?.looks = looking }
        }
    }
    /// Counts the changes to `design`, as the Mac's store.version: the live room takes in what
    /// was done here when it moves on.
    nonisolated(unsafe) static var designVersion = 0
    nonisolated(unsafe) static var assets = Assets(folder: nil)
    /// Where the open design is kept: its package, or its file.
    nonisolated(unsafe) public internal(set) static var designURL: URL?

    /// The open fonts that stand in for the Mac's (Web/tools/openfonts.py): `manifest.json` and
    /// the faces it lists, in `folder`. The system font's stand-in is registered as "System".
    public static func loadFonts(from folder: URL) throws {
        let data = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        let manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let system = manifest["system"] as? [String: Any], let file = system["file"] as? String {
            try add("System", "", Data(contentsOf: folder.appendingPathComponent(file)))
            Fonts.files["System/"] = folder.appendingPathComponent(file)
            SystemFont.weights = (system["weights"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            if let o = system["opsz"] as? [Any], o.count == 2, let low = (o[0] as? NSNumber)?.doubleValue, let high = (o[1] as? NSNumber)?.doubleValue {
                SystemFont.opticalSizes = low...high
            }
        }
        for face in manifest["faces"] as? [[String: Any]] ?? [] {
            guard let family = face["family"] as? String, let name = face["face"] as? String, let file = face["file"] as? String else { continue }
            try add(family, name, Data(contentsOf: folder.appendingPathComponent(file)))
            Fonts.files["\(family)/\(name)"] = folder.appendingPathComponent(file)
        }
        NSFontManager.shared.families = manifest["families"] as? [String: [String]] ?? [:]
        // The Mac's families drawn here in fonts that stand in for them, whose letters are spaced
        // to the Mac's widths (MacFonts.spacing).
        var standIns = Set((manifest["standsIn"] as? [String: Any] ?? [:]).keys)
        if (manifest["system"] as? [String: Any])?["standsIn"] != nil { standIns.insert(TextStyle.system) }
        MacFonts.standIns = standIns
        // Windows' own fonts too, but where only the open ones are wanted (measuring them).
        if ProcessInfo.processInfo.environment["BEZZLE_OPEN_FONTS_ONLY"] == nil { readInstalledFonts() }
        bz_text_forget()
        TextLayout.forget()
    }

    private static func add(_ family: String, _ face: String, _ data: Data) throws {
        let added = data.withUnsafeBytes { bz_font_add(family, face, $0.baseAddress, Int32($0.count)) }
        if added == 0 { throw CoreError("Skia cannot read the font \(family) \(face)") }
    }

    /// Opens the design in `folder`, a .bezzle package: its document.json, and its pictures in
    /// images/, by their file names, as the core asks for them. Answers its artboards.
    public static func open(_ folder: URL) throws -> [Board] {
        let doc = try read(folder)
        typing = nil
        versions.reset()
        timeTable.forget()
        previewBase = nil
        showingVersion = false
        fronts = [:]
        sceneLooks = [:]
        // A shared design opens as it is shared, which its own file may lag behind.
        design = openShared(folder, file: doc)
        // Opened as it is, it has nothing done here to be written.
        sharing?.changedHere = false
        sharing?.editedHere = false
        missingSince = nil
        designURL = folder
        Editing.undos = []
        Editing.redos = []
        assets = Assets(folder: folder.appendingPathComponent("images"))
        return boards()
    }

    /// Lets the open design go, once it is saved: a save that comes later has nothing to write.
    public static func close() {
        typing = nil
        sharing?.close()
        sharing = nil
        fronts = [:]
        versions.reset()
        timeTable.forget()
        previewBase = nil
        showingVersion = false
        sceneLooks = [:]
        design = nil
        designURL = nil
        Editing.undos = []
        Editing.redos = []
        Editing.gestureStart = nil
        Editing.gestureBase = nil
        assets = Assets(folder: nil)
    }

    /// A design's document as its file has it, its pictures given to Skia by their file names
    /// (each picture's own UUID): a package with its document.json, or a design from before
    /// pictures, one JSON file. Nothing that is open changes.
    static func read(_ folder: URL) throws -> BezzleDocument {
        var isFolder: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder)
        let json = isFolder.boolValue ? folder.appendingPathComponent("document.json") : folder
        var doc = try JSONDecoder().decode(BezzleDocument.self, from: Data(contentsOf: json))
        doc.repairStyles()
        let images = folder.appendingPathComponent("images")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []
        for name in names {
            let data = try Data(contentsOf: images.appendingPathComponent(name))
            giveSkia(name, data, fromPackage: true)
        }
        // Pictures from the relay that wait beside a design in a synced folder (`arrivals`).
        let waiting = arrivals.images(of: folder)
        for name in Set((try? FileManager.default.contentsOfDirectory(atPath: waiting.path)) ?? []).subtracting(names) {
            if let data = try? Data(contentsOf: waiting.appendingPathComponent(name)) { giveSkia(name, data) }
        }
        return doc
    }

    /// Pictures and named versions that came from the relay to a design in a synced folder, kept
    /// beside it in this computer's own folder until the folder brings them (`FolderShare.Arrivals`,
    /// which says why; the Mac's Arrivals).
    static let arrivals: FolderShare.Arrivals = {
        let env = ProcessInfo.processInfo.environment
        let base = env["LOCALAPPDATA"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return FolderShare.Arrivals(root: base.appendingPathComponent("Bezzle", isDirectory: true).appendingPathComponent("Arrivals", isDirectory: true))
    }()

    /// How long one waits for the folder to bring it before this computer writes it into the design.
    nonisolated(unsafe) public static var arrivalsGrace: TimeInterval = 120

    /// Draws the design's layer `index` (an artboard) at `scale` pixels a point with the app's own
    /// renderer, and Skia makes the pictures it recorded: premultiplied RGBA, rows top first.
    public static func render(board index: Int, scale: Double) -> (width: Int, height: Int, pixels: [UInt8])? {
        guard let doc = design, index < doc.nodes.count else { return nil }
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        // A deck as the post in front of it here.
        guard let image = Renderer.image(of: seen(doc.nodes[index]), scale: CGFloat(scale), assets: assets) else { return nil }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let done = pixels.withUnsafeMutableBytes { bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 0, $0.baseAddress) }
        forget(before: first)
        return done == 0 ? (image.width, image.height, pixels) : nil
    }

    /// Draws artboard `index` as `render` does, into pixels the caller has: its size first, then,
    /// in `fill`, where to put the premultiplied BGRA pixels, rows top first (a WinUI
    /// WriteableBitmap's own layout). The layers `hiding` are left out.
    public static func render(board index: Int, scale: Double, hiding: Set<UUID> = [], into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard var doc = design, index < doc.nodes.count else { return false }
        // As much of the canvas as the artboard covers with them all: what the canvas places it by.
        let part = drawn(seen(doc.nodes[index]))
        // The text being typed into is shown by its editor, not drawn under it, as on the Mac, and
        // texts whose letters are on their way by the canvas, over the design.
        for id in hiding { doc.update(id) { $0.hidden = true } }
        // A text on a curve is straight while it is typed into, as on the Mac.
        if let id = typing?.id, doc.node(id)?.isCurved == true { doc.update(id) { $0 = LetterFlights.straight($0, frame: $0.frame).node } }
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        // A deck as the post in front of it here.
        let board = seen(doc.nodes[index])
        guard let image = picture(of: board, part: part == board.frame ? nil : part, scale: CGFloat(scale)) else { return false }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        defer { forget(before: first) }
        guard let pixels = fill(image.width, image.height) else { return false }
        return bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 1, pixels) == 0
    }

    /// Artboard `index` as the canvas shows it, for trying it without a window: from where it is
    /// looked at (`sceneLooks`) and as far as it reaches when it shows what runs past its edges,
    /// which is the part of the canvas `covers` says. Premultiplied RGBA, rows top first.
    public static func renderShown(board index: Int, scale: Double) -> (width: Int, height: Int, pixels: [UInt8], covers: CGRect)? {
        guard let doc = design, index < doc.nodes.count else { return nil }
        let board = seen(doc.nodes[index])
        let part = drawn(board)
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let image = picture(of: board, part: part == board.frame ? nil : part, scale: CGFloat(scale)) else { return nil }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let done = pixels.withUnsafeMutableBytes { bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 0, $0.baseAddress) }
        forget(before: first)
        return done == 0 ? (image.width, image.height, pixels, part) : nil
    }

    /// The pictures made for drawings before `first` are let go here, but not the design's own;
    /// each is forgotten by Skia when nothing holds it any more (`CGImage.released`): the drawing
    /// keeps some of them to draw them again (as 3D layers' flattened faces).
    static func forget(before first: Int) {
        if CGImage.released == nil { CGImage.released = { id in bz_picture_forget(Int32(id)) } }
        Images.shared.list.removeAll { image in
            if case .asset = image.source { return false }
            return image.id < first
        }
    }

    /// Writes pixels as `render` makes them to a PNG file.
    public static func writePNG(_ pixels: [UInt8], width: Int, height: Int, to url: URL) throws {
        let written = pixels.withUnsafeBytes { bz_png_write(url.path, Int32(width), Int32(height), $0.baseAddress) }
        if written != 0 { throw CoreError("Could not write \(url.path)") }
    }

    /// A picture the core made, as Skia will make it (CGImage.Source).
    static func send(_ p: CGImage) {
        let id = Int32(p.id), w = Int32(p.width), h = Int32(p.height)
        switch p.source {
        case .asset(let n):
            bz_picture_asset(id, Int32(n))
        case .picture(let commands):
            commands.withUnsafeBufferPointer { bz_picture_recording(id, w, h, $0.baseAddress, Int64($0.count)) }
        case .changed(let from, let changes):
            var crop: [Double] = [0, 0, 0, 0], blur = -1.0, clamp: Int32 = 0, perspective: [Double]?, ramp: [Double]?
            var develop: (cube: [Float], size: Int, amounts: [Double])?
            for change in changes {
                switch change {
                case .develop(let cube, let size, let dehaze, let clarity, let texture, let sharpness):
                    develop = (cube, size, [dehaze, clarity, texture, sharpness])
                case .crop(let r): crop = [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)]
                case .blur(let sigma, let c): blur = sigma; clamp = c ? 1 : 0
                case .rampBlur(let sigma, let c, let a, let b):
                    blur = sigma
                    clamp = c ? 1 : 0
                    ramp = [Double(a.x), Double(a.y), Double(b.x), Double(b.y)]
                case .perspective(let m, _): perspective = m
                // Worked out by the core where it is asked for (ImportPictures.spread).
                case .spread: break
                }
            }
            defer {
                if let ramp { ramp.withUnsafeBufferPointer { bz_picture_ramp(id, $0.baseAddress) } }
                if let develop {
                    develop.cube.withUnsafeBufferPointer { cube in
                        develop.amounts.withUnsafeBufferPointer { bz_picture_develop(id, cube.isEmpty ? nil : cube.baseAddress, Int32(develop.size), $0.baseAddress) }
                    }
                }
            }
            crop.withUnsafeBufferPointer { c in
                if let m = perspective {
                    m.withUnsafeBufferPointer { bz_picture_changed(id, w, h, Int32(from.id), c.baseAddress, blur, clamp, $0.baseAddress) }
                } else {
                    bz_picture_changed(id, w, h, Int32(from.id), c.baseAddress, blur, clamp, nil)
                }
            }
        case .pixels(let bytes, let row, let gray):
            guard gray || p.straightAlpha else {
                bytes.withUnsafeBufferPointer { bz_picture_pixels(id, w, h, Int32(row), $0.baseAddress) }
                return
            }
            // Skia is given RGBA, its colours multiplied by how solid they are.
            var rgba = [UInt8](repeating: 255, count: p.width * p.height * 4)
            for y in 0..<p.height {
                for x in 0..<p.width {
                    let to = (y * p.width + x) * 4
                    if gray {
                        for c in 0..<3 { rgba[to + c] = bytes[y * row + x] }
                    } else {
                        let from = y * row + x * 4, a = Int(bytes[from + 3])
                        for c in 0..<3 { rgba[to + c] = UInt8((Int(bytes[from + c]) * a + 127) / 255) }
                        rgba[to + 3] = UInt8(a)
                    }
                }
            }
            rgba.withUnsafeBufferPointer { bz_picture_pixels(id, w, h, w * 4, $0.baseAddress) }
        }
    }

    nonisolated public struct CoreError: Swift.Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }
}

extension WindowsCore {
    /// The shadow an artboard casts on the canvas, as the Mac's canvas draws it (2 pt down, blur
    /// 10, the shadow colour at 13%), `width` by `height` pixels at `scale` pixels a point, into
    /// BGRA pixels `pad` larger on every side, which `fill` gives once it has the size.
    public static func artboardShadow(width: Int, height: Int, scale: Double, colour: UInt32 = 0x3A3226,
                                      into fill: (_ width: Int, _ height: Int, _ pad: Int) -> UnsafeMutableRawPointer?) -> Bool {
        let pad = Int((14 * scale).rounded(.up))
        guard let pixels = fill(width + 2 * pad, height + 2 * pad, pad) else { return false }
        return bz_shadow(Int32(width), Int32(height), Int32(pad), 10 * scale, 2 * scale, colour, 0.13, pixels) == 0
    }
}

extension WindowsCore {
    /// Saves the design where it is kept, as the Mac's DocumentStore.save does: a shared design's
    /// changes first, in this computer's own files in it (`SharedSession.persist`), then its
    /// document.json (sorted keys), written whole; a package gone meanwhile is looked for (a shared
    /// design renamed by someone else) and otherwise made again, so nothing is lost. True when the
    /// design was written.
    ///
    /// In a folder a sync service keeps in step, only what was changed here: with nothing changed on
    /// this computer since it last wrote, nothing is written, so that one only looking on writes
    /// nothing while another works; `closing`, it keeps once what came over the relay from people
    /// the folder does not bring. And a design away from where it was is not made again at once:
    /// the service takes it away for a moment as it puts in place what another computer wrote, and
    /// one made again meanwhile is a second design of the same name to it. `Away` says to try again
    /// in a moment; after `missingGrace` it is written where it was all the same.
    @discardableResult
    public static func save(closing: Bool = false) throws -> Bool {
        if inSyncedFolder, sharing?.changedHere != true {
            if closing { sharing?.persist(force: true) }
            return false
        }
        // Renamed or moved while open: saved where it is now, not begun again where it was.
        if !follow() { followFile(alsoIn: designsFolder()) }
        guard let url = designURL, let doc = previewBase ?? design else { return false }
        if inSyncedFolder, !FileManager.default.fileExists(atPath: url.appendingPathComponent("document.json").path) {
            let since = missingSince ?? Date()
            missingSince = since
            if Date().timeIntervalSince(since) < missingGrace { throw Away() }
            NSLog("Bezzle wrote %@ again where it was, after it stayed away", url.path)
        }
        missingSince = nil
        if let sharing {
            var shared = doc
            shared.viewport = nil
            sharing.takeIn(shared)
            sharing.persist(force: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(doc)
        var isFolder: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
        if exists, !isFolder.boolValue {
            try data.write(to: url, options: .atomic)
        } else {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
            try data.write(to: url.appendingPathComponent("document.json"), options: .atomic)
        }
        // Pictures and versions from the relay that the folder has not brought by now go in with
        // this computer's own change; those it brought are forgotten (`arrivals`).
        if inSyncedFolder { arrivals.settle(url, grace: arrivalsGrace) }
        // Written: nothing done here waits to be.
        sharing?.changedHere = false
        return true
    }

    /// The design is away from where it was, in a synced folder: saved again in a moment.
    public struct Away: Error, CustomStringConvertible {
        public var description: String { "The design is away for a moment" }
    }

    /// How long a design in a synced folder may be away before it is written again where it was.
    nonisolated(unsafe) public static var missingGrace: TimeInterval = 20
    /// Since when the open design has not been where it was, while that lasts.
    nonisolated(unsafe) static var missingSince: Date?
}

extension WindowsCore {
    /// A size a design can start at, as the Mac's home offers it (Store/Library.swift's Preset).
    nonisolated public struct Size: Sendable {
        public let name: String
        public let width: Double
        public let height: Double
        /// Its family (Preset.Group), which says what it is drawn as on home's stage.
        public var group = ""
    }

    /// The sizes by kind (Devices, Social media, Print & slides) and family, in the order offered.
    public static func sizes() -> [(kind: String, families: [(name: String, sizes: [Size])])] {
        Preset.Kind.allCases.map { kind in
            (kind.title.key, Preset.Group.all(of: kind).map { group in
                (group.title.key, Preset.all.filter { $0.group == group }.map { Size(name: $0.name, width: Double($0.size.width), height: Double($0.size.height), group: group.rawValue) })
            }.filter { !$0.1.isEmpty })
        }
    }

    /// Makes a new design in `folder`, with one artboard of `size`, as the Mac's Library.create
    /// does: "Untitled", then "Untitled 2"…, in the person's language; returns where it is. Its
    /// artboard is named for its size, as the Mac's home names it (HomeStage: the preset's title).
    public static func createDesign(in folder: URL, size: Size?) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let untitled = String(localized: "Untitled")
        var url = folder.appendingPathComponent("\(untitled).bezzle")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(untitled) \(i).bezzle")
            i += 1
        }
        var doc = BezzleDocument()
        if let size {
            let name = Preset.all.first { $0.name == size.name }.map { String(localized: $0.title) } ?? String(localized: "Artboard")
            doc.nodes = [Node(kind: .artboard, name: name, frame: CGRect(x: 0, y: 0, width: size.width, height: size.height))]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: url.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
        try encoder.encode(doc).write(to: url.appendingPathComponent("document.json"), options: .atomic)
        return url
    }

    /// Writes a copy of the open design into `folder`, as the Mac's Save a Copy does: its
    /// document and pictures (not its versions or sharing), named `name` or, when that is taken,
    /// "name 2" and on. Returns where it is.
    public static func saveCopy(named name: String, in folder: URL) throws -> URL {
        guard let doc = previewBase ?? design else { throw CoreError("No design is open.") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent("\(name).bezzle")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(name) \(i).bezzle")
            i += 1
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let images = url.appendingPathComponent("images", isDirectory: true)
        if let from = assets.folder, FileManager.default.fileExists(atPath: from.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: from, to: images)
        } else {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        }
        try encoder.encode(doc).write(to: url.appendingPathComponent("document.json"), options: .atomic)
        return url
    }

    /// Draws the first artboard of the design at `url` for a thumbnail, `width` pixels wide,
    /// into BGRA pixels `fill` gives once it has the size; opens the design to do it.
    public static func thumbnail(of url: URL, width: Double, height: Double, scale: Double, into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        // Read on its own: the design that is open, its file and its undo stay as they are.
        guard let doc = try? read(url) else { return false }
        let pictures = Assets(folder: url.appendingPathComponent("images"))
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let image = Renderer.thumbnail(of: doc, size: CGSize(width: width, height: height), scale: CGFloat(scale), assets: pictures, cover: true) else { return false }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        defer { forget(before: first) }
        guard let pixels = fill(image.width, image.height) else { return false }
        return bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 1, pixels) == 0
    }
}

extension WindowsCore {
    /// Home's table, as the Mac's Stage draws it: the table's colour, radius 20, a pool of light
    /// where the clock puts it (Daylight: from the left in the morning to the right by evening, a
    /// lamp after dark), and the far edge falling into shade; into BGRA pixels.
    public static func stage(width: Int, height: Int, scale: Double, table: UInt32, dark: Bool, date: Date = Date(),
                             into pixels: UnsafeMutableRawPointer) -> Bool {
        let calendar = Calendar.current
        let hour = Double(calendar.component(.hour, from: date)) + Double(calendar.component(.minute, from: date)) / 60
        let lamp = !(6..<20).contains(hour)
        let day = (hour - 6) / 14
        let x = lamp ? 0.8 : 0.14 + day * 0.72, warmth = lamp ? 1 : max(0, day - 0.45) * 1.6
        let t = min(max(warmth, 0), 1)
        let light = (r: 0.92 + 0.08 * t, g: 0.95 - 0.11 * t, b: 1.0 - 0.36 * t)
        let rgb = UInt32(light.r * 255) << 16 | UInt32(light.g * 255) << 8 | UInt32(light.b * 255)
        let strength = dark ? (lamp ? 0.13 : 0.075) : (lamp ? 0.5 : 0.62)
        return bz_stage(Int32(width), Int32(height), scale, table, rgb, strength, x, lamp ? 0.25 : 0, lamp ? 0.62 : 0.85, dark ? 0.16 : 0.035, pixels) == 0
    }
}
