import Foundation

// The AI server on Windows works on the designs open in the window's tabs, as the Mac's does.
// The tools copied from Bezzle/MCP ask a DocumentStore for a design; here there is one for each
// open design (its `WindowsCore.Slot`), which answers from the core, and from the app (`MCPHost`)
// for what only the window knows: which designs are open, what is selected, what is in view. A
// tool makes the design it works on the core's (`store(args)` activates it), whether its tab is in
// front or not, and once the tool is done the design in front is the core's again (`settle`).

/// What the app does for the AI server: it fills these in as it starts. Those that are about one
/// design are about the design the core works on now (`WindowsCore.active`).
@MainActor public final class MCPHost {
    public static let shared = MCPHost()

    /// Where designs are kept: the home screen's folder.
    public var designsFolder: () -> URL = { FileManager.default.temporaryDirectory }
    /// Opens a design in a tab of its own and brings it to the front, as home does, or brings its
    /// tab to the front when it is open already. Returns that tab's slot once open.
    public var open: @MainActor (URL, WindowsCore.ImportSummary?) async -> WindowsCore.Slot? = { _, _ in nil }
    /// The open designs, the tab in front first, then as they were last looked at.
    public var designs: () -> [WindowsCore.Slot] = { [] }
    /// Brings an open design's tab to the front.
    public var bringForward: (WindowsCore.Slot) -> Void = { _ in }
    /// Closes an open design's tab, saving it; home comes to the front if it was in front.
    public var close: (WindowsCore.Slot) -> Void = { _ in }
    /// The design was given another name: its tab says so.
    public var renamed: () -> Void = {}
    /// A tool is done: the design in front is the one the core works on again.
    public var settle: () -> Void = {}
    /// The layers selected, and selecting others (on the artboard they are on).
    public var selection: () -> [UUID] = { [] }
    public var select: ([UUID]) -> Void = { _ in }
    /// The design changed: the window draws it again and saves it a moment later.
    public var edited: () -> Void = {}
    /// The part of the canvas in view, and how near it is looked at.
    public var visible: () -> CGRect = { .zero }
    public var zoom: () -> Double = { 1 }
    /// The view brought round: to everything, to a part of the canvas, or to a zoom.
    public var zoomToFit: () -> Void = {}
    public var show: (CGRect) -> Void = { _ in }
    public var setZoom: (Double) -> Void = { _ in }
    /// The artboard the selection is on, or the one last worked on, by its place in the design.
    public var focusedBoard: () -> Int? = { nil }
    /// Typing into a text ends, so a change comes after it.
    public var endEditing: () -> Void = {}
    /// What came across from the other app the design just opened was brought in from, for the window to say.
    public var broughtIn: (WindowsCore.ImportSummary) -> Void = { _ in }
    /// The design's film desk (Animate), and the window's mode: 0 design, 1 prototype, 2 inspect, 3 animate.
    public var film: () -> WindowsCore.FilmDesk? = { nil }
    public var mode: () -> Int = { 0 }
    public var setMode: (Int) -> Void = { _ in }
}

/// The Mac's DocumentStore as the tools ask it, over one open design. What it reads and changes
/// it reads from the core with its design lent the core for that long (`lent`), so it answers for
/// its own design whichever is the core's; the tools' own calls into the core work on the design
/// `store(args)` made the core's.
@MainActor final class DocumentStore {
    let slot: WindowsCore.Slot

    private init(_ slot: WindowsCore.Slot) {
        self.slot = slot
    }

    /// One store for each open design, the same each time it is asked for.
    private static var made: [DocumentStore] = []

    static func of(_ slot: WindowsCore.Slot) -> DocumentStore {
        made.removeAll { !$0.slot.isOpen }
        if let store = made.first(where: { $0.slot === slot }) { return store }
        let store = DocumentStore(slot)
        made.append(store)
        return store
    }

    /// Makes this design the one the core works on, for a tool.
    func activate() {
        if slot.isOpen { WindowsCore.activate(slot) }
    }

    /// What `read` gives with this design the core's, or `otherwise` once it is closed.
    private func lent<T>(_ otherwise: T, _ read: () -> T) -> T {
        slot.isOpen ? WindowsCore.using(slot, read) : otherwise
    }

