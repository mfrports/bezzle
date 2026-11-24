import Foundation
import BezzleCore

/// What the parts of a design window share: the tool, what is selected and on which artboard,
/// the zoom. Each part listens and shows it again when it changes (as the Mac's DocumentStore is
/// observed). One for each design open in a tab, each with its own history in its `slot`.
@MainActor
final class DesignSession {
    /// The design in the core: the one it works on while this tab is in front.
    let slot: WindowsCore.Slot
    /// What the design was called as it opened, should it be closed meanwhile.
    private let openedAs: String
    /// The design's name, as its package is called now (renamed, or found renamed).
    var name: String { slot.url?.deletingPathExtension().lastPathComponent ?? openedAs }
    /// Whether its tab is in front. Behind, what changes is drawn once it comes back
    /// (`cameToFront`), and its views ask nothing of the core, which works on another design.
    private(set) var isFront = true
    private var stale = false

    /// The tab went behind another, or home.
    func wentBack() { isFront = false }

    /// The tab is in front again: what changed meanwhile, by an AI assistant or others sharing
    /// the design, is shown.
    func cameToFront() {
        isFront = true
        guard stale else { return }
        stale = false
        for f in editListeners { f(nil) }
        changed()
    }

    var tool: Glyphs.Tool = .select {
        didSet {
            // The pen works on the points being edited; any other drawing tool leaves them.
            if tool != .select && tool != .pen { pen.editingPath = nil }
            // Placing a picture is done with the select tool alone.
            if tool != .select { pictures.editing = nil }
            // With the note tool out, ticked-off threads show as faint flags.
            notes.showDone = tool == .note
            changed()
        }
    }
    /// The pen and a path's points (the shared PenTool): the canvas hands it the pointer, the
    /// Path card shows and sets the points it has picked.
    let pen = WindowsCore.Pen()
    /// The notes in the margin (the Mac's NoteOperations and NotesLayer).
    let notes = WindowsCore.NotesHand()
    /// Building with the pieces the selected shapes cut each other into (the shared
    /// PieceBuilding): the Arrange card's Build button starts it, the canvas works it.
    let builder = WindowsCore.BuildHand()
    /// The photo as the control, while the Photo card is open with its target on (the Mac's
    /// DevelopTool): the card turns it on, the canvas works it.
    let develop = WindowsCore.DevelopHand()
    /// The design inspected (the Mac's InspectTool): read, never changed.
    let inspect = WindowsCore.InspectHand()
    /// The design as a prototype (the Mac's FlowTool): threads pulled from layers to screens.
    let flow = WindowsCore.FlowHand()
    /// A picture being placed inside the layer it fills (the Mac's PictureTool and
    /// store.editingPicture): the canvas works it, the Fill card says how.
    let pictures = WindowsCore.PictureHand()
    /// The design animated (the Mac's store.film and its AnimateOperations): the film on the
    /// desk, its playhead and what of it is picked; the canvas's hand and the timeline's.
    let film = WindowsCore.FilmDesk()
    private(set) lazy var motion = WindowsCore.MotionHand(desk: film)
    private(set) lazy var filmHand = WindowsCore.FilmHand(desk: film)
    /// What follows the film on the desk: its playhead, what of it is picked, the camera.
    private var filmListeners: [() -> Void] = []
    func listenToFilm(_ f: @escaping () -> Void) { filmListeners.append(f) }
    /// What follows the playhead alone, at every step of a hand scrubbing through the film: the
    /// film on the canvas and the timeline's playhead. Told when nothing else of the desk changed.
    private var playheadListeners: [() -> Void] = []
    func listenToPlayhead(_ f: @escaping () -> Void) { playheadListeners.append(f) }
    /// What shows the film at the panels' moment (`FilmDesk.panelTime`), caught up with the
    /// playhead no more than thirty times a second while it is dragged: the panel's cards and the
    /// timeline's row above.
    private var panelTimeListeners: [() -> Void] = []
    func listenToPanelTime(_ f: @escaping () -> Void) { panelTimeListeners.append(f) }

