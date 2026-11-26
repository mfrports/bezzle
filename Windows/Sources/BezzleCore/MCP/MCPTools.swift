import Foundation

// From Bezzle/MCP/MCPTools.swift, for Windows: what an AI assistant can do in Bezzle, as tools
// of the Model Context Protocol. Each change goes through the core as one made by hand does, so
// it shows at once, is one step of the undo history, and is saved a moment later. A tool works on
// the design it names, open in a tab whether in front or not, or opened in one, as on the Mac.

@MainActor final class MCPTools {
    struct Definition {
        let name: String
        let title: String
        let description: String
        let properties: JSONValue
        var required: [String] = []
        var readOnly = false
        var destructive = false
        let run: (Arguments) async throws -> [Content]
    }

    enum Content {
        case text(String)
        case png(Data)

        var json: JSONValue {
            switch self {
            case .text(let s): ["type": "text", "text": .string(s)]
            case .png(let data): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": "image/png"]
            }
        }
    }

    private var definitions: [Definition] = []

    init() {
        definitions = makeDefinitions()
    }

    var list: [JSONValue] {
        definitions.map { d in
            [
                "name": .string(d.name),
                "title": .string(d.title),
                "description": .string(d.description),
                "inputSchema": .object([("type", "object"), ("properties", d.properties)] + (d.required.isEmpty ? [] : [("required", .array(d.required.map { .string($0) }))])),
                "annotations": [
                    "title": .string(d.title),
                    "readOnlyHint": .bool(d.readOnly),
                    "destructiveHint": .bool(d.destructive),
                    "idempotentHint": .bool(d.readOnly),
                    "openWorldHint": false,
                ],
            ]
        }
    }

    var names: [String] { definitions.map(\.name) }

    func has(_ name: String) -> Bool { definitions.contains { $0.name == name } }

    func call(_ name: String, _ arguments: [String: Any]) async -> JSONValue {
        guard let tool = definitions.first(where: { $0.name == name }) else { return Self.failed("There is no tool called \(name).") }
        // The tool works on the design it names, in front or not; then the one in front is the
        // core's again.
        defer { MCPHost.shared.settle() }
        do {
            let content = try await tool.run(Arguments(arguments))
            return ["content": .array(content.map(\.json))]
        } catch let error as MCPError {
            return Self.failed(error.message)
        } catch {
            return Self.failed("\(error)")
        }
    }

    private static func failed(_ message: String) -> JSONValue {
        ["content": [["type": "text", "text": .string(message)]], "isError": true]
    }

    /// Told to the assistant when it connects.
    static let instructions = """
        Bezzle is an app for designing screens, posts and pages, here on Windows. A design is an \
        infinite canvas of artboards (like screens or pages, possibly carousels of slides, or \
        decks of posts that share one design and differ in their words and pictures) with layers \
        on them: rectangles, ellipses, lines, text, paths (vector outlines), groups. Coordinates \
        are points, y pointing down. An artboard's x and y are on the canvas; any other layer's \
        are measured from the top left of the artboard or group it lies in. Layers are listed \
        bottom first. Refer to designs by name and layers by id (or exact name). Start with \
        get_design to see what is open. add_layers builds a whole screen in one call, nested; \
        update_layers changes many layers at once. Look at what you made with render and fix \
        what looks wrong. browse opens websites in Bezzle's own browser, signed in as the person \
        left it and clicked through, and import_website brings in the pages it shows, several at \
        once into one design. An artboard is also a film, in Animate: get_animation reads its keys \
        and animate sets them, for its layers and for a camera that looks at it. Keys hold \
        changes from the design, never places of their own, so a layer comes on with one key away \
        from the design at the start (fade 0, move a little below) and one back at the design a \
        little later (fade 1, move 0, 0). Its moves give several layers such an entrance ready \
        made, one after another by apart seconds. Leave pace at auto unless there is a reason: it \
        settles what comes home and flows through keys that keep going. The camera at rest (zoom \
        1, no tilt) shows the whole artboard, and a fly over is a few camera keys with tilt and \
        zoom, ending at rest. How a layer looks is keyed too (a key with look): its colours, a \
        border's width, its corners and its shadow, each value the look itself at that time. \
        Every change is one step the person can undo with Ctrl+Z, and \
        designs save themselves: there is no save.
        """