    var doc: BezzleDocument { lent(BezzleDocument()) { WindowsCore.design ?? BezzleDocument() } }
    var seenDoc: BezzleDocument { lent(doc) { WindowsCore.seen ?? WindowsCore.design ?? BezzleDocument() } }
    var url: URL { slot.url ?? URL(fileURLWithPath: "/") }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var assets: Assets { lent(Assets(folder: nil)) { WindowsCore.assets } }
    var isOpen: Bool { slot.isOpen }
    var selection: [UUID] {
        get { lent([]) { MCPHost.shared.selection() } }
        set { if slot.isOpen { WindowsCore.using(slot) { MCPHost.shared.select(newValue) } } }
    }
    var fronts: [UUID: Int] {
        get { lent([:]) { WindowsCore.fronts } }
        set { if slot.isOpen { WindowsCore.using(slot) { WindowsCore.fronts = newValue } } }
    }
    /// Nothing is pointed at by a person while the assistant works.
    var hovered: UUID? {
        get { nil }
        set {}
    }
    var layerCount: Int { doc.allNodes.count }
    /// The size new artboards are given: the Mac's standard one.
    var lastPreset: CGSize? { nil }
    var visibleCanvasRect: CGRect { lent(.zero) { MCPHost.shared.visible() } }
    var zoom: Double { lent(1) { MCPHost.shared.zoom() } }

    var focusedArtboard: Node? {
        lent(nil) {
            guard let i = MCPHost.shared.focusedBoard(), let doc = WindowsCore.design, doc.nodes.indices.contains(i), doc.nodes[i].isArtboard else { return nil }
            return doc.nodes[i]
        }
    }

    // MARK: Animate, as the Mac's store has it (AnimateOperations.swift)

    /// The window's film desk for this design.
    private var desk: WindowsCore.FilmDesk? { lent(nil) { MCPHost.shared.film() } }
    /// Whether the window shows the design in Animate.
    var animating: Bool { lent(false) { MCPHost.shared.mode() == 3 } }
    /// The desk as the tools read it: its artboard, whether it plays, where the playhead shows.
    struct FilmShown {
        var board: UUID?
        var playing: Bool
        var live: Double
    }
    var film: FilmShown {
        guard let d = desk else { return FilmShown(board: nil, playing: false, live: 0) }
        return FilmShown(board: d.board, playing: d.playing, live: d.live)
    }
    var filmTime: Double { desk?.filmTime ?? 0 }
    var filmBoard: Node? { lent(nil) { desk?.filmBoard } }
    func focusFilm() { if slot.isOpen { WindowsCore.using(slot) { desk?.focus() } } }
    /// Turns the window to Animate.
    func showAnimate() { if slot.isOpen { WindowsCore.using(slot) { MCPHost.shared.setMode(3) } } }
    func seek(_ t: Double) { desk?.seek(t) }
    func playFilm(fromStart: Bool = false) { desk?.play(fromStart: fromStart) }
    func pauseFilm() { desk?.pause() }
    static func cameraAim(at ids: [UUID], on board: Node, in doc: BezzleDocument, time t: Double) -> (move: [Double], zoom: Double)? {
        board.cameraAim(at: ids, in: doc, time: t)
    }
    /// The post a deck shows in front.
    func front(of deck: Node) -> Int? { deck.front(in: fronts) }

    var canUndo: Bool { lent(false) { !Editing.undos.isEmpty && Editing.gestureStart == nil } }
    var canRedo: Bool { lent(false) { !Editing.redos.isEmpty && Editing.gestureStart == nil } }

    /// Whether this is the design at `url`. A package's address may or may not end in a slash.
    func isAt(_ url: URL) -> Bool {
        isOpen && Self.same(self.url, url)
    }

    func zoomToFit() { if slot.isOpen { WindowsCore.using(slot) { MCPHost.shared.zoomToFit() } } }

    /// Whether two addresses are the same design, told apart by path as Windows compares them.
    static func same(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
            == b.standardizedFileURL.path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    }

    /// Windows opens no design to look at only.
    var isReadOnly: Bool { false }
    func node(_ id: UUID) -> Node? { doc.node(id) }
    func save() { if slot.isOpen { WindowsCore.using(slot) { try? WindowsCore.save() } } }
    /// Whether it may be given another name: not someone else's design shared with this computer.
    var mayRename: Bool { lent(false) { WindowsCore.mayRename } }
    static func finishSaving() {}