    /// Starts placing the one selected layer's picture inside it (the Mac's editPicture).
    func placePicture() {
        guard WindowsCore.PictureHand.canPlace(selection) else { return }
        tool = .select
        pen.editingPath = nil
        pictures.editing = selection[0]
        showCard?("Fill")
        changed()
    }
    /// Takes the background away from the selected pictures (the Mac's store.removeBackground): the
    /// canvas and the Fill card show the work as it goes, and the cutout comes as a step of its own.
    func removeBackground() {
        WindowsCore.removeBackground(selection)
        changed()
    }

    /// Gives up taking the background away from the selected pictures (the Mac's
    /// store.giveUpRemovingBackground): they stay whole, and the canvas lets its line go.
    func giveUpRemovingBackground() {
        WindowsCore.giveUpRemovingBackground(selection)
        changed()
    }

    /// Shows the selected pictures whole again (the Mac's store.restoreBackground).
    func restoreBackground() {
        WindowsCore.restoreBackground(selection)
        edited(board: nil)
    }

    /// Makes the selected layers' pictures shapes (the Mac's store.vectorize): the canvas shows the
    /// pencil passing over each, and the group of shapes comes as a step of its own.
    func vectorize() {
        guard WindowsCore.canVectorize(selection) else { return }
        if pictures.editing != nil { pictures.editing = nil }
        WindowsCore.vectorize(selection)
        changed()
    }

    /// Puts the picture back in the place of the selected group made of it.
    func backToPicture() {
        guard selection.count == 1, WindowsCore.isVector(selection[0]) else { return }
        WindowsCore.backToPicture(selection[0])
        edited(board: nil)
    }

    /// Design, Prototype, Inspect or Animate (0, 1, 2, 3), as the bar's switch says.
    var mode = 0 {
        didSet {
            guard mode != oldValue else { return }
            // Only while designing is an artboard looked at from the side: seen as a prototype,
            // inspected or animated, all is from the front again, as on the Mac. Before the film
            // lays its artboard out, which it does from the design as it is looked at.
            if mode != 0, WindowsCore.using(slot, { WindowsCore.lookFromTheFront() }) { previewed(board: nil) }
            inspect.on = mode == 2
            flow.on = mode == 1
            if mode != 0 { develop.on = false }
            // Points in hand are the design's or the film's: going into Animate or out of it,
            // they are put down and taken in hand there anew, as on the Mac.
            if mode == 3 || oldValue == 3 { pen.editingPath = nil }
            film.modeChanged(mode == 3)
            motion.modeChanged()
            changed()
        }
    }
    /// Says something went wrong, with OK to put it away (the window's questions).
    var tell: ((String, String) -> Void)?
    /// Plays the prototype from a screen, or from where it starts (the window's player).
    var play: ((UUID?) -> Void)?
    /// A layer brought into sight on the canvas, when it is out of it.
    var reveal: ((UUID) -> Void)?
    /// The Export sheet, opened.
    var openExport: (() -> Void)?
    /// The style pointed at in the inspector: the canvas outlines every layer that uses it.
    var pointedStyle: UUID? { didSet { if pointedStyle != oldValue { for f in styleListeners { f() } } } }
    /// Layers outlined for a moment besides, such as those a look found is on, while it is pointed at.
    var litLayers: [UUID] = [] { didSet { if litLayers != oldValue { for f in styleListeners { f() } } } }
    private var styleListeners: [() -> Void] = []
    func listenToStyles(_ f: @escaping () -> Void) { styleListeners.append(f) }
    /// The Photo card's colour whose rows show, as a press on the photo picks it.
    var pickPhotoBand: ((String) -> Void)?
    /// What the fill menu is open on, while it is: one of the layers' fills or borders (the Mac's
    /// GradientSession.target), whose gradient the canvas shows its handles for.
    struct FillMenuTarget: Equatable {
        var border: Bool
        var slot: Int
        var ids: [UUID]
        var board: Int
    }
    var fillMenu: FillMenuTarget? { didSet { if fillMenu != oldValue { for f in gradientListeners { f() } } } }
    /// Which of the gradient's colours is chosen, in the fill menu's bar and on the canvas alike.
    var gradientStop = 0 { didSet { if gradientStop != oldValue { for f in gradientListeners { f() } } } }
    private var gradientListeners: [() -> Void] = []
    func listenToGradient(_ f: @escaping () -> Void) { gradientListeners.append(f) }
    /// A mask's outline drawn once on the canvas, running out (true) as it is let go, or in.
    var ringMask: ((UUID, Bool) -> Void)?
    /// The fill menu made again as the gradient changed on the canvas: with its colour panel
    /// (another colour chosen), or its bar alone.
    var refreshFillMenu: ((_ panelToo: Bool) -> Void)?
    /// The selected layers, all on the artboard at `board` (its index among the design's layers);
    /// with none selected, `board` is the artboard whose page the layers list shows, if any.
    private(set) var selection: [UUID] = []
    private(set) var board: Int?
    /// The canvas and zoom label follow the view without refreshing the design's panels.
    var zoom = 0.5 {
        didSet {
            guard zoom != oldValue else { return }
            guard isFront else { stale = true; return }
            for f in zoomListeners { f() }
        }
    }
    private var zoomListeners: [() -> Void] = []
    func listenToZoom(_ f: @escaping () -> Void) { zoomListeners.append(f) }
    /// The inspector's open card, which the canvas lights what belongs to it for (a layout grid).
    var openCard: String? { didSet { if openCard != oldValue { openCardChanged?() } } }
    /// Where the open card holds a style ("fill:0", "text"), which a style taken goes to, as on
    /// the Mac it goes to the open aspect's place; the inspector says.
    var openStylePlace: (() -> String?)?
    var openCardChanged: (() -> Void)?
    /// Opens a card in the inspector, by its name, as the Mac's store.openAspect is set.
    var showCard: ((String) -> Void)?
    var showsLayers = true { didSet { changed() } }
    /// The resources panel out, in the layers list's place.
    var showsResources = false { didSet { changed() } }