    // MARK: Designs open in tabs

    /// The design `design` names, opened if it is not, or the one in front; it is the design the
    /// core works on until the tool is done.
    func store(_ args: Arguments) async throws -> DocumentStore {
        if let ref = try args.string("design") {
            if let store = Self.openStore(ref) {
                store.activate()
                return store
            }
            return try await open(try locate(ref))
        }
        guard let front = Self.stores.first else {
            throw MCPError("No design is open. list_designs shows the designs; open one with open_design, or make one with create_design.")
        }
        front.activate()
        return front
    }

    /// The open designs, the tab in front first, then as they were last looked at.
    static var stores: [DocumentStore] { MCPHost.shared.designs().filter(\.isOpen).map(DocumentStore.of) }

    private static func openStore(_ ref: String) -> DocumentStore? {
        let url = fileURL(ref)
        return stores.first { $0.name.caseInsensitiveCompare(ref) == .orderedSame || url.map($0.isAt) == true }
    }

    /// What the Mac adds when a file is out of its sandbox's reach; Windows has none.
    static var unreachable: String { "" }

    /// The designs on the home screen: those in the designs folder, the latest first, and those
    /// open in tabs from elsewhere after them, as the Mac's library lists designs opened from
    /// outside its folder.
    private static func designs() -> [(name: String, url: URL, modified: Date)] {
        let folder = MCPHost.shared.designsFolder()
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        func entry(_ url: URL) -> (name: String, url: URL, modified: Date) {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (url.deletingPathExtension().lastPathComponent, url, modified)
        }
        let inFolder = urls.filter { $0.pathExtension.lowercased() == "bezzle" }.map(entry).sorted { $0.modified > $1.modified }
        let elsewhere = stores.map(\.url).filter { url in !inFolder.contains { DocumentStore.same($0.url, url) } }.map(entry)
        return inFolder + elsewhere
    }

    /// A design's file: one on the home screen by name, or a path.
    private func locate(_ ref: String) throws -> URL {
        if let entry = Self.designs().first(where: { $0.name.caseInsensitiveCompare(ref) == .orderedSame }) { return entry.url }
        if let url = Self.fileURL(ref), FileManager.default.fileExists(atPath: url.path) { return url }
        throw MCPError("There is no design called \"\(ref)\". list_designs shows them all; a path to a .bezzle design works too.")
    }

    private static func fileURL(_ ref: String) -> URL? {
        guard ref.contains("/") || ref.contains("\\") else { return nil }
        return URL(fileURLWithPath: ref).standardizedFileURL
    }