    func copiesInOrder(of master: UUID) -> [UUID] { doc.copiesInOrder(of: master) }
    func grid(holding id: UUID) -> Node? { doc.grid(holding: id) }
    func slots(of grid: Node) -> [Node] { doc.slots(of: grid) }
    func slot(of id: UUID) -> UUID? { doc.slot(of: id) }
    func styles(of kind: StyleKind) -> [Style] { doc.styles(of: kind) }
    func suggestedName(for look: StyleLook) -> String { doc.suggestedName(for: look) }
    /// The Mac washes a changed style across its artboard; Windows runs its wave as any change does.
    func washIn(_ boardID: UUID, before: BezzleDocument) {}

    /// What would suit a layer's picture best, as the Photo card's Auto works it out.
    func autoDevelop(for n: Node) -> Develop { WindowsCore.autoDevelop(n) }

    /// Turns a deck to one of its posts, what was selected going with it.
    func turn(_ deckID: UUID, to post: Int) {
        let moved = WindowsCore.turn(deckID, to: post, selection: selection)
        if moved != selection { selection = moved }
        MCPHost.shared.edited()
    }

    /// A picture file copied into the design's own pictures, as a fill.
    func importPicture(_ file: URL) -> ImageFill? { WindowsCore.importPicture(file) }

    /// From Store/CutoutOperations.swift: the pictures filling `ids` cut out by the core, in this
    /// design (its window shows the work as it goes, as the Mac's canvas does for the assistant).
    typealias CutoutTrouble = WindowsCore.CutoutTrouble
    func cutOut(_ ids: [UUID], picks: [CGPoint]? = nil) async throws -> [UUID] {
        guard slot.isOpen else { throw CutoutTrouble.noPictures }
        activate()
        return try await WindowsCore.cutOut(ids, picks: picks)
    }

    /// From Store/VectorOperations.swift: pictures traced into shapes by the core, in this design
    /// (its window shows the pencil pass, as the Mac's canvas does for the assistant).
    typealias VectorTrouble = WindowsCore.VectorTrouble
    func vectorizable(_ id: UUID) -> Bool { lent(false) { WindowsCore.vectorizable(id) } }
    func vector(of id: UUID) -> (source: VectorSource, version: VectorSource.Version)? { lent(nil) { WindowsCore.vector(of: id) } }
    func isRetracing(_ id: UUID) -> Bool { lent(false) { WindowsCore.isRetracing(id) } }
    func setVector(_ id: UUID, _ change: (inout VectorSettings) -> Void) {
        guard slot.isOpen else { return }
        WindowsCore.using(slot) { WindowsCore.setVector(id, change) }
    }
    func backToPicture(_ id: UUID) {
        guard slot.isOpen else { return }
        WindowsCore.using(slot) { WindowsCore.backToPicture(id) }
        MCPHost.shared.edited()
    }
    func vectorize(_ ids: [UUID], settings: VectorSettings) async throws -> [UUID] {
        guard slot.isOpen else { throw VectorTrouble.noPictures }
        activate()
        return try await WindowsCore.vectorize(ids, settings: settings)
    }

    /// Where a part, icon or library component would go, as the Mac's store works it out.
    func placing(_ resource: Resource, at point: CGPoint?, on target: UUID? = nil,
                 into boardID: UUID? = nil, dark: Bool? = nil, width: CGFloat? = nil) -> ResourcePlacing? {
        let board: Node? = boardID.flatMap { doc.node($0) } ?? (point.map { p in doc.artboard(at: p) } ?? focusedArtboard)
        let usable = board.flatMap { $0.locked ? nil : $0 }
        let center: CGPoint = point ?? {
            if boardID != nil, let usable { return usable.frame.center }
            let visible = visibleCanvasRect
            guard let usable else { return visible.center }
            let shown = usable.frame.intersection(visible)
            return shown.isNull || shown.isEmpty ? usable.frame.center : shown.center
        }()
        let dark = dark ?? Kits.isDark(usable)
        return doc.placing(resource, center: center, on: usable, over: target, dark: dark, width: width,
                           library: { WindowsCore.library($0) })
    }

    /// The pictures what is taken from another design holds, copied into this one.
    func bringPictures(_ take: LibraryTake) { WindowsCore.bringPictures(take) }

    /// The Mac opens a note's thread on the margin; Windows shows notes as they are.
    func showThread(_ id: UUID) {}
    var openThread: UUID? { nil }

    // MARK: What the Mac's store does to a design, as the tools ask it

    static func duplicate(_ ids: [UUID], in doc: inout BezzleDocument, offset: CGPoint) -> [UUID] {
        doc.duplicate(ids.filter { doc.node($0)?.locked == false }, offset: offset)
    }