    /// Brings the resources panel out in the layers list's place, or puts it away and the layers
    /// list back if it was out before (the Mac's toggleResources).
    func toggleResources() { showsResources.toggle() }

    /// The layer under the pointer, on the canvas or in the layers list: the canvas outlines it
    /// and the list lights its row, as the Mac's store.hovered. It has listeners of its own, as
    /// it changes with every move of the pointer.
    var hovered: UUID? { didSet { if hovered != oldValue { for f in hoverListeners { f() } } } }
    private var hoverListeners: [() -> Void] = []
    func listenToHover(_ f: @escaping () -> Void) { hoverListeners.append(f) }

    private var listeners: [() -> Void] = []
    /// What wants to know that the design itself changed (an edit, an undo).
    private var editListeners: [(_ board: Int?) -> Void] = []

    /// For the design the core has just opened in `slot`, the one it works on now.
    init(slot: WindowsCore.Slot) {
        self.slot = slot
        openedAs = slot.url?.deletingPathExtension().lastPathComponent ?? ""
        notes.opened(WindowsCore.designPath ?? openedAs)
        // A shared design: what the others did comes in as their files come into its folder.
        // The Mac is told by the folder; here it is looked at every few seconds, in front or not,
        // as the Mac's FolderSync looks after every open design.
        shareTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lookAtShare() }
        }
        if WindowsCore.designHasPreview { previewed = WindowsCore.designChanges }
        film.select = { [weak self] ids in
            guard let self else { return }
            let board = ids.first.flatMap { WindowsCore.board(of: $0) ?? WindowsCore.boardIndex(of: $0) } ?? self.board
            self.select(ids, on: board)
        }
        film.changed = { [weak self] in self?.filmChanged() }
        film.edited = { [weak self] in self?.filmEdited() }
        film.moved = { [weak self] in
            guard let self else { return }
            guard self.isFront else { self.stale = true; return }
            for f in self.playheadListeners { f() }
        }
        film.panelMoved = { [weak self] in
            guard let self else { return }
            guard self.isFront else { self.stale = true; return }
            for f in self.panelTimeListeners { f() }
        }
        // The design changed under the film, by an undo or by others: its desk follows, and a
        // shape's points in hand are put down once it is gone.
        listenToEdits { [weak self] _ in
            self?.film.designChanged()
            self?.motion.designChanged()
        }
    }

    /// The desk changed: what follows the film shows it again.
    private func filmChanged() {
        guard isFront else { stale = true; return }
        for f in filmListeners { f() }
    }

    /// The film changed in the design: its keys or its settings. What follows the film shows it
    /// again and the design is saved a moment later; the artboards' own sheets are not drawn again,
    /// as a key changes nothing of how a layer looks where the design has it.
    private func filmEdited() {
        if isFront { for f in filmListeners { f() } } else { stale = true }
        scheduleSave()
    }

    deinit {
        shareTimer?.invalidate()
        previewTimer?.invalidate()
    }

    nonisolated(unsafe) private var shareTimer: Timer?

    /// The tab is closed: nothing is looked at or saved for it any more.
    func closed() {
        shareTimer?.invalidate()
        shareTimer = nil
        saveTimer?.invalidate()
        saveTimer = nil
        previewTimer?.invalidate()
        previewTimer = nil
    }

    // MARK: The Finder's picture

    /// Which change of the design the picture a Mac's Finder shows for its file was last made
    /// from; nil while it has none (the Mac's DocumentStore.previewed). See the core's DesignPreview.
    private var previewed: Int?
    nonisolated(unsafe) private var previewTimer: Timer?

    /// The design was saved: if it changed, its picture is made again a little later, once for
    /// however many changes come meanwhile, as the Mac's schedulePreview does.
    private func schedulePreview() {
        guard previewed != WindowsCore.designChanges, previewTimer == nil else { return }
        previewTimer = Timer.scheduledTimer(withTimeInterval: WindowsCore.previewEvery, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.previewTimer = nil
                // Wait until the edit is settled before asking for a preview of the package.
                let dragging = self.slot.isOpen && WindowsCore.using(self.slot) { WindowsCore.inGesture }
                if dragging {
                    self.previewTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                        MainActor.assumeIsolated { self?.previewTimer = nil; self?.makePreview() }
                    }
                } else {
                    self.makePreview()
                }
            }
        }
    }

    /// Makes the design's picture as it is now, if it changed since the last was made: after a
    /// pause in the work, as the tab closes, and as Bezzle quits (the Mac's makePreview).
    func makePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        guard slot.isOpen else { return }
        WindowsCore.using(slot) {
            let change = WindowsCore.designChanges
            guard previewed != change else { return }
            if let revision = WindowsCore.savedPreview {
                guard !savePending, unsaved == nil else { return }
                SavedPreviews.shared.enqueue(revision) { [weak self] kept in
                    guard let self, self.slot.isOpen else { return }
                    WindowsCore.using(self.slot) {
                        guard WindowsCore.designChanges == change else { return }
                        if kept || WindowsCore.savedPreview == revision {
                            // A failed render keeps the old thumbnail. Try again after another edit.
                            self.previewed = change
                        } else {
                            self.schedulePreview()
                        }
                    }
                }
                return
            }
            previewed = change
            WindowsCore.writePreview()
        }
    }

    /// Shows what others sharing the design changed since the last look, if anything: what they
    /// took away is no longer selected, and the design is saved with their changes in it, as the
    /// Mac's showChangesFromOthers saves; but in a synced folder by whoever changed it, as the
    /// design is one item to the folder's service, and one written by two computers at once is
    /// kept as two ("Poster 2").
    func lookAtShare() {
        guard slot.isOpen else { return }
        WindowsCore.using(slot) {
            guard WindowsCore.lookAtShare() else { return }
            let kept = selection.filter { WindowsCore.has(layer: $0) }
            if kept != selection { select(kept, on: board) }
            edited(board: nil, saving: !WindowsCore.inSyncedFolder)
        }
    }

    func select(_ ids: [UUID], on board: Int?) {
        // A layer of a deck's post behind brings that post to the front, as on the Mac.
        let fronts = WindowsCore.fronts
        let ids = WindowsCore.selecting(ids)
        selection = ids
        if WindowsCore.fronts != fronts { previewed(board: nil) }
        pen.selection = ids
        if let editing = pen.editingPath, ids != [editing] { pen.editingPath = nil }
        if let placing = pictures.editing, ids != [placing] { pictures.editing = nil }
        self.board = board
        film.selectionChanged(ids)
        motion.selectionChanged(ids)
        changed()
    }

    func listen(_ f: @escaping () -> Void) { listeners.append(f) }
    func listenToEdits(_ f: @escaping (_ board: Int?) -> Void) { editListeners.append(f) }

    func changed() {
        guard isFront else { stale = true; return }
        for f in listeners { f() }
    }

    /// The design changed on `board` (or anywhere, nil): what shows it draws it again, and it is
    /// saved a moment later, as the Mac saves (DocumentStore.scheduleSave: 600 ms after a change).
    func edited(board: Int?, saving: Bool = true) {
        if isFront {
            for f in editListeners { f(board) }
            changed()
        } else {
            stale = true
        }
        if saving { scheduleSave() }
    }

    /// A change is shown on `board` that is not made (a font pointed at in a menu): what shows
    /// the design draws it again, and nothing is saved.
    func previewed(board: Int?) {
        guard isFront else { stale = true; return }
        for f in editListeners { f(board) }
    }

    /// Asks for a design to open (Ctrl+O).
    var onOpen: (() -> Void)?
    /// A copy of the design saved beside the others and opened (Ctrl+Shift+S, the Mac's Save a Copy).
    var onSaveCopy: (() -> Void)?
    /// Asks for a file from Adobe XD, Figma, Sketch or Photoshop to bring in (the Bezzle menu).
    var onBringIn: (() -> Void)?

    /// Why the design could not be saved, if it could not; shown by the window.
    private(set) var unsaved: String?
    var onUnsaved: ((String?) -> Void)?
    private var saveTimer: Timer?

    func scheduleSave() {
        saveTimer?.invalidate()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.save() }
        }
    }

    /// Whether a change waits to be saved.
    var savePending: Bool { saveTimer != nil }

    /// Saves the design, in front or not: the core works on it for that long. `closing`, it is the
    /// last save (`WindowsCore.save(closing:)`).
    func save(closing: Bool = false) {
        saveTimer?.invalidate()
        saveTimer = nil
        guard slot.isOpen else { return }
        WindowsCore.using(slot) {
            do {
                // In a synced folder, nothing is written for what others did alone.
                guard try WindowsCore.save(closing: closing) else { return }
                if unsaved != nil { unsaved = nil; onUnsaved?(nil) }
                // A version is taken by itself as the design is worked on.
                WindowsCore.versions.saved()
                schedulePreview()
            } catch is WindowsCore.Away {
                // Its sync service has it away for a moment: looked for again shortly.
                guard !closing else { return }
                saveTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.save() }
                }
            } catch {
                let why = "\(error)"
                if unsaved != why { unsaved = why; onUnsaved?(why) }
            }
        }
    }

    /// The selected layers as the core describes them.
    var selectedLayers: [WindowsCore.Layer] {
        guard let board else { return [] }
        let layers = WindowsCore.layers(board: board)
        // The artboard itself, selected by its name, is not among what lies on it.
        let artboard = WindowsCore.boardLayer(board)
        return selection.compactMap { id in layers.first { $0.id == id } ?? (artboard?.id == id ? artboard : nil) }
    }
}