    /// Opens a design in a tab, as the home screen does, and brings it to the front.
    /// A file from Adobe XD, Figma, Sketch or Photoshop becomes a new design in the designs
    /// folder, which is what opens, as on the Mac.
    private func open(_ url: URL) async throws -> DocumentStore {
        var url = url
        var report: WindowsCore.ImportSummary?
        if WindowsCore.imports(url) {
            do {
                (url, report) = try WindowsCore.importDesign(url, into: MCPHost.shared.designsFolder())
            } catch {
                throw MCPError("\(url.lastPathComponent) could not be brought in: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
        }
        guard url.pathExtension.lowercased() == "bezzle" else {
            throw MCPError("\(url.lastPathComponent) is not a design: Bezzle opens .bezzle designs, and brings in .xd, .fig, .sketch, .psd and .psb files.")
        }
        if let store = Self.stores.first(where: { $0.isAt(url) }) {
            store.activate()
            return store
        }
        MCPHost.shared.endEditing()
        guard let slot = await MCPHost.shared.open(url, report), slot.isOpen else {
            throw MCPError("\(url.lastPathComponent) could not be opened.")
        }
        let store = DocumentStore.of(slot)
        store.activate()
        return store
    }

    // MARK: Designs

    func listDesigns(_ args: Arguments) throws -> [Content] {
        let open = Self.stores
        let designs: [JSONValue] = Self.designs().map { entry in
            let store = open.first { $0.isAt(entry.url) }
            return .compact([
                ("name", .string(entry.name)),
                ("path", .string(entry.url.path)),
                ("modified", .string(ISO8601DateFormatter().string(from: entry.modified))),
                ("open", store != nil ? true : nil),
                ("front", store != nil && store === open.first ? true : nil),
            ])
        }
        return [.text(JSONValue.compact([("folder", .string(MCPHost.shared.designsFolder().path)), ("designs", .array(designs))]).text)]
    }

    func createDesign(_ args: Arguments) async throws -> [Content] {
        var board = Node(kind: .artboard, frame: .zero)
        var warnings: [String] = []
        var props: [String: Any] = [:]
        for key in ["preset", "carousel", "width", "height"] where args[key] != nil { props[key] = args[key] }
        var doc = BezzleDocument()
        if !props.isEmpty {
            board.frame.size = CGSize(width: 393, height: 852)
            try Self.apply(props, to: &board, warnings: &warnings)
            let preset = try args.string("preset").flatMap { p in Preset.all.first { $0.name.caseInsensitiveCompare(p) == .orderedSame } }
            board.name = preset.map { String(localized: $0.title) } ?? (board.isCarousel ? String(localized: "Carousel") : String(localized: "Artboard"))
            doc.nodes = [board]
        }
        let wanted = try args.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\\", with: "-")
        let folder = MCPHost.shared.designsFolder()
        let base = wanted.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Untitled")
        var url = folder.appendingPathComponent("\(base).bezzle")
        var i = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) \(i).bezzle")
            i += 1
        }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileManager.default.createDirectory(at: url.appendingPathComponent("images", isDirectory: true), withIntermediateDirectories: true)
            try encoder.encode(doc).write(to: url.appendingPathComponent("document.json"), options: .atomic)
        } catch {
            throw MCPError("The design could not be made: \(error)")
        }
        let store = try await open(url)
        store.zoomToFit()
        return [.text(summary(of: store, warnings: warnings).text)]
    }

    func openDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        MCPHost.shared.bringForward(store.slot)
        store.activate()
        return [.text(summary(of: store).text)]
    }

    func importWebsite(_ args: Arguments) async throws -> [Content] {
        if let urls = try args.strings("urls"), !urls.isEmpty { return try await importPages(urls, args) }
        if try args.bool("shown") == true { return try await importShown(args) }
        guard let address = try args.string("url"), let url = WebCapture.address(address) else {
            throw MCPError("Give the page's address, such as https://example.com, or shown true to read the page in Bezzle's browser.")
        }
        let sizes = try webSizes(args)
        let hide = try args.bool("hide_banners") ?? true
        if try args.string("design") != nil {
            let store = try await store(args)
            let ids: [UUID], report: ImportReport
            do {
                (ids, report) = try await WebImport.run(url, sizes: sizes, hideBanners: hide, into: store.slot, named: try args.string("name"))
            } catch {
                throw MCPError("\(address) could not be brought in: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            showBrought(ids, report, in: store)
            return [.text(brought(ids, report, into: store))]
        }
        let design: URL, report: ImportReport
        do {
            (design, report) = try await WebImport.run(url, sizes: sizes, hideBanners: hide, into: MCPHost.shared.designsFolder())
        } catch {
            throw MCPError("\(address) could not be brought in: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        // Opened in a tab, as the Mac opens it, with what came across at the canvas's foot.
        let store = try await open(design)
        MCPHost.shared.broughtIn(WindowsCore.summary(of: report))
        store.zoomToFit()
        var text = summary(of: store).text
        var lines = report.notes.sorted { $0.value > $1.value }.map { "\($0.key): \($0.value)" }
        if !report.missingFonts.isEmpty { lines.append("Fonts not on this computer: " + report.missingFonts.sorted().joined(separator: ", ")) }
        if !lines.isEmpty { text += "\n\nOnly approximated:\n" + lines.map { "- \($0)" }.joined(separator: "\n") }
        return [.text(text)]
    }

    /// The widths asked for, each once, as the import's sizes know them.
    private func webSizes(_ args: Arguments) throws -> [WebCapture.Size] {
        var sizes: [WebCapture.Size] = []
        if let widths = args["widths"] as? [Any] {
            for w in widths {
                guard let n = WebCapture.number(w) ?? Double("\(w)"), n >= 240 else { throw MCPError("widths should be numbers of pixels, from 240 up.") }
                let size = Self.webSize(n)
                if !sizes.contains(where: { $0.width == size.width }) { sizes.append(size) }
            }
        }
        return sizes
    }

    /// Several pages into one design together, side by side and one step of its undo history:
    /// with shown, through Bezzle's browser, the page open as it is first; else each read afresh
    /// at every width asked for. Both are signed in as the browser is.
    private func importPages(_ addresses: [String], _ args: Arguments) async throws -> [Content] {
        var urls: [URL] = []
        for a in addresses {
            guard let url = WebCapture.address(a) else { throw MCPError("\(a) is not a web address Bezzle can open.") }
            urls.append(url)
        }
        let into = try args.string("design") != nil ? try await store(args) : nil
        if try args.bool("shown") == true {
            let browser = WebBrowser.shared
            guard let here = browser.url else { throw MCPError("Bezzle's browser has no page open: browse with action open and a url first.") }
            var pages = [WebSitePage(url: WebSitePage.plain(here), name: browser.title, kind: .open)]
            for url in urls where !pages.contains(where: { $0.id == WebSitePage.plain(url).absoluteString }) {
                pages.append(WebSitePage(url: WebSitePage.plain(url), name: url.path, kind: .linked))
            }
            let done: WebBrowser.Brought
            do { done = try await browser.importPages(pages, into: into?.slot) } catch {
                throw MCPError("The pages could not be brought in: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            let store = DocumentStore.of(done.slot)
            var text = brought(done.ids, done.report, into: store)
            if !done.missed.isEmpty { text += "\nNot read: " + done.missed.map(\.absoluteString).joined(separator: ", ") }
            return [.text(text)]
        }
        var sizes = try webSizes(args)
        if sizes.isEmpty { sizes = [.desktop] }
        let hide = try args.bool("hide_banners") ?? true
        var reads: [WebRead] = [], held: [String: Data] = [:], missed: [String] = []
        var named = into?.doc.nodes ?? []
        for url in urls {
            do {
                let (some, pictures) = try await WebImport.read(url, sizes: sizes, hideBanners: hide)
                for (i, var read) in some.enumerated() {
                    read.name = WebImport.boardName(of: read.page, size: sizes[i], among: named)
                    named.append(Node(kind: .artboard, name: read.name, frame: .zero))
                    reads.append(read)
                }
                held.merge(pictures) { a, _ in a }
            } catch {
                missed.append("\(url.absoluteString) (\((error as? LocalizedError)?.errorDescription ?? "\(error)"))")
            }
        }
        guard let first = urls.first, !reads.isEmpty else { throw MCPError("None of the pages could be read: " + missed.joined(separator: "; ")) }
        var text: String
        if let into {
            guard into.isOpen else { throw MCPError("\(into.name) was closed while the pages were read.") }
            let (ids, report): ([UUID], ImportReport)
            do {
                (ids, report) = try WindowsCore.using(into.slot) { try WindowsCore.bringIn(reads, held: held, source: WebImport.source(of: first)) }
            } catch {
                throw MCPError("The pages could not be brought in: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
            }
            showBrought(ids, report, in: into)
            text = brought(ids, report, into: into)
        } else {
            let (design, report) = try WebImport.write(reads, held: held, source: WebImport.source(of: first), into: MCPHost.shared.designsFolder())
            let store = try await open(design)
            if !report.lines.isEmpty { MCPHost.shared.broughtIn(WindowsCore.summary(of: report)) }
            store.zoomToFit()
            text = brought(store.doc.nodes.filter(\.isArtboard).map(\.id), report, into: store)
        }
        if !missed.isEmpty { text += "\nNot read: " + missed.joined(separator: "; ") }
        return [.text(text)]
    }

    /// The page in Bezzle's browser, read as it is, into a design.
    private func importShown(_ args: Arguments) async throws -> [Content] {
        let into = try args.string("design") != nil ? try await store(args) : nil
        let done: WebBrowser.Brought
        do {
            done = try await WebBrowser.shared.importShown(name: try args.string("name"), into: into?.slot)
        } catch let error as WebBrowser.Failure {
            if case .nothingOpen = error { throw MCPError("Bezzle's browser has no page open: browse with action open and a url first.") }
            throw MCPError(error.localizedDescription)
        } catch {
            throw MCPError("The page could not be brought in: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        return [.text(brought(done.ids, done.report, into: DocumentStore.of(done.slot)))]
    }

    /// The new artboards in the design's window, selected, and what came across at its foot, as
    /// the Mac's store shows pages brought in.
    private func showBrought(_ ids: [UUID], _ report: ImportReport, in store: DocumentStore) {
        guard store.isOpen else { return }
        store.activate()
        MCPHost.shared.edited()
        store.selection = ids
        if !report.lines.isEmpty { MCPHost.shared.broughtIn(WindowsCore.summary(of: report)) }
    }

    /// What was brought in, for the assistant: the new artboards, and what was only approximated.
    private func brought(_ ids: [UUID], _ report: ImportReport, into store: DocumentStore) -> String {
        let doc = store.doc
        let boards: [JSONValue] = ids.compactMap { id in
            guard let n = doc.node(id) else { return nil }
            return .object([("id", .string(id.uuidString)), ("name", .string(n.name)), ("x", .number(Double(n.frame.minX))), ("y", .number(Double(n.frame.minY))),
                            ("width", .number(Double(n.frame.width))), ("height", .number(Double(n.frame.height)))])
        }
        var pairs: [(String, JSONValue)] = [("design", .string(store.name)), ("artboards", .array(boards))]
        let lines = report.lines
        if !lines.isEmpty { pairs.append(("approximated", .array(lines.map { .string($0) }))) }
        return JSONValue.object(pairs).text
    }

    /// A width a page is read at, as the import's sizes know it.
    static func webSize(_ width: Double) -> WebCapture.Size { WindowsCore.WebWidth(width).size }

    func closeDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let name = store.name
        MCPHost.shared.close(store.slot)
        return [.text("Closed \(name). It was saved.")]
    }

    /// Renames the design's package, its tab staying open, as the Mac's store renames it: a name
    /// taken already gets a number after it.
    func renameDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        guard let name = try args.string("name"), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MCPError("Give the new name.") }
        guard store.mayRename else { throw MCPError("\(store.name) was shared with you, so it keeps the name it was shared under.") }
        MCPHost.shared.endEditing()
        guard WindowsCore.renamedURL(store.url, to: name) != nil else { return [.text(summary(of: store).text)] }
        guard WindowsCore.renameDesign(to: name) else { throw MCPError("\(store.url.lastPathComponent) could not be renamed.") }
        MCPHost.shared.renamed()
        return [.text(summary(of: store).text)]
    }

    func duplicateDesign(_ args: Arguments) async throws -> [Content] {
        guard let ref = try args.string("design") else { throw MCPError("Say which design to copy.") }
        let open = Self.openStore(ref)
        let url = try open?.url ?? locate(ref)
        open?.save()
        // Named as the Mac's Library.duplicate names it, in the person's language.
        let folder = url.deletingLastPathComponent(), base = String(localized: "\(url.deletingPathExtension().lastPathComponent) copy")
        var copy = folder.appendingPathComponent("\(base).bezzle")
        var i = 2
        while FileManager.default.fileExists(atPath: copy.path) {
            copy = folder.appendingPathComponent("\(base) \(i).bezzle")
            i += 1
        }
        do {
            try FileManager.default.copyItem(at: url, to: copy)
        } catch {
            throw MCPError("The copy could not be made: \(error)")
        }
        return [.text(JSONValue.object([("name", .string(copy.deletingPathExtension().lastPathComponent)), ("path", .string(copy.path))]).text)]
    }

    func deleteDesign(_ args: Arguments) async throws -> [Content] {
        guard let ref = try args.string("design") else { throw MCPError("Say which design to delete.") }
        let open = Self.openStore(ref)
        let url = try open?.url ?? locate(ref)
        if let open { MCPHost.shared.close(open.slot) }
        guard WindowsCore.recycle(url) else { throw MCPError("\(url.lastPathComponent) could not be moved to the Recycle Bin.") }
        return [.text("Moved \(url.lastPathComponent) to the Recycle Bin.")]
    }

    /// What a design is, how it is looked at, and its layers.
    func getDesign(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        let depth = try args.int("depth") ?? .max
        let budget = Budget(Self.layerBudget)
        var pairs = summaryPairs(of: store)
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: store.doc)
            pairs.append(("layer", Self.describe(store.doc.node(id)!, in: store.doc, full: false, depth: depth, budget: budget)))
        } else {
            pairs.append(("layers", .array(store.doc.nodes.map { Self.describe($0, in: store.doc, full: false, depth: depth, budget: budget) })))
        }
        if budget.left <= 0 {
            pairs.append(("note", "Not every layer is listed. Ask for one artboard with layer, or less of it with depth."))
        }
        return [.text(JSONValue.compact(pairs).text)]
    }

    func summary(of store: DocumentStore, warnings: [String] = []) -> JSONValue {
        .compact(summaryPairs(of: store) + [("warnings", .array(warnings.map { .string($0) }))])
    }

    private func summaryPairs(of store: DocumentStore) -> [(String, JSONValue?)] {
        let visible = store.visibleCanvasRect
        return [
            ("design", .string(store.name)),
            ("path", .string(store.url.path)),
            ("artboards", .array(store.doc.artboards.map { .object([("id", .string($0.id.uuidString)), ("name", .string($0.name))]) })),
            ("layerCount", .number(store.layerCount)),
            ("selection", .array(store.selection.map { .string($0.uuidString) })),
            ("view", .compact([("zoom", .number(store.zoom)), ("visible", visible.width > 0 ? Self.rect(visible) : nil)])),
            ("canUndo", store.canUndo ? true : nil),
            ("canRedo", store.canRedo ? true : nil),
        ]
    }

    // MARK: Undo

    func undo(_ args: Arguments, redo: Bool) async throws -> [Content] {
        let store = try await store(args)
        MCPHost.shared.endEditing()
        var done = 0
        for _ in 0..<max(1, try args.int("steps") ?? 1) {
            guard redo ? WindowsCore.redo() : WindowsCore.undo() else { break }
            done += 1
        }
        guard done > 0 else { return [.text("There is nothing to \(redo ? "redo" : "undo").")] }
        MCPHost.shared.edited()
        return [.text(JSONValue.object([(redo ? "redid" : "undid", .number(done)), ("now", summary(of: store))]).text)]
    }

    // MARK: Looking

    func view(_ args: Arguments) async throws -> [Content] {
        let store = try await store(args)
        if let ref = try args.string("layer") {
            let id = try Self.layer(ref, in: store.doc)
            guard let frame = store.doc.absoluteFrame(of: id) else { throw MCPError("That layer is gone.") }
            MCPHost.shared.show(Geometry.bounds(of: frame, rotation: store.doc.node(id)?.rotation ?? 0))
        } else if let word = args["zoom"] as? String {
            switch word.lowercased() {
            case "fit", "all": store.zoomToFit()
            case "selection":
                guard let r = store.doc.selectionFrame(store.selection) else { throw MCPError("Nothing is selected.") }
                MCPHost.shared.show(r)
            default: throw MCPError("zoom is a number, 1 for actual size, or \"fit\" or \"selection\".")
            }
        } else if let zoom = try args.number("zoom") {
            MCPHost.shared.setZoom(min(max(zoom, 0.02), 64))
        } else {
            throw MCPError("Give a layer to look at, or a zoom.")
        }
        return [.text(summary(of: store).text)]
    }

    func listFonts(_ args: Arguments) throws -> [Content] {
        let all = Fonts.families
        if let family = try args.string("family") {
            let match = family.caseInsensitiveCompare("SF Pro") == .orderedSame ? TextStyle.system : all.first { $0.caseInsensitiveCompare(family) == .orderedSame }
            guard let match else { throw MCPError("There is no font family called \(family) in Bezzle.") }
            return [.text(JSONValue.object([("family", .string(match)), ("faces", .array(Fonts.faces(of: match).map { .string($0) }))]).text)]
        }
        let search = try args.string("search")?.lowercased()
        let families = all.filter { search == nil || $0.lowercased().contains(search!) }
        return [.text(JSONValue.object([("families", .array(families.map { .string($0) })), ("note", "\"System\" is SF Pro, drawn on Windows with an open look-alike. list_fonts with a family lists its faces.")]).text)]
    }

    // MARK: Reading what was sent

    struct Arguments {
        let values: [String: Any]

        init(_ values: [String: Any]) { self.values = values }

        /// What was sent for `key`, if anything; null counts as nothing.
        subscript(key: String) -> Any? { values[key].flatMap { $0 is NSNull ? nil : $0 } }

        func string(_ key: String) throws -> String? { try Read.string(self[key], key) }
        func number(_ key: String) throws -> Double? { try Read.number(self[key], key) }
        func int(_ key: String) throws -> Int? { try Read.number(self[key], key).map { Int($0.rounded()) } }
        func bool(_ key: String) throws -> Bool? { try Read.bool(self[key], key) }

        /// A list of strings, or one on its own.
        func strings(_ key: String) throws -> [String]? {
            guard let v = self[key] else { return nil }
            if let s = v as? String { return [s] }
            guard let list = v as? [Any], let strings = list as? [String] else { throw MCPError("\(key) should be a list of strings.") }
            return strings
        }

        func objects(_ key: String) throws -> [[String: Any]]? {
            guard let v = self[key] else { return nil }
            if let one = v as? [String: Any] { return [one] }
            guard let list = v as? [Any], let objects = list as? [[String: Any]] else { throw MCPError("\(key) should be a list of objects.") }
            return objects
        }
    }

    /// Values of one kind or another out of what `JSONSerialization` read, with a word for the
    /// assistant when one is not what it should be.
    enum Read {
        static func string(_ v: Any?, _ key: String) throws -> String? {
            guard let v, !(v is NSNull) else { return nil }
            guard let s = v as? String else { throw MCPError("\(key) should be a string.") }
            return s
        }

        static func number(_ v: Any?, _ key: String) throws -> Double? {
            guard let v, !(v is NSNull) else { return nil }
            if let s = v as? String, let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
            guard let n = v as? NSNumber, !n.isBoolean, n.doubleValue.isFinite else { throw MCPError("\(key) should be a number.") }
            return n.doubleValue
        }

        static func bool(_ v: Any?, _ key: String) throws -> Bool? {
            guard let v, !(v is NSNull) else { return nil }
            if let b = v as? Bool, !(v is NSNumber) || (v as? NSNumber)?.isBoolean == true { return b }
            guard let n = v as? NSNumber, n.isBoolean else { throw MCPError("\(key) should be true or false.") }
            return n.boolValue
        }

        static func object(_ v: Any?, _ key: String) throws -> [String: Any]? {
            guard let v, !(v is NSNull) else { return nil }
            guard let o = v as? [String: Any] else { throw MCPError("\(key) should be an object.") }
            return o
        }

        /// A point as {x, y} or [x, y].
        static func point(_ v: Any?, _ key: String) throws -> CGPoint? {
            guard let v, !(v is NSNull) else { return nil }
            if let o = v as? [String: Any], let x = try number(o["x"], "\(key).x"), let y = try number(o["y"], "\(key).y") { return CGPoint(x: x, y: y) }
            if let a = v as? [Any], a.count == 2, let x = try number(a[0], key), let y = try number(a[1], key) { return CGPoint(x: x, y: y) }
            throw MCPError("\(key) should be a point, {\"x\": 0, \"y\": 0}.")
        }
    }
}

struct MCPError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}