    static func groupable(_ ids: [UUID], in doc: BezzleDocument) -> [UUID]? { doc.groupable(ids) }

    static let grouping: LocalizedStringResource = "Group"

    static func group(_ ids: [UUID], in doc: inout BezzleDocument, name: String?) -> UUID? {
        guard let group = doc.group(ids) else { return nil }
        if let name, !name.isEmpty { doc.update(group) { $0.name = name } }
        return group
    }

    static func ungroup(_ ids: [UUID], in doc: inout BezzleDocument) -> [UUID] {
        doc.ungroup(ids.filter { doc.node($0).map { $0.isGroup && !$0.isRepeatGrid } == true })
    }

    static func broken(_ deck: Node) -> Set<Int> { Deck.broken(deck) }

    // MARK: From the Mac's Store (CurveOperations, GridOperations, ComponentOperations,
    // MaskOperations, ResourceOperations, LibraryShelf, DevelopOperations, LayoutOperations)

// CurveOperations.swift
    /// Takes texts off the outlines they ride (`BezzleDocument.takeOffPath`).
    static func takeOffPath(_ ids: [UUID], in doc: inout BezzleDocument) {
        doc.takeOffPath(ids)
    }

// CurveOperations.swift
    static let straightening = LocalizedStringResource("undo.straighten-text", defaultValue: "Straighten Text", comment: "Undo name: a text's letters straight again after running along a curve.")

// GridOperations.swift
    /// The pictures among some files, and those in any folders among them, in the Finder's order by name.
    static func pictureFiles(in urls: [URL]) -> [URL] {
        let types = Set(["png", "jpg", "jpeg", "heic", "heif", "gif", "tif", "tiff", "webp", "bmp"])
        var found: [URL] = []
        for url in urls {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            if isFolder.boolValue {
                let inside = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                found += inside.filter { types.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            } else if types.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        return found
    }

// ComponentOperations.swift
    /// The groups in the design that look the same as a copy's component and could be copies of it.
    static func lookAlikes(of copyID: UUID, in doc: BezzleDocument) -> [UUID] { doc.lookAlikes(of: copyID) }

// MaskOperations.swift
    static let unmasking = LocalizedStringResource("undo.release-mask", defaultValue: "Release Mask", comment: "Undo name and menu: a mask taken apart, what it held showing whole again.")

// MaskOperations.swift
    static let takingOut = LocalizedStringResource("undo.take-out-of-mask", defaultValue: "Take Out of Mask", comment: "Undo name: layers taken out of the shape that held them.")

// MaskOperations.swift
    /// Takes layers out of the masks they lie in (shared: `BezzleDocument.takeOutOfMasks`).
    static func takeOut(_ ids: [UUID], in doc: inout BezzleDocument) { doc.takeOutOfMasks(ids) }

// CurveOperations.swift
    static let slidingText = LocalizedStringResource("undo.slide-text", defaultValue: "Move Text along Path", comment: "Undo name: a text moved along the outline it runs on, or to its other side.")

// CurveOperations.swift
    static let riding = LocalizedStringResource("undo.text-on-path", defaultValue: "Put Text on Path", comment: "Undo name: a text laid along a shape's outline, following it.")

// CurveOperations.swift
    static func ride(_ text: UUID, on shape: UUID, curve: TextCurve, in doc: inout BezzleDocument) -> UUID? {
        doc.ride(text, on: shape, curve: curve)
    }

// ComponentOperations.swift
    static func renameVariant(_ v: Int?, of masterID: UUID, to name: String, in doc: inout BezzleDocument) {
        doc.renameVariant(v, of: masterID, to: name)
    }

// ComponentOperations.swift
    static func renameComponent(_ masterID: UUID, to name: String, in doc: inout BezzleDocument) {
        doc.renameComponent(masterID, to: name)
    }

// ComponentOperations.swift
    static func removeVariant(_ v: Int, of masterID: UUID, in doc: inout BezzleDocument) {
        doc.removeVariant(v, of: masterID)
    }

// MaskOperations.swift
    /// Of several layers, the one that holds the rest (shared: `BezzleDocument.maskPlan`).
    static func maskPlan(_ ids: [UUID], in doc: BezzleDocument) -> MaskPlan? { doc.maskPlan(ids) }

// MaskOperations.swift
    static let masking = LocalizedStringResource("undo.mask", defaultValue: "Mask", comment: "Undo name and button: layers put inside a shape, cut off at its outline.")

// MaskOperations.swift
    static func mask(_ plan: MaskPlan, in doc: inout BezzleDocument) -> UUID? { doc.mask(plan) }

// GridOperations.swift
    static func makeRepeatGrid(of ids: [UUID], in doc: inout BezzleDocument, columns: Int = 1, rows: Int = 1,
                               columnGap: CGFloat? = nil, rowGap: CGFloat? = nil, name: String? = nil) -> UUID? {
        doc.makeRepeatGrid(of: ids, columns: columns, rows: rows, columnGap: columnGap, rowGap: rowGap, name: name)
    }

// ComponentOperations.swift
    static func makeComponent(from ids: [UUID], in doc: inout BezzleDocument, name: String? = nil, part: String? = nil) -> UUID? {
        doc.makeComponent(from: ids, name: name, part: part)
    }

// ComponentOperations.swift
    static func link(_ id: UUID, to masterID: UUID, in doc: inout BezzleDocument) -> UUID? { doc.link(id, to: masterID) }

// LibraryShelf.swift
    /// Where on a layer a style of its kind goes: the place the inspector has open, if it is of
    /// that kind, else the first fill (a text's letters), its type, its first shadow or its
    /// corners. What it goes on is turned on, so it shows.
    static func give(_ style: Style, to n: inout Node, at open: StylePlace?, dark: Bool, naming: Bool = true) {
        n.give(style, at: open, dark: dark, naming: naming)
    }

// DevelopOperations.swift
    /// Whether a layer shows a picture that can be developed.
    static func develops(_ n: Node) -> Bool { n.fill.on && n.fill.image != nil }

// LayoutOperations.swift
    nonisolated static func changeLayout(of node: inout Node, _ change: (inout LayoutGrid) -> Void) {
        node.changeLayout(change)
    }

// CurveOperations.swift
    /// Whether a text could ride `shape`'s outline (`BezzleDocument.canRide`, in Model/TextRiding.swift).
    static func canRide(_ text: UUID, on shape: UUID, in doc: BezzleDocument) -> Bool {
        doc.canRide(text, on: shape)
    }

// CurveOperations.swift
    static let bending = LocalizedStringResource("undo.bend-text", defaultValue: "Bend Text", comment: "Undo name: a text's letters bent into an arc.")

    // ResourceOperations.swift
    static func add(_ node: Node, part: String?, to board: UUID?, in doc: inout BezzleDocument) -> UUID {
        doc.add(node, part: part, to: board)
    }

}

/// The Mac's LibraryShelf as the libraries tool asks it: the other designs, read as libraries.
@MainActor final class LibraryShelf {
    static let shared = LibraryShelf()

    var designs: [LibraryContent] { WindowsCore.shelfContents }

    /// Every design in the designs folder read again, as it is now, but `except`. While it waits,
    /// the window goes on with the design in front, and the one a tool works on is the core's
    /// again after.
    func refreshed(except: URL? = nil) async {
        let folder = MCPHost.shared.designsFolder()
        let urls = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "bezzle" && !Self.same($0, except) }
        let working = WindowsCore.active
        MCPHost.shared.settle()
        await WindowsCore.refreshLibraries(urls)
        if let working, working.isOpen { WindowsCore.activate(working) }
    }

    func content(_ url: URL) -> LibraryContent? { WindowsCore.library(url) }

    static func same(_ a: URL, _ b: URL?) -> Bool { WindowsCore.same(a, b) }
}

/// The Mac's DocumentStore again, over a copy of the design: what the Object menu and the deck
/// and grid commands do to a selection, done to the copy, which `MCPTools.onSelection` then puts
/// in as one step (Store/DeckOperations.swift, GridOperations.swift).
@MainActor final class DesignCopy {
    var doc: BezzleDocument
    var selection: [UUID]
    var fronts: [UUID: Int]

    init(_ doc: BezzleDocument, selection: [UUID], fronts: [UUID: Int]) {
        self.doc = doc
        self.selection = selection
        self.fronts = fronts
    }

    func front(of deck: Node) -> Int? { deck.front(in: fronts) }

    // MARK: Decks

    func turn(_ deckID: UUID, to post: Int) {
        guard let deck = doc.node(deckID), deck.isDeck, deck.posts.contains(post) else { return }
        let was = front(of: deck)
        guard was != post else { return }
        selection = doc.carried(selection, deck: deckID, from: was, to: post).filter { doc.node($0) != nil }
        fronts[deckID] = post
    }

    func addPost(to boardID: UUID) {
        guard let board = doc.node(boardID), board.isArtboard, !board.locked else { return }
        let after = board.isDeck ? front(of: board) : nil
        guard let added = doc.addPost(to: boardID, after: after) else { return }
        if let after { fronts[boardID] = after }
        turn(boardID, to: added)
    }

    func removePost(_ post: Int, from deckID: UUID) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        let posts = deck.posts
        guard posts.count > 1, let i = posts.firstIndex(of: post) else { return }
        let next = i + 1 < posts.count ? posts[i + 1] : posts[i - 1]
        let shown = front(of: deck) == post
        let k = Deck.key(from: post, to: next)
        func inIt(_ id: UUID) -> Bool { doc.post(of: id).map { $0.deck.id == deckID && $0.post == post } ?? false }
        let carried = selection.map { inIt($0) ? $0.mixed(k) : $0 }
        doc.removePost(post, from: deckID)
        if doc.node(deckID)?.isDeck != true { fronts[deckID] = nil } else if shown { fronts[deckID] = next }
        selection = carried.filter { doc.node($0) != nil }
    }

    func movePost(_ post: Int, in deckID: UUID, to index: Int) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked, let posts = deck.posts(moving: post, to: index) else { return }
        doc.update(deckID) { $0.deck?.posts = posts }
    }

    func unstack(_ deckID: UUID) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        doc.unstack(deckID, keeping: front(of: deck))
        fronts[deckID] = nil
    }

    func spreadOut(_ deckID: UUID) {
        guard let deck = doc.node(deckID), deck.isDeck, !deck.locked else { return }
        selection = doc.spreadOut(deckID, keeping: front(of: deck))
        fronts[deckID] = nil
    }

    @discardableResult
    func spread(_ values: [String], from textID: UUID) -> [Int] {
        guard doc.node(textID)?.kind == .text else { return [] }
        return doc.spread([(textID, { n, i in
            guard n.kind == .text else { return }
            n.text = values[i]
            n.refit()
        })], count: values.count)
    }

    @discardableResult
    func spread(_ pictures: [ImageFill], from shapeID: UUID) -> [Int] {
        doc.spread([(shapeID, { n, i in
            n.fill.on = true
            n.fill.image = pictures[i]
        })], count: pictures.count)
    }

    // MARK: Repeat grids

    func fill(_ slot: UUID, in gridID: UUID, with values: [String]) {
        guard doc.node(gridID) != nil, !values.isEmpty else { return }
        doc.fillCells(slot, in: gridID, with: values)
    }

    func fill(_ slot: UUID, in gridID: UUID, withPictures pictures: [ImageFill]) {
        guard doc.node(gridID) != nil, !pictures.isEmpty else { return }
        doc.fillCells(slot, in: gridID, withPictures: pictures)
    }

    @discardableResult
    func fill(_ gridID: UUID, from text: String, startingWith preferred: UUID? = nil) -> Int {
        guard let grid = doc.node(gridID), !doc.assignments(from: text, in: grid, startingWith: preferred).isEmpty else { return 0 }
        return doc.fillCells(gridID, from: text, startingWith: preferred)
    }
}

/// What a screen of a size is played on (the Mac's Player.device, Views/Player.swift).
enum MCPDevice {
    static func device(for size: CGSize) -> (SizeForm, CGSize) {
        let screens: Set<Preset.Group> = [.iPhone, .android, .iPad, .mac, .web, .watch]
        if let p = Preset.all.first(where: { abs($0.size.width - size.width) < 0.5 && abs($0.size.height - size.height) < 0.5 }) {
            return (SizeForm.of(p), size)
        }
        if let p = Preset.all.first(where: { screens.contains($0.group) && abs($0.size.width - size.width) < 0.5 && $0.size.height < size.height }) {
            return (SizeForm.of(p), p.size)
        }
        let w = size.width, h = size.height
        if w <= 460, h >= w * 1.3 { return (.phone(island: true), CGSize(width: w, height: min(h, (w * 2.17).rounded()))) }
        if w <= 1100, h >= w * 0.6 { return (.tablet, CGSize(width: w, height: min(h, (w * 1.4).rounded()))) }
        if w > 1100 { return (.browser, CGSize(width: w, height: min(h, (w * 0.62).rounded()))) }
        return (.post(roundness: 0.012), size)
    }
}
