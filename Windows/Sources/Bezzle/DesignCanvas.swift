import Foundation
import WinSDK
import WinUI
import WinAppSDK
import WindowsFoundation
import UWP
import BezzleCore

/// The canvas, as the Mac's (Canvas/CanvasView.swift; numbers in DESIGN.md): the artboards on the
/// table, each casting its shadow and with its name above it, drawn by the core into bitmaps.
/// A click picks the layer under it, a drag moves what is picked as one gesture, the handles
/// resize it (Shift keeps a corner's proportions); Delete deletes, the arrows nudge (Shift by 10),
/// Ctrl+Z and Ctrl+Y (or Ctrl+Shift+Z) undo and redo; the tools' letters choose them. The wheel
/// pans; Ctrl and the wheel zoom round the pointer, Ctrl with +, − and 0 step and fit.
@MainActor
final class DesignCanvas {
    let root = Grid()
    private let stage = Canvas()
    /// Over the artboards, always: the hover, the selection and its handles; then the rulers.
    private let overlay = Canvas()
    private let rulers = Rulers()
    /// Where a text is typed into, over the canvas: the text field the Mac's editor is here.
    private let editorLayer = Canvas()
    private var editor: TextBox?
    private var editing: (id: UUID, board: Int)?
    /// Over the text typed into: the caret, the letters picked out, the misspelt words.
    private let typingMarks = Canvas()
    private var caretPath: WinUI.Path?
    private var caretOn = true
    private var blink: Timer?
    /// Where the letters picked out were picked from, and where the caret is (the other end):
    /// Shift and the keys that go by lines move this end.
    private var typingAnchor = 0, typingActive = 0
    /// How far along the lines Up and Down keep to, as they go.
    private var typingGoal: Double?
    /// A press on the words typed into, picking letters out as it is dragged: by letters, by
    /// words after two clicks, by paragraphs after three, from what the press picked.
    private var typingPress: (clicks: Int, from: NSRange)?
    /// Words or a selection given to the field from the text, not typed.
    private var settingField = false
    private var cardsPending = false
    /// Opens the find bar to check the design's spelling (the window's).
    var checkSpelling: (() -> Void)?
    private let session: DesignSession

    /// Where the design's origin is on the stage, in its pixels (DIPs).
    private var pan = CGPoint(x: 64, y: 64)
    private var pixelScale = 1.0
    private var zoom: Double { flyingZoom ?? session.zoom }
    /// The zoom while the view flies to someone in the live room, until it rests (LiveCanvas.swift).
    private var flyingZoom: Double?
    /// The others in the design's live room, drawn on the canvas.
    let liveCanvas = LiveCanvas()

    private var boards: [WindowsCore.Board] = []
    private static let rasterMargin = 192.0
    private struct CanvasSurface {
        let view = Image()
        private(set) var bitmap: WriteableBitmap?
        private(set) var area: CanvasRasterArea?
        private var needsDraw = false

        mutating func update(_ next: CanvasRasterArea?, refreshing: Bool,
                             draw: (CanvasRasterArea, (Int, Int) -> UnsafeMutableRawPointer?) -> Bool) -> Bool {
            guard let next else { clear(); return false }
            guard refreshing || needsDraw || area != next || bitmap == nil else { return false }
            var target = bitmap
            let drawn = draw(next) { width, height in
                if target == nil || target!.pixelWidth != Int32(width) || target!.pixelHeight != Int32(height) {
                    target = WriteableBitmap(Int32(width), Int32(height))
                }
                return (try? target?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
            }
            guard drawn, let target else { needsDraw = true; return false }
            try? target.invalidate()
            if bitmap !== target { view.source = target }
            bitmap = target
            area = next
            needsDraw = false
            return true
        }

        mutating func clear() {
            guard bitmap != nil else { return }
            view.source = nil
            bitmap = nil
            area = nil
            needsDraw = false
            view.visibility = .collapsed
        }
    }

    private struct Sheet {
        var image = CanvasSurface()
        var shadow = CanvasSurface()
        let name = TextBlock()
        var title: String?
        var id: UUID?
        var shadowColour: UInt32?
        var shadowScale: Double?
    }
    private var sheets: [Int: Sheet] = [:]
    /// Layers lying on the canvas outside artboards, each drawn on its own, by their place in the design.
    private var loose: [WindowsCore.Loose] = []
    private var looseSheets: [Int: CanvasSurface] = [:]

    /// The hovered layer's outline, 1.5 wide; each selected layer's, 1 wide, along its turn (a
    /// line's two ends), in the colour of component copies for one; the box round several, dashed.
    private let hover = WinUI.Path()
    private var outlines: [WinUI.Path] = []
    private let bounds = WinUI.Path()
    /// The handles, white with a soft shadow under them, as the Mac draws them: square, or round
    /// at a line's ends and under text as wide as its words.
    /// The dots inside a selected rectangle's corners, shown while the pointer is on it.
    private let cornerDots = (0..<4).map { _ in Ellipse() }
    private var dotsShown = false
    /// The selected layer's shadow, dashed, while the pointer is on it.
    private let shadowLine = WinUI.Path()
    private var shadowShown = false
    /// What a drag measures, in a pill under it, as the Mac's canvas shows it.
    private let measurePill = Border()
    private let measureText = TextBlock()
    private let handles = (0..<8).map { _ in Rectangle() }
    private let handleShades = (0..<8).map { _ in Rectangle() }
    /// The handles shown, on the stage: each by its place in `WindowsCore.handleOrder` (a line's
    /// ends by 0 and 1).
    private var shownHandles: [(index: Int, point: CGPoint)] = []
    private var lineEnds = false
    /// While something is dragged: the lines it catches on and the gaps as wide as others (in
    /// pencil, as the Mac draws them), and the box dragged out to pick with.
    private let guideLines = WinUI.Path()
    private let gapFields = WinUI.Path()
    private let marqueeBox = Rectangle()
    private var guides: [WindowsCore.GuideLine] = []
    /// Where the right-click menu opens.
    var menus: MenuHost? {
        didSet {
            margin.menus = menus
            // A gradient's handles take their presses over what closes the fill menu.
            menus?.addOverCatcher(gradients.layer)
        }
    }
    /// A gradient's handles where the layer is, while its fill menu is open.
    private(set) lazy var gradients: GradientHandles = {
        let g = GradientHandles(session: session)
        g.menuOpen = { [weak self] in self?.menus?.isOpen == true }
        g.toStage = { [weak self] p in self?.onStage(p) ?? p }
        g.toCanvas = { [weak self] p in self?.inDesign(p) ?? p }
        g.canvasPlace = { [weak self] in
            guard let self, let host = self.menus?.layer, let t = try? self.stage.transformToVisual(host),
                  let o = try? t.transformPoint(Point(x: 0, y: 0)) else { return nil }
            return CGRect(x: Double(o.x), y: Double(o.y), width: self.stage.actualWidth, height: self.stage.actualHeight)
        }
        return g
    }()
    /// The notes in the margin, beside the sheets.
    private(set) lazy var margin = MarginView(notes: session.notes)
    /// Decks as stacks of cards: their feet, the row under a selected one, turning, the spread.
    private(set) lazy var decks = DeckView(session: session)
    private var overlaysAdded = false
    private static let handleSize = 8.0

    /// What a press has taken hold of: the selection to move (copies of it with Alt), a handle,
    /// a line's end, a box to drag out from a point on the canvas (with what was selected before,
    /// with Shift, and the artboard it began on), or a layer being drawn.
    private enum Grab {
        case move(duplicate: Bool)
        case handle(Int)
        case lineEnd(Int)
        case marquee(start: CGPoint, base: [UUID], inside: Int?)
        case draw(id: UUID, kind: String, start: CGPoint, board: Int?)
        /// Just outside a corner: turning in the page. A corner's dot: rounding the corners. The
        /// layer's shadow: moving it, once the pointer goes 3 points (a click picks what is there).
        /// A turned layer's knob, or just outside the middle of a side: turning it in depth.
        /// A selected repeat grid's handle, gap or corner: repeating, spacing or turning it. A
        /// layout grid's gutter, margin or baseline, while its card is open.
        case turn, corner, shadow, depth, grid, layout
        /// Alt on nothing, beside the layers: the artboard there looked at from the side.
        case look
        /// The canvas itself, moved round with Space held or the wheel pressed, from where it was.
        case pan(start: CGPoint)
        /// Pieces of the shapes being built with, joined or wiped away.
        case build
        /// A selected path's corner dot (rounding its corners), or a shape's edge with Alt (an
        /// outline pulled out or in).
        case outline
        /// A selected text's bead, swung round the middle of its words to bend them.
        case curve
        /// A selected photo, the control while the Photo card's target is on.
        case develop
        /// Inspecting: a click picks what is under the pointer, a drag moves the view.
        case inspect(start: CGPoint, target: UUID?)
        /// The design as a prototype: a thread pulled, the flag carried, a screen moved, the view moved.
        case flow
        /// The note tool: a click starts a note about what is there, a drag draws a loop round a part.
        case note(start: CGPoint)
        /// Decks: scrubbing along the row under a stack, or a post taken up in the spread.
        case deck
        /// A picture being placed inside its layer: moved, or sized by a corner.
        case picture
        /// Animated: a layer or the camera posed, a bead of a layer's way moved, a loop pulled.
        case motion
    }
    private var drag: (from: CGPoint, board: Int, moved: Bool, grab: Grab)?
    /// Whether Alt, which at the press makes copies, has been let go since: pressed again during
    /// the move, it pushes what is dragged in depth (the Mac's Control).
    private var altLetGo = false
    /// The text a press with the Text tool began on: a click types into it, a drag draws a new
    /// one over it, as on the Mac.
    private var textUnderPress: UUID?
    /// The text selected when a new one was begun, whose look it takes.
    private var drawLike: UUID?
    /// A picture being placed inside its layer (the Mac's PictureTool, ported): the whole of it
    /// past the layer's outline, faded, in a picture of its own (one more for one fading out),
    /// and its edges, the outline and the crop marks over it.
    var pictures: WindowsCore.PictureHand { session.pictures }
    private let pictureMarks = Canvas()
    private var pictureGhosts: [(image: Image, bitmap: WriteableBitmap?, key: String?)] = []
    private var pictureTicking: EventCleanup?
    private var drawingPictures = false
    /// Pictures being cut out, as the pencil goes over them, and the subjects of a cut-out picture
    /// being placed (the Mac's CutoutTool, ported): one picture over the stage, under the marks.
    let cutouts = WindowsCore.CutoutHand()
    private let cutoutImage = Image()
    private var cutoutBitmap: WriteableBitmap?
    private var cutoutTicking: EventCleanup?
    private var drawingCutouts = false
    /// Pictures being vectorized, and the pencil passing over one just made shapes (the Mac's
    /// VectorTool, ported): one picture over the stage, under the marks, as the cutouts' is.
    let vectors = WindowsCore.VectorHand()
    private let vectorImage = Image()
    private var vectorBitmap: WriteableBitmap?
    private var vectorTicking: EventCleanup?
    private var drawingVectors = false
    /// Pictures on their way in sight, by the artboard they are on, as the live room last showed
    /// them, and the grain's frame they were drawn at (`drawDeveloping`).
    private var developingShown: [Int: [WindowsCore.LiveDeveloping]] = [:]
    private var developingFrame = -1
    /// Whether placing took the last press: the double click WinUI tells of after it is then placing's.
    private var pictureTookPress = false
    /// The pen and a path's points (the shared PenTool), and what it shows over the design.
    var pen: WindowsCore.Pen { session.pen }
    /// Building with pieces (the shared PieceBuilding), started from the Arrange card.
    var builder: WindowsCore.BuildHand { session.builder }
    private let buildMarks = Canvas()
    /// A selected shape's outline (the shared OutlineDragging): a path's corner dots, the edge with Alt.
    let outlineHand = WindowsCore.OutlineHand()
    private let outlineMarks = Canvas()
    /// The word "Mask" offered after a change, above what it is about (the Mac's MaskTool offer):
    /// pointed at, the mask shows made; pressed, it is made.
    private let offerChip = Border()
    private let styleMarks = Canvas()
    private let waveMarks = Canvas()
    private var waveTick: EventCleanup?
    private var waveToken = 0
    /// The artboards as they were, shown ahead of a style's wave.
    private var washImages: [Image] = []

    private func removeFromStage(_ e: UIElement) {
        var k: UInt32 = 0
        if (try? stage.children.indexOf(e, &k)) == true { stage.children.removeAt(k) }
    }
    private var shownOffer: WindowsCore.MaskOffer?
    private var offerLit = false
    /// How far the word offered has sprung in (0 to 1), and the offer it shows, kept while it
    /// shrinks away after there is none.
    private var offerShown = DeckSpring(0)
    private var offerKept: WindowsCore.MaskOffer?
    private lazy var offerTicker = Motion.Ticker { [weak self] dt in self?.stepOffer(dt) ?? false }
    /// What is offered for a moment after a change to a copy (the Mac's ComponentTool offer): a
    /// capsule beside the copy, its words and buttons, the first the one to take.
    private let copyChip = Border()
    /// The other copies of the copy picked, faintly, and its component's name over it.
    private let componentMarks = Canvas()
    /// The light running between copies as one is changed, the outline drawn round one just made,
    /// and the row of variants beside a copy picked (the Mac's ComponentTool).
    private let copyMarks = CopyMarks()
    /// Whether the last press dragged: a quick press after it is a press of its own.
    private var lastPressDragged = false
    /// Whether the last press went into the group it was on, which WinUI's double tap after it
    /// then leaves alone.
    private var pressEntered = false
    private var copyOffer: WindowsCore.CopyOffer?
    private var copyButtons: [(rect: CGRect, index: Int)] = []
    /// The offer's button under the pointer: a style's lights the layers it is about.
    private var copyHovered: Int?
    private var copyLit = false
    /// Something being moved, held still over a shape (the Mac's MaskTool dip): the shape under
    /// the pointer and where it came to rest, whether resting would open it, the shape opened and
    /// the mask it made, and the shapes opened and left again in this drag.
    private struct Dip {
        var over: UUID?
        var at: CGPoint = .zero
        /// When the rest began, for the line run round the shape as it passes.
        var since = 0.0
        var ready = false
        var opened: (shape: UUID, mask: UUID)?
        var declined: Set<UUID> = []
        /// Counts each rest, so a wait for an earlier one comes to nothing.
        var rest = 0
        /// The mask what is moved would come out of, lying wholly off its shape.
        var leaving: UUID?
    }
    private var dip: Dip?
    /// What masks show as things go into them and come out (the Mac's MaskTool): the line run
    /// round a shape rested on, the glow, the ghosts of what is cut off, the rings, the names.
    private let maskMarks = MaskMarks()
    /// How long something has to rest over a shape for it to open, and how far the pointer may
    /// wander on screen and still be resting, as on the Mac.
    private static let dipRest = 0.9
    private static let dipWander = 3.0
    let knife = WindowsCore.KnifeHand()
    /// Turning in depth (the shared DepthTurning): the knob of a turned layer, and turning from
    /// just outside the middle of a side.
    let depth = WindowsCore.Depth()
    /// Looking at an artboard from the side (the shared DepthLook): Alt dragged beside the layers,
    /// the posts under what stands off the page, and the word that looks from the front again.
    let looking = WindowsCore.LookHand()
    private let lookMarks = Canvas()
    /// Where each word that looks from the front again stands on the stage, and the artboard the
    /// pointer's is by.
    private var lookWords: [(board: UUID, rect: CGRect)] = []
    private var lookHovered: UUID?
    /// Guides (the shared GuideDragging): pulled out of the rulers, moved by their lines and tabs.
    let guideHand = WindowsCore.Guides()
    /// A selected repeat grid (the shared GridHandles): its handles repeat it, its gaps space it.
    let gridHand = WindowsCore.GridHand()
    /// A layout grid's gutters, margins and baselines (the shared LayoutHandles), while its card is open.
    let layoutHand = WindowsCore.LayoutHand()
    private let gridMarks = Canvas()
    /// Words along curves (the Mac's CurveTool, ported): a selected text's beads bend it, and a
    /// text held on a shape's edge catches on it and slides along it.
    let curveHand = WindowsCore.CurveHand()
    private let curveMarks = Canvas()
    /// Letters springing to new places as a text goes onto a curve, along it or off it (the Mac's
    /// CurveTool flights), over the artboards, which leave those texts to them meanwhile.
    private let letters = FlyingLetters()
    /// The photo as the control (the Mac's DevelopTool, ported), with what it shows.
    var develop: WindowsCore.DevelopHand { session.develop }
    private let developMarks = Canvas()
    /// The millimetre paper under the screens while prototyping or inspecting.
    private let paper = Canvas()
    /// The design inspected (the Mac's InspectTool, ported): its measures.
    var inspect: WindowsCore.InspectHand { session.inspect }
    private let inspectMarks = Canvas()
    /// What the inspect marks show, and how far they have grown in since it changed.
    private var inspectShown = ""
    private var inspectGrow = DeckSpring(1)
    private lazy var inspectTicker = Motion.Ticker { [weak self] dt in
        guard let self else { return false }
        self.inspectGrow.step(dt, stiffness: 420, damping: 24)
        self.drawInspect()
        return !self.inspectGrow.settled
    }
    private var inspecting: Bool { session.mode == 2 }
    /// The design as a prototype (the Mac's FlowTool, ported): its threads and flags.
    var flow: WindowsCore.FlowHand { session.flow }
    private var prototyping: Bool { session.mode == 1 }
    /// The design animated: its film shows, and what is picked is posed in it.
    private var animating: Bool { session.mode == 3 }
    /// The film on the canvas, and what is posed over it (the Mac's FilmStageView and MotionTool).
    private(set) lazy var film = FilmView(session: session)
    var motion: WindowsCore.MotionHand { session.motion }
    /// Space pressed, and whether the view moved before it was let go: a tap plays the film.
    private var spaceTap: (at: Double, moved: Bool)?
    /// The artboard whose sheet the film covers.
    private var filmCovers: UUID?
    private let flowMarks = Canvas()
    /// What looking back through the versions marks on the canvas: what differs from now.
    private let timeMarks = Canvas()
    /// A part or icon carried over the canvas from the resources panel: the real thing, where it
    /// will land, and what letting go does.
    private let resourceGhost = Canvas()
    private var ghost: (key: String, image: Image)?
    private var ghostShown: (x: DeckSpring, y: DeckSpring, w: DeckSpring, h: DeckSpring)?
    private var ghostPlan: WindowsCore.PlanLook?
    private var ghostTicking: EventCleanup?
    private var timeTicking: EventCleanup?
    /// The layer that differs under the pointer, while looking back.
    private var timeHovered: UUID?
    private var flowTicking = false
    private let noteBox = TextBox()
    /// The layer whose thread's note is being written.
    private var noteFor: UUID?
    private var curveTicking = false
    /// The drawing aids' menu, for a click on the rulers' corner.
    var aidsMenu: (() -> [MenuHost.Entry])?
    private let depthMarks = Canvas()
    private let penMarks = Canvas()
    /// Where carousels will be cut into slides, and each slide's number over it.
    private let slideMarks = Canvas()
    /// The artboards' layout grids and guides.
    private let aidMarks = Canvas()
    /// What the find bar finds.
    private let foundMarks = Canvas()
    /// The layer moved, resized or typed into, where it is in a deck's other posts.
    private let echoes = WinUI.Path()
    /// The last press, for telling a double click from two: when, and where on the stage.
    private var lastPress: (at: CGPoint, time: UInt32, clicks: Int)?
    private var hovered: UUID? { session.hovered }
    /// Where the pointer last was on the stage, and the pointer shown there.
    private var lastPoint: CGPoint?
    private var shownPointer: Pointer?
    /// Space held: a press moves the canvas round, as on the Mac.
    private var spaceDown = false

    init(session: DesignSession) {
        self.session = session
        root.background = Theme.brush(Theme.table)
        root.children.append(stage)
        stage.children.append(decks.feet)
        root.children.append(letters.layer)
        root.children.append(overlay)
        // First on the overlay: right over the artboards, under every other mark.
        overlay.children.append(maskMarks.layer)
        root.children.append(decks.layer)
        root.children.append(margin.layer)
        root.children.append(rulers.root)
        root.children.append(editorLayer)
        overlay.isHitTestVisible = false
        margin.view = { [weak self] in (self?.zoom ?? 1, self?.pan ?? .zero) }
        margin.layerAt = { [weak self] p in self.flatMap { WindowsCore.pick(p, selection: [], zoom: $0.zoom) } }
        margin.edited = { [weak self] in self?.session.edited(board: nil) }
        margin.reveal = { [weak self] p in self?.reveal(CGRect(x: p.x - 40, y: p.y - 40, width: 80, height: 80)) }
        margin.returnFocus = { [weak self] in self?.takeKeys() }
        decks.toView = { [weak self] r in self?.onStage(rect: r) ?? r }
        decks.stageSize = { [weak self] in (self?.stage.actualWidth ?? 0, self?.stage.actualHeight ?? 0) }
        decks.pixelScale = { [weak self] in self?.pixelScale ?? 1 }
        decks.zoom = { [weak self] in self?.zoom ?? 1 }
        decks.hideSheet = { [weak self] id, hide in self?.hideSheet(id, hide) }
        decks.rowAllowed = { [weak self] in
            guard let self else { return false }
            return self.session.tool == .select && self.editing == nil && self.pen.editingPath == nil && self.session.mode == 0
                && !WindowsCore.versions.lookingBack
        }
        decks.turned = { [weak self] in self?.session.previewed(board: nil) }
        root.sizeChanged.addHandler { [weak self] _, _ in self?.place() }
        stage.background = Theme.clear
        root.isTabStop = true

        hover.strokeThickness = 1.5
        bounds.stroke = Theme.brush(Theme.selection)
        bounds.strokeThickness = 1
        let dashes = DoubleCollection()
        dashes.append(3)
        dashes.append(3)
        bounds.strokeDashArray = dashes
        for shape in [hover, bounds] { shape.visibility = .collapsed; shape.isHitTestVisible = false }
        guideLines.stroke = Theme.brush(Theme.selection)
        guideLines.strokeThickness = 1
        gapFields.fill = Theme.brush(Theme.selection, 0.07)
        gapFields.stroke = Theme.brush(Theme.selection, 0.55)
        gapFields.strokeThickness = 1
        marqueeBox.fill = Theme.brush(Theme.selection, 0.08)
        marqueeBox.stroke = Theme.brush(Theme.selection, 0.8)
        marqueeBox.strokeThickness = 1
        for shape in [guideLines, gapFields, marqueeBox] as [Shape] { shape.visibility = .collapsed; shape.isHitTestVisible = false }
        for h in handles {
            h.width = Self.handleSize
            h.height = Self.handleSize
            h.fill = Theme.brush(0xFFFFFF)
            h.stroke = Theme.brush(Theme.selection)
            h.strokeThickness = 1
            h.visibility = .collapsed
            h.isHitTestVisible = false
        }
        for dot in cornerDots {
            dot.width = 7
            dot.height = 7
            dot.fill = Theme.brush(0xFFFFFF)
            dot.stroke = Theme.brush(Theme.selection)
            dot.strokeThickness = 1
            dot.visibility = .collapsed
            dot.isHitTestVisible = false
        }
        shadowLine.stroke = Theme.brush(Theme.selection, 0.7)
        shadowLine.strokeThickness = 1
        let shadowDashes = DoubleCollection()
        shadowDashes.append(3)
        shadowDashes.append(3)
        shadowLine.strokeDashArray = shadowDashes
        shadowLine.visibility = .collapsed
        shadowLine.isHitTestVisible = false
        measurePill.background = Theme.brush(Theme.selection)
        measurePill.cornerRadius = Theme.corners(6)
        measurePill.height = 20
        measurePill.isHitTestVisible = false
        measurePill.visibility = .collapsed
        measureText.fontFamily = Theme.ui
        measureText.fontSize = 11
        measureText.fontWeight = FontWeight(weight: 500)
        measureText.foreground = Theme.brush(0xFFFFFF)
        measureText.verticalAlignment = .center
        measureText.margin = Theme.inset(7, 0, 7, 0)
        measurePill.child = measureText
        for shade in handleShades {
            shade.width = Self.handleSize + 1
            shade.height = Self.handleSize + 1
            shade.fill = Theme.brush(0, 0.12)
            shade.visibility = .collapsed
            shade.isHitTestVisible = false
        }

        pictures.redraw = { [weak self] in
            self?.drawPictures()
            self?.session.changed()
        }
        pictures.changed = { [weak self] in self?.session.edited(board: nil) }
        // A click on a cut-out picture being placed keeps or drops the subject there, once it is
        // clear it is not the first of a double click.
        pictures.clicked = { [weak self] v in self?.cutouts.click(at: v, doubleClick: Double(GetDoubleClickTime()) / 1000) }
        cutouts.redraw = { [weak self] in self?.drawCutouts() }
        maskMarks.view = { [weak self] in
            guard let self else { return (1, .zero, .zero, 1) }
            return (self.zoom, self.pan, CGSize(width: self.stage.actualWidth, height: self.stage.actualHeight), self.pixelScale)
        }
        maskMarks.state = { [weak self] in
            guard let self else { return ([], nil, nil, nil, false) }
            let d = self.dip
            var waiting: (over: UUID, since: Double)?
            if let d, d.opened == nil, d.ready, let over = d.over { waiting = (over, d.since) }
            return (self.session.selection, waiting, d?.opened, d?.opened == nil ? d?.leaving : nil, self.editing != nil)
        }
        maskMarks.unwound = { [weak self] in self?.session.previewed(board: nil) }
        copyMarks.view = { [weak self] in
            guard let self else { return (1, .zero, .zero, 1) }
            return (self.zoom, self.pan, CGSize(width: self.stage.actualWidth, height: self.stage.actualHeight), self.pixelScale)
        }
        copyMarks.state = { [weak self] in
            guard let self else { return ([], false) }
            let free = self.session.tool == .select && self.session.mode == 0 && self.editing == nil && self.drag == nil
                && !self.builder.active && self.pen.editingPath == nil && !WindowsCore.versions.lookingBack
            return (self.session.selection, free)
        }
        copyMarks.litChanged = { [weak self] in self?.drawCopyOutlines() }
        copyMarks.preview = { [weak self] copy, variant, on in
            WindowsCore.previewVariant(variant, of: copy, on)
            self?.session.previewed(board: nil)
        }
        copyMarks.choose = { [weak self] _, variant in
            guard let self else { return }
            let picked = WindowsCore.setVariant(variant, self.session.selection)
            self.session.select(picked, on: self.session.board)
            self.session.edited(board: nil)
        }
        copyMarks.addVariant = { [weak self] _ in
            guard let self else { return }
            let picked = WindowsCore.addVariant(self.session.selection)
            self.session.select(picked, on: self.session.board)
            self.session.edited(board: nil)
        }
        session.ringMask = { [weak self] mask, out in self?.maskMarks.ring(mask, out: out) }
        pen.redraw = { [weak self] in self?.drawPen() }
        knife.redraw = { [weak self] in self?.drawPen() }
        depth.redraw = { [weak self] in self?.drawDepth() }
        gridHand.redraw = { [weak self] in self?.drawGrids() }
        builder.redraw = { [weak self] in self?.drawBuild() }
        outlineHand.redraw = { [weak self] in self?.drawOutline() }
        curveHand.redraw = { [weak self] in self?.drawCurves() }
        develop.redraw = { [weak self] in self?.drawDevelop() }
        inspect.redraw = { [weak self] in self?.drawInspect() }
        flow.redraw = { [weak self] in self?.drawFlow() }
        flow.titleHit = { [weak self] p in self?.titleHit(p) }
        flow.pick = { [weak self] p in self.flatMap { WindowsCore.pick(p, selection: $0.session.selection, zoom: $0.zoom) } }
        flow.select = { [weak self] ids in
            guard let self else { return }
            self.session.select(ids, on: ids.first.flatMap(WindowsCore.board(of:)) ?? ids.first.flatMap(WindowsCore.boardIndex(of:)))
        }
        flow.writeNote = { [weak self] id, at in self?.beginNote(on: id, at: at) }
        flow.play = { [weak self] id in self?.session.play?(id) }
        inspect.titleHit = { [weak self] p in self?.titleHit(p) }
        motion.titleHit = { [weak self] p in self?.titleHit(p) }
        motion.redraw = { [weak self] in self?.drawMotion() }
        // A shape's points moved where no pose keeps them, or points taken away until no outline
        // is left, or From… with nothing to take.
        motion.beep = { _ = MessageBeep(0) }
        film.resync = { [weak self] in Probe.time("canvas.placeFilm(play)") { self?.placeFilm() } }
        session.film.run = { [weak self] in self?.film.run() }
        session.film.inSight = { [weak self] in self?.artboardInSight() }
        session.film.frame = { [weak self] id in self?.frameFilm(id) }
        session.listenToFilm { [weak self] in Probe.time("canvas.placeFilm") { self?.placeFilm() } }
        session.listenToPlayhead { [weak self] in Probe.time("canvas.placeFilm(moved)") { self?.placeFilm() } }
        curveHand.edited = { [weak self] in self?.session.edited(board: nil) }
        curveHand.fly = { [weak self] id, p in self?.letters.fly(id, from: p) }
        letters.watching = { [weak self] in
            guard let self else { return ([], nil, nil) }
            return (self.session.selection, self.editing?.id, self.curveHand.holding)
        }
        letters.view = { [weak self] in
            guard let self else { return (1, .zero, .zero, 1) }
            return (self.zoom, self.pan, CGSize(width: self.stage.actualWidth, height: self.stage.actualHeight), self.pixelScale)
        }
        letters.turned = { [weak self] texts in self?.lettersTurned(texts) }
        offerChip.height = 28
        offerChip.cornerRadius = Theme.corners(14)
        offerChip.background = Theme.brush(Theme.selection)
        offerChip.isHitTestVisible = false
        offerChip.visibility = .collapsed
        let offerWords = StackPanel()
        offerWords.orientation = .horizontal
        offerWords.spacing = 6
        offerWords.margin = Theme.inset(10, 0, 13, 0)
        offerWords.verticalAlignment = .center
        let offerGlyph = Glyphs.mask(size: 13, brush: Theme.brush(0xFFFFFF))
        offerGlyph.verticalAlignment = .center
        offerWords.children.append(offerGlyph)
        let offerText = Theme.text(Words.t("Mask"), size: 11.5, weight: 600)
        offerText.foreground = Theme.brush(0xFFFFFF)
        offerText.verticalAlignment = .center
        offerWords.children.append(offerText)
        offerChip.child = offerWords
        outlineHand.picked = { [weak self] ids in
            guard let self else { return }
            self.session.select(ids, on: ids.first.flatMap(WindowsCore.board(of:)) ?? self.session.board)
        }
        builder.changed = { [weak self] in
            self?.session.changed()
            self?.drawBuild()
        }
        builder.built = { [weak self] now in
            guard let self else { return }
            self.session.select(now, on: now.first.flatMap(WindowsCore.board(of:)) ?? self.session.board)
            self.session.edited(board: nil)
        }
        layoutHand.redraw = { [weak self] in self?.drawAids() }
        guideHand.redraw = { [weak self] in self?.drawAids() }
        guideHand.click = { [weak self] v, shift in self?.clickThrough(at: v, adding: shift) }
        guideHand.under = { [weak self] v in
            guard let self, let id = self.pick(v) else { return nil }
            return WindowsCore.bounds(of: [id])
        }
        guideHand.cornerMenu = { [weak self] v in
            guard let self, let menus = self.menus, let entries = self.aidsMenu?() else { return }
            menus.show(at: v, width: 220, entries: entries)
        }
        depth.pick = { [weak self] p in
            guard let self else { return nil }
            return self.pick(self.onStage(p))
        }
        pen.onDropPen = { [weak self] in self?.session.tool = .select }
        penMarks.isHitTestVisible = false
        stage.pointerPressed.addHandler { [weak self] _, args in self?.pressed(args) }
        stage.pointerMoved.addHandler { [weak self] _, args in self?.moved(args) }
        stage.pointerReleased.addHandler { [weak self] _, args in self?.released(args) }
        stage.pointerExited.addHandler { [weak self] _, _ in
            self?.liveCanvas.pointerMoved(to: nil, stage: .zero)
            if self?.drag == nil {
                self?.setHover(nil)
                self?.gridHand.hover(nil)
                self?.layoutHand.hover(nil)
                self?.curveHand.hover(nil)
                self?.develop.hover(nil)
                self?.inspect.hover(nil)
                self?.flow.hover(nil)
                self?.decks.hover(nil, onCanvas: nil)
                self?.copyMarks.hover(nil)
            }
        }
        stage.pointerWheelChanged.addHandler { [weak self] _, args in self?.wheel(args) }
        stage.doubleTapped.addHandler { [weak self] _, args in self?.doubleTapped(args) }
        stage.rightTapped.addHandler { [weak self] _, args in self?.rightTapped(args) }
        // Pictures and words dragged in from elsewhere, as the Mac's canvas takes them (Dropping):
        // over a shape a picture fills, the shape is lit.
        stage.allowDrop = true
        stage.dragOver.addHandler { [weak self] _, args in self?.dragOver(args) }
        stage.dragLeave.addHandler { [weak self] _, _ in self?.setHover(nil) }
        stage.drop.addHandler { [weak self] _, args in self?.dropped(args) }
        root.loaded.addHandler { [weak self] _, _ in
            guard let self else { return }
            self.pixelScale = self.root.xamlRoot?.rasterizationScale ?? 1
            // Fitted as the design opens; its tab coming back to the front shows it as it was left.
            if self.fitted {
                if self.session.isFront { self.place() }
                return
            }
            self.fitted = true
            self.lookFirst()
        }
        session.openCardChanged = { [weak self] in self?.drawAids() }
        let showSession: () -> Void = { [weak self] in
            self?.stepLetters()
            self?.placeOverlays()
            // The row under a stack follows the selection.
            self?.decks.update()
            self?.drawPen()
            // Into or out of Inspect: the paper and the measures come or go.
            self?.drawPaper()
            self?.drawInspect()
            self?.drawFlow()
            self?.placeFilm()
        }
        session.listen(showSession)
        session.listenToZoom(showSession)
        session.listenToHover { [weak self] in self?.placeOverlays() }
        // The fill menu opened or shut, or another of its gradient's colours chosen.
        session.listenToGradient { [weak self] in self?.gradients.draw() }
        wireLive()
        session.listenToStyles { [weak self] in self?.drawStyleUsers() }
        session.listenToEdits { [weak self] board in
            guard let self else { return }
            self.redraw(board: board)
            self.margin.draw()
            self.decks.edited()
            self.place()
            // A step made at once to a copy offers what can be made of it; any other step takes
            // what was offered away.
            // A change to a style runs out as light over every layer that has it.
            if self.drag == nil, let wave = WindowsCore.considerStyleWave(selection: self.session.selection) { self.startWave(wave) }
            if self.drag == nil, let considered = WindowsCore.considerCopyOffer(selection: self.session.selection) {
                if let offer = considered { self.showCopyOffer(offer) } else if self.copyOffer != nil {
                    self.copyOffer = nil
                    self.placeCopyOffer()
                }
            }
        }
    }

    /// The keys come here again, from a field that was typed into.
    func takeKeys() {
        _ = try? root.focus(.programmatic)
    }

    /// Size changes behind another tab could not draw that tab's design.
    func refreshViewport() {
        guard fitted, root.isLoaded, session.isFront else { return }
        pixelScale = root.xamlRoot?.rasterizationScale ?? pixelScale
        place()
    }

    /// Whether `panel` holds `child`, asked of the panel: WinUI's own `parent` can say nil for an
    /// element in a panel while the canvas is out of the window (its tab behind another, or just
    /// coming back), and adding it again then fails.
    private func holds(_ panel: Panel, _ child: UIElement) -> Bool {
        var at: UInt32 = 0
        return (try? panel.children.indexOf(child, &at)) == true
    }

    /// Whether the view was fitted to the design once, as it first showed.
    private var fitted = false

    /// The design's tab goes behind another: what is typed is kept, and a drag going on is taken
    /// back, as Escape takes it back, so nothing is left half done while another design is worked on.
    func leaveFront() {
        if let drag { cancelDrag(drag.grab, moved: drag.moved) }
        finishTyping()
    }

    /// The whole design in view, as the Mac fits it: 64 points round it, never above 1×.
    func fit() {
        // Not yet laid out, the canvas fits itself once it is (root.loaded): drawn before that,
        // its marks went onto the overlay twice and WinUI stopped the app (an AI assistant making
        // or bringing in a design zooms to fit at once).
        guard root.isLoaded else { return }
        boards = WindowsCore.boards()
        fit(boards.reduce(CGRect.null) { $0.union($1.frame) }, padding: 64, most: 1)
    }

    /// How a design shows as it opens, as the Mac's DocumentStore.lookFirst: the welcome tour on
    /// its first sheet, 48 points round it; any other design whole.
    private func lookFirst() {
        guard root.isLoaded else { return }
        boards = WindowsCore.boards()
        guard let cover = boards.first(where: { $0.id == Welcome.coverID }) else { fit(); return }
        fit(cover.frame, padding: 48, most: 1)
    }

    /// What is selected in view, as the Mac's Zoom to Selection: 80 points round it, never above 8×.
    func fitSelection() {
        guard let box = WindowsCore.bounds(of: session.selection) else { fit(); return }
        fit(box, padding: 80, most: 8)
    }

    private func fit(_ all: CGRect, padding: Double, most: Double) {
        let width = max(200, root.actualWidth > 0 ? root.actualWidth : 900), height = max(200, root.actualHeight > 0 ? root.actualHeight : 600)
        if !all.isNull, all.width > 0, all.height > 0 {
            let z = min(most, (width - 2 * padding) / Double(all.width), (height - 2 * padding) / Double(all.height))
            flyingZoom = nil
            session.zoom = max(0.02, z)
            pan = CGPoint(x: (width - Double(all.width) * zoom) / 2 - Double(all.minX) * zoom,
                          y: (height - Double(all.height) * zoom) / 2 - Double(all.minY) * zoom)
        }
        drawAll()
    }

    /// A part of the canvas brought into view, 80 points round it, never above 8×: what an AI
    /// assistant asks to look at.
    func show(_ r: CGRect) { fit(r, padding: 80, most: 8) }

    /// The part of the canvas in view.
    var visibleRect: CGRect { visibleOnCanvas }

    /// Typing into a text ends, kept, before something else changes the design.
    func finishTyping() { if editing != nil { endEditing() } }

    /// The zoom menu's steps: in or out one step, or to a zoom, about the middle of the canvas.
    func zoomStep(in grow: Bool) { step(in: grow) }
    func zoom(to z: Double) { zoom(to: z, around: CGPoint(x: root.actualWidth / 2, y: root.actualHeight / 2)) }
    var currentZoom: Double { zoom }
    /// The canvas point in the middle of what shows.
    var middleOnCanvas: CGPoint { inDesign(CGPoint(x: root.actualWidth / 2, y: root.actualHeight / 2)) }
    /// The drawing aids shown or hidden: drawn again.
    func aidsChanged() {
        drawAids()
        showRulers()
    }

    // MARK: Drawing

    private func drawAll() {
        if !letters.step().isEmpty { placeEditor() }
        boards = WindowsCore.boards()
        let visible = rasterViewport
        for k in boards.indices { draw(k, visible: visible) }
        for (k, old) in sheets where k >= boards.count {
            var sheet = old
            sheet.image.clear()
            sheet.shadow.clear()
            sheet.name.visibility = .collapsed
            sheets[k] = sheet
        }
        drawLoose(visible: visible)
        place(refreshingCanvas: false)
    }

    /// The layers lying on the canvas drawn again, each over as much as it paints.
    private func drawLoose(visible: CGRect? = nil, refreshing: Bool = true) {
        if refreshing { loose = WindowsCore.looseLayers() }
        let view = visible ?? rasterViewport
        var shown = Set<Int>()
        for item in loose {
            var surface = looseSheets[item.index] ?? {
                let surface = CanvasSurface()
                surface.view.isHitTestVisible = false
                stage.children.append(surface.view)
                return surface
            }()
            let area = rasterArea(item.reach, visible: view, keeping: surface.area)
            let drew = surface.update(area, refreshing: refreshing) { area, fill in
                WindowsCore.render(loose: item.index, scale: area.scale, hiding: hiding(on: item.index),
                                   part: area.whole ? nil : area.rect, into: fill)
            }
            place(surface)
            looseSheets[item.index] = surface
            // Pictures on their way in it, drawn developing again over what was drawn anew.
            if drew, developingShown[item.index] != nil { developInto(loose: item) }
            shown.insert(item.index)
        }
        for (k, old) in looseSheets where !shown.contains(k) {
            var surface = old
            surface.clear()
            looseSheets[k] = surface
        }
    }

    /// What shows `board` (an artboard, or a layer on the canvas) drawn again.
    private func redraw(board: Int?) {
        // Letters that set off with this change, or landed, and so their texts' artboards too.
        let turned = letters.step()
        defer { if !turned.isEmpty { placeEditor() } }
        // What is known of each artboard first: the change may have moved or sized it.
        let now = WindowsCore.boards()
        guard let board, now.count == boards.count, let k = now.firstIndex(where: { $0.index == board }) else { drawAll(); return }
        boards = now
        draw(k)
        redrawTexts(turned, besides: board)
        letters.draw()
    }

    /// What is left out of the picture of `board` (by its place among the design's layers): the
    /// texts whose letters are on their way. The text typed into is drawn as it is, with its
    /// caret over it.
    private func hiding(on board: Int) -> Set<UUID> {
        letters.hidden
    }

    /// The pictures of the artboards (or layers on the canvas) these texts are on drawn again,
    /// but for `done`, drawn already.
    private func redrawTexts(_ texts: Set<UUID>, besides done: Int? = nil) {
        var drawn: Set<Int> = done.map { [$0] } ?? []
        var loose = false
        for id in texts {
            guard let index = WindowsCore.board(of: id), !drawn.contains(index) else { continue }
            drawn.insert(index)
            if let k = boards.firstIndex(where: { $0.index == index }) { draw(k) } else { loose = true }
        }
        if loose { drawLoose() }
    }

    /// The letters stepped on outside a change drawn, as when the selection changes.
    private func stepLetters() {
        let turned = letters.step()
        if !turned.isEmpty { lettersTurned(turned) }
        letters.draw()
    }

    /// Letters that set off or landed: their texts drawn again with them, or without; the text
    /// typed into shows once its letters have landed.
    private func lettersTurned(_ texts: Set<UUID>) {
        redrawTexts(texts)
        placeEditor()
        if editing != nil { drawTyping() }
    }

    private var rasterViewport: CGRect {
        let visible = visibleOnCanvas
        if !visible.isEmpty { return visible }
        let origin = inDesign(.zero)
        return CGRect(origin: origin, size: CGSize(width: root.actualWidth / zoom, height: root.actualHeight / zoom))
    }

    private var rasterScale: Double { min(zoom, session.zoom) * pixelScale }

    private func rasterArea(_ bounds: CGRect, visible: CGRect, keeping current: CanvasRasterArea?) -> CanvasRasterArea? {
        CanvasRasterArea.select(bounds: bounds, visible: visible, margin: Self.rasterMargin / zoom,
                                scale: rasterScale, keeping: current, flying: flyingZoom != nil)
    }

    /// Artboard `k` drawn over its visible part, with its shadow.
    private func draw(_ k: Int, visible: CGRect? = nil, refreshing: Bool = true) {
        guard boards.indices.contains(k) else { return }
        let board = boards[k]
        var sheet = sheets[k] ?? {
            let sheet = Sheet()
            sheet.shadow.view.isHitTestVisible = false
            sheet.image.view.isHitTestVisible = false
            sheet.name.fontFamily = Theme.ui
            sheet.name.fontSize = 11
            sheet.name.fontWeight = FontWeight(weight: 500)
            sheet.name.textTrimming = .characterEllipsis
            sheet.name.isHitTestVisible = false
            stage.children.append(sheet.shadow.view)
            stage.children.append(sheet.name)
            stage.children.append(sheet.image.view)
            return sheet
        }()
        let view = visible ?? rasterViewport
        let bounds = board.drawn.isEmpty ? board.frame : board.drawn
        let area = rasterArea(bounds, visible: view, keeping: sheet.image.area)
        let drew = sheet.image.update(area, refreshing: refreshing || sheet.id != board.id) { area, fill in
            WindowsCore.render(board: board.index, scale: area.scale, hiding: hiding(on: board.index),
                               part: area.whole ? nil : area.rect, into: fill)
        }
        sheet.id = board.id
        drawShadow(of: board.frame, visible: view, sheet: &sheet)
        place(sheet.image, shown: board.id != filmCovers)
        place(sheet.shadow)
        if sheet.title != board.name {
            sheet.name.text = board.name
            sheet.title = board.name
        }
        sheets[k] = sheet
        // Pictures on their way on it, drawn developing again over what was drawn anew.
        if drew, developingShown[board.index] != nil { developInto(k) }
    }

    private func drawShadow(of frame: CGRect, visible: CGRect, sheet: inout Sheet) {
        let scale = sheet.image.area?.scale ?? rasterScale
        let pad = (14 * pixelScale).rounded(.up)
        let width = (frame.width * scale).rounded(), height = (frame.height * scale).rounded()
        let bounds = CGRect(x: frame.minX - pad / scale, y: frame.minY - pad / scale,
                            width: (width + 2 * pad) / scale, height: (height + 2 * pad) / scale)
        let area = CanvasRasterArea.select(bounds: bounds, visible: visible, margin: Self.rasterMargin / zoom,
                                           scale: scale, keeping: sheet.shadow.area)
        let colour = Theme.shadow
        let refresh = colour != sheet.shadowColour || pixelScale != sheet.shadowScale
        _ = sheet.shadow.update(area, refreshing: refresh) { area, fill in
            let part = area.pixels.offsetBy(dx: -pad, dy: -pad)
            return WindowsCore.artboardShadow(boardWidth: width, boardHeight: height, part: part,
                                               scale: pixelScale, colour: colour, into: fill)
        }
        sheet.shadowColour = colour
        sheet.shadowScale = pixelScale
    }

    /// Everything where the zoom and pan put it.
    /// The canvas seen as a prototype or inspected: a sheet of millimetre paper, ruled in the
    /// pencil's blue under the screens, as the Mac's FlowTool draws it: the fine ruling never
    /// closer than 9 points on screen nor further apart than 45, every fifth line a stronger one,
    /// fixed to the canvas as it moves.
    private func drawPaper() {
        if !holds(stage, paper) {
            paper.isHitTestVisible = false
            try? stage.children.insertAt(0, paper)
        }
        paper.children.clear()
        guard session.mode != 0 || flow.showing else { return }
        let w = Double(stage.actualWidth), h = Double(stage.actualHeight)
        guard w > 0, h > 0 else { return }
        var step = 8.0
        while step * zoom < 9 { step *= 5 }
        while step * zoom > 45 { step /= 5 }
        var minor = PathData(), major = PathData()
        let ox = -Double(pan.x) / zoom, oy = -Double(pan.y) / zoom
        var i = Int(floor(ox / step))
        while true {
            let x = (Double(i) * step - ox) * zoom
            if x > w { break }
            let c = x.rounded() + 0.5
            if i % 5 == 0 { major.move(c, 0); major.line(c, h) } else { minor.move(c, 0); minor.line(c, h) }
            i += 1
        }
        var j = Int(floor(oy / step))
        while true {
            let y = (Double(j) * step - oy) * zoom
            if y > h { break }
            let c = y.rounded() + 0.5
            if j % 5 == 0 { major.move(0, c); major.line(w, c) } else { minor.move(0, c); minor.line(w, c) }
            j += 1
        }
        let ink = Theme.dark ? 0x8FA8F2 as UInt32 : 0x3A63D8
        for (d, alpha) in [(minor, Theme.dark ? 0.07 : 0.075), (major, Theme.dark ? 0.14 : 0.17)] {
            guard let path = markPath(d) else { continue }
            path.stroke = Theme.brush(ink, alpha)
            paper.children.append(path)
        }
    }

    private func place(_ surface: CanvasSurface, shown: Bool = true) {
        guard let area = surface.area else { return }
        guard shown else { surface.view.visibility = .collapsed; return }
        let rect = onStage(rect: area.rect)
        try? Canvas.setLeft(surface.view, rect.minX)
        try? Canvas.setTop(surface.view, rect.minY)
        surface.view.width = rect.width
        surface.view.height = rect.height
        surface.view.visibility = .visible
    }

    private func place(refreshingCanvas: Bool = true) {
        drawPaper()
        margin.draw()
        drawFound()
        if refreshingCanvas, session.isFront {
            let visible = rasterViewport
            for k in boards.indices { draw(k, visible: visible, refreshing: false) }
            drawLoose(visible: visible, refreshing: false)
        }
        for (k, board) in boards.enumerated() {
            guard let sheet = sheets[k] else { continue }
            let at = onStage(board.frame.origin)
            let w = Double(board.frame.width) * zoom
            // The name 19 above, as wide as the artboard (at least 40), gone under 30 wide; a
            // carousel's as wide as its first slide, less the room for its number.
            try? Canvas.setLeft(sheet.name, Double(at.x))
            try? Canvas.setTop(sheet.name, Double(at.y) - 19)
            let named = board.slide.map { Double($0.width) * zoom - Self.slideNumberRoom } ?? w
            sheet.name.maxWidth = max(named, 40)
            sheet.name.visibility = w < 30 ? .collapsed : .visible
        }
        placeSlideMarks()
        drawAids()
        decks.update()
        letters.draw()
        placeOverlays()
        placeFilm()
        // The others' marks move with the canvas.
        liveCanvas.changed()
    }

    // MARK: The film

    /// The canvas hand sees the canvas as it is now.
    private func syncMotion() {
        motion.zoom = CGFloat(zoom)
        motion.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// The film laid out at the playhead where the artboard is, over its sheet, and what is posed
    /// drawn over it; out of Animate, the sheet shows again.
    func placeFilm() {
        guard animating, session.isFront else {
            if film.shown != nil || film.image.visibility == .visible || filmCovers != nil {
                film.hide()
                coverSheet(nil)
            }
            return
        }
        if !holds(stage, film.image) { stage.children.append(film.image) }
        if !holds(overlay, film.marks) { overlay.children.append(film.marks) }
        syncMotion()
        Probe.time("canvas.filmSync") { film.sync(zoom: zoom, pan: CGPoint(x: Double(pan.x), y: Double(pan.y)), size: CGSize(width: stage.actualWidth, height: stage.actualHeight), pixelScale: pixelScale) }
        coverSheet(film.shown)
        drawMotion()
    }

    /// The sheet of the film's artboard put away under the film, and any other shown again.
    private func coverSheet(_ id: UUID?) {
        guard filmCovers != id || id != nil else { return }
        filmCovers = id
        for (k, board) in boards.enumerated() {
            guard let image = sheets[k]?.image else { continue }
            image.view.visibility = board.id == id || image.bitmap == nil ? .collapsed : .visible
        }
    }

    /// What is posed over the film, as the canvas hand has it now.
    private func drawMotion() {
        guard animating else { film.drawMarks(nil, pixelScale: pixelScale); return }
        syncMotion()
        film.drawMarks(motion.marks(), pixelScale: pixelScale)
    }

    /// The artboard most in sight, for the film's desk to take when nothing is picked.
    private func artboardInSight() -> UUID? {
        let seen = visibleOnCanvas
        let shown = WindowsCore.boards().filter { !$0.hidden }
        func area(_ r: CGRect) -> Double { r.isNull ? 0 : Double(r.width * r.height) }
        guard let best = shown.max(by: { area($0.frame.intersection(seen)) < area($1.frame.intersection(seen)) }),
              best.frame.intersects(seen) else { return nil }
        return best.id
    }

    /// The view moved so the film's artboard lies whole above the timeline, as the Mac's
    /// frameFilm: clear of the card as tall as this film's lines make it; one that shows whole
    /// there already is left where it is, and one that has to move moves only the way it must.
    private func frameFilm(_ id: UUID) {
        guard root.isLoaded, let board = WindowsCore.boards().first(where: { $0.id == id }) else { return }
        let w = root.actualWidth, h = root.actualHeight - FilmFraming.foot(lines: session.film.lineCount)
        guard w > 0, h > 160 else { return }
        let f = board.frame
        let now = FilmFraming.View(zoom: zoom, panX: Double(pan.x), panY: Double(pan.y))
        guard let to = FilmFraming.framed(x: Double(f.minX), y: Double(f.minY), width: Double(f.width), height: Double(f.height),
                                          from: now, roomWidth: w, roomHeight: h) else { return }
        flyingZoom = nil
        session.zoom = to.zoom
        pan = CGPoint(x: to.panX, y: to.panY)
        drawAll()
    }

    /// While a layer of a post is moved, resized or typed into, the same layer in every other
    /// post: faint dashes in pencil, as the Mac's DeckTool draws them.
    private func drawEchoes() {
        if !holds(overlay, echoes) {
            echoes.isHitTestVisible = false
            echoes.stroke = Theme.brush(Theme.pencil, 0.45)
            echoes.strokeThickness = 1
            let dashes = DoubleCollection()
            dashes.append(3)
            dashes.append(3)
            echoes.strokeDashArray = dashes
            overlay.children.append(echoes)
        }
        let id = editing?.id ?? (session.selection.count == 1 ? session.selection.first : nil)
        let quads = decks.spreading ? [] : WindowsCore.echoes(of: id)
        guard !quads.isEmpty else {
            echoes.visibility = .collapsed
            return
        }
        let geometry = PathGeometry()
        for quad in quads where quad.count == 4 {
            let figure = PathFigure()
            func at(_ p: CGPoint) -> Point {
                let q = onStage(p)
                return Point(x: Float(Double(q.x).rounded() + 0.5), y: Float(Double(q.y).rounded() + 0.5))
            }
            figure.startPoint = at(quad[0])
            figure.isClosed = true
            figure.isFilled = false
            for p in quad.dropFirst() {
                let segment = LineSegment()
                segment.point = at(p)
                figure.segments.append(segment)
            }
            geometry.figures.append(figure)
        }
        echoes.data = geometry
        echoes.visibility = .visible
    }

    /// The letters picked out in the text being typed into, if any.
    var typedSelection: String? {
        guard let editor, editor.selectionLength > 0 else { return nil }
        return editor.selectedText
    }

    /// Marks what the find bar finds, as the Mac's CanvasView.drawFound: each found word lit as a
    /// highlighter would, the one picked out brighter and ringed, or for misspelt words a wavy
    /// line under each.
    func drawFound() {
        if !holds(overlay, foundMarks) {
            foundMarks.isHitTestVisible = false
            overlay.children.insertAt(0, foundMarks)
        }
        foundMarks.children.clear()
        guard let finder = WindowsCore.finder, session.mode == 0, !WindowsCore.versions.lookingBack else { return }
        let marks = finder.marks(in: visibleOnCanvas, editing: editing?.id)
        guard !marks.isEmpty else { return }
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        func shape(_ quad: [CGPoint]) -> String {
            let points = quad.map(onStage)
            return "M" + points.map { n(Double($0.x)) + "," + n(Double($0.y)) }.joined(separator: " L") + " Z "
        }
        var lit = "", picked = "", waves = "", pickedWaves = ""
        for mark in marks {
            for quad in mark.quads where quad.count == 4 {
                if finder.spelling {
                    let line = Self.squiggle(under: quad.map(onStage))
                    if mark.picked { picked += shape(quad); pickedWaves += line } else { waves += line }
                } else if mark.picked {
                    picked += shape(quad)
                } else {
                    lit += shape(quad)
                }
            }
        }
        func path(_ data: String, fill: Brush? = nil, stroke: Brush? = nil, width: Double = 1) {
            guard !data.isEmpty, let p = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='F1 \(data)'/>")) as? WinUI.Path else { return }
            p.fill = fill
            p.stroke = stroke
            p.strokeThickness = width
            p.strokeStartLineCap = .round
            p.strokeEndLineCap = .round
            p.strokeLineJoin = .round
            foundMarks.children.append(p)
        }
        if finder.spelling {
            path(picked, fill: Theme.brush(0xE63333, 0.14))
            path(waves, stroke: Theme.brush(0xE02929, 0.8), width: 1.2)
            path(pickedWaves, stroke: Theme.brush(0xE02929), width: 1.6)
        } else {
            path(lit, fill: Theme.brush(0xFFD61A, 0.28))
            path(picked, fill: Theme.brush(0xFFD61A, 0.55), stroke: Theme.brush(0xEE9900, 0.95), width: 1.5)
        }
    }

    /// A wavy line along the bottom of a word (its quad on the stage), the way a misspelt word is
    /// marked as it is typed: as path data.
    private static func squiggle(under quad: [CGPoint]) -> String {
        let a = quad[3], b = quad[2]
        let length = hypot(Double(b.x - a.x), Double(b.y - a.y))
        guard length > 1 else { return "" }
        let ux = Double(b.x - a.x) / length, uy = Double(b.y - a.y) / length
        let wave = 3.0, height = 1.6
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        var d = "M" + n(Double(a.x)) + "," + n(Double(a.y)) + " "
        var t = 0.0
        while t < length {
            let next = min(t + wave, length)
            let up = (Int(t / wave) % 2 == 0 ? 1.0 : -1.0) * height
            let mid = (t + next) / 2
            let cx = Double(a.x) + ux * mid - uy * up * 2, cy = Double(a.y) + uy * mid + ux * up * 2
            d += "Q" + n(cx) + "," + n(cy) + " " + n(Double(a.x) + ux * next) + "," + n(Double(a.y) + uy * next) + " "
            t = next
        }
        return d
    }

    /// Layout grids, as the Mac's LayoutTool draws them at rest: columns and rows washed in the red
    /// of a ruled margin with an edge each side, baselines in the pale blue of lined paper (fading
    /// as they crowd together zooming out); brighter while the grid's card is open or something on
    /// its artboard is dragged. And the guides, in pencil, from edge to edge of their artboards.
    private func drawAids() {
        if !holds(overlay, aidMarks) {
            aidMarks.isHitTestVisible = false
            overlay.children.insertAt(0, aidMarks)
        }
        aidMarks.children.clear()
        func crisp(_ v: Double) -> Double { v.rounded() + 0.5 }
        func path(_ data: String, fill: Brush? = nil, stroke: Brush? = nil) {
            guard !data.isEmpty, let p = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='1'/>")) as? WinUI.Path else { return }
            p.fill = fill
            p.stroke = stroke
            aidMarks.children.append(p)
        }
        let red = Inspector.red, blue = Inspector.blue
        syncLayout()
        // What is being moved or resized on an artboard, to light the columns it spans.
        let moving: Bool = switch drag?.grab {
        case .move?, .handle?: drag?.moved == true
        default: false
        }
        let span = moving ? WindowsCore.columnSpan(session.selection) : nil
        let spanBoard = moving ? session.selection.first.flatMap(WindowsCore.board(of:)) : nil
        for m in WindowsCore.gridMarks() {
            let index = boards.first { $0.id == m.board }?.index
            let lit = (session.selection == [m.board] && session.openCard == "Layout Grid") || (drag?.moved == true && index != nil && index == session.board)
                || layoutHand.workedOn == m.board
            let a = lit ? 1.0 : 0.0
            let wash = 0.04 + 0.035 * a, edge = 0.12 + 0.2 * a
            let spanned = index != nil && index == spanBoard ? span?.lit ?? [] : []
            for (bands, columns) in [(m.columns, true), (m.rows, false)] where !bands.isEmpty {
                var washes = PathData(), edges = PathData(), litWashes = PathData(), litEdges = PathData()
                for (i, r) in bands.enumerated() {
                    let o = onStage(r.origin)
                    let x = Double(o.x), y = Double(o.y), w = Double(r.width) * zoom, h = Double(r.height) * zoom
                    guard (columns ? w : h) >= 0.5 else { continue }
                    let spans = columns && spanned.contains(i)
                    if spans { litWashes.rect(x, y, w, h) } else { washes.rect(x, y, w, h) }
                    if columns {
                        if spans {
                            litEdges.move(crisp(x), y); litEdges.line(crisp(x), y + h)
                            litEdges.move(crisp(x + w), y); litEdges.line(crisp(x + w), y + h)
                        } else {
                            edges.move(crisp(x), y); edges.line(crisp(x), y + h)
                            edges.move(crisp(x + w), y); edges.line(crisp(x + w), y + h)
                        }
                    } else {
                        edges.move(x, crisp(y)); edges.line(x + w, crisp(y))
                        edges.move(x, crisp(y + h)); edges.line(x + w, crisp(y + h))
                    }
                }
                path(washes.d, fill: Theme.brush(red, columns ? wash : wash * 0.8))
                path(edges.d, stroke: Theme.brush(red, edge))
                path(litWashes.d, fill: Theme.brush(red, wash + 0.07))
                path(litEdges.d, stroke: Theme.brush(red, edge + 0.2))
            }
            // Each column's number along the top while the grid is worked on.
            if layoutHand.editable == m.board {
                for (i, r) in m.columns.enumerated() {
                    let o = onStage(r.origin), w = Double(r.width) * zoom
                    guard w >= 14 else { continue }
                    let label = Theme.text("\(m.perArea > 0 ? i % m.perArea + 1 : i + 1)", size: 9, weight: 600)
                    label.foreground = Theme.brush(red, 0.85)
                    try? label.measure(Size(width: 60, height: 20))
                    try? Canvas.setLeft(label, (Double(o.x) + w / 2 - Double(label.desiredSize.width) / 2).rounded())
                    try? Canvas.setTop(label, Double(o.y) + 4)
                    aidMarks.children.append(label)
                }
            }
            let crowd = min(max((Double(m.step) * zoom - 2.5) / 5, 0), 1)
            if crowd > 0.01, !m.baselines.isEmpty {
                var lines = PathData()
                for b in m.baselines {
                    let y = crisp(Double(onStage(CGPoint(x: 0, y: b.y)).y))
                    lines.move(Double(onStage(CGPoint(x: b.from, y: 0)).x), y)
                    lines.line(Double(onStage(CGPoint(x: b.to, y: 0)).x), y)
                }
                path(lines.d, stroke: Theme.brush(blue, (0.14 + 0.14 * a) * crowd))
            }
        }
        // The part of the grid under the pointer, or held: its bands hatched, as the gaps between
        // layers are when they line up; a baseline drawn firmly, and the first, which stays.
        for band in layoutHand.lit() {
            let o = onStage(band.rect.origin)
            let x = Double(o.x), y = Double(o.y), w = Double(band.rect.width) * zoom, h = Double(band.rect.height) * zoom
            if band.line {
                var line = PathData()
                line.rect(x, y - 0.75, w, 1.5)
                path(line.d, fill: Theme.brush(blue, band.held ? 0.95 : 0.6))
                continue
            }
            guard w > 0, h > 0 else { continue }
            var fill = PathData()
            fill.rect(x, y, w, h)
            path(fill.d, fill: Theme.brush(red, 0.14))
            let hatch = Canvas()
            hatch.width = w
            hatch.height = h
            let clip = RectangleGeometry()
            clip.rect = Rect(x: 0, y: 0, width: Float(w), height: Float(h))
            hatch.clip = clip
            var lines = PathData()
            var hx = -h
            while hx < w {
                lines.move(hx, h)
                lines.line(hx + h, 0)
                hx += 4
            }
            if let shape = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(lines.d)' StrokeThickness='0.75'/>")) as? WinUI.Path {
                shape.stroke = Theme.brush(red, 0.5)
                hatch.children.append(shape)
            }
            try? Canvas.setLeft(hatch, x)
            try? Canvas.setTop(hatch, y)
            aidMarks.children.append(hatch)
        }
        // How many columns something spans exactly, in a red pill over it.
        if let span, let count = span.exact {
            let r = span.box, o = onStage(r.origin)
            let box = Border()
            box.height = 18
            box.cornerRadius = Theme.corners(9)
            box.background = Theme.brush(red)
            let words = Theme.text(count == 1 ? "1 column" : "\(count) columns", size: 10.5, weight: 600)
            words.foreground = Theme.brush(0xFFFFFF)
            words.margin = Theme.inset(7, 0, 7, 0)
            words.verticalAlignment = .center
            box.child = words
            try? box.measure(Size(width: 300, height: 18))
            let w = Double(box.desiredSize.width)
            try? Canvas.setLeft(box, (Double(o.x) + Double(r.width) * zoom / 2 - w / 2).rounded())
            try? Canvas.setTop(box, (Double(o.y) - 26).rounded())
            aidMarks.children.append(box)
        }
        // The guides: lit under the pointer or while moved; one being dragged in or off, and its
        // distances to the edges, as the Mac shows them (without its unrolling and quivering).
        syncGuides()
        var calm = PathData(), lit = PathData()
        for g in guideHand.lines() {
            let a = onStage(g.from), b = onStage(g.to)
            let x0 = g.vertical ? crisp(Double(a.x)) : Double(a.x), y0 = g.vertical ? Double(a.y) : crisp(Double(a.y))
            let x1 = g.vertical ? crisp(Double(b.x)) : Double(b.x), y1 = g.vertical ? Double(b.y) : crisp(Double(b.y))
            if g.lit { lit.move(x0, y0); lit.line(x1, y1) } else { calm.move(x0, y0); calm.line(x1, y1) }
        }
        path(calm.d, stroke: Theme.brush(Theme.selection, 0.62))
        if let shape = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(lit.d.isEmpty ? "M0,0" : lit.d)' StrokeThickness='1.25'/>")) as? WinUI.Path, !lit.d.isEmpty {
            shape.stroke = Theme.brush(Theme.selection)
            aidMarks.children.append(shape)
        }
        func pill(_ text: String, at p: CGPoint, solid: Bool, warning: Bool) {
            let ink = warning ? Theme.warning : Theme.selection
            let box = Border()
            box.height = 18
            box.cornerRadius = Theme.corners(9)
            box.background = solid ? Theme.brush(ink) : Theme.brush(0xFFFFFF)
            box.borderBrush = Theme.brush(ink)
            box.borderThickness = Theme.inset(solid ? 0 : 1)
            let words = Theme.text(text, size: 10.5, weight: 600)
            words.foreground = solid ? Theme.brush(0xFFFFFF) : Theme.brush(ink)
            words.margin = Theme.inset(6, 0, 6, 0)
            words.verticalAlignment = .center
            box.child = words
            try? box.measure(Size(width: 300, height: 18))
            let w = Double(box.desiredSize.width)
            try? Canvas.setLeft(box, (Double(p.x) - w / 2).rounded())
            try? Canvas.setTop(box, (Double(p.y) - 9).rounded())
            aidMarks.children.append(box)
        }
        for h in guideHand.held() {
            let a = onStage(h.from), b = onStage(h.to)
            var line = PathData()
            line.move(Double(a.x), Double(a.y))
            line.line(Double(b.x), Double(b.y))
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(line.d)' StrokeThickness='\(h.leaving ? 1 : 1.25)'"
                + (h.leaving ? " StrokeDashArray='4 3'" : "") + "/>"
            if let shape = (try? XamlReader.load(xaml)) as? WinUI.Path {
                shape.stroke = Theme.brush(Theme.selection, h.leaving ? 0.4 : 1)
                aidMarks.children.append(shape)
            }
            if h.leaving {
                let q = onStage(h.pointer)
                pill(Words.t("Release to remove"), at: CGPoint(x: Double(q.x) + 14 + 50, y: Double(q.y) + 14 + 9), solid: true, warning: true)
                continue
            }
            // Each distance beside the pointer along the guide, solid toward the edge it keeps to.
            for span in h.spans {
                let s0 = onStage(span.from), s1 = onStage(span.to)
                var dim = PathData()
                let off = 26.0
                let d0 = h.vertical ? CGPoint(x: Double(s0.x), y: Double(s0.y) + off) : CGPoint(x: Double(s0.x) + off, y: Double(s0.y))
                let d1 = h.vertical ? CGPoint(x: Double(s1.x), y: Double(s1.y) + off) : CGPoint(x: Double(s1.x) + off, y: Double(s1.y))
                dim.move(Double(d0.x), Double(d0.y)); dim.line(Double(d1.x), Double(d1.y))
                path(dim.d, stroke: Theme.brush(Theme.selection, 0.75))
                pill(number(Double(span.length)), at: CGPoint(x: (Double(d0.x) + Double(d1.x)) / 2, y: (Double(d0.y) + Double(d1.y)) / 2), solid: span.kept, warning: false)
            }
        }
        rulers.showTabs(WindowsCore.showsRulers ? guideHand.tabs().map { (Double($0.at), $0.vertical, $0.lit) } : [])
    }

    private func number(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    /// The guides see the canvas as it is now.
    private func syncGuides() {
        guideHand.zoom = CGFloat(zoom)
        guideHand.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
        guideHand.size = CGSize(width: root.actualWidth, height: root.actualHeight)
        guideHand.selecting = session.tool == .select && editing == nil
        guideHand.rulerIndex = session.board
    }

    /// A press on a guide that did not become a drag: a click on what lies under it.
    private func clickThrough(at p: CGPoint, adding: Bool) {
        let id = pick(p)
        if adding, let id {
            var picked = session.selection
            if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
            session.select(picked, on: WindowsCore.board(of: id) ?? session.board)
        } else {
            session.select(id.map { [$0] } ?? [], on: id.flatMap(WindowsCore.board(of:)) ?? session.board)
        }
    }

    static let slideNumberRoom = 28.0

    /// A carousel's cuts, as the Mac's canvas draws them (drawSlideCuts): a dashed pencil line
    /// down each, over a pale one so it shows on dark slides and light ones; and each slide's
    /// number in the names' row at its right, once a slide leaves room for it beside the name.
    private func placeSlideMarks() {
        if !holds(overlay, slideMarks) {
            slideMarks.isHitTestVisible = false
            overlay.children.insertAt(0, slideMarks)
        }
        slideMarks.children.clear()
        for board in boards where !board.hidden && board.slides > 1 {
            guard let slide = board.slide, Double(slide.width) * zoom >= 4 else { continue }
            let at = onStage(board.frame.origin)
            let h = Double(board.frame.height) * zoom, step = Double(slide.width) * zoom
            var cuts = PathData()
            for i in 1..<board.slides {
                let x = (Double(at.x) + Double(i) * step).rounded() + 0.5
                cuts.move(x, Double(at.y))
                cuts.line(x, Double(at.y) + h)
            }
            for (colour, alpha, dashed) in [(UInt32(0xFFFFFF), 0.7, false), (Theme.pencil, 1.0, true)] {
                let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(cuts.d)' StrokeThickness='1'"
                    + (dashed ? " StrokeDashArray='4 3'" : "") + "/>"
                guard let line = (try? XamlReader.load(xaml)) as? WinUI.Path else { continue }
                line.stroke = Theme.brush(colour, alpha)
                slideMarks.children.append(line)
            }
            guard step >= Self.slideNumberRoom + 40 else { continue }
            let lit = session.board == board.index
            for i in 0..<board.slides {
                let number = Theme.text("\(i + 1)", size: 11, weight: 500)
                number.foreground = lit ? Theme.brush(Theme.pencil) : Theme.brush(Theme.ink, 0.5)
                number.width = Self.slideNumberRoom
                number.textAlignment = .right
                try? Canvas.setLeft(number, Double(at.x) + Double(i + 1) * step - Self.slideNumberRoom)
                try? Canvas.setTop(number, Double(at.y) - 19)
                slideMarks.children.append(number)
            }
        }
    }

    private func placeOverlays() {
        if !overlaysAdded {
            overlay.children.append(hover)
            overlay.children.append(bounds)
            overlay.children.append(gapFields)
            overlay.children.append(guideLines)
            overlay.children.append(marqueeBox)
            overlay.children.append(shadowLine)
            for h in handleShades { overlay.children.append(h) }
            for h in handles { overlay.children.append(h) }
            for d in cornerDots { overlay.children.append(d) }
            overlay.children.append(measurePill)
            overlaysAdded = true
        }
        if session.pointedStyle != nil || !session.litLayers.isEmpty { drawStyleUsers() }
        drawEchoes()
        if editing != nil { drawTyping() }
        for (k, board) in boards.enumerated() {
            let lit = session.board == board.index
            sheets[k]?.name.foreground = lit ? Theme.brush(Theme.pencil) : Theme.brush(Theme.ink, 0.5)
        }
        if let id = hovered, !session.selection.contains(id), drag == nil, session.mode == 0,
           let line = WindowsCore.shown([id], zoom: zoom)?.outlines.first {
            trace(hover, line.points, closed: line.closed)
            hover.stroke = Theme.brush(line.copy ? Theme.linked : Theme.selection)
            hover.visibility = .visible
        } else {
            hover.visibility = .collapsed
        }
        showRulers()
        // A path whose points show has them in place of its frame and handles.
        let pointsShown = session.selection.count == 1 && session.selection.first == pen.shownPath
        // A picture being placed has its own edges and corners instead.
        let placing = session.selection.count == 1 && session.selection.first == pictures.editing
        // Shapes being built with show their pieces instead.
        let shown = session.selection.isEmpty || pointsShown || placing || builder.active || session.mode != 0 ? nil : WindowsCore.shown(session.selection, zoom: zoom)
        let lines = shown?.outlines ?? []
        while outlines.count < lines.count {
            let path = WinUI.Path()
            path.strokeThickness = 1
            path.isHitTestVisible = false
            // Under the handles, over the hover.
            try? overlay.children.insertAt(1, path)
            outlines.append(path)
        }
        for (k, path) in outlines.enumerated() {
            guard k < lines.count else { path.visibility = .collapsed; continue }
            trace(path, lines[k].points, closed: lines[k].closed)
            path.stroke = Theme.brush(lines[k].copy ? Theme.linked : Theme.selection)
            path.visibility = .visible
        }
        if let box = shown?.bounds {
            trace(bounds, box, closed: true)
            bounds.visibility = .visible
        } else {
            bounds.visibility = .collapsed
        }
        shownHandles = (shown?.handles ?? []).map { ($0.index, onStage($0.point)) }
        lineEnds = shown?.round == true && lines.first?.closed == false
        let round = shown?.round == true
        for k in handles.indices {
            guard k < shownHandles.count else {
                handles[k].visibility = .collapsed
                handleShades[k].visibility = .collapsed
                continue
            }
            let p = shownHandles[k].point
            let x = (Double(p.x)).rounded() - Self.handleSize / 2, y = (Double(p.y)).rounded() - Self.handleSize / 2
            let r = round ? Self.handleSize / 2 : 0
            handles[k].radiusX = r
            handles[k].radiusY = r
            handleShades[k].radiusX = round ? (Self.handleSize + 1) / 2 : 1
            handleShades[k].radiusY = handleShades[k].radiusX
            try? Canvas.setLeft(handles[k], x)
            try? Canvas.setTop(handles[k], y)
            try? Canvas.setLeft(handleShades[k], x - 0.5)
            try? Canvas.setTop(handleShades[k], y)
            handles[k].visibility = .visible
            handleShades[k].visibility = .visible
        }
        placeHolds()
        drawDepth()
        drawLook()
        drawGrids()
        drawOutline()
        drawCurves()
        drawDevelop()
        drawInspect()
        drawFlow()
        drawBuild()
        placeOffer()
        placeCopyOffer()
        drawComponents()
        drawCutouts()
        drawVectors()
        drawPictures()
        // Something picked inside a mask: the mask's outline, and the ghost of what it cuts off.
        maskMarks.update()
        gradients.draw()
        if drag == nil, let p = lastPoint { updatePointer(at: p) }
    }

    // MARK: Placing a picture

    /// Placing sees the canvas as it is now.
    private func syncPictures() {
        pictures.zoom = CGFloat(zoom)
        pictures.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    // MARK: Cutting out

    /// Cutting out sees the canvas as it is now.
    private func syncCutouts() {
        cutouts.zoom = CGFloat(zoom)
        cutouts.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
        cutouts.placing = pictures.editing
    }

    /// Pictures being cut out and a cut-out picture's subjects, as the Mac's CutoutTool draws
    /// them over the canvas: one picture over the stage (under the marks), drawn frame by frame
    /// while anything moves in it.
    func drawCutouts() {
        if !holds(overlay, cutoutImage) {
            cutoutImage.isHitTestVisible = false
            cutoutImage.stretch = .fill
            cutoutImage.visibility = .collapsed
            try? overlay.children.insertAt(0, cutoutImage)
        }
        guard !drawingCutouts else { return }
        drawingCutouts = true
        defer { drawingCutouts = false }
        syncCutouts()
        var bitmap = cutoutBitmap
        let covered = cutouts.draw(scale: pixelScale, stage: CGSize(width: stage.actualWidth, height: stage.actualHeight)) { width, height in
            if bitmap == nil || bitmap!.pixelWidth != Int32(width) || bitmap!.pixelHeight != Int32(height) {
                bitmap = WriteableBitmap(Int32(width), Int32(height))
            }
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        if let covered {
            try? bitmap?.invalidate()
            if cutoutBitmap !== bitmap { cutoutImage.source = bitmap }
            cutoutBitmap = bitmap
            try? Canvas.setLeft(cutoutImage, Double(covered.minX))
            try? Canvas.setTop(cutoutImage, Double(covered.minY))
            cutoutImage.width = Double(covered.width)
            cutoutImage.height = Double(covered.height)
            cutoutImage.visibility = .visible
        } else {
            cutoutImage.visibility = .collapsed
        }
        tickCutouts()
    }

    // MARK: Vectorizing

    /// Pictures being vectorized, and the pencil passing over one just made shapes, as the Mac's
    /// VectorTool draws them over the canvas: one picture over the stage (under the marks), drawn
    /// frame by frame while anything moves in it.
    func drawVectors() {
        if !holds(overlay, vectorImage) {
            vectorImage.isHitTestVisible = false
            vectorImage.stretch = .fill
            vectorImage.visibility = .collapsed
            try? overlay.children.insertAt(0, vectorImage)
        }
        guard !drawingVectors else { return }
        drawingVectors = true
        defer { drawingVectors = false }
        vectors.zoom = CGFloat(zoom)
        vectors.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
        var bitmap = vectorBitmap
        let covered = vectors.draw(scale: pixelScale, stage: CGSize(width: stage.actualWidth, height: stage.actualHeight)) { width, height in
            if bitmap == nil || bitmap!.pixelWidth != Int32(width) || bitmap!.pixelHeight != Int32(height) {
                bitmap = WriteableBitmap(Int32(width), Int32(height))
            }
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        if let covered {
            try? bitmap?.invalidate()
            if vectorBitmap !== bitmap { vectorImage.source = bitmap }
            vectorBitmap = bitmap
            try? Canvas.setLeft(vectorImage, Double(covered.minX))
            try? Canvas.setTop(vectorImage, Double(covered.minY))
            vectorImage.width = Double(covered.width)
            vectorImage.height = Double(covered.height)
            vectorImage.visibility = .visible
        } else {
            vectorImage.visibility = .collapsed
        }
        guard vectorTicking == nil, vectors.animating else { return }
        vectorTicking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drawVectors()
                if !self.vectors.animating {
                    self.vectorTicking?.dispose()
                    self.vectorTicking = nil
                    self.drawVectors()
                }
            }
        }
    }

    /// Frame by frame while a picture is being cut out, or what was cut off drops away.
    private func tickCutouts() {
        guard cutoutTicking == nil, cutouts.animating else { return }
        cutoutTicking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.drawCutouts()
                if !self.cutouts.animating {
                    self.cutoutTicking?.dispose()
                    self.cutoutTicking = nil
                    self.drawCutouts()
                }
            }
        }
    }

    /// The picture being placed, as the Mac's PictureTool draws it: the whole of it past the
    /// layer's outline at 42%, its edge white on a dark line, the layer's outline in pencil, a
    /// guide through the middle it caught on, and white crop marks at its corners on a dark edge;
    /// fading in as placing begins and out as it ends.
    private func drawPictures() {
        // Asked of the overlay: `parent` is nil while this tab is out of the window.
        if !holds(overlay, pictureMarks) {
            pictureMarks.isHitTestVisible = false
            // Over the selection, under the measure.
            var at: UInt32 = 0
            if (try? overlay.children.indexOf(measurePill, &at)) == true { try? overlay.children.insertAt(at, pictureMarks) } else { overlay.children.append(pictureMarks) }
            for _ in 0..<2 {
                let image = Image()
                image.isHitTestVisible = false
                image.stretch = .fill
                image.visibility = .collapsed
                pictureMarks.children.append(image)
                pictureGhosts.append((image, nil, nil))
            }
        }
        // Drawn once at a time: what placing ending does draws the canvas again.
        guard !drawingPictures else { return }
        drawingPictures = true
        defer { drawingPictures = false }
        // Building, prototyping or inspecting leave placing, as on the Mac.
        if pictures.editing != nil, builder.active || session.mode != 0 { pictures.editing = nil }
        syncPictures()
        let all = pictures.marks()
        while pictureMarks.children.size > UInt32(pictureGhosts.count) { pictureMarks.children.removeAt(UInt32(pictureGhosts.count)) }
        var used: Set<Int> = []
        for m in all {
            // The picture past the outline, drawn again only when it has moved: in the picture
            // that shows it already, or one that shows nothing wanted now.
            let keys = all.map(\.key)
            var slot: Int?
            for k in pictureGhosts.indices where !used.contains(k) && pictureGhosts[k].key == m.key { slot = k; break }
            if slot == nil {
                for k in pictureGhosts.indices where !used.contains(k) && !keys.contains(where: { $0 == pictureGhosts[k].key }) { slot = k; break }
            }
            if slot == nil { slot = pictureGhosts.indices.first { !used.contains($0) } }
            if let k = slot {
                used.insert(k)
                let image = pictureGhosts[k].image
                if pictureGhosts[k].key != m.key {
                    var bitmap = pictureGhosts[k].bitmap
                    let covered = pictures.ghost(m, scale: pixelScale, stage: CGSize(width: stage.actualWidth, height: stage.actualHeight)) { width, height in
                        if bitmap == nil || bitmap!.pixelWidth != Int32(width) || bitmap!.pixelHeight != Int32(height) {
                            bitmap = WriteableBitmap(Int32(width), Int32(height))
                        }
                        return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
                    }
                    if let covered {
                        try? bitmap?.invalidate()
                        if pictureGhosts[k].bitmap !== bitmap { image.source = bitmap }
                        try? Canvas.setLeft(image, Double(covered.minX))
                        try? Canvas.setTop(image, Double(covered.minY))
                        image.width = Double(covered.width)
                        image.height = Double(covered.height)
                        pictureGhosts[k].bitmap = bitmap
                        pictureGhosts[k].key = m.key
                    } else {
                        pictureGhosts[k].key = nil
                    }
                }
                image.opacity = m.alpha * WindowsCore.PictureHand.ghost
                image.visibility = pictureGhosts[k].key == nil ? Visibility.collapsed : Visibility.visible
            }
            let group = Canvas()
            group.isHitTestVisible = false
            group.opacity = m.alpha
            func line(_ data: String, _ brush: Brush, _ width: Double, round: Bool = false) {
                guard !data.isEmpty, let path = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)'/>")) as? WinUI.Path else { return }
                path.stroke = brush
                path.strokeThickness = width
                path.strokeLineJoin = .round
                if round {
                    path.strokeStartLineCap = .round
                    path.strokeEndLineCap = .round
                }
                group.children.append(path)
            }
            // The picture's edge: a fine white line on a dark one, to show over anything.
            var edge = ""
            for (i, c) in m.edge.enumerated() { edge += (i == 0 ? "M" : "L") + String(format: "%.2f,%.2f ", Double(c.x), Double(c.y)) }
            edge += "Z"
            line(edge, Theme.brush(0, 0.28), 2)
            line(edge, Theme.brush(0xFFFFFF, 0.9), 1)
            // The layer's own outline, which cuts the picture off.
            line(m.outline, Theme.brush(Theme.selection), 1.5)
            // Where the picture's middle caught on the layer's.
            if let guides = m.guides { line(guides, Theme.brush(Theme.selection), 1) }
            // Crop marks: white on a dark edge, with a soft shadow, over a light table and a dark
            // picture alike.
            line(m.crops, Theme.brush(0, 0.1), 8, round: true)
            line(m.crops, Theme.brush(0, 0.3), 5, round: true)
            line(m.crops, Theme.brush(0xFFFFFF), 3, round: true)
            pictureMarks.children.append(group)
        }
        for k in pictureGhosts.indices where !used.contains(k) { pictureGhosts[k].image.visibility = .collapsed }
        tickPictures()
    }

    /// Frame by frame while placing fades in or out, or the picture springs back to rest.
    private func tickPictures() {
        guard pictureTicking == nil, pictures.animating else { return }
        pictureTicking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pictures.step()
                self.drawPictures()
                if !self.pictures.animating {
                    self.pictureTicking?.dispose()
                    self.pictureTicking = nil
                    self.drawPictures()
                }
            }
        }
    }

    /// The depth tool sees the canvas as it is now.
    private func syncDepth() {
        depth.selection = session.selection
        depth.free = session.tool == .select && editing == nil && pen.editingPath == nil && session.mode == 0
        depth.zoom = CGFloat(zoom)
        depth.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// The layout grid's handles see the canvas as it is now.
    private func syncLayout() {
        layoutHand.selection = session.selection
        layoutHand.free = session.tool == .select && editing == nil && pen.editingPath == nil && session.mode == 0
        layoutHand.cardOpen = session.openCard == "Layout Grid"
        layoutHand.zoom = CGFloat(zoom)
        layoutHand.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// The word "Mask", where the Mac shows it: centred over all it is about, 12 above it (below
    /// it when that would leave the canvas), kept on the canvas.
    private func offerRect(_ offer: WindowsCore.MaskOffer) -> CGRect {
        try? offerChip.measure(Size(width: 400, height: 28))
        let w = Double(offerChip.desiredSize.width)
        let o = onStage(offer.box.origin)
        let r = CGRect(x: Double(o.x), y: Double(o.y), width: Double(offer.box.width) * zoom, height: Double(offer.box.height) * zoom)
        var x = (Double(r.midX) - w / 2).rounded(), y = (Double(r.minY) - 28 - 12).rounded()
        let top = WindowsCore.showsRulers ? 8 + Double(WindowsCore.Guides.rulerSize) : 8
        if y < top { y = (Double(r.maxY) + 12).rounded() }
        x = min(max(x, 8), max(8, root.actualWidth - w - 8))
        return CGRect(x: x, y: y, width: w, height: 28)
    }

    /// Shows the word offered, when there is one for what is picked, and nothing else is under way.
    private func placeOffer() {
        if !holds(overlay, offerChip) { overlay.children.append(offerChip) }
        let free = session.tool == .select && editing == nil && pen.editingPath == nil && !builder.active && drag == nil
        let offer = free ? WindowsCore.maskOffer(session.selection) : nil
        if offer != shownOffer, offerLit, let was = shownOffer {
            offerLit = false
            maskMarks.previewEnded()
            WindowsCore.previewOffer(was, false)
            session.previewed(board: nil)
        }
        shownOffer = offer
        // A new word springs in; one going away shrinks back into the shape, as the Mac's MaskTool
        // has it. Another offer while one shows moves the word there.
        if offer != offerKept {
            if offer != nil, offerKept == nil || offerShown.value < 0.05 { offerShown = DeckSpring(0) }
            offerKept = offer ?? offerKept
            offerShown.target = offer == nil ? 0 : 1
            if !offerShown.settled { offerTicker.start() }
        }
        layOffer()
    }

    /// The word where it is, as far as it has sprung: up out of the shape it is about from 85%
    /// of its size and 6 points lower, faded in as one piece; a point higher while pointed at.
    private func layOffer() {
        guard let kept = offerKept, offerShown.value > 0.01 else {
            offerChip.visibility = .collapsed
            if shownOffer == nil { offerKept = nil }
            return
        }
        let r = offerRect(kept)
        let k = offerShown.value
        let lifted = offerLit && shownOffer != nil
        try? Canvas.setLeft(offerChip, Double(r.minX))
        try? Canvas.setTop(offerChip, Double(r.minY))
        let s = 0.85 + 0.15 * k
        let t = CompositeTransform()
        t.centerX = Double(r.width) / 2
        t.centerY = Double(r.height)
        t.scaleX = s
        t.scaleY = s
        t.translateY = s * (6 * (1 - k) - (lifted ? 1 : 0))
        offerChip.renderTransform = t
        offerChip.opacity = min(1, max(k, 0))
        offerChip.background = lifted ? Theme.brush(0x3357C0) : Theme.brush(Theme.selection)
        offerChip.visibility = .visible
    }

    /// One frame of the word springing (the Mac's stiffness 300, damping 20).
    private func stepOffer(_ dt: Double) -> Bool {
        offerShown.step(dt, stiffness: 300, damping: 20)
        layOffer()
        return !offerShown.settled
    }

    /// As the Mac's ComponentTool: with a copy picked, every other copy of its component faintly
    /// dashed in violet, so what will change with it is in sight; and over the copy, at its top
    /// left, a diamond and the component's name, with the variant it shows.
    /// A change to a style running out as light over every layer that has it, as the Mac's
    /// WaveView: a faint front from where the change was made (or from the inspector's side), and
    /// each layer lighting up as it reaches it, the nearest first, then fading; a glow round the
    /// layer, not over it, so the change itself is what is seen.
    private func startWave(_ w: WindowsCore.StyleWave) {
        if !holds(overlay, waveMarks) {
            waveMarks.isHitTestVisible = false
            overlay.children.append(waveMarks)
        }
        waveMarks.children.clear()
        waveTick?.dispose()
        waveTick = nil
        let width = Double(stage.actualWidth), height = Double(stage.actualHeight)
        let o = w.origin.map { onStage($0) }
        let origin = (x: o.map { Double($0.x) } ?? width + 40, y: o.map { Double($0.y) } ?? height / 2)
        var glows: [(paths: [WinUI.Path], distance: Double)] = []
        for corners in WindowsCore.layerOutlines(w.layers) {
            let points = corners.map { onStage($0) }
            guard let first = points.first else { continue }
            var d = PathData()
            d.move(Double(first.x), Double(first.y))
            for p in points.dropFirst() { d.line(Double(p.x), Double(p.y)) }
            d.close()
            let xs = points.map { Double($0.x) }, ys = points.map { Double($0.y) }
            let x = min(max(origin.x, xs.min()!), xs.max()!), y = min(max(origin.y, ys.min()!), ys.max()!)
            var paths: [WinUI.Path] = []
            for (stroke, alpha) in [(12.0, 0.14), (5.0, 0.22), (1.5, 0.9)] {
                guard let path = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='\(stroke)' StrokeLineJoin='Round'/>")) as? WinUI.Path else { continue }
                path.stroke = Theme.brush(Theme.pencil, alpha)
                path.opacity = 0
                waveMarks.children.append(path)
                paths.append(path)
            }
            glows.append((paths, hypot(x - origin.x, y - origin.y)))
        }
        // However far apart the layers lie, the last is reached within 0.55 seconds.
        let speed = 1500.0, longest = 0.55, rise = 0.11, fall = 0.62
        let far = glows.map(\.distance).max() ?? 0
        let k = far / speed > longest ? longest / (far / speed) : 1
        let delays = glows.map { $0.distance / speed * k }
        let pace = speed * (far > 0 ? max(1, far / speed / longest) : 1)
        let end = (delays.max() ?? 0) + rise + fall
        let reach = hypot(max(origin.x, width - origin.x), max(origin.y, height - origin.y))
        var rings: [Ellipse] = []
        for (stroke, alpha) in [(14.0, 0.05), (1.5, 0.16)] {
            let ring = Ellipse()
            ring.stroke = Theme.brush(Theme.pencil, alpha)
            ring.strokeThickness = stroke
            ring.isHitTestVisible = false
            waveMarks.children.append(ring)
            rings.append(ring)
        }
        func glow(_ t: Double) -> Double {
            if t <= 0 { return 0 }
            if t < rise { let u = t / rise; return 1 - (1 - u) * (1 - u) }
            let u = (t - rise) / fall
            return u >= 1 ? 0 : pow(1 - u, 2.2)
        }
        // The artboards as they looked before, ahead of the front: the change comes in behind it,
        // as paint washing over them.
        for e in washImages { removeFromStage(e) }
        washImages = []
        let visible = CGRect(origin: inDesign(.zero), size: CGSize(width: width / zoom, height: height / zoom))
        let wash = WindowsCore.styleWash(w, visible: visible, scale: zoom * pixelScale)
        var washBitmaps: [WriteableBitmap?] = []
        if let wash {
            for rect in wash.rects {
                let image = Image()
                image.stretch = .fill
                image.isHitTestVisible = false
                let o = onStage(rect.origin)
                try? Canvas.setLeft(image, Double(o.x))
                try? Canvas.setTop(image, Double(o.y))
                image.width = Double(rect.width) * zoom
                image.height = Double(rect.height) * zoom
                stage.children.append(image)
                washImages.append(image)
                washBitmaps.append(nil)
            }
        }
        let washOrigin = w.origin ?? inDesign(CGPoint(x: origin.x, y: origin.y))
        waveToken += 1
        let token = waveToken, start = WindowsCore.now
        func step() {
            guard token == waveToken else { return }
            let t = WindowsCore.now - start
            let r = max(t, 0) * pace
            if let wash {
                let rc = BezzleCore.CGFloat(r / zoom), edge = BezzleCore.CGFloat(36 / zoom)
                for (k, image) in washImages.enumerated() where image.visibility == .visible {
                    guard wash.ahead(k, origin: washOrigin, radius: rc - edge) else {
                        image.visibility = .collapsed
                        continue
                    }
                    var bitmap = washBitmaps[k]
                    _ = wash.draw(k, origin: washOrigin, radius: rc, edge: edge) { bw, bh in
                        if bitmap == nil || bitmap!.pixelWidth != Int32(bw) || bitmap!.pixelHeight != Int32(bh) { bitmap = WriteableBitmap(Int32(bw), Int32(bh)) }
                        return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
                    }
                    try? bitmap?.invalidate()
                    if washBitmaps[k] !== bitmap { image.source = bitmap }
                    washBitmaps[k] = bitmap
                }
            }
            for ring in rings {
                ring.visibility = r < reach ? .visible : .collapsed
                ring.width = 2 * r
                ring.height = 2 * r
                ring.opacity = max(0, 1 - r / reach)
                try? Canvas.setLeft(ring, origin.x - r)
                try? Canvas.setTop(ring, origin.y - r)
            }
            for (g, delay) in zip(glows, delays) {
                let lit = glow(t - delay)
                for path in g.paths { path.opacity = lit }
            }
            if t > end + 0.05 {
                waveMarks.children.clear()
                for e in washImages { removeFromStage(e) }
                washImages = []
                waveTick?.dispose()
                waveTick = nil
            }
        }
        step()
        waveTick = CompositionTarget.rendering.addHandler { _, _ in MainActor.assumeIsolated { step() } }
    }

    /// Whether the style outlines show, and how far they have faded in or out.
    private var stylesShown = false
    private var styleFade: (from: Double, to: Double, elapsed: Double)?
    private lazy var styleTicker = Motion.Ticker { [weak self] dt in self?.stepStyleFade(dt) ?? false }

    private func fadeStyles(to target: Double) {
        styleFade = (Double(styleMarks.opacity), target, 0)
        styleTicker.start()
    }

    private func stepStyleFade(_ dt: Double) -> Bool {
        guard var f = styleFade else { return false }
        f.elapsed += dt
        let k = min(f.elapsed / 0.16, 1)
        styleMarks.opacity = f.from + (f.to - f.from) * Motion.easeOut(k)
        styleFade = k < 1 ? f : nil
        // Faded out: gone.
        if k >= 1, f.to == 0 { styleMarks.children.clear() }
        return k < 1
    }

    /// Every layer that uses the style pointed at in the inspector, outlined in pencil.
    private func drawStyleUsers() {
        if !holds(overlay, styleMarks) {
            styleMarks.isHitTestVisible = false
            overlay.children.append(styleMarks)
        }
        // Coming and going, the outlines fade, as the Mac's do (ease out, 0.16 s); while they
        // show, they follow what is pointed at at once.
        guard session.mode == 0, session.pointedStyle != nil || !session.litLayers.isEmpty else {
            if stylesShown {
                stylesShown = false
                fadeStyles(to: 0)
            }
            return
        }
        styleMarks.children.clear()
        if !stylesShown {
            stylesShown = true
            // From nothing, or from as far as fading out had gone.
            if styleFade == nil { styleMarks.opacity = 0 }
            fadeStyles(to: 1)
        }
        var lines = PathData()
        let outlines = session.pointedStyle.map { WindowsCore.styleUserOutlines($0) } ?? []
        for corners in outlines + WindowsCore.layerOutlines(session.litLayers) {
            guard let first = corners.first else { continue }
            let a = onStage(first)
            lines.move(Double(a.x), Double(a.y))
            for p in corners.dropFirst() { let q = onStage(p); lines.line(Double(q.x), Double(q.y)) }
            lines.close()
        }
        guard !lines.d.isEmpty else { return }
        for (width, alpha, filled) in [(5.0, 0.2, true), (1.25, 0.9, false)] {
            if let path = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(lines.d)' StrokeThickness='\(width)' StrokeLineJoin='Round'/>")) as? WinUI.Path {
                path.stroke = Theme.brush(Theme.pencil, alpha)
                if filled { path.fill = Theme.brush(Theme.pencil, 0.08) }
                styleMarks.children.append(path)
            }
        }
    }

    private func drawComponents() {
        if !holds(overlay, componentMarks) {
            componentMarks.isHitTestVisible = false
            // The copies as they were under the dashed outlines; the light and the row over them.
            overlay.children.append(copyMarks.ghosts)
            overlay.children.append(componentMarks)
            overlay.children.append(copyMarks.lights)
            overlay.children.append(copyMarks.row)
        }
        // What a change just did to copies, run out as light from where it was made.
        copyMarks.take()
        copyMarks.draw()
        drawCopyOutlines()
    }

    /// The other copies of the one picked, dashed, and its component's name over it.
    private func drawCopyOutlines() {
        componentMarks.children.clear()
        guard session.tool == .select, !builder.active, session.mode == 0 else { return }
        var lines = PathData()
        // A copy the light is on shows that, rather than its dashed outline.
        for (id, corners) in WindowsCore.otherCopiesByID(session.selection) where !copyMarks.isLit(id) {
            guard let first = corners.first else { continue }
            let a = onStage(first)
            lines.move(Double(a.x).rounded() + 0.5, Double(a.y).rounded() + 0.5)
            for p in corners.dropFirst() { let q = onStage(p); lines.line(Double(q.x).rounded() + 0.5, Double(q.y).rounded() + 0.5) }
            lines.close()
        }
        if !lines.d.isEmpty,
           let path = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(lines.d)' StrokeThickness='1' StrokeDashArray='3 3'/>")) as? WinUI.Path {
            path.stroke = Theme.brush(Theme.linked, 0.42)
            componentMarks.children.append(path)
        }
        guard editing == nil, let tag = WindowsCore.copyTag(session.selection), Double(tag.width) * zoom > 36 else { return }
        let o = onStage(tag.at)
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 5
        let diamond = Glyphs.view(Glyphs.diamond(size: 8), size: 8, brush: Theme.brush(Theme.linked))
        diamond.verticalAlignment = .center
        row.children.append(diamond)
        // The variant's name after the dot, as the model made it (a default one in English).
        let parts = tag.text.components(separatedBy: "  \u{00B7}  ")
        let words = Theme.text(parts.count == 2 ? parts[0] + "  \u{00B7}  " + Words.match(parts[1]) : tag.text, size: 10.5, weight: 500)
        words.foreground = Theme.brush(Theme.linked)
        row.children.append(words)
        try? row.measure(Size(width: 600, height: 30))
        try? Canvas.setLeft(row, Double(o.x).rounded() + 1)
        try? Canvas.setTop(row, (Double(o.y) - Double(row.desiredSize.height) - 4).rounded())
        componentMarks.children.append(row)
    }

    /// Shows an offer after a change to a copy, for 8 seconds, unless another comes first.
    private func showCopyOffer(_ offer: WindowsCore.CopyOffer) {
        copyOffer = offer
        let token = offer.token
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.copyOffer?.token == token else { return }
                self.copyOffer = nil
                WindowsCore.dropCopyOffer()
                self.placeCopyOffer()
            }
        }
        placeCopyOffer()
    }

    /// The offer beside the copy it is about, where it covers nothing of it; else under it. Only
    /// while that copy is what is picked, and nothing is being typed or dragged.
    private func placeCopyOffer() {
        if !holds(overlay, copyChip) {
            copyChip.height = 28
            copyChip.cornerRadius = Theme.corners(14)
            copyChip.background = Theme.brush(Theme.card)
            copyChip.borderBrush = Theme.brush(Theme.ink, 0.12)
            copyChip.borderThickness = Theme.inset(0.5)
            copyChip.isHitTestVisible = false
            overlay.children.append(copyChip)
        }
        copyButtons = []
        guard let offer = copyOffer, drag == nil, editing == nil,
              WindowsCore.componentLook(session.selection)?.copy == offer.anchor || session.selection.contains(offer.anchor),
              // On the canvas, not in its artboard as the Frame card counts (selectionFrame):
              // else the word lands off screen for anything on an artboard away from the origin.
              let frame = WindowsCore.bounds(of: [offer.anchor]) else {
            copyChip.visibility = .collapsed
            copyHovered = nil
            if copyLit {
                copyLit = false
                session.litLayers = []
            }
            return
        }
        let row = StackPanel()
        row.orientation = .horizontal
        row.spacing = 4
        row.margin = Theme.inset(12, 0, 4, 0)
        row.verticalAlignment = .center
        let words = Theme.text(Words.match(offer.words), size: 11.5, ink: 2)
        words.verticalAlignment = .center
        words.margin = Theme.inset(0, 0, 6, 0)
        row.children.append(words)
        var pills: [Border] = []
        for (i, title) in offer.buttons.enumerated() {
            let pill = Border()
            pill.height = 20
            pill.cornerRadius = Theme.corners(10)
            // A component's offer in the violet of copies; a style's in the pencil's blue.
            let tint = offer.style ? Theme.pencil : Theme.linked
            // Pointed at, the filled one darker and the others' wash deeper, as on the Mac.
            let pointed = copyHovered == i
            pill.background = i == 0 ? Theme.brush(pointed ? Theme.mix(tint, 0, 0.15) : tint) : Theme.brush(tint, pointed ? 0.16 : 0.08)
            let label = Theme.text(Words.match(title), size: 11.5, weight: 600)
            label.foreground = i == 0 ? Theme.brush(0xFFFFFF) : Theme.brush(tint)
            label.margin = Theme.inset(9, 0, 9, 0)
            label.verticalAlignment = .center
            pill.child = label
            row.children.append(pill)
            pills.append(pill)
        }
        copyChip.child = row
        try? copyChip.measure(Size(width: 800, height: 28))
        let w = Double(copyChip.desiredSize.width)
        let o = onStage(frame.origin)
        let r = CGRect(x: Double(o.x), y: Double(o.y), width: Double(frame.width) * zoom, height: Double(frame.height) * zoom)
        var x = (Double(r.maxX) + 14).rounded(), y = (Double(r.midY) - 14).rounded()
        if let row = copyMarks.layout(), let first = row.cards.first,
           row.look.copy == offer.anchor || WindowsCore.componentLook(session.selection)?.copy == row.look.copy {
            // Under the row of variants beside the copy, or under the copy and the row under it.
            if row.beside {
                x = Double(first.minX)
                y = (Double(first.maxY) + 10).rounded()
            } else {
                x = (Double(r.midX) - w / 2).rounded()
                y = (Double(first.maxY) + 12).rounded()
            }
        } else if x + w > root.actualWidth - 8 {
            x = min(max((Double(r.midX) - w / 2).rounded(), 8), max(8, root.actualWidth - w - 8))
            y = (Double(r.maxY) + 12).rounded()
        }
        try? Canvas.setLeft(copyChip, x)
        try? Canvas.setTop(copyChip, y)
        copyChip.visibility = .visible
        // Where each button is on the stage, for a press there.
        var left = x + 12 + Double(words.desiredSize.width) + 4
        for (i, pill) in pills.enumerated() {
            let pw = Double(pill.desiredSize.width)
            copyButtons.append((CGRect(x: left, y: y + 4, width: pw, height: 20), i))
            left += pw + 4
        }
    }

    /// The pointer over an offer's buttons: the one under it darkens, and a style's outlines on
    /// the canvas the layers it is about (the Mac's OfferChip lighting `offer.layers`).
    private func pointCopyOffer(at p: CGPoint) {
        let over = copyButtons.first { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }?.index
        guard over != copyHovered else { return }
        copyHovered = over
        placeCopyOffer()
        let layers = over != nil && copyOffer?.style == true ? WindowsCore.styleOfferLayers : []
        if !layers.isEmpty {
            copyLit = true
            session.litLayers = layers
        } else if copyLit {
            copyLit = false
            session.litLayers = []
        }
    }

    /// Whether `p` on the stage is on the word offered.
    private func onOffer(_ p: CGPoint) -> Bool {
        guard let offer = shownOffer else { return false }
        return offerRect(offer).insetBy(dx: -2, dy: -2).contains(p)
    }

    // MARK: Holding a drag over a shape

    /// What is moved has been dragged to `p` on the stage: held still a moment over a shape that
    /// would cut it off, the shape opens and takes it in; dragged off the shape it opened, the
    /// shape closes again, and does not open again in the same drag.
    private func dipMoved(at p: CGPoint) {
        var d = dip ?? Dip()
        let ids = session.selection
        if let opened = d.opened {
            // Inside it still, what it holds moves inside it.
            if WindowsCore.onDip(opened.mask, at: inDesign(p), slop: CGFloat(12 / zoom)) { dip = d; return }
            // Off it, it closes: its outline runs out once, as it was.
            maskMarks.closed(opened.mask)
            WindowsCore.closeDip()
            d.opened = nil
            d.declined.insert(opened.shape)
            d.over = nil
            d.ready = false
            dip = d
            drawDip()
            return
        }
        let over = WindowsCore.dipTarget(at: inDesign(p), moving: ids)
        let wandered = hypot(Double(p.x) - Double(d.at.x), Double(p.y) - Double(d.at.y)) > Self.dipWander
        if over != d.over || wandered {
            d.over = over
            d.at = p
            d.since = WindowsCore.now
            d.ready = over.map { !d.declined.contains($0) && WindowsCore.canDip(ids, over: $0) } == true
            d.rest += 1
            if d.ready, let over {
                let rest = d.rest
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.dipRest * MaskMarks.slow) { [weak self] in
                    MainActor.assumeIsolated { self?.dipOpens(over, rest: rest) }
                }
            }
        }
        d.leaving = WindowsCore.leavingMask(ids)
        dip = d
        drawDip()
    }

    /// The shape rested on, the rest not broken since: it opens, and what is moved goes into it.
    private func dipOpens(_ over: UUID, rest: Int) {
        guard var d = dip, d.rest == rest, d.over == over, d.ready, d.opened == nil,
              case .move? = drag?.grab, drag?.moved == true else { return }
        guard let mask = WindowsCore.openDip(session.selection, over: over) else { return }
        d.opened = (over, mask)
        dip = d
        session.edited(board: nil)
        // What reaches past the shape was showing whole a moment ago: it fades from there, and
        // the shape glows open.
        maskMarks.opened(holding: session.selection)
        drawDip()
    }

    /// What resting over a shape shows, as the Mac's MaskTool draws it: a line run round the
    /// shape waited on as the moment passes, the shape opened glowing, what it cuts off a ghost,
    /// and its name under it (`MaskMarks`).
    private func drawDip() {
        maskMarks.update()
    }

    /// The outline's dots and edge see the canvas as it is now.
    private func syncOutline() {
        outlineHand.follow(session.selection)
        outlineHand.free = session.tool == .select && editing == nil && pen.editingPath == nil && !builder.active && session.mode == 0
        outlineHand.zoom = CGFloat(zoom)
        outlineHand.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// A selected path's corner dots, while the pointer is on it, and a shape's edge lit with Alt
    /// over it, as the Mac's OutlineTool draws them.
    private func drawOutline() {
        if !holds(overlay, outlineMarks) {
            outlineMarks.isHitTestVisible = false
            overlay.children.append(outlineMarks)
        }
        outlineMarks.children.clear()
        syncOutline()
        let m = outlineHand.marks()
        if let edge = m.edge, !edge.isEmpty,
           let path = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(edge)' StrokeThickness='2'/>")) as? WinUI.Path {
            path.stroke = Theme.brush(Theme.selection)
            outlineMarks.children.append(path)
        }
        for p in m.dots {
            let x = Double(p.x).rounded(), y = Double(p.y).rounded()
            let shade = Ellipse()
            shade.width = 8
            shade.height = 8
            shade.fill = Theme.brush(0, 0.18)
            try? Canvas.setLeft(shade, x - 4)
            try? Canvas.setTop(shade, y - 3.5)
            outlineMarks.children.append(shade)
            let dot = Ellipse()
            dot.width = 7
            dot.height = 7
            dot.fill = Theme.brush(0xFFFFFF)
            dot.stroke = Theme.brush(Theme.selection)
            dot.strokeThickness = 1
            try? Canvas.setLeft(dot, x - 3.5)
            try? Canvas.setTop(dot, y - 3.5)
            outlineMarks.children.append(dot)
        }
    }

    /// Building with pieces sees the canvas as it is now.
    private func syncBuild() {
        builder.zoom = CGFloat(zoom)
        builder.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// The pieces of the shapes being built with, as the Mac's ShapeBuilder draws them: the one
    /// under the pointer, or those the drag has touched, tinted; every piece's edge, faint and
    /// dashed but for those; the way the drag has gone. Wiping away in red, joining in blue.
    private func drawBuild() {
        if !holds(overlay, buildMarks) {
            buildMarks.isHitTestVisible = false
            overlay.children.append(buildMarks)
        }
        buildMarks.children.clear()
        guard builder.active else { return }
        syncBuild()
        let m = builder.marks()
        let ink: UInt32 = m.erasing ? 0xE04A33 : Theme.selection
        func shape(_ data: String, width: Double, dash: String? = nil) -> WinUI.Path? {
            guard !data.isEmpty else { return nil }
            let dashes = dash.map { " StrokeDashArray='\($0)'" } ?? ""
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='\(width)' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'\(dashes)/>"
            return (try? XamlReader.load(xaml)) as? WinUI.Path
        }
        for piece in m.pieces where piece.lit {
            guard let path = shape(piece.data, width: 0) else { continue }
            path.fill = Theme.brush(ink, m.erasing ? 0.28 : 0.22)
            buildMarks.children.append(path)
        }
        for piece in m.pieces {
            guard let path = shape(piece.data, width: 1, dash: piece.lit ? nil : "3 2") else { continue }
            path.stroke = piece.lit ? Theme.brush(ink) : Theme.brush(Theme.selection, 0.55)
            buildMarks.children.append(path)
        }
        if m.trail.count > 1 {
            var way = PathData()
            way.move(Double(m.trail[0].x), Double(m.trail[0].y))
            for p in m.trail.dropFirst() { way.line(Double(p.x), Double(p.y)) }
            if let path = shape(way.d, width: 2) {
                path.stroke = Theme.brush(ink, 0.9)
                buildMarks.children.append(path)
            }
        }
    }

    /// The selection made a component, of which it is then the first copy (Ctrl+Alt+K, as ⌥⌘K).
    private func makeComponent() {
        guard let made = WindowsCore.makeComponent(session.selection) else { MessageBeep(0); return }
        session.select([made.copy], on: WindowsCore.board(of: made.copy) ?? session.board)
        session.showCard?("Component")
        session.edited(board: nil)
        // Other groups that look the same are offered to be linked to it.
        if let offer = WindowsCore.offerLinking(made.copy, made.lookAlikes) { showCopyOffer(offer) }
    }

    /// Building with the selected shapes' pieces started, or done (Ctrl+Alt+B, as ⌥⌘B on the Mac).
    private func toggleBuild() {
        if builder.active {
            builder.building = nil
        } else if session.selection.count > 1, WindowsCore.canCombine(session.selection) {
            // As the Mac opens Arrange when building starts, where its Build button is lit.
            session.showCard?("Arrange")
            builder.start(session.selection)
        } else {
            MessageBeep(0)
        }
    }

    /// The prototype's hand sees the canvas as it is now.
    private func syncFlow() {
        flow.selection = session.selection
        flow.zoom = CGFloat(zoom)
        flow.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// The prototype as the Mac's FlowTool draws it: threads in pencil over the paper's white edge,
    /// brighter when picked or pointed at, dashed for going back, arrowheads, notes on paper tags,
    /// the start flag, the layer a thread comes out of with its knob, and while a thread is pulled,
    /// the screens it could go to and the well to go back.
    private func drawFlow() {
        if !holds(overlay, flowMarks) {
            flowMarks.isHitTestVisible = false
            overlay.children.append(flowMarks)
        }
        flowMarks.children.clear()
        // Seen as a prototype, and a moment longer as the threads draw back into their layers.
        guard flow.showing else {
            if session.mode == 0, !paper.children.isEmpty { drawPaper() }
            paper.opacity = 1
            return
        }
        syncFlow()
        let m = flow.marks()
        flowMarks.opacity = m.alpha
        // The paper's ruling comes and goes with the threads; inspected, it simply is.
        if session.mode == 0, paper.children.isEmpty { drawPaper() }
        paper.opacity = session.mode == 2 ? 1 : m.alpha
        let dark = Theme.dark
        let thread: UInt32 = dark ? 0x8FA8F2 : 0x3A63D8, bright: UInt32 = dark ? 0xC2D1FF : 0x2347B8, cut: UInt32 = dark ? 0xE4705C : 0xB3402F
        let casing: UInt32 = dark ? 0x101114 : 0xFFFFFF, plate: UInt32 = dark ? 0x2A2926 : 0xFFFEFB
        func xamlPath(_ data: String, width: Double, dash: String? = nil) -> WinUI.Path? {
            let dashes = dash.map { " StrokeDashArray='\($0)'" } ?? ""
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='\(width)' StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'\(dashes)/>"
            return (try? XamlReader.load(xaml)) as? WinUI.Path
        }
        func add(_ e: UIElement) { flowMarks.children.append(e) }
        func ring(_ r: CGRect, width: Double, ink: UInt32, alpha: Double, radius: Double, dash: String? = nil) {
            let rect = Rectangle()
            rect.width = Double(r.width)
            rect.height = Double(r.height)
            rect.radiusX = radius
            rect.radiusY = radius
            rect.stroke = Theme.brush(ink, alpha)
            rect.strokeThickness = width
            if let dash {
                let d = DoubleCollection()
                for part in dash.split(separator: " ") { d.append(Double(part) ?? 3) }
                rect.strokeDashArray = d
            }
            try? Canvas.setLeft(rect, Double(r.minX))
            try? Canvas.setTop(rect, Double(r.minY))
            add(rect)
        }
        // The screens it could go to, lifting while a thread is pulled; the one picked, outlined.
        for s in m.lifted {
            if s.on { ring(s.rect.insetBy(dx: -3, dy: -3), width: 6, ink: thread, alpha: 0.18, radius: 9) }
            ring(s.rect, width: s.on ? 2.5 : 1, ink: s.on ? bright : thread, alpha: s.on ? 1 : 0.4, radius: 7)
        }
        for s in m.screens { ring(s.rect, width: s.width, ink: s.bright ? bright : thread, alpha: s.bright ? 0.7 : 1, radius: s.bright ? 6 : 5) }
        // A screen a thread was just tied to, ringing once: its glow, then the ring.
        if let a = m.answer {
            ring(a.rect.insetBy(dx: -3, dy: -3), width: a.width + 6, ink: thread, alpha: 0.16 * a.alpha, radius: a.radius + 3)
            ring(a.rect, width: a.width, ink: bright, alpha: a.alpha, radius: a.radius)
        }
        for t in m.threads {
            let width = t.bright ? 2.6 : 1.8
            let dash = t.dashed ? "2.8 2.2" : nil
            if let under = xamlPath(t.curve.data, width: width + 3) {
                under.stroke = Theme.brush(casing, (dark ? 0.9 : 0.95) * t.alpha)
                add(under)
            }
            if t.bright, let glow = xamlPath(t.curve.data, width: width + 6) {
                glow.stroke = Theme.brush(thread, 0.18 * t.alpha)
                add(glow)
            }
            if let line = xamlPath(t.curve.data, width: width, dash: dash) {
                line.stroke = Theme.brush(t.cut ? cut : t.bright ? bright : thread, t.alpha)
                add(line)
            }
        }
        for a in m.arrows {
            let l = a.bright ? 8.0 : 7.0, x = Double(a.at.x), y = Double(a.at.y)
            var d = PathData()
            d.move(x - l * cos(a.angle - 0.55), y - l * sin(a.angle - 0.55))
            d.line(x, y)
            d.line(x - l * cos(a.angle + 0.55), y - l * sin(a.angle + 0.55))
            if let head = xamlPath(d.d, width: a.bright ? 2.6 : 2) {
                head.stroke = Theme.brush(a.bright ? bright : thread)
                add(head)
            }
        }
        for dot in m.dots {
            let e = Ellipse()
            e.width = 6.4
            e.height = 6.4
            e.fill = Theme.brush(dot.bright ? bright : thread)
            try? Canvas.setLeft(e, Double(dot.at.x) - 3.2)
            try? Canvas.setTop(e, Double(dot.at.y) - 3.2)
            add(e)
        }
        for n in m.notes {
            let tag = Border()
            tag.width = Double(n.rect.width)
            tag.height = Double(n.rect.height)
            tag.cornerRadius = Theme.corners(5)
            tag.background = Theme.brush(plate)
            tag.borderBrush = n.bright ? Theme.brush(thread) : Theme.brush(Theme.ink, dark ? 0.14 : 0.12)
            tag.borderThickness = Theme.inset(n.bright ? 1 : 0.5)
            let text = TextBlock()
            text.text = n.text
            text.fontFamily = FontFamily("Segoe Print")
            text.fontSize = 12
            text.foreground = Theme.brush(dark ? 0xB9C9FA : 0x2F4FB5)
            text.textTrimming = .characterEllipsis
            text.horizontalAlignment = .center
            text.verticalAlignment = .center
            text.margin = Theme.inset(9, 0, 9, 0)
            tag.child = text
            try? Canvas.setLeft(tag, Double(n.rect.minX))
            try? Canvas.setTop(tag, Double(n.rect.minY))
            add(tag)
        }
        for t in m.timers {
            let pill = Border()
            pill.height = 16
            pill.cornerRadius = Theme.corners(8)
            pill.background = Theme.brush(plate)
            pill.padding = Theme.inset(6, 0, 6, 0)
            let text = Theme.text("◷ " + t.text, size: 10, weight: 600)
            text.foreground = Theme.brush(dark ? 0xB9C9FA : 0x2F4FB5)
            text.verticalAlignment = .center
            pill.child = text
            try? Canvas.setLeft(pill, Double(t.at.x))
            try? Canvas.setTop(pill, Double(t.at.y))
            add(pill)
        }
        // The layer pointed at and those picked, with the knob a thread comes out of.
        for o in m.outlines {
            ring(o.rect, width: o.width, ink: thread, alpha: 1, radius: 4)
            if o.knob {
                let k = (x: Double(o.rect.maxX), y: Double(o.rect.midY))
                let knob = Ellipse()
                knob.width = 12
                knob.height = 12
                knob.fill = Theme.brush(thread)
                try? Canvas.setLeft(knob, k.x - 6)
                try? Canvas.setTop(knob, k.y - 6)
                add(knob)
                var plus = PathData()
                plus.move(k.x - 2.6, k.y); plus.line(k.x + 2.6, k.y)
                plus.move(k.x, k.y - 2.6); plus.line(k.x, k.y + 2.6)
                if let p = xamlPath(plus.d, width: 1.6) {
                    p.stroke = Theme.brush(0xFFFFFF)
                    add(p)
                }
            }
        }
        // The flags: a ribbon of pencil out of a screen's side, notched at its free end, with the
        // triangle of play; a ghost of one dashed.
        for f in m.flags {
            let r = f.rect, notch = 6.0
            var d = PathData()
            d.move(Double(r.minX), Double(r.minY))
            d.line(Double(r.maxX) - 3, Double(r.minY))
            d.quad(Double(r.maxX), Double(r.minY), Double(r.maxX), Double(r.minY) + 3)
            d.line(Double(r.maxX), Double(r.maxY) - 3)
            d.quad(Double(r.maxX), Double(r.maxY), Double(r.maxX) - 3, Double(r.maxY))
            d.line(Double(r.minX), Double(r.maxY))
            d.line(Double(r.minX) + notch, Double(r.midY))
            d.close()
            if let ribbon = xamlPath(d.d, width: f.ghost ? 1.2 : 0, dash: f.ghost ? "2.5 2" : nil) {
                if f.ghost { ribbon.stroke = Theme.brush(thread, f.alpha) } else { ribbon.fill = Theme.brush(Theme.dark ? 0x8FA8F2 : 0x3A63D8, f.alpha) }
                if f.lifted { ribbon.translation = Vector3(x: 0, y: -2, z: 0) }
                add(ribbon)
            }
            let c = (x: Double(r.midX) + 2, y: Double(r.midY))
            var tri = PathData()
            tri.move(c.x - 3.5, c.y - 5); tri.line(c.x + 5, c.y); tri.line(c.x - 3.5, c.y + 5); tri.close()
            if let play = xamlPath(tri.d, width: 0) {
                play.fill = Theme.brush(f.ghost ? thread : 0xFFFFFF, f.alpha)
                add(play)
            }
        }
        // The well to drop a thread in to go back.
        if let well = m.well {
            let e = Ellipse()
            e.width = Double(well.rect.width)
            e.height = Double(well.rect.height)
            e.fill = Theme.brush(plate)
            e.stroke = Theme.brush(well.on ? bright : thread)
            e.strokeThickness = well.on ? 2.2 : 1.3
            if !well.on {
                let d = DoubleCollection()
                d.append(2.3)
                d.append(2.3)
                e.strokeDashArray = d
            }
            try? Canvas.setLeft(e, Double(well.rect.minX))
            try? Canvas.setTop(e, Double(well.rect.minY))
            add(e)
            let c = (x: Double(well.rect.midX), y: Double(well.rect.midY)), u = Double(well.rect.width) / 40
            var hook = PathData()
            hook.move(c.x + 7 * u, c.y + 6 * u)
            hook.cubic(c.x + 8 * u, c.y - 4 * u, c.x, c.y - 3 * u, c.x - 6 * u, c.y - 2 * u)
            hook.move(c.x - 2 * u, c.y - 6.5 * u); hook.line(c.x - 6.5 * u, c.y - 2 * u); hook.line(c.x - 2 * u, c.y + 2.5 * u)
            if let p = xamlPath(hook.d, width: 1.8) {
                p.stroke = Theme.brush(well.on ? bright : thread)
                add(p)
            }
        }
        // Beads of light: the end of a thread in the hand.
        for light in m.lights {
            let s = light.size
            let glow = Ellipse()
            glow.width = s * 2.4
            glow.height = s * 2.4
            glow.fill = Theme.brush(thread, 0.22)
            try? Canvas.setLeft(glow, Double(light.at.x) - s * 1.2)
            try? Canvas.setTop(glow, Double(light.at.y) - s * 1.2)
            add(glow)
            let bead = Ellipse()
            bead.width = s
            bead.height = s
            bead.fill = Theme.brush(thread)
            try? Canvas.setLeft(bead, Double(light.at.x) - s / 2)
            try? Canvas.setTop(bead, Double(light.at.y) - s / 2)
            add(bead)
            let core = Ellipse()
            core.width = s * 0.38
            core.height = s * 0.38
            core.fill = Theme.brush(0xFFFFFF)
            try? Canvas.setLeft(core, Double(light.at.x) - s * 0.19)
            try? Canvas.setTop(core, Double(light.at.y) - s * 0.19)
            add(core)
        }
        if flow.animating, !flowTicking {
            flowTicking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                MainActor.assumeIsolated {
                    self?.flowTicking = false
                    self?.drawFlow()
                }
            }
        }
    }

    /// A note written on a thread, where it hangs: a field there, Enter keeps what is typed and
    /// Escape lets it be.
    private func beginNote(on id: UUID, at p: CGPoint) {
        if !holds(overlay, noteBox) {
            noteBox.width = 220
            noteBox.fontFamily = FontFamily("Segoe Print")
            noteBox.fontSize = 13
            noteBox.placeholderText = Words.t("Write a Note")
            overlay.children.append(noteBox)
            noteBox.keyDown.addHandler { [weak self] _, args in
                guard let self, let args else { return }
                if args.key == .enter {
                    args.handled = true
                    if let id = self.noteFor { WindowsCore.setFlowNote(self.noteBox.text, for: [id]) }
                    self.endNote()
                } else if args.key == .escape {
                    args.handled = true
                    self.endNote()
                }
            }
            noteBox.lostFocus.addHandler { [weak self] _, _ in self?.endNote() }
        }
        noteFor = id
        noteBox.text = WindowsCore.flowNote(id) ?? ""
        noteBox.visibility = .visible
        try? Canvas.setLeft(noteBox, Double(p.x) - 110)
        try? Canvas.setTop(noteBox, Double(p.y) - 34)
        _ = try? noteBox.focus(.programmatic)
        try? noteBox.selectAll()
    }

    private func endNote() {
        guard noteFor != nil else { return }
        noteFor = nil
        noteBox.visibility = .collapsed
        session.edited(board: nil)
        takeKeys()
    }

    /// The inspecting hand sees the canvas as it is now.
    private func syncInspect() {
        inspect.selection = session.selection
        inspect.zoom = CGFloat(zoom)
        inspect.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// What is inspected, measured as the Mac's InspectTool draws it: outlines in pencil, or the
    /// gaps' pink, lines over a casing of white, dashed reaches, hatched gaps, and numbers on pills.
    private func drawInspect() {
        if !holds(overlay, inspectMarks) {
            inspectMarks.isHitTestVisible = false
            overlay.children.append(inspectMarks)
        }
        inspectMarks.children.clear()
        guard inspecting else { return }
        syncInspect()
        let m = inspect.marks()
        // Each mark grows in from its middle when what is shown changes, a little past and back
        // (the Mac's InspectTool: stiffness 420, damping 24): lines drawn out from their middles,
        // their ticks and dashes once drawn, gaps and numbers coming up.
        let key = inspect.shownKey
        if key != inspectShown {
            inspectShown = key
            inspectGrow = DeckSpring(0)
            inspectGrow.target = 1
            inspectTicker.start()
        }
        let g = inspectGrow.value, e = min(max(g, 0), 1), drawn = e >= 0.98
        let pencil: UInt32 = 0x3A63D8, pink: UInt32 = 0xE0457B
        func px(_ v: BezzleCore.CGFloat) -> Double { Double(v).rounded() + 0.5 }
        func path(_ d: PathData, width: Double, ink: UInt32, alpha: Double = 1, dash: String? = nil) {
            guard let p = markPath(d, thickness: width, dash: dash) else { return }
            p.stroke = Theme.brush(ink, alpha)
            p.strokeStartLineCap = .round
            p.strokeEndLineCap = .round
            inspectMarks.children.append(p)
        }
        for r in m.hatches where r.width > 0.5 && r.height > 0.5 {
            let field = Rectangle()
            field.width = Double(r.width)
            field.height = Double(r.height)
            field.fill = Theme.brush(pink, 0.07)
            try? Canvas.setLeft(field, Double(r.minX))
            try? Canvas.setTop(field, Double(r.minY))
            field.opacity = e
            inspectMarks.children.append(field)
            var d = PathData()
            var x = Double(r.minX) - Double(r.height)
            while x < Double(r.maxX) {
                // Each stroke cut to the gap, as the Mac clips the hatch to it.
                let x0 = max(x, Double(r.minX)), y0 = Double(r.maxY) - (x0 - x)
                let x1 = min(x + Double(r.height), Double(r.maxX)), y1 = Double(r.maxY) - (x1 - x)
                if x1 > x0 { d.move(x0, y0); d.line(x1, y1) }
                x += 4
            }
            path(d, width: 1, ink: pink, alpha: 0.4 * e)
        }
        for o in m.outlines {
            var d = PathData()
            d.rect(px(o.rect.minX), px(o.rect.minY), Double(o.rect.width).rounded(), Double(o.rect.height).rounded())
            path(d, width: o.width, ink: o.gap ? pink : pencil, dash: o.dashed ? "4 3" : nil)
        }
        for dash in m.dashes where drawn {
            var d = PathData()
            d.move(px(dash.from.x), px(dash.from.y))
            d.line(px(dash.to.x), px(dash.to.y))
            path(d, width: 1, ink: pink, alpha: 0.8, dash: "3 3")
        }
        // The lines over a casing of white, so they read on any layer.
        for gap in [false, true] {
            var d = PathData()
            for l in m.lines where l.gap == gap && (!l.tick || drawn) {
                let mx = (Double(l.from.x) + Double(l.to.x)) / 2, my = (Double(l.from.y) + Double(l.to.y)) / 2
                let k = l.tick ? 1 : e
                d.move(px(BezzleCore.CGFloat(mx + (Double(l.from.x) - mx) * k)), px(BezzleCore.CGFloat(my + (Double(l.from.y) - my) * k)))
                d.line(px(BezzleCore.CGFloat(mx + (Double(l.to.x) - mx) * k)), px(BezzleCore.CGFloat(my + (Double(l.to.y) - my) * k)))
            }
            path(d, width: 3, ink: 0xFFFFFF, alpha: 0.7)
            path(d, width: 1, ink: gap ? pink : pencil, alpha: gap ? 1 : 0.9)
        }
        for l in m.labels {
            let ink = l.gap ? pink : pencil
            let pill = Border()
            pill.height = 17
            pill.cornerRadius = Theme.corners(8.5)
            pill.padding = Theme.inset(5, 0, 5, 0)
            pill.background = Theme.brush(l.solid ? ink : 0xFFFFFF)
            pill.borderBrush = l.solid ? Theme.brush(0xFFFFFF, 0.9) : Theme.brush(ink)
            pill.borderThickness = Theme.inset(l.solid ? 1.5 : 1)
            let text = Theme.text(l.text, size: 10.5, weight: 600)
            text.foreground = l.solid ? Theme.brush(0xFFFFFF) : Theme.brush(ink)
            text.verticalAlignment = .center
            pill.child = text
            try? pill.measure(Size(width: 300, height: 17))
            let w = Double(pill.desiredSize.width)
            try? Canvas.setLeft(pill, (Double(l.at.x) - w / 2).rounded())
            try? Canvas.setTop(pill, (Double(l.at.y) - 8.5).rounded())
            // Grown about its middle, a little past and back.
            if g < 0.999 || g > 1.001 {
                let grow = CompositeTransform()
                grow.centerX = w / 2
                grow.centerY = 8.5
                grow.scaleX = max(g, 0.01)
                grow.scaleY = max(g, 0.01)
                pill.renderTransform = grow
                pill.opacity = e
            }
            inspectMarks.children.append(pill)
        }
        if let tag = m.nameTag {
            let plate = Border()
            plate.cornerRadius = Theme.corners(4)
            plate.background = Theme.brush(0xFFFFFF, 0.92)
            plate.padding = Theme.inset(4, 2, 4, 2)
            plate.maxWidth = tag.width
            let text = Theme.text(tag.text, size: 10.5, weight: 500)
            text.foreground = Theme.brush(pencil)
            text.textTrimming = .characterEllipsis
            plate.child = text
            try? plate.measure(Size(width: 400, height: 30))
            try? Canvas.setLeft(plate, Double(tag.at.x))
            try? Canvas.setTop(plate, Double(tag.at.y) - Double(plate.desiredSize.height) - 2)
            inspectMarks.children.append(plate)
        }
    }

    /// The photo as the control sees the canvas as it is now.
    private func syncDevelop() {
        develop.selection = session.selection
        develop.free = session.tool == .select && editing == nil && pen.editingPath == nil && !builder.active && session.mode == 0
        develop.zoom = CGFloat(zoom)
        develop.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// Where the photo's colour is read while it is the control, as the Mac's DevelopTool draws
    /// it: a ring, light and dark so it shows on any photo, and beside it a label with the colour,
    /// what it is, and while dragging, how much.
    private func drawDevelop() {
        if !holds(overlay, developMarks) {
            developMarks.isHitTestVisible = false
            overlay.children.append(developMarks)
        }
        developMarks.children.clear()
        syncDevelop()
        guard let m = develop.mark() else { return }
        let x = Double(m.at.x), y = Double(m.at.y)
        for (width, brush) in [(3.0, Theme.brush(0, 0.35)), (1.5, Theme.brush(0xFFFFFF))] {
            let ring = Ellipse()
            ring.width = 14
            ring.height = 14
            ring.stroke = brush
            ring.strokeThickness = width
            try? Canvas.setLeft(ring, x - 7)
            try? Canvas.setTop(ring, y - 7)
            developMarks.children.append(ring)
        }
        let pill = Border()
        pill.height = 24
        pill.cornerRadius = Theme.corners(12)
        pill.background = Theme.brush(Theme.dark ? 0x2A2926 : 0xFCFBF8)
        pill.borderBrush = Theme.brush(Theme.ink, 0.12)
        pill.borderThickness = Theme.inset(0.5)
        pill.padding = Theme.inset(8, 0, 10, 0)
        let line = StackPanel()
        line.orientation = .horizontal
        line.spacing = 7
        line.verticalAlignment = .center
        let swatch = Ellipse()
        swatch.width = 12
        swatch.height = 12
        swatch.fill = Theme.brush(m.colour)
        swatch.stroke = Theme.brush(0, 0.15)
        swatch.strokeThickness = 0.75
        swatch.verticalAlignment = .center
        line.children.append(swatch)
        let words = Theme.text(m.words, size: 11.5, weight: 500)
        words.verticalAlignment = .center
        line.children.append(words)
        if let amount = m.amount {
            let number = Theme.text(amount, size: 11.5, weight: 600)
            number.foreground = Theme.brush(Theme.pencil)
            number.verticalAlignment = .center
            line.children.append(number)
        }
        pill.child = line
        try? pill.measure(Size(width: 400, height: 24))
        let w = Double(pill.desiredSize.width)
        // Beside the ring, or on its other side near the stage's right edge.
        let left = x + 14 + w > Double(stage.actualWidth) - 8 ? x - 14 - w : x + 14
        try? Canvas.setLeft(pill, left)
        try? Canvas.setTop(pill, y + 12)
        developMarks.children.append(pill)
    }

    /// The curve hand sees the canvas as it is now.
    private func syncCurve() {
        curveHand.selection = session.selection
        curveHand.free = session.tool == .select && editing == nil && pen.editingPath == nil && !builder.active && session.mode == 0
        curveHand.zoom = CGFloat(zoom)
        curveHand.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// Words along curves as the Mac's CurveTool draws them: an edge being rested on and the
    /// line running out along it, the glow of one just caught on or left, and a selected text's
    /// line with its beads. Drawn again each frame while something on them is on its way.
    private func drawCurves() {
        if !holds(overlay, curveMarks) {
            curveMarks.isHitTestVisible = false
            overlay.children.append(curveMarks)
        }
        curveMarks.children.clear()
        syncCurve()
        let m = curveHand.marks()
        func stroke(_ d: String, width: Double, alpha: Double, glow: Double) {
            guard alpha > 0.01 else { return }
            var data = PathData()
            data.d = d
            // A soft wider line under it, for the Mac's glow.
            if glow > 0.02, let halo = markPath(data, thickness: width + 4 + 8 * glow) {
                halo.stroke = Theme.brush(Theme.pencil, min(0.95, glow) * 0.22)
                halo.strokeStartLineCap = .round
                halo.strokeEndLineCap = .round
                halo.strokeLineJoin = .round
                curveMarks.children.append(halo)
            }
            guard let path = markPath(data, thickness: width) else { return }
            path.stroke = Theme.brush(Theme.pencil, min(alpha, 1))
            path.strokeStartLineCap = .round
            path.strokeEndLineCap = .round
            path.strokeLineJoin = .round
            curveMarks.children.append(path)
        }
        if let e = m.edge { stroke(e.path, width: 1.5, alpha: e.alpha, glow: e.glow) }
        if let r = m.run { stroke(r.path, width: 3, alpha: r.alpha, glow: r.glow) }
        if let f = m.flash { stroke(f.path, width: 2, alpha: f.alpha, glow: f.glow) }
        if let line = m.line { stroke(line, width: 1, alpha: m.lineStrong ? 0.7 : 0.45, glow: 0) }
        for bead in m.beads {
            let size = bead.lit ? 9.0 : 7.0
            let dot = Ellipse()
            dot.width = size
            dot.height = size
            dot.fill = bead.lit ? Theme.brush(Theme.pencil) : Theme.brush(0xFFFFFF)
            dot.stroke = Theme.brush(Theme.pencil)
            dot.strokeThickness = 1
            try? Canvas.setLeft(dot, Double(bead.at.x) - size / 2)
            try? Canvas.setTop(dot, Double(bead.at.y) - size / 2)
            curveMarks.children.append(dot)
        }
        // On its way: drawn again a frame from now.
        if curveHand.animating, !curveTicking {
            curveTicking = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
                MainActor.assumeIsolated {
                    self?.curveTicking = false
                    self?.drawCurves()
                }
            }
        }
    }

    /// The grid tool sees the canvas as it is now.
    private func syncGrid() {
        gridHand.selection = session.selection
        gridHand.free = session.tool == .select && editing == nil && pen.editingPath == nil && session.mode == 0
        gridHand.zoom = CGFloat(zoom)
        gridHand.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
    }

    /// A path as XAML reads it, stroked one point thick (dashed when `dash` is given).
    private func markPath(_ d: PathData, thickness: Double = 1, dash: String? = nil) -> WinUI.Path? {
        guard !d.d.isEmpty else { return nil }
        let dashes = dash.map { " StrokeDashArray='\($0)'" } ?? ""
        let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='\(thickness)'\(dashes)/>"
        return (try? XamlReader.load(xaml)) as? WinUI.Path
    }

    /// A selected repeat grid as the Mac's GridTool draws it: the same layer in the other cells,
    /// each cell faintly dashed, the gaps under the pointer, the cells to come, and its handles.
    private func drawGrids() {
        if !holds(overlay, gridMarks) {
            gridMarks.isHitTestVisible = false
            overlay.children.append(gridMarks)
        }
        gridMarks.children.clear()
        syncGrid()
        let m = gridHand.marks()
        // Lines of one point fall on whole pixels.
        func crisp(_ p: CGPoint) -> (Double, Double) { (Double(p.x).rounded() + 0.5, Double(p.y).rounded() + 0.5) }
        func add(_ corners: [CGPoint], to d: inout PathData) {
            guard let first = corners.first else { return }
            let a = crisp(first)
            d.move(a.0, a.1)
            for p in corners.dropFirst() { let b = crisp(p); d.line(b.0, b.1) }
            d.close()
        }
        func stroked(_ d: PathData, alpha: Double, dash: String?) {
            guard let path = markPath(d, dash: dash) else { return }
            path.stroke = Theme.brush(Theme.selection, alpha)
            gridMarks.children.append(path)
        }
        var copies = PathData()
        for c in m.copies { add(c, to: &copies) }
        stroked(copies, alpha: 0.6, dash: "3 2")
        var cells = PathData()
        for c in m.cells { add(c, to: &cells) }
        stroked(cells, alpha: m.cellsActive ? 0.55 : 0.3, dash: "3 3")
        for band in m.gaps {
            var fill = PathData()
            add(band.corners, to: &fill)
            if let path = markPath(fill, thickness: 0) {
                path.fill = Theme.brush(Theme.selection, 0.16)
                gridMarks.children.append(path)
            }
            var edges = PathData()
            for (a, b) in band.edges {
                let p = crisp(a), q = crisp(b)
                edges.move(p.0, p.1)
                edges.line(q.0, q.1)
            }
            stroked(edges, alpha: 0.7, dash: nil)
        }
        for ghost in m.ghosts {
            var d = PathData()
            add(ghost.corners, to: &d)
            guard let path = markPath(d, dash: "4 3") else { continue }
            path.fill = Theme.brush(Theme.selection, 0.07 * ghost.near)
            path.stroke = Theme.brush(Theme.selection, 0.25 + 0.55 * ghost.near)
            gridMarks.children.append(path)
        }
        // A pull of pencil blue on the edge it pulls out, with two grip lines across, as on a
        // drawer, or a dot at the corner; drawn upright about its middle, turned with the grid.
        for h in m.handles {
            let w = Double(h.size.width), t = Double(h.size.height), r = min(w, t) / 2
            let place = Affine(tx: Double(h.at.x), ty: Double(h.at.y), angle: h.angle * .pi / 180)
            var shade = PathData(place: Affine(tx: place.tx, ty: place.ty + 0.75, angle: place.angle))
            shade.rect(-w / 2 - 1, -t / 2 - 1, w + 2, t + 2, radius: r + 1)
            if let path = markPath(shade, thickness: 0) {
                path.fill = Theme.brush(0, 0.18)
                gridMarks.children.append(path)
            }
            var body = PathData(place: place)
            body.rect(-w / 2, -t / 2, w, t, radius: r)
            if let path = markPath(body, thickness: 1.5) {
                path.fill = Theme.brush(Theme.selection)
                path.stroke = Theme.brush(0xFFFFFF)
                gridMarks.children.append(path)
            }
            guard !h.dot else { continue }
            var grips = PathData(place: place)
            for d in [-2.0, 2.0] {
                if h.across {
                    grips.move(-1.5, d); grips.line(1.5, d)
                } else {
                    grips.move(d, -1.5); grips.line(d, 1.5)
                }
            }
            if let path = markPath(grips) {
                path.stroke = Theme.brush(0xFFFFFF, 0.85)
                gridMarks.children.append(path)
            }
        }
    }

    /// The knob a turned layer's face points with, on its stalk from the layer's middle, and the
    /// ring where the face is seen edge on, or the ball being turned, as the Mac draws them.
    private func drawDepth() {
        if !holds(overlay, depthMarks) {
            depthMarks.isHitTestVisible = false
            overlay.children.append(depthMarks)
        }
        depthMarks.children.clear()
        depth.selection = session.selection
        depth.zoom = CGFloat(zoom)
        depth.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
        let o = depth.overlay()
        func circle(_ c: CGPoint, _ r: Double, alpha: Double, dash: (Double, Double)) {
            var d = PathData()
            d.move(Double(c.x) - r, Double(c.y))
            d.d += String(format: "A%.2f,%.2f 0 1 1 %.2f,%.2f A%.2f,%.2f 0 1 1 %.2f,%.2f Z", r, r, Double(c.x) + r, Double(c.y), r, r, Double(c.x) - r, Double(c.y))
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(d.d)' StrokeThickness='1' StrokeDashArray='\(dash.0) \(dash.1)'/>"
            guard let path = (try? XamlReader.load(xaml)) as? WinUI.Path else { return }
            path.stroke = Theme.brush(Theme.selection, alpha)
            depthMarks.children.append(path)
        }
        if let (center, radius) = o.ball {
            circle(center, Double(radius), alpha: 0.35, dash: (3, 4))
            return
        }
        guard let (center, knob) = o.stalk else { return }
        if let ring = o.ring { circle(ring, WindowsCore.Depth.reach, alpha: 0.4, dash: (2, 3)) }
        var line = PathData()
        line.move(Double(center.x), Double(center.y))
        line.line(Double(knob.x), Double(knob.y))
        if let stalk = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(line.d)' StrokeThickness='1.25'/>")) as? WinUI.Path {
            stalk.stroke = Theme.brush(Theme.selection)
            depthMarks.children.append(stalk)
        }
        func dot(_ c: CGPoint, _ size: Double, fill: UInt32, rim: Bool) {
            let e = Ellipse()
            e.width = size
            e.height = size
            e.fill = Theme.brush(fill)
            if rim {
                e.stroke = Theme.brush(Theme.selection)
                e.strokeThickness = 1
            }
            try? Canvas.setLeft(e, Double(c.x) - size / 2)
            try? Canvas.setTop(e, Double(c.y) - size / 2)
            depthMarks.children.append(e)
        }
        dot(center, 4, fill: Theme.selection, rim: false)
        dot(knob, 12, fill: 0xFFFFFF, rim: true)
        dot(knob, 4, fill: Theme.selection, rim: false)
    }

    // MARK: Looking from the side

    /// The look tool sees the canvas as it is now.
    private func syncLook() {
        looking.zoom = CGFloat(zoom)
        looking.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
        looking.focused = session.board
    }

    /// An artboard is looked at from elsewhere (all of them, with nil): its picture is drawn
    /// again as far as it reaches now, with what stands off the page, and the marks with it.
    /// Nothing of the design changed, so nothing else hears of it and nothing is saved.
    private func lookChanged(_ board: UUID?) {
        guard let k = board.flatMap(WindowsCore.boardIndex(of:)) else { drawAll(); return }
        redraw(board: k)
        place()
    }

    /// What shows while artboards are looked at from the side, as the Mac's LookTool draws it: a
    /// post under each corner of what stands off the page (of what is picked alone, when some of
    /// it is), and by each such artboard's top right corner, in the line its name is in, the
    /// word that looks at it from the front again. Only while designing.
    private func drawLook() {
        if !holds(overlay, lookMarks) {
            lookMarks.isHitTestVisible = false
            overlay.children.append(lookMarks)
        }
        lookMarks.children.clear()
        lookWords = []
        guard session.mode == 0, WindowsCore.lookingFromTheSide else { lookHovered = nil; return }
        syncLook()
        // Clear of the rulers, where they show.
        let ruled = WindowsCore.showsRulers ? Rulers.thickness : 0
        let view = CGRect(x: ruled, y: ruled, width: max(0, stage.actualWidth - ruled), height: max(0, stage.actualHeight - ruled))
        let marks = looking.marks(selection: session.selection, size: CGSize(width: stage.actualWidth, height: stage.actualHeight))
        var posts = PathData(), feet = PathData()
        for post in marks.posts {
            posts.move(Double(post.foot.x), Double(post.foot.y))
            posts.line(Double(post.top.x), Double(post.top.y))
            feet.rect(Double(post.foot.x) - 1.5, Double(post.foot.y) - 1.5, 3, 3, radius: 1.5)
        }
        if let path = markPath(posts) {
            path.stroke = Theme.brush(Theme.pencil, 0.5)
            lookMarks.children.append(path)
        }
        if let path = markPath(feet, thickness: 0) {
            path.fill = Theme.brush(Theme.pencil, 0.5)
            lookMarks.children.append(path)
        }
        for board in marks.boards {
            let label = Theme.text(Words.t("Look from the Front"), size: 11, weight: 600)
            label.foreground = Theme.brush(0xFFFFFF)
            label.horizontalAlignment = .center
            label.verticalAlignment = .center
            try? label.measure(Size(width: 400, height: 20))
            let r = WindowsCore.LookHand.wordRect(by: board.frame, words: CGFloat(label.desiredSize.width), in: view)
            let pill = Border()
            pill.width = Double(r.width)
            pill.height = Double(r.height)
            pill.cornerRadius = Theme.corners(Double(r.height) / 2)
            // Pointed at, a little darker, as on the Mac.
            pill.background = Theme.brush(lookHovered == board.id ? Theme.mix(Theme.pencil, 0x000000, 0.12) : Theme.pencil)
            pill.child = label
            try? Canvas.setLeft(pill, Double(r.minX))
            try? Canvas.setTop(pill, Double(r.minY))
            lookMarks.children.append(pill)
            lookWords.append((board.id, r))
        }
        if let hovered = lookHovered, !lookWords.contains(where: { $0.board == hovered }) { lookHovered = nil }
    }

    /// The word under `p` on the stage, by the artboard it is of.
    private func lookWord(at p: CGPoint) -> UUID? {
        lookWords.first { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }?.board
    }

    /// The pointer over a word that looks from the front again: it darkens.
    private func pointLook(at p: CGPoint) {
        let over = lookWord(at: p)
        guard over != lookHovered else { return }
        lookHovered = over
        drawLook()
    }

    /// The corner dots, the shadow's outline and the measure, as the pointer and the drag have them.
    private func placeHolds() {
        let holding: Grab? = drag?.grab
        let rounding: Bool = if case .corner? = holding { true } else { false }
        let moving: Bool = if case .shadow? = holding { drag?.moved == true } else { false }
        let dots = session.tool == .select && pictures.editing == nil && (dotsShown || rounding) ? WindowsCore.cornerDots(session.selection, zoom: zoom, pan: pan) : []
        for (k, dot) in cornerDots.enumerated() {
            guard k < dots.count else { dot.visibility = .collapsed; continue }
            try? Canvas.setLeft(dot, Double(dots[k].x).rounded() - 3.5)
            try? Canvas.setTop(dot, Double(dots[k].y).rounded() - 3.5)
            dot.visibility = .visible
        }
        if shadowShown || moving, let corners = WindowsCore.shadowOutline(session.selection) {
            trace(shadowLine, corners, closed: true)
            shadowLine.visibility = .visible
        } else {
            shadowLine.visibility = .collapsed
        }
        if let (text, box) = WindowsCore.measure {
            measureText.text = text
            measurePill.visibility = .visible
            try? measurePill.measure(Size(width: 400, height: 20))
            let w = Double(measurePill.desiredSize.width)
            let a = onStage(CGPoint(x: box.midX, y: box.maxY))
            try? Canvas.setLeft(measurePill, (Double(a.x) - w / 2).rounded())
            try? Canvas.setTop(measurePill, (Double(a.y) + 10).rounded())
        } else {
            measurePill.visibility = .collapsed
        }
    }

    /// The lines and gaps a drag catches on, drawn until it ends (an empty list).
    private func showGuides(_ lines: [WindowsCore.GuideLine]) {
        guides = lines
        let straight = lines.filter { $0.field == nil }, fields = lines.compactMap(\.field)
        guideLines.visibility = straight.isEmpty ? .collapsed : .visible
        gapFields.visibility = fields.isEmpty ? .collapsed : .visible
        if !straight.isEmpty { guideLines.data = figures(straight.map { ([$0.from, $0.to], false) }) }
        if !fields.isEmpty {
            gapFields.data = figures(fields.map { r in ([CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                                                         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)], true) })
        }
    }

    /// The box dragged out to pick with (on the canvas), or none.
    private func showMarquee(_ box: CGRect?) {
        guard let box else { marqueeBox.visibility = .collapsed; return }
        let a = onStage(CGPoint(x: box.minX, y: box.minY))
        try? Canvas.setLeft(marqueeBox, Double(a.x).rounded())
        try? Canvas.setTop(marqueeBox, Double(a.y).rounded())
        marqueeBox.width = max(1, Double(box.width) * zoom)
        marqueeBox.height = max(1, Double(box.height) * zoom)
        marqueeBox.visibility = .visible
    }

    /// Paths through points (on the canvas) as one geometry on the stage.
    private func figures(_ paths: [([CGPoint], Bool)]) -> PathGeometry {
        let geometry = PathGeometry()
        for (points, closed) in paths {
            guard let first = points.first else { continue }
            func at(_ p: CGPoint) -> Point {
                let q = onStage(p)
                return Point(x: Float((Double(q.x)).rounded() + 0.5), y: Float((Double(q.y)).rounded() + 0.5))
            }
            let figure = PathFigure()
            figure.startPoint = at(first)
            figure.isClosed = closed
            figure.isFilled = closed
            for p in points.dropFirst() {
                let segment = LineSegment()
                segment.point = at(p)
                figure.segments.append(segment)
            }
            geometry.figures.append(figure)
        }
        return geometry
    }

    /// `path` through `points` (on the canvas), placed on the stage.
    private func trace(_ path: WinUI.Path, _ points: [CGPoint], closed: Bool) {
        guard let first = points.first else { return }
        func at(_ p: CGPoint) -> Point {
            let q = onStage(p)
            return Point(x: Float((Double(q.x)).rounded() + 0.5), y: Float((Double(q.y)).rounded() + 0.5))
        }
        let figure = PathFigure()
        figure.startPoint = at(first)
        figure.isClosed = closed
        figure.isFilled = false
        for p in points.dropFirst() {
            let segment = LineSegment()
            segment.point = at(p)
            figure.segments.append(segment)
        }
        let geometry = PathGeometry()
        geometry.figures.append(figure)
        path.data = geometry
    }

    /// The rulers measure the selection's artboard, counted from its corner.
    private func showRulers() {
        let sheet = session.board.flatMap { b in boards.first { $0.index == b }?.frame }
        var selection: CGRect?
        if let sheet, let f = selectedFrame() { selection = f.offsetBy(dx: sheet.minX, dy: sheet.minY) }
        rulers.root.visibility = WindowsCore.showsRulers ? .visible : .collapsed
        rulers.show(width: root.actualWidth, height: root.actualHeight, zoom: zoom, pan: pan, sheet: sheet, selection: selection)
    }

    private func show(_ shape: Rectangle, _ box: CGRect) {
        try? Canvas.setLeft(shape, Double(box.minX))
        try? Canvas.setTop(shape, Double(box.minY))
        shape.width = max(1, Double(box.width))
        shape.height = max(1, Double(box.height))
        shape.visibility = .visible
    }

    private func onStage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: Double(pan.x) + Double(p.x) * zoom, y: Double(pan.y) + Double(p.y) * zoom)
    }

    /// Where a part of the canvas lies in `element`'s points, when any of it is in sight.
    func rect(onCanvas r: CGRect, in element: UIElement) -> CGRect? {
        let a = onStage(r.origin)
        let shown = CGRect(x: a.x, y: a.y, width: Double(r.width) * zoom, height: Double(r.height) * zoom)
        guard shown.intersects(CGRect(x: 0, y: 0, width: stage.actualWidth, height: stage.actualHeight)),
              let t = try? stage.transformToVisual(element),
              let o = try? t.transformPoint(Point(x: Float(shown.minX), y: Float(shown.minY))) else { return nil }
        return CGRect(x: Double(o.x), y: Double(o.y), width: Double(shown.width), height: Double(shown.height))
    }

    /// A part of the canvas brought into sight, its middle to the middle, when none of it shows.
    func reveal(_ r: CGRect) {
        let a = onStage(r.origin)
        let shown = CGRect(x: a.x, y: a.y, width: Double(r.width) * zoom, height: Double(r.height) * zoom)
        let w = stage.actualWidth, h = stage.actualHeight
        guard w > 0, h > 0, !shown.intersects(CGRect(x: 0, y: 0, width: w, height: h)) else { return }
        pan = CGPoint(x: w / 2 - Double(r.midX) * zoom, y: h / 2 - Double(r.midY) * zoom)
        place()
    }

    private func inDesign(_ p: CGPoint) -> CGPoint {
        CGPoint(x: (Double(p.x) - Double(pan.x)) / zoom, y: (Double(p.y) - Double(pan.y)) / zoom)
    }

    /// A layer on the stage: of artboard `board`, or of whichever artboard holds it.
    private func onStage(layer id: UUID, board: Int? = nil) -> CGRect? {
        // On an artboard, its frame counted from the artboard's corner; on the canvas, from the canvas's.
        let places = boards.map { ($0.index, $0.frame.origin) } + loose.map { ($0.index, CGPoint.zero) }
        for (index, origin) in places where board == nil || index == board {
            if let f = WindowsCore.layers(board: index).first(where: { $0.id == id })?.frame {
                let o = onStage(CGPoint(x: origin.x + f.minX, y: origin.y + f.minY))
                return CGRect(x: o.x, y: o.y, width: Double(f.width) * zoom, height: Double(f.height) * zoom)
            }
        }
        return nil
    }

    private func selectedFrame() -> CGRect? {
        guard let id = session.selection.first, let board = session.board else { return nil }
        return WindowsCore.layers(board: board).first { $0.id == id }?.frame
    }

    /// The handle under `p` on the stage, by its place in `WindowsCore.handleOrder` (or a line's end).
    private func handle(at p: CGPoint) -> Int? {
        let reach = lineEnds ? 7 : Self.handleSize / 2 + 3
        return shownHandles.first { abs(Double($0.point.x) - Double(p.x)) <= reach && abs(Double($0.point.y) - Double(p.y)) <= reach }?.index
    }

    // MARK: The pen

    /// The pen sees the canvas as it is now: the selection, the zoom and where it is, the tool.
    private func syncPen() {
        pen.selection = session.selection
        knife.selection = session.selection
        syncView()
    }

    /// Where the canvas is and which tool is in hand, but not the selection: drawing the marks
    /// again must not take back what the pen or the knife just picked.
    private func syncView() {
        pen.zoom = CGFloat(zoom)
        pen.pan = CGPoint(x: Double(pan.x), y: Double(pan.y))
        pen.penInHand = session.tool == .pen
        pen.selecting = session.tool == .select
        knife.zoom = CGFloat(zoom)
        knife.pan = pen.pan
        knife.knifeInHand = session.tool == .knife
    }

    /// What the knife cut shows: the pieces picked, the design drawn again, the blade.
    private func knifeChanged() {
        if knife.selection != session.selection {
            session.select(knife.selection, on: knife.selection.first.flatMap(WindowsCore.board(of:)) ?? session.board)
            session.edited(board: nil)
        }
        drawPen()
    }

    /// What the pen did shows: what it picked, the design drawn again, its marks.
    private func penChanged() {
        if pen.selection != session.selection {
            session.select(pen.selection, on: pen.selection.first.flatMap(WindowsCore.board(of:)) ?? session.board)
        }
        session.edited(board: pen.shownPath.flatMap(WindowsCore.board(of:)) ?? session.board)
        drawPen()
    }

    /// The pen's marks over the design: the path's outline, the curve still to come, the handles
    /// and points (7 square, filled when picked), the ring round the first point, the ghost of a
    /// point to add and the box dragged round points, all in pencil, as the Mac draws them.
    private func drawPen() {
        penMarks.children.clear()
        if !holds(overlay, penMarks) { overlay.children.append(penMarks) }
        syncView()
        if session.tool == .knife, let (line, anchors) = knife.blade() {
            // A pale rim, so the blade shows on anything, and the blade dashed in a warm red.
            for (colour, alpha, width, dashed) in [(UInt32(0xFFFFFF), 0.8, 3.0, false), (UInt32(0xE04A33), 1.0, 1.25, true)] {
                let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(line)' StrokeThickness='\(width)' "
                    + "StrokeStartLineCap='Round' StrokeEndLineCap='Round' StrokeLineJoin='Round'" + (dashed ? " StrokeDashArray='4 2.4'" : "") + "/>"
                guard let shape = (try? XamlReader.load(xaml)) as? WinUI.Path else { continue }
                shape.stroke = Theme.brush(colour, alpha)
                penMarks.children.append(shape)
            }
            for a in anchors {
                let dot = Border()
                dot.width = 7
                dot.height = 7
                dot.cornerRadius = Theme.corners(3.5)
                dot.background = a.newest ? Theme.brush(0xE04A33) : Theme.brush(0xFFFFFF)
                dot.borderBrush = Theme.brush(0xE04A33)
                dot.borderThickness = Theme.inset(1)
                try? Canvas.setLeft(dot, Double(a.point.x) - 3.5)
                try? Canvas.setTop(dot, Double(a.point.y) - 3.5)
                penMarks.children.append(dot)
            }
            return
        }
        guard session.tool == .pen || pen.editingPath != nil || pen.shownPath != nil else { return }
        let o = pen.overlay()
        func path(_ data: String, alpha: Double = 1, width: Double = 1) {
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(data)' StrokeThickness='\(width)'/>"
            guard let shape = (try? XamlReader.load(xaml)) as? WinUI.Path else { return }
            shape.stroke = Theme.brush(Theme.pencil, alpha)
            penMarks.children.append(shape)
        }
        if let outline = o.outline, !outline.isEmpty { path(outline) }
        if let toCome = o.toCome { path(toCome, alpha: 0.75) }
        for h in o.handles {
            var line = PathData()
            line.move(Double(h.point.x), Double(h.point.y))
            line.line(Double(h.handle.x), Double(h.handle.y))
            path(line.d, alpha: 0.85)
        }
        func box(_ at: CGPoint, round: Bool, filled: Bool, alpha: Double = 1) {
            let b = Border()
            b.width = 7
            b.height = 7
            b.cornerRadius = Theme.corners(round ? 3.5 : 0)
            b.background = filled ? Theme.brush(Theme.pencil, alpha) : Theme.brush(0xFFFFFF, alpha)
            b.borderBrush = Theme.brush(Theme.pencil, alpha)
            b.borderThickness = Theme.inset(1)
            try? Canvas.setLeft(b, Double(at.x) - 3.5)
            try? Canvas.setTop(b, Double(at.y) - 3.5)
            penMarks.children.append(b)
        }
        for h in o.handles { box(h.handle, round: true, filled: false) }
        for a in o.anchors { box(a.point, round: false, filled: a.filled) }
        if let c = o.closing {
            let ring = Border()
            ring.width = 15
            ring.height = 15
            ring.cornerRadius = Theme.corners(7.5)
            ring.borderBrush = Theme.brush(Theme.pencil)
            ring.borderThickness = Theme.inset(1.5)
            try? Canvas.setLeft(ring, Double(c.x) - 7.5)
            try? Canvas.setTop(ring, Double(c.y) - 7.5)
            penMarks.children.append(ring)
        }
        if let spot = o.spot { box(spot, round: false, filled: false, alpha: 0.55) }
        if let r = o.marquee {
            let m = Border()
            m.width = Double(r.width)
            m.height = Double(r.height)
            m.background = Theme.brush(Theme.pencil, 0.08)
            m.borderBrush = Theme.brush(Theme.pencil, 0.8)
            m.borderThickness = Theme.inset(1)
            try? Canvas.setLeft(m, Double(r.minX))
            try? Canvas.setTop(m, Double(r.minY))
            penMarks.children.append(m)
        }
    }

    // MARK: Things dragged in

    /// StandardDataFormats.StorageItems, which the bindings leave out: files, as Explorer drags them.
    private static let storageItems = "Shell IDList Array"

    private func dragOver(_ args: DragEventArgs?) {
        guard let args, let view = args.dataView else { return }
        let files = (try? view.contains(Self.storageItems)) == true, words = (try? view.contains("Text")) == true
        args.acceptedOperation = files || words ? .copy : .none

        guard let p = try? args.getPosition(stage) else { return }
        let target = WindowsCore.dropTarget(at: inDesign(CGPoint(x: Double(p.x), y: Double(p.y))), zoom: zoom)
        setHover(target.flatMap { WindowsCore.isShape($0) || (words && WindowsCore.isText($0)) ? $0 : nil })
    }

    private func dropped(_ args: DragEventArgs?) {
        guard let args, let view = args.dataView, let p = try? args.getPosition(stage) else { return }
        let at = inDesign(CGPoint(x: Double(p.x), y: Double(p.y)))
        setHover(nil)
        let deferral = try? args.getDeferral()
        Task { @MainActor [weak self] in
            defer { try? deferral?.complete() }
            var files: [URL] = []
            var text: String?
            if (try? view.contains(Self.storageItems)) == true, let items = try? await view.getStorageItemsAsync()?.get() {
                for k in 0..<items.size {
                    if let item = (try? items.getAt(k)) ?? nil, !item.path.isEmpty { files.append(URL(fileURLWithPath: item.path)) }
                }
            } else if (try? view.contains("Text")) == true {
                text = try? await view.getTextAsync()?.get()
            }
            guard let self else { return }
            // Designs, and files from other apps, open in tabs of their own, as the Mac opens what
            // is dropped on Bezzle's Dock icon (Windows' taskbar takes no drops).
            let designs = files.filter { $0.pathExtension.lowercased() == "bezzle" || WindowsCore.imports($0) }
            if !designs.isEmpty {
                DispatchQueue.main.async { MainActor.assumeIsolated { designs.forEach { Tabs.shared.open($0) } } }
                files.removeAll { designs.contains($0) }
                guard !files.isEmpty else { return }
            }
            let target = WindowsCore.dropTarget(at: at, zoom: self.zoom)
            guard let made = WindowsCore.drop(files: files, text: text, at: at, on: target) else { return }
            self.session.select(made, on: made.first.flatMap(WindowsCore.board(of:)))
            self.session.edited(board: nil)
        }
    }

    // MARK: Picking and dragging

    private func point(_ args: PointerRoutedEventArgs?) -> CGPoint {
        guard let p = try? args?.getCurrentPoint(stage)?.position else { return .zero }
        return CGPoint(x: Double(p.x), y: Double(p.y))
    }

    /// What a click at `p` on the stage picks, as the Mac picks it (`Picking`, shared): the group
    /// the selection lies in is looked in first.
    private func pick(_ p: CGPoint) -> UUID? {
        titleHit(p) ?? WindowsCore.pick(inDesign(p), selection: session.selection, zoom: zoom)
    }

    /// The artboard whose name is at `p` on the stage, as the Mac's titleHit: its name, 19 above
    /// it and 16 tall, as wide as it reads (at least 40, at most the artboard), a little taller to
    /// be caught.
    private func titleHit(_ p: CGPoint) -> UUID? {
        for (k, board) in boards.enumerated().reversed() where !board.hidden {
            guard let sheet = sheets[k], sheet.name.visibility == .visible else { continue }
            let at = onStage(board.frame.origin)
            let w = min(sheet.name.actualWidth + 2, max(Double(board.frame.width) * zoom, 40))
            let r = CGRect(x: Double(at.x), y: Double(at.y) - 21, width: w, height: 20)
            if r.contains(p) { return board.id }
        }
        return nil
    }

    private func setHover(_ id: UUID?) {
        session.hovered = id
    }

    /// Whether a press soon after the last is on the group or copy that one picked, alone, and
    /// was not a drag: the Mac counts it as the second click of a double click wherever on the
    /// group it lands (macOS keeps a click count by time), so that clicking a copy and then its
    /// shape goes into it, as the welcome tour has it. Windows' own counting wants the second
    /// within four pixels of the first.
    private func secondPressOnGroup(_ p: CGPoint) -> Bool {
        guard !lastPressDragged, session.tool == .select, session.mode == 0, session.selection.count == 1,
              let id = session.selection.first, WindowsCore.isGroup(id) else { return false }
        return pick(p) == id
    }

    private func pressed(_ args: PointerRoutedEventArgs?) {
        // On the words typed into, the press puts the caret; anywhere else it ends the typing.
        if editing != nil {
            if pressOnTyped(args) { return }
            endEditing()
        }
        _ = try? root.focus(.pointer)
        let p = point(args), c = inDesign(p)
        // A second press soon after the first, where it was, is a double click, as Windows counts them.
        let now = GetTickCount()
        let onGroup = secondPressOnGroup(p)
        if let last = lastPress, now - last.time <= GetDoubleClickTime(),
           abs(Double(last.at.x - p.x)) <= 4 && abs(Double(last.at.y - p.y)) <= 4 || onGroup {
            lastPress = (p, now, last.clicks + 1)
        } else {
            lastPress = (p, now, 1)
        }
        // A drag until its release says otherwise.
        lastPressDragged = true
        let intoGroup = onGroup && (lastPress?.clicks ?? 1) >= 2
        pressEntered = false
        // With Space held, or the wheel pressed, the canvas moves round, whatever tool is in hand.
        let middle = (try? args?.getCurrentPoint(stage))?.properties?.isMiddleButtonPressed == true
        if spaceDown || middle {
            _ = try? stage.capturePointer(args?.pointer)
            drag = (p, -1, false, .pan(start: pan))
            setHover(nil)
            showPointer(.grab)
            return
        }
        // Looking back, a press picks a layer that differs from now, to bring back; the view
        // moves as ever.
        if WindowsCore.versions.lookingBack {
            WindowsCore.versions.pick(at: c)
            return
        }
        // Decks: the row under a stack, the feet of the cards behind it, every post spread out.
        if session.mode == 0, session.tool == .select || decks.spreading, decks.down(at: p) {
            _ = try? stage.capturePointer(args?.pointer)
            drag = (p, -1, false, .deck)
            return
        }
        // Animated: what is picked is posed, the camera taken in hand, a loop pulled round layers.
        if animating {
            syncMotion()
            motion.down(at: p, clicks: lastPress?.clicks ?? 1, shift: shift, deep: control)
            if motion.dragging {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, -1, false, .motion)
            }
            drawMotion()
            updatePointer(at: p)
            return
        }
        // The design as a prototype: threads, flags and screens take the press.
        if prototyping {
            syncFlow()
            if flow.down(at: p, clicks: lastPress?.clicks ?? 1, shift: shift) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, -1, false, .flow)
            }
            drawFlow()
            return
        }
        // Inspecting: a click picks what is under the pointer, a drag moves the view, and nothing changes.
        if inspecting {
            syncInspect()
            _ = try? stage.capturePointer(args?.pointer)
            drag = (p, -1, false, .inspect(start: pan, target: inspect.deepest(at: p)))
            return
        }
        // Someone else's design no longer shared is only looked at: a click picks, nothing changes.
        if WindowsCore.isReadOnly {
            let picked = pick(p)
            session.select(picked.map { [$0] } ?? [], on: picked.flatMap(WindowsCore.board(of:)) ?? session.board)
            return
        }
        // A word offered after a change is taken before anything else.
        if let hit = copyButtons.first(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) {
            copyOffer = nil
            if let picked = WindowsCore.takeCopyOffer(hit.index) { session.select(picked, on: session.board) }
            session.edited(board: nil)
            return
        }
        // The word by an artboard looked at from the side looks at it from the front again.
        if session.mode == 0, let board = lookWord(at: p) {
            lookHovered = nil
            if WindowsCore.look(at: board, across: 0, down: 0) { lookChanged(board) }
            return
        }
        // The row of variants beside a copy picked: a card makes the copy that variant, the round
        // button a new variant of it.
        if session.mode == 0, copyMarks.down(at: p) { return }
        if let offer = shownOffer, onOffer(p) {
            offerLit = false
            if let mask = WindowsCore.takeOffer(offer) {
                session.select([mask], on: WindowsCore.board(of: mask) ?? session.board)
                // What was cut off sinks in, and the outline draws in once.
                maskMarks.committed(mask)
            }
            session.edited(board: nil)
            return
        }
        // The rulers, whatever the tool, as on the Mac.
        syncGuides()
        if guideHand.rulerDown(at: p, clicks: lastPress?.clicks ?? 1, shift: shift, option: option, command: control) {
            _ = try? stage.capturePointer(args?.pointer)
            return
        }
        // Placing a picture: a press on it moves it, on a corner sizes it; anywhere else placing
        // ends, and the press goes on as any.
        pictureTookPress = false
        if session.tool == .select, pictures.editing != nil {
            syncPictures()
            if pictures.down(at: p, clicks: lastPress?.clicks ?? 1) {
                pictureTookPress = true
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, session.board ?? -1, false, .picture)
                drawPictures()
                session.changed()
                return
            }
            pictures.editing = nil
            drawPictures()
            session.changed()
        }
        // The knife, cutting what its line runs across.
        if session.tool == .knife {
            syncPen()
            _ = try? stage.capturePointer(args?.pointer)
            knife.down(at: p, shift: shift, clicks: lastPress?.clicks ?? 1)
            knifeChanged()
            return
        }
        // The pen, and the points of a path being edited, as the Mac's canvas hands them on.
        if session.tool == .pen || pen.editingPath != nil {
            syncPen()
            if session.tool == .pen {
                _ = try? stage.capturePointer(args?.pointer)
                pen.penDown(at: p, shift: shift, option: option, command: control)
                penChanged()
                return
            }
            if pen.editDown(at: p, shift: shift, option: option, command: control, clicks: lastPress?.clicks ?? 1) {
                _ = try? stage.capturePointer(args?.pointer)
                penChanged()
                return
            }
            // Off the path's points and outline: dragging round points, or, on another layer, out
            // of editing to pick that. A click on nothing at all leaves editing too.
            let other = pick(p)
            if other == nil || other == pen.editingPath {
                if (lastPress?.clicks ?? 1) >= 2 {
                    pen.editingPath = nil
                } else {
                    _ = try? stage.capturePointer(args?.pointer)
                    pen.startMarquee(at: p, adding: shift, offPath: other == nil)
                }
                penChanged()
                return
            }
            pen.editingPath = nil
            drawPen()
            session.changed()
        }
        if session.tool == .note {
            _ = try? stage.capturePointer(args?.pointer)
            drag = (p, -1, false, .note(start: c))
            return
        }
        // A click on the canvas puts an open note away.
        if margin.notes.openThread != nil { margin.notes.openThread = nil }
        if let kind = drawn(session.tool) {
            let on = kind == "artboard" ? nil : WindowsCore.board(at: c)
            // A click with the Text tool on a text types into it, all its words picked out; a
            // drag, over one or not, draws a new one.
            textUnderPress = kind == "text" ? WindowsCore.hit(c, zoom: zoom).flatMap { WindowsCore.isText($0) ? $0 : nil } : nil
            // New text looks as the text selected, as on the Mac.
            drawLike = kind == "text" && session.selection.count == 1 && WindowsCore.isText(session.selection[0]) ? session.selection[0] : nil
            _ = try? stage.capturePointer(args?.pointer)
            drag = (p, on ?? -1, false, .draw(id: UUID(), kind: kind, start: CGPoint(x: Double(c.x).rounded(), y: Double(c.y).rounded()), board: on))
            WindowsCore.beginGesture()
            return
        }
        // Off the pieces, building is done, and the press goes on as any.
        if session.tool == .select, builder.active {
            syncBuild()
            if builder.down(at: p, option: option) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, -1, false, .build)
                return
            }
        }
        // A selected grid's handles repeat it, and its gaps space it, as the Mac asks first.
        if session.tool == .select {
            syncGrid()
            if gridHand.down(at: p) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, session.selection.first.flatMap(WindowsCore.board(of:)) ?? -1, false, .grid)
                return
            }
        }
        // A turned layer's knob, as the Mac asks its depth tool first.
        if session.tool == .select, let board = session.board {
            syncDepth()
            if depth.down(at: p, clicks: lastPress?.clicks ?? 1) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, board, false, .depth)
                session.edited(board: board)
                return
            }
        }
        // A selected text's beads bend it.
        if session.tool == .select {
            syncCurve()
            if curveHand.down(at: p, clicks: lastPress?.clicks ?? 1, command: control) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, session.board ?? -1, false, .curve)
                showPointer(.grab)
                return
            }
        }
        // A path's corner dots, and a shape's edge with Alt, unless a resize handle is in the way.
        if session.tool == .select, handle(at: p) == nil {
            syncOutline()
            if outlineHand.down(at: p, shift: shift, option: option) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, session.board ?? -1, false, .outline)
                return
            }
        }
        // As the Mac's selectDown: a handle first, then what lies under the pointer.
        if let k = handle(at: p), let board = session.board {
            _ = try? stage.capturePointer(args?.pointer)
            drag = (p, board, false, lineEnds ? .lineEnd(k) : .handle(k))
            if lineEnds { WindowsCore.beginGesture() } else { WindowsCore.beginPull(session.selection) }
            return
        }
        // With the Photo card open and its target on, the photo is the control.
        if session.tool == .select {
            syncDevelop()
            if develop.down(at: p, clicks: lastPress?.clicks ?? 1) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, session.board ?? -1, false, .develop)
                return
            }
        }
        // Just outside a corner, a corner's dot, the layer's shadow, as the Mac's handleHit has them.
        if session.tool == .select, let board = session.board,
           let hit = WindowsCore.hit(at: p, selection: session.selection, zoom: zoom, pan: pan, selecting: true) {
            switch hit {
            case .rotate:
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, board, false, .turn)
                WindowsCore.beginTurn(session.selection, at: c)
                return
            case .corner(let k):
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, board, false, .corner)
                WindowsCore.beginCorner(session.selection[0], corner: k)
                return
            case .shadow:
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, board, false, .shadow)
                return
            case .turnInDepth:
                syncDepth()
                _ = try? stage.capturePointer(args?.pointer)
                depth.startTurn(at: p)
                drag = (p, board, false, .depth)
                return
            default:
                break
            }
        }
        // With its card open, a selected artboard's grid is changed where it is drawn; then a
        // guide's line, where no layer lies under it, as the Mac's selectDown has them.
        if session.tool == .select {
            syncLayout()
            if layoutHand.down(at: p) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, session.board ?? -1, false, .layout)
                return
            }
            if guideHand.lineDown(at: p, shift: shift, option: option, command: control) {
                _ = try? stage.capturePointer(args?.pointer)
                return
            }
        }
        // A second click soon after on the group or copy just picked goes into it, one level,
        // wherever on it it lands, as the Mac's double click does (CanvasView.selectDown).
        if session.tool == .select, intoGroup, !shift, let id = session.selection.first,
           let inner = WindowsCore.pick(inDesign(p), inGroup: id, zoom: zoom) {
            session.select([inner], on: WindowsCore.board(of: inner) ?? session.board)
            pressEntered = true
            // Each quick click after it goes one level further.
            lastPressDragged = false
            return
        }
        // A double click on a layer filled with a picture places the picture inside it, and a
        // drag straight on moves it, as on the Mac (a text's letters are typed into instead).
        if session.tool == .select, (lastPress?.clicks ?? 1) == 2, !shift, let id = pick(p), !WindowsCore.isText(id),
           WindowsCore.PictureHand.canPlace([id]) {
            session.select([id], on: WindowsCore.board(of: id))
            session.placePicture()
            syncPictures()
            if pictures.down(at: p, clicks: 1) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, session.board ?? -1, false, .picture)
            }
            pictureTookPress = true
            drawPictures()
            return
        }
        if let id = pick(p) {
            let board = WindowsCore.board(of: id)
            if shift {
                var picked = session.selection
                if let i = picked.firstIndex(of: id) { picked.remove(at: i) } else { picked.append(id) }
                session.select(picked, on: board ?? session.board)
            } else if !session.selection.contains(id) {
                session.select([id], on: board)
            }
            _ = try? stage.capturePointer(args?.pointer)
            drag = (p, board ?? -1, false, .move(duplicate: option))
            return
        }
        // Inside the box round several layers, a drag moves them all.
        if session.selection.count > 1, !shift, let box = WindowsCore.bounds(of: session.selection), box.contains(c) {
            _ = try? stage.capturePointer(args?.pointer)
            drag = (p, session.board ?? -1, false, .move(duplicate: option))
            return
        }
        // Alt on nothing takes the scene and turns the look: an artboard seen from the side (the
        // Mac's Control). What is picked stays picked.
        if option, session.tool == .select, session.mode == 0 {
            syncLook()
            if looking.down(at: p) {
                _ = try? stage.capturePointer(args?.pointer)
                drag = (p, session.board ?? -1, false, .look)
                return
            }
        }
        // Elsewhere a box is dragged out, adding to the selection with Shift.
        let inside = WindowsCore.board(at: c)
        let base = shift ? session.selection : []
        if !shift { session.select([], on: inside) }
        _ = try? stage.capturePointer(args?.pointer)
        drag = (p, inside ?? -1, false, .marquee(start: c, base: base, inside: inside))
    }

    private func moved(_ args: PointerRoutedEventArgs?) {
        let p = point(args)
        lastPoint = p
        liveCanvas.pointerMoved(to: inDesign(p), stage: p)
        // Placing a cut-out picture, the subject under the pointer lights up.
        if drag == nil, pictures.editing != nil || cutouts.hovering {
            syncCutouts()
            cutouts.hover(at: pictures.editing != nil ? p : nil)
        }
        if typingPress != nil {
            dragOnTyped(to: p)
            return
        }
        if case .deck? = drag?.grab {
            decks.drag(to: p)
            return
        }
        if drag == nil, session.mode == 0 {
            decks.hover(p, onCanvas: inDesign(p))
            if decks.spreading { showPointer(.arrow); return }
            if decks.points(at: p) { showPointer(.pointingHand); return }
            // The row of variants beside a copy picked: the canvas leaves what is under it alone.
            copyMarks.hover(p)
            if copyMarks.covers(p) {
                setHover(nil)
                showPointer(.pointingHand)
                return
            }
            // The word that looks from the front again takes the arrow, and nothing under it lights.
            pointLook(at: p)
            if lookHovered != nil {
                setHover(nil)
                showPointer(.arrow)
                return
            }
        }
        if WindowsCore.versions.lookingBack, drag == nil {
            hoverTime(WindowsCore.versions.layer(at: inDesign(p)))
            showPointer(timeHovered != nil ? .pointingHand : .arrow)
            return
        }
        if case .pan(let start)? = drag?.grab, let from = drag?.from {
            pan = CGPoint(x: Double(start.x) + Double(p.x) - Double(from.x), y: Double(start.y) + Double(p.y) - Double(from.y))
            spaceTap?.moved = true
            place()
            return
        }
        if case .motion? = drag?.grab {
            syncMotion()
            motion.drag(to: p, shift: shift, free: control, push: option)
            // A shape's point in hand catches on what lies around, as in the design.
            showGuides(motion.guideLines)
            drag?.moved = true
            updatePointer(at: p)
            return
        }
        // Animated, the pointer finds what is posed and what poses it.
        if animating, drag == nil {
            syncMotion()
            motion.hover(p)
            updatePointer(at: p)
            return
        }
        if case .inspect(let start, _)? = drag?.grab, let from = drag?.from {
            let dx = Double(p.x) - Double(from.x), dy = Double(p.y) - Double(from.y)
            guard drag?.moved == true || (dx * dx + dy * dy).squareRoot() >= 3 else { return }
            drag?.moved = true
            pan = CGPoint(x: Double(start.x) + dx, y: Double(start.y) + dy)
            showPointer(.grab)
            place()
            return
        }
        if case .note(let start)? = drag?.grab, let from = drag?.from {
            let dx = Double(p.x) - Double(from.x), dy = Double(p.y) - Double(from.y)
            guard drag?.moved == true || (dx * dx + dy * dy).squareRoot() >= 3 else { return }
            drag?.moved = true
            let c = inDesign(p)
            margin.notes.circle = CGRect(x: min(start.x, c.x), y: min(start.y, c.y), width: abs(c.x - start.x), height: abs(c.y - start.y))
            return
        }
        if case .flow? = drag?.grab {
            syncFlow()
            flow.drag(to: p) { [weak self] to in
                guard let self else { return }
                self.pan = to
                self.place()
            }
            drag?.moved = true
            if !flow.panning { session.edited(board: nil) }
            showPointer(pointer(at: p))
            return
        }
        // As a prototype, the pointer finds threads, flags and what a thread comes out of.
        if prototyping, drag == nil {
            syncFlow()
            flow.hover(p)
            showPointer(pointer(at: p))
            return
        }
        // Inspecting, the pointer measures what it is on.
        if inspecting, drag == nil {
            syncInspect()
            inspect.hover(p)
            showPointer(.arrow)
            return
        }
        if guideHand.pressed {
            syncGuides()
            guideHand.drag(to: p, shift: shift, option: option, command: control)
            updatePointer(at: p)
            return
        }
        if pen.dragging {
            syncPen()
            pen.drag(to: p, shift: shift, option: option, command: control)
            penChanged()
            return
        }
        if session.tool == .knife {
            syncPen()
            if knife.dragging { knife.drag(to: p, shift: shift) } else { knife.hover(p, shift: shift) }
            return
        }
        if drag == nil, session.tool == .pen || pen.editingPath != nil {
            syncPen()
            pen.hover(p, shift: shift, option: option, command: control)
            showGuides(pen.guideLines)
            if session.tool == .pen { return }
        }
        guard let d = drag else {
            setHover(pick(p))
            // The corner dots show while the pointer is on the selected rectangle; the shadow's
            // outline while it is on the shadow.
            let dots = session.tool == .select && WindowsCore.onRectangle(p, selection: session.selection, zoom: zoom, pan: pan)
            let onShadow = session.tool == .select && WindowsCore.onShadow(p, selection: session.selection, zoom: zoom, pan: pan)
            if session.tool == .select {
                syncDepth()
                depth.hover(p)
                syncGrid()
                gridHand.hover(p)
                syncLayout()
                layoutHand.hover(p)
                syncBuild()
                builder.hover(p, option: option)
                syncOutline()
                outlineHand.hover(p, shift: shift, option: option)
                syncCurve()
                curveHand.hover(p)
                syncDevelop()
                develop.hover(p)
                // The word offered shows what it would do while it is pointed at.
                let lit = onOffer(p)
                if lit != offerLit, let offer = shownOffer {
                    offerLit = lit
                    // Shown made, what it cuts off fading; let go, it grows back before it goes.
                    maskMarks.preview(offer, lit)
                    session.previewed(board: nil)
                    placeOffer()
                }
                pointCopyOffer(at: p)
            }
            syncGuides()
            guideHand.hover(p)
            if dots != dotsShown || onShadow != shadowShown {
                dotsShown = dots
                shadowShown = onShadow
                placeHolds()
            }
            updatePointer(at: p)
            return
        }
        if case .picture = d.grab {
            syncPictures()
            pictures.drag(to: p, shift: shift, option: option, command: control)
            drag?.moved = true
            placeHolds()
            showPointer(pointer(at: p))
            return
        }
        if case .depth = d.grab {
            syncDepth()
            depth.drag(to: p, shift: shift, option: option)
            drag?.moved = true
            session.edited(board: d.board)
            return
        }
        if case .look = d.grab {
            syncLook()
            // The picture is drawn again only when the look has turned; how far says itself by the pointer.
            if looking.drag(to: p, steps: shift) { lookChanged(looking.board) } else { placeHolds() }
            drag?.moved = true
            return
        }
        if case .outline = d.grab {
            syncOutline()
            outlineHand.drag(to: p, shift: shift, option: option)
            drag?.moved = true
            session.edited(board: d.board >= 0 ? d.board : nil)
            showPointer(pointer(at: p))
            return
        }
        if case .build = d.grab {
            syncBuild()
            builder.drag(to: p, option: option)
            showPointer(pointer(at: p))
            return
        }
        if case .develop = d.grab {
            syncDevelop()
            develop.drag(to: p, slow: option)
            drag?.moved = true
            session.edited(board: nil)
            showPointer(pointer(at: p))
            return
        }
        if case .curve = d.grab {
            syncCurve()
            curveHand.drag(to: p, command: control)
            drag?.moved = true
            session.edited(board: nil)
            return
        }
        if case .grid = d.grab {
            syncGrid()
            gridHand.drag(to: p, shift: shift)
            drag?.moved = true
            session.edited(board: d.board >= 0 ? d.board : nil)
            return
        }
        if case .layout = d.grab {
            syncLayout()
            layoutHand.drag(to: p)
            drag?.moved = true
            session.edited(board: d.board >= 0 ? d.board : nil)
            return
        }
        let dx = (Double(p.x) - Double(d.from.x)) / zoom, dy = (Double(p.y) - Double(d.from.y)) / zoom
        // A drag begins once the pointer has gone 3 points, as on the Mac.
        guard d.moved || (dx * dx + dy * dy).squareRoot() * zoom > 3 else { return }
        let first = !d.moved
        drag?.moved = true
        // From where the gesture began: the core makes the change again from there. Ctrl, as
        // Command on the Mac, keeps anything from catching.
        switch d.grab {
        case .draw(let id, let kind, let start, let board):
            var end = inDesign(p)
            // With Shift, a square or a circle; a line keeps to the nearest eighth of a turn.
            if shift {
                let w = Double(end.x) - Double(start.x), h = Double(end.y) - Double(start.y)
                if kind == "line" {
                    let angle = (atan2(h, w) / (.pi / 4)).rounded() * (.pi / 4), length = (w * w + h * h).squareRoot()
                    end = CGPoint(x: Double(start.x) + cos(angle) * length, y: Double(start.y) + sin(angle) * length)
                } else {
                    let side = max(abs(w), abs(h))
                    end = CGPoint(x: Double(start.x) + (w < 0 ? -side : side), y: Double(start.y) + (h < 0 ? -side : side))
                }
            }
            WindowsCore.draw(id, kind: kind, from: start, to: CGPoint(x: Double(end.x).rounded(), y: Double(end.y).rounded()), board: board, click: false, like: drawLike)
            session.edited(board: board)
            return
        case .move(let duplicate):
            if first {
                let moving = WindowsCore.beginMove(session.selection, duplicate: duplicate)
                if duplicate { session.select(moving, on: session.board) }
                altLetGo = !duplicate
            }
            if !option { altLetGo = true }
            syncCurve()
            if case .handled = curveHand.moving(session.selection, from: inDesign(d.from), at: p) {
                if dip?.opened == nil, dip != nil {
                    dip = nil
                    drawDip()
                }
                showGuides([])
                session.edited(board: nil)
                return
            }
            // Alt pressed once it is under way brings it nearer going up and sends it further going
            // down, staying where it is across (`DepthPushing`, shared).
            showGuides(WindowsCore.move(by: CGPoint(x: dx, y: dy), deep: option && altLetGo, constrain: shift, snapping: !control, zoom: zoom))
            showPointer(WindowsCore.pushingInDepth ? .upDown : .arrow)
            if curveHand.claims {
                if dip?.opened == nil, dip != nil {
                    dip = nil
                    drawDip()
                }
            } else {
                dipMoved(at: p)
            }
        case .handle(let k):
            showGuides(WindowsCore.resize(session.selection, handle: k, to: inDesign(p), keep: shift, fromCenter: option, snapping: !control, zoom: zoom))
            WindowsCore.measureSize(session.selection)
        case .turn, .corner:
            WindowsCore.hold(to: inDesign(p), shift: shift, option: option)
        case .shadow:
            if first, let id = session.selection.first { WindowsCore.beginShadow(id, at: inDesign(d.from)) }
            WindowsCore.hold(to: inDesign(p), shift: shift, option: option)
        case .depth, .look, .grid, .layout, .pan, .build, .outline, .curve, .develop, .inspect, .flow, .note, .deck, .picture, .motion:
            return
        case .lineEnd(let k):
            guard let id = session.selection.first else { return }
            WindowsCore.moveLineEnd(id, end: k, to: inDesign(p), constrain: shift)
        case .marquee(let start, let base, let inside):
            let end = inDesign(p)
            let box = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
            let picked = WindowsCore.marquee(box, onBoard: inside, zoom: zoom)
            // Picked again only when the box takes in something else: picking makes the panels
            // again, and the box moves at every step.
            let next = base + picked.filter { !base.contains($0) }
            if next != session.selection || (inside ?? session.board) != session.board { session.select(next, on: inside ?? session.board) }
            showMarquee(box)
            return
        }
        session.edited(board: d.board)
    }

    private func released(_ args: PointerRoutedEventArgs?) {
        if typingPress != nil {
            typingPress = nil
            try? stage.releasePointerCapture(args?.pointer)
            return
        }
        if guideHand.pressed {
            try? stage.releasePointerCapture(args?.pointer)
            syncGuides()
            guideHand.up(at: point(args), shift: shift, option: option, command: control)
            session.edited(board: nil)
            return
        }
        if knife.dragging {
            try? stage.releasePointerCapture(args?.pointer)
            syncPen()
            knife.up(at: point(args))
            knifeChanged()
            return
        }
        if pen.dragging {
            try? stage.releasePointerCapture(args?.pointer)
            syncPen()
            pen.up(at: point(args), shift: shift, option: option, command: control)
            showGuides([])
            penChanged()
            return
        }
        guard let d = drag else { return }
        drag = nil
        lastPressDragged = d.moved
        try? stage.releasePointerCapture(args?.pointer)
        showGuides([])
        switch d.grab {
        case .draw(let id, let kind, let start, let board):
            let under = textUnderPress
            textUnderPress = nil
            if kind == "text", !d.moved, let under, let at = WindowsCore.board(of: under) {
                WindowsCore.endGesture()
                session.select([under], on: at)
                beginEditing(under, board: at)
                return
            }
            if !d.moved { WindowsCore.draw(id, kind: kind, from: start, to: start, board: board, click: true, like: drawLike) }
            WindowsCore.endGesture()
            // What was drawn is picked; the tool is put down, but for Text, which stays in hand.
            if kind == "artboard" {
                session.select([], on: WindowsCore.boardIndex(of: id))
            } else {
                session.select([id], on: board)
            }
            if kind != "text" { session.tool = .select }
            // A shape just drawn over a picture offers to mask it.
            WindowsCore.inviteMask(session.selection)
            session.edited(board: kind == "artboard" ? nil : board)
            // Typed into at once, on an artboard or on the canvas beside them (where its own place
            // among the design's layers stands for an artboard's), as on the Mac.
            if kind == "text", let at = board ?? WindowsCore.board(of: id) { beginEditing(id, board: at) }
        case .move:
            // Dropped riding an edge, it stays on it, settled where it lies.
            syncCurve()
            if d.moved, curveHand.released().rides {
                dip = nil
                drawDip()
                WindowsCore.endRide(session.selection)
                session.select(session.selection, on: session.selection.first.flatMap(WindowsCore.board(of:)) ?? session.board)
                session.edited(board: nil)
                return
            }
            // Dropped, each goes onto the artboard its middle is over, or off onto the canvas.
            if d.moved {
                // Into the shape it opened, the mask is what is picked; dragged wholly off the mask
                // it lay in, it comes out of it, as one step with the move.
                let opened = dip?.opened?.mask
                dip = nil
                let leaving = opened == nil ? WindowsCore.leavingMask(session.selection) : nil
                // Coming out, the mask's outline runs out once, as it was; going in, it draws in.
                if let leaving { maskMarks.ring(leaving, out: true) }
                drawDip()
                WindowsCore.endMove(takingOut: leaving != nil)
                if let opened, WindowsCore.board(of: opened) != nil { maskMarks.ring(opened, out: false) }
                let picked = opened.flatMap { WindowsCore.board(of: $0) != nil ? [$0] : nil } ?? session.selection
                session.select(picked, on: picked.first.flatMap(WindowsCore.board(of:)) ?? session.board)
                WindowsCore.inviteMask(session.selection)
                session.edited(board: nil)
            }
        case .handle:
            WindowsCore.endPull()
            WindowsCore.clearMeasure()
            if d.moved {
                WindowsCore.inviteMask(session.selection)
                session.edited(board: d.board)
            }
        case .turn, .corner:
            WindowsCore.letGo()
            session.edited(board: d.board)
        case .depth:
            syncDepth()
            depth.up(at: point(args), adding: shift)
            // A click outside what is picked picks what is there.
            if depth.selection != session.selection {
                session.select(depth.selection, on: depth.selection.first.flatMap(WindowsCore.board(of:)) ?? session.board)
            }
            session.edited(board: d.board)
        case .look:
            // A click, nothing dragged, looks from the front again.
            let board = looking.board
            if looking.up() { lookChanged(board) } else { placeOverlays() }
        case .grid:
            gridHand.up()
            session.edited(board: d.board >= 0 ? d.board : nil)
        case .curve:
            curveHand.up()
            session.edited(board: nil)
            updatePointer(at: point(args))
        case .flow:
            syncFlow()
            flow.up(at: point(args))
            session.edited(board: nil)
            updatePointer(at: point(args))
        case .motion:
            syncMotion()
            motion.up(at: point(args), shift: shift)
            drawMotion()
            updatePointer(at: point(args))
        case .deck:
            decks.up(at: point(args))
        case .picture:
            // Let go past covering, it springs back to rest.
            pictures.up()
            placeHolds()
            drawPictures()
            updatePointer(at: point(args))
        case .note(let start):
            let c = inDesign(point(args))
            if d.moved, let circle = margin.notes.circle, circle.width > 0 || circle.height > 0 {
                margin.notes.begin(around: circle)
            } else {
                margin.notes.begin(at: start, on: pick(point(args)) ?? WindowsCore.boardID(at: c))
            }
            // Written, the tool goes back to picking, as on the Mac.
            session.tool = .select
        case .inspect(_, let target):
            showPointer(.arrow)
            guard !d.moved else { return }
            syncInspect()
            let picked = target.map { [inspect.pick(for: $0)] } ?? []
            session.select(picked, on: picked.first.flatMap(WindowsCore.board(of:)) ?? WindowsCore.boardIndex(of: picked.first ?? UUID()))
            syncInspect()
            inspect.hover(point(args))
            drawInspect()
        case .develop:
            syncDevelop()
            develop.up(at: point(args))
            // A colour pressed on shows its rows in the card.
            if let band = develop.pressedBand { session.pickPhotoBand?(band) }
            session.edited(board: nil)
            updatePointer(at: point(args))
        case .layout:
            layoutHand.up()
            session.edited(board: d.board >= 0 ? d.board : nil)
        case .pan:
            updatePointer(at: point(args))
        case .build:
            syncBuild()
            builder.up(at: point(args))
        case .outline:
            syncOutline()
            outlineHand.up()
            session.edited(board: d.board >= 0 ? d.board : nil)
        case .shadow:
            if d.moved {
                WindowsCore.letGo()
                session.edited(board: d.board)
            } else {
                // Only a click, on the shadow: whatever is there is picked, as anywhere else.
                let id = pick(point(args))
                session.select(id.map { [$0] } ?? [], on: id.flatMap(WindowsCore.board(of:)) ?? session.board)
            }
        case .lineEnd:
            WindowsCore.endGesture()
            if d.moved { session.edited(board: d.board) }
        case .marquee:
            showMarquee(nil)
        }
    }

    /// A key let go: Space puts the hand away.
    func keyUp(_ args: KeyRoutedEventArgs?) {
        guard let args, args.key == .space, spaceDown else { return }
        args.handled = true
        spaceDown = false
        // Pressed and let go without moving the view: the film plays, or stops.
        if animating, let tap = spaceTap, !tap.moved, WindowsCore.now - tap.at < 0.4, drag == nil { session.film.toggle() }
        spaceTap = nil
        if let p = lastPoint { updatePointer(at: p) }
    }

    // MARK: The pointer

    /// Shows a pointer over the canvas, rulers and all.
    private func showPointer(_ pointer: Pointer) {
        guard pointer != shownPointer else { return }
        shownPointer = pointer
        root.protectedCursor = pointer.cursor
    }

    private func updatePointer(at p: CGPoint) { showPointer(pointer(at: p)) }

    /// What the pointer shows at `p` on the stage, in the order the Mac's canvas asks its tools
    /// (CanvasView.updateCursor).
    private func pointer(at p: CGPoint) -> Pointer {
        if case .pan? = drag?.grab { return .grab }
        if spaceDown { return .grab }
        if animating {
            syncMotion()
            switch motion.pointer(at: p) {
            case .arrow: return .arrow
            case .resize(let a): return .resize(a)
            case .rotate(let a): return .rotate(a)
            case .turn: return .turn
            case .cross: return .cross
            case .pointingHand: return .pointingHand
            case .grab, .grabbing: return .grab
            }
        }
        // Over the words typed into, the I-beam that puts the caret.
        if editing != nil, typingPress != nil || WindowsCore.typingCovers(inDesign(p), slack: 4 / zoom) { return .iBeam }
        syncGuides()
        switch guideHand.pointer(at: p) {
        case .across?: return .across
        case .upDown?: return .upDown
        case .cross?: return .cross
        case .pointingHand?: return .pointingHand
        case .arrow?: return .arrow
        case nil: break
        }
        syncLayout()
        if let across = layoutHand.pointer(at: p) { return across ? .across : .upDown }
        if drag == nil, onOffer(p) || copyButtons.contains(where: { $0.rect.insetBy(dx: -2, dy: -3).contains(p) }) { return .pointingHand }
        // The word that looks from the front again takes the arrow, as on the Mac.
        if drag == nil, session.mode == 0, lookWord(at: p) != nil { return .arrow }
        if prototyping {
            syncFlow()
            switch flow.pointer(at: p) {
            case .grab, .grabbing: return .grab
            case .pointing: return .pointingHand
            case .arrow: return .arrow
            }
        }
        if session.tool == .pen { return .pen(Self.penMark(pen.mark)) }
        syncDevelop()
        switch develop.pointer(at: p) {
        case .cross?: return .cross
        case .across?: return .across
        case .upDown?: return .upDown
        case nil: break
        }
        if session.tool == .select, pen.editingPath != nil { return pen.mark == "add" ? .pen(1) : .arrow }
        // Over a picture being placed: a corner sizes it, the rest moves it.
        syncPictures()
        switch pictures.pointer(at: p) {
        case .resize(let a)?: return .resize(a)
        case .hand?: return .grab
        case nil: break
        }
        syncDepth()
        if depth.turnsPointer { return .turn }
        syncGrid()
        switch gridHand.pointer(at: p) {
        case .resize(let a)?: return .resize(a)
        case .turn(let a)?: return .rotate(a)
        case nil: break
        }
        syncCurve()
        if curveHand.grabs(at: p) { return .grab }
        if let b = builder.pointer { return b.onPiece ? .build(erase: b.erase) : .arrow }
        syncOutline()
        switch outlineHand.pointer(at: p) {
        case .cross?: return .cross
        case .across(let a)?: return .resize(a)
        case nil: break
        }
        switch session.tool {
        case .knife:
            return .knife
        case .select:
            switch WindowsCore.handlePointer(at: p, selection: session.selection, zoom: zoom, pan: pan, selecting: editing == nil) {
            case .resize(let a)?: return .resize(a)
            case .rotate(let a)?: return .rotate(a)
            case .cross?: return .cross
            case .grab?: return .grab
            case .turn?: return .turn
            case nil: return .arrow
            }
        case .text:
            // The selected text's handles resize it with the Text tool in hand too.
            if case .resize(let a)? = WindowsCore.handlePointer(at: p, selection: session.selection, zoom: zoom, pan: pan, selecting: false) {
                return .resize(a)
            }
            return .iBeam
        default:
            return .cross
        }
    }

    /// The mark the pen's pointer shows beside its nib, by what a click does there.
    private static func penMark(_ mark: String) -> Int {
        switch mark {
        case "add": 1
        case "remove": 2
        case "close": 3
        case "convert": 4
        case "carryOn": 5
        default: 0
        }
    }

    /// A drag taken back: the design as it was when it began, and no step made. What is held
    /// stays held until the button comes up, doing nothing more.
    private func cancelDrag(_ grab: Grab, moved: Bool) {
        drag = nil
        switch grab {
        case .move:
            if moved { WindowsCore.cancelMove() }
            curveHand.cancel()
            dip = nil
            drawDip()
        case .handle:
            WindowsCore.cancelMove()
        case .lineEnd, .draw:
            WindowsCore.cancelGesture()
        case .turn, .corner, .shadow:
            WindowsCore.cancelHold()
        case .marquee:
            showMarquee(nil)
        case .depth:
            depth.cancel()
        case .look:
            // Looked at as before the drag; the design itself was never touched.
            let board = looking.board
            if looking.cancel() { lookChanged(board) } else { placeOverlays() }
            return
        case .grid:
            gridHand.cancel()
        case .layout:
            layoutHand.cancel()
        case .pan:
            break
        case .build:
            _ = builder.key("escape")
        case .outline:
            outlineHand.cancel()
        case .curve:
            curveHand.cancel()
        case .develop:
            _ = develop.cancel()
        case .inspect:
            break
        case .flow:
            _ = flow.cancel()
        case .note:
            margin.notes.circle = nil
        case .deck:
            _ = decks.cancel()
        case .picture:
            pictures.cancelDrag()
            placeHolds()
        case .motion:
            motion.cancel()
        }
        showGuides([])
        session.edited(board: nil)
    }

    /// Rectangles, ellipses and lines become paths, and texts the outlines of their letters
    /// (Ctrl+8, the Mac's ⌘8), as one step; a beep for texts whose letters are pictures (emoji).
    private func convertToPath() {
        let selection = session.selection
        guard WindowsCore.canConvertToPath(selection) else { MessageBeep(0); return }
        // Words being typed are the text's before it is outlined.
        if editing != nil { endEditing() }
        let done = WindowsCore.convertToPath(selection)
        if done.refused { MessageBeep(0) }
        guard done.changed else { return }
        session.select(selection, on: session.board)
        session.edited(board: nil)
    }

    /// Each selected layer's border made a shape of its own (Ctrl+Alt+O, the Mac's ⌥⌘O).
    private func outlineBorders() {
        let made = WindowsCore.outlineBorders(session.selection)
        guard !made.isEmpty else { MessageBeep(0); return }
        session.select(made, on: session.board)
        session.edited(board: nil)
    }

    /// The tools that draw a layer, and the kind each draws; the others are to come.
    private func drawn(_ tool: Glyphs.Tool) -> String? {
        switch tool {
        case .artboard: "artboard"
        case .rectangle: "rectangle"
        case .ellipse: "ellipse"
        case .line: "line"
        case .text: "text"
        default: nil
        }
    }

    // MARK: Typing

    /// A double click goes into a group, one level each time; on a text, it starts typing.
    private func doubleTapped(_ args: DoubleTappedRoutedEventArgs?) {
        // Animated, a double click is the film's (`MotionHand`, a shape's points taken in hand
        // there): the design's own points, groups and words are not opened under it. Nor under a
        // prototype, whose hand has the second click already (`FlowHand.down`: a screen played, a
        // thread's note written, a group gone into), nor under Inspect, where nothing changes.
        if animating || prototyping || inspecting { return }
        // A double click that began placing a picture, or ended it, is placing's alone.
        if pictureTookPress {
            pictureTookPress = false
            return
        }
        // The press that made it a double click went into a group already.
        if pressEntered {
            pressEntered = false
            return
        }
        guard let q = try? args?.getPosition(stage) else { return }
        let p = CGPoint(x: Double(q.x), y: Double(q.y))
        // On the words typed into, two clicks pick out a word (`pressOnTyped`).
        if editing != nil, WindowsCore.typingCovers(inDesign(p), slack: 4 / zoom) { return }
        guard let id = pick(p), let board = WindowsCore.board(of: id) else { return }
        // A double click on a path edits its points, as on the Mac.
        if WindowsCore.isPath(id), session.tool == .select, pen.editingPath == nil {
            session.select([id], on: board)
            syncPen()
            pen.editSelectedPoints()
            penChanged()
            return
        }
        if WindowsCore.isGroup(id), let inner = WindowsCore.pick(inDesign(p), inGroup: id, zoom: zoom) {
            session.select([inner], on: board)
            return
        }
        guard WindowsCore.isText(id) else { return }
        session.select([id], on: board)
        beginEditing(id, board: board)
    }

    /// Typing into a text, as the Mac's editor: one step for all of it. The canvas draws the
    /// words as they are, each letter in its own look (straight, for words on a curve), and over
    /// them the caret, the letters picked out and the misspelt words; a field no one sees takes
    /// the keys, and each change it hears is made to the text's runs (`WindowsCore.typed`).
    /// Presses on the words put the caret and pick letters out; Up, Down, Home and End and the
    /// picking with Shift go by the lines the core lays.
    private func beginEditing(_ id: UUID, board: Int) {
        guard !WindowsCore.isReadOnly, let layer = WindowsCore.layers(board: board).first(where: { $0.id == id }), layer.isText else { return }
        endEditing()
        guard let words = WindowsCore.beginTyping(id) else { return }
        editing = (id, board)
        let field = TextBox()
        // Unseen, and out of the pointer's way (clipped to nothing), yet hit-testable: WinUI
        // changes a text box's words, but tells no one (TextChanged), while it is not.
        field.opacity = 0.01
        let nothing = RectangleGeometry()
        nothing.rect = Rect(x: 0, y: 0, width: 0, height: 0)
        field.clip = nothing
        field.isSpellCheckEnabled = false
        field.isTextPredictionEnabled = false
        field.fontFamily = Theme.ui
        field.fontSize = max(1, (layer.fontSize ?? 12) * zoom)
        field.background = Theme.clear
        field.borderThickness = Theme.inset(0)
        field.padding = Theme.inset(0)
        field.minWidth = 4
        field.minHeight = 0
        field.acceptsReturn = true
        field.textWrapping = .wrap
        // Its words once it takes more than one line: given before, a text box keeps the first alone,
        // and typing into a text of several lines then lost every line but the first.
        field.text = words
        field.textChanged.addHandler { [weak self] _, _ in self?.fieldTyped() }
        field.selectionChanged.addHandler { [weak self] _, _ in self?.fieldPicked() }
        // Before the field: Esc, the editor's own Undo, the Format keys and the keys that go by lines.
        field.previewKeyDown.addHandler { [weak self] _, args in self?.typingKey(args) }
        // Focus once it is on screen: before, WinUI gives it none. Every letter picked out, as on the Mac.
        field.loaded.addHandler { [weak self] sender, _ in
            guard let field = sender as? TextBox else { return }
            _ = try? field.focus(.programmatic)
            self?.pickLetters(anchor: 0, active: (words as NSString).length)
        }
        // The field keeps the keys while it is typed into: WinUI moves the focus on (to a panel's
        // scroller) once the double click that began the typing lets go. Another field taking
        // them ends the typing, as leaving the text for a field does on the Mac; a press on the
        // canvas away from the words ends it before the canvas takes them.
        field.losingFocus.addHandler { [weak self] _, args in
            guard let self, self.editing != nil, let args else { return }
            if args.newFocusedElement is TextBox {
                DispatchQueue.main.async { MainActor.assumeIsolated { if self.editing?.id == id { self.endEditing(focusing: false) } } }
                return
            }
            _ = try? args.tryCancel()
        }
        editorLayer.children.append(field)
        editor = field
        typingAnchor = 0
        typingActive = (words as NSString).length
        placeEditor()
        redraw(board: board)
        caretMoved()
        session.changed()
    }

    /// Keeps the field near the words, where Windows shows what an input method is composing.
    private func placeEditor() {
        guard let editing, let field = editor else { return }
        if let typed = WindowsCore.typingPlace(of: editing.id) {
            let o = onStage(typed.frame.origin)
            let w = Double(typed.frame.width) * zoom, h = Double(typed.frame.height) * zoom
            try? Canvas.setLeft(field, Double(o.x))
            try? Canvas.setTop(field, Double(o.y))
            field.width = max(w + 24, 24)
            let t = CompositeTransform()
            t.centerX = w / 2
            t.centerY = h / 2
            t.rotation = typed.rotation
            field.renderTransform = t
            return
        }
        field.renderTransform = nil
        guard let box = onStage(layer: editing.id, board: editing.board) else { return }
        try? Canvas.setLeft(field, Double(box.minX))
        try? Canvas.setTop(field, Double(box.minY))
        field.width = max(Double(box.width) + 24, 24)
    }

    /// The field's words, as the text keeps them (WinUI's text box breaks lines with \r).
    private var fieldWords: String { editor.map { $0.text.replacingOccurrences(of: "\r", with: "\n") } ?? "" }

    /// The words changed in the field: the change made to the text's runs, the caret after it.
    private func fieldTyped() {
        guard let field = editor, let editing else { return }
        let words = fieldWords
        // The field shown words it was given (undoing, a spelling chosen): nothing typed.
        guard words != WindowsCore.typingWords else { return }
        let caret = NSRange(location: Int(field.selectionStart), length: Int(field.selectionLength))
        WindowsCore.typed(words, caret: caret)
        typingAnchor = caret.location
        typingActive = NSMaxRange(caret)
        typingGoal = nil
        session.edited(board: editing.board)
        placeEditor()
        caretMoved()
    }

    /// The field's caret moved, or letters were picked out in it.
    private func fieldPicked() {
        guard !settingField, let field = editor, editing != nil else { return }
        // The words are changing: the caret comes with them (`fieldTyped`).
        guard fieldWords == WindowsCore.typingWords else { return }
        let start = Int(field.selectionStart), length = Int(field.selectionLength)
        let shown = NSRange(location: min(typingAnchor, typingActive), length: abs(typingActive - typingAnchor))
        guard NSRange(location: start, length: length) != shown else { return }
        // Picked out from the end it was picked out from, when only the other end moved.
        if length > 0, typingAnchor == start || typingAnchor == start + length {
            typingActive = typingAnchor == start ? start + length : start
        } else {
            typingAnchor = start
            typingActive = start + length
        }
        typingGoal = nil
        lettersPicked(NSRange(location: start, length: length))
    }

    /// Picks letters out from `anchor` to `active` (the caret, when they are the same), in the
    /// field and in the text.
    private func pickLetters(anchor: Int, active: Int) {
        guard let field = editor else { return }
        typingAnchor = anchor
        typingActive = active
        let r = NSRange(location: min(anchor, active), length: abs(active - anchor))
        settingField = true
        try? field.select(Int32(r.location), Int32(r.length))
        settingField = false
        lettersPicked(r)
    }

    private func lettersPicked(_ r: NSRange) {
        if WindowsCore.pick(r) { cardsFollow() }
        caretMoved()
    }

    /// The cards show the letters picked out, a moment after they change (not at every step of a drag).
    private func cardsFollow() {
        guard !cardsPending else { return }
        cardsPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cardsPending = false
                self.session.changed()
            }
        }
    }

    /// Words and what is picked out given to the field, from the text (the editor's Undo, a
    /// spelling chosen), not as typed.
    private func putInField(_ words: String, picked r: NSRange) {
        guard let field = editor else { return }
        settingField = true
        field.text = words
        try? field.select(Int32(r.location), Int32(r.length))
        settingField = false
        typingAnchor = r.location
        typingActive = NSMaxRange(r)
        typingGoal = nil
        cardsFollow()
        caretMoved()
    }

    /// The caret shows again where it is now, and blinks on from there.
    private func caretMoved() {
        caretOn = true
        drawTyping()
        blink?.invalidate()
        blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.editing != nil else { return }
                self.caretOn.toggle()
                self.caretPath?.visibility = self.caretOn ? .visible : .collapsed
            }
        }
    }

    /// The caret, the letters picked out (washed in pencil, as the Mac's editor picks them out)
    /// and the misspelt words (a red wave under each, words said twice a green dotted line).
    private func drawTyping() {
        if typingMarks.parent == nil {
            typingMarks.isHitTestVisible = false
            overlay.children.append(typingMarks)
        }
        typingMarks.children.clear()
        caretPath = nil
        guard let editing, session.mode == 0, !letters.hidden.contains(editing.id), let marks = WindowsCore.typingMarks(zoom: zoom) else { return }
        func n(_ v: Double) -> String { String(format: "%.2f", v) }
        func shape(_ quad: [CGPoint]) -> String {
            guard quad.count == 4 else { return "" }
            let points = quad.map(onStage)
            return "M" + points.map { n(Double($0.x)) + "," + n(Double($0.y)) }.joined(separator: " L") + " Z "
        }
        @discardableResult func path(_ data: String, fill: Brush? = nil, stroke: Brush? = nil, width: Double = 1, dashes: [Double] = []) -> WinUI.Path? {
            guard !data.isEmpty, let p = (try? XamlReader.load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='F1 \(data)'/>")) as? WinUI.Path else { return nil }
            p.fill = fill
            p.stroke = stroke
            p.strokeThickness = width
            p.strokeStartLineCap = .round
            p.strokeEndLineCap = .round
            p.strokeLineJoin = .round
            if !dashes.isEmpty {
                let d = DoubleCollection()
                for v in dashes { d.append(v) }
                p.strokeDashArray = d
            }
            typingMarks.children.append(p)
            return p
        }
        path(marks.picked.map(shape).joined(), fill: Theme.brush(Theme.selection, 0.22))
        path(marks.misspelt.map { Self.squiggle(under: $0.map(onStage)) }.joined(), stroke: Theme.brush(0xE02929, 0.8), width: 1.2)
        let dotted = marks.repeated.map { q -> String in
            let a = onStage(q[3]), b = onStage(q[2])
            return "M\(n(Double(a.x))),\(n(Double(a.y) + 1)) L\(n(Double(b.x))),\(n(Double(b.y) + 1)) "
        }.joined()
        path(dotted, stroke: Theme.brush(0x2E9E4F, 0.9), width: 1.6, dashes: [0.1, 2])
        if let caret = marks.caret, let p = path(shape(caret), fill: Theme.brush(Theme.selection)) {
            p.visibility = caretOn ? .visible : .collapsed
            caretPath = p
        }
    }

    /// Typing is done: one step; an empty text is not kept, unless it is a cell's or a post's
    /// words. The keys go back to the canvas, unless another field took them.
    private func endEditing(focusing: Bool = true) {
        guard let done = editing else { return }
        editing = nil
        typingPress = nil
        blink?.invalidate()
        blink = nil
        typingMarks.children.clear()
        caretPath = nil
        if let field = editor {
            var k: UInt32 = 0
            if (try? editorLayer.children.indexOf(field, &k)) == true { editorLayer.children.removeAt(k) }
        }
        editor = nil
        if (WindowsCore.text(of: done.id) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !WindowsCore.keepsWhenEmpty(done.id) {
            WindowsCore.delete([done.id])
            session.select([], on: done.board)
        }
        WindowsCore.endTyping()
        session.edited(board: done.board)
        if focusing { _ = try? root.focus(.programmatic) }
    }

    // MARK: Keys while typing

    /// The keys the field is not to have: Esc, the editor's Undo and Redo, the Format menu's
    /// keys (Ctrl for the Mac's ⌘), the keys that go by the lines the core lays (Up, Down, Home,
    /// End, and picking out with Shift), Return on an empty item of a list and Backspace at the
    /// start of one, which end the list there, and Tab in a deck, which goes on to the next post.
    private func typingKey(_ args: KeyRoutedEventArgs?) {
        guard let args, let editing else { return }
        let ctrl = control, shift = self.shift, alt = option
        // AltGr is Ctrl and Alt together: what it types is the field's.
        if ctrl && alt { return }
        func format(_ f: WindowsCore.TextFormat) {
            args.handled = true
            formatText(f)
        }
        let length = (fieldWords as NSString).length
        func go(to i: Int) {
            args.handled = true
            let at = min(max(i, 0), length)
            pickLetters(anchor: shift ? typingAnchor : at, active: at)
        }
        switch args.key {
        case .escape:
            args.handled = true
            endEditing()
        case .z where ctrl: args.handled = true; stepTyping(back: !shift)
        case .y where ctrl: args.handled = true; stepTyping(back: false)
        case .b where ctrl: format(.bold)
        case .i where ctrl: format(.italic)
        case .u where ctrl: format(.underline)
        case .x where ctrl && shift: format(.strikethrough)
        case .number8 where ctrl && shift: format(.bulletList)
        case .number7 where ctrl && shift: format(.numberList)
        case .up, .down:
            let goal = typingGoal
            let to = WindowsCore.typingLine(from: typingActive, by: args.key == .up ? -1 : 1, x: goal)
            go(to: to.index)
            typingGoal = to.x
        case .home where ctrl: go(to: 0)
        case .end where ctrl: go(to: length)
        case .home: go(to: WindowsCore.typingLineEdge(from: typingActive, end: false))
        case .end: go(to: WindowsCore.typingLineEdge(from: typingActive, end: true))
        case .left where shift: go(to: ctrl ? WindowsCore.typingWordStep(from: typingActive, forward: false) : WindowsCore.typingLetterStep(from: typingActive, forward: false))
        case .right where shift: go(to: ctrl ? WindowsCore.typingWordStep(from: typingActive, forward: true) : WindowsCore.typingLetterStep(from: typingActive, forward: true))
        case .enter where !shift, .back:
            if WindowsCore.typingEndsList(onReturn: args.key == .enter) {
                args.handled = true
                session.edited(board: editing.board)
                caretMoved()
            }
        case .tab:
            args.handled = true
            // Outside a deck, a tab, as the Mac's text view types one.
            if WindowsCore.typingInPost {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.typeOnInDeck(forward: !shift) } }
            } else if !shift {
                insertTyped("\t")
            }
        default:
            // Bigger and smaller: Ctrl+Shift with the full stop and the comma, as ⇧⌘. and ⇧⌘, on the Mac.
            let raw = args.key.rawValue
            if ctrl, shift, raw == 190 { format(.bigger) }
            if ctrl, shift, raw == 188 { format(.smaller) }
        }
    }

    /// Letters typed by the canvas rather than the field (a tab, which the field would take for
    /// going to the next control): in place of what is picked out, the caret after them.
    private func insertTyped(_ letters: String) {
        guard let editing, let t = WindowsCore.typing else { return }
        let ns = fieldWords as NSString
        let at = min(t.picked.location, ns.length)
        let r = NSRange(location: at, length: min(t.picked.length, ns.length - at))
        let words = ns.replacingCharacters(in: r, with: letters)
        let caret = NSRange(location: r.location + (letters as NSString).length, length: 0)
        WindowsCore.typed(words, caret: caret)
        putInField(words, picked: caret)
        session.edited(board: editing.board)
        placeEditor()
    }

    /// A command of the Format menu, on what is typed into or on the selected texts; a beep
    /// where there is no text.
    func formatText(_ f: WindowsCore.TextFormat) {
        let ids = editing.map { [$0.id] } ?? session.selection
        guard WindowsCore.format(f, ids) else { MessageBeep(0); return }
        session.edited(board: editing?.board ?? session.board)
        if editing != nil { caretMoved() }
    }

    /// The editor's own Undo and Redo while typing: each change taken back, words and looks.
    private func stepTyping(back: Bool) {
        guard let editing else { return }
        guard let now = back ? WindowsCore.undoTyping() : WindowsCore.redoTyping() else { MessageBeep(0); return }
        putInField(now.words, picked: now.picked)
        session.edited(board: editing.board)
    }

    /// In a deck, Tab goes on to the same words in the next post, as in a table, and Shift+Tab
    /// back; past the first or the last, nothing (the Mac's typeOn).
    private func typeOnInDeck(forward: Bool) {
        guard editing != nil, let next = WindowsCore.typingNextPost(forward: forward) else { return }
        endEditing()
        _ = WindowsCore.turn(next.deck, to: next.post, selection: [])
        guard let board = WindowsCore.board(of: next.id) else { return }
        session.select([next.id], on: board)
        session.previewed(board: nil)
        beginEditing(next.id, board: board)
    }

    // MARK: Pointer while typing

    /// A press on the words typed into: the caret there, with Shift as far as there, two clicks
    /// a word and three a paragraph; a drag picks letters out. The right button leaves what is
    /// picked out for the menu. Answers whether the press was on the words.
    private func pressOnTyped(_ args: PointerRoutedEventArgs?) -> Bool {
        let p = point(args)
        guard editing != nil, let i = WindowsCore.typingIndex(at: inDesign(p), slack: 4 / zoom) else { return false }
        let now = GetTickCount()
        let clicks: Int
        if let last = lastPress, now - last.time <= GetDoubleClickTime(), abs(Double(last.at.x - p.x)) <= 4, abs(Double(last.at.y - p.y)) <= 4 {
            clicks = last.clicks + 1
        } else {
            clicks = 1
        }
        lastPress = (p, now, clicks)
        if (try? args?.getCurrentPoint(stage))?.properties?.isRightButtonPressed == true { return true }
        _ = try? stage.capturePointer(args?.pointer)
        switch clicks {
        case 1:
            if shift { pickLetters(anchor: typingAnchor, active: i) } else { pickLetters(anchor: i, active: i) }
            typingPress = (1, NSRange(location: typingAnchor, length: 0))
        case 2:
            let word = WindowsCore.typingWord(at: i)
            pickLetters(anchor: word.location, active: NSMaxRange(word))
            typingPress = (2, word)
        default:
            let paragraph = WindowsCore.typingParagraph(at: i)
            pickLetters(anchor: paragraph.location, active: NSMaxRange(paragraph))
            typingPress = (3, paragraph)
        }
        return true
    }

    /// The press on the words dragged: the letters picked out as far as the pointer, by words
    /// or paragraphs after two or three clicks.
    private func dragOnTyped(to p: CGPoint) {
        guard let press = typingPress, let i = WindowsCore.typingIndex(at: inDesign(p), slack: -1) else { return }
        let from = press.from
        switch press.clicks {
        case 1:
            pickLetters(anchor: typingAnchor, active: i)
        default:
            let at = press.clicks == 2 ? WindowsCore.typingWord(at: i) : WindowsCore.typingParagraph(at: i)
            if at.location < from.location {
                pickLetters(anchor: NSMaxRange(from), active: at.location)
            } else {
                pickLetters(anchor: from.location, active: max(NSMaxRange(at), NSMaxRange(from)))
            }
        }
    }

    /// The right-click menu on the words typed into, as the Mac's text view has it: how a
    /// misspelt word under the pointer might be spelt, and leaving it or learning it; cutting,
    /// copying and pasting; the Format menu's commands; and the spelling's.
    private func typingMenu(at w: CGPoint, index i: Int) {
        guard let menus, let editing, let field = editor else { return }
        var entries: [MenuHost.Entry] = []
        let board = editing.board
        if let found = WindowsCore.typingMisspelt(at: i) {
            pickLetters(anchor: found.range.location, active: NSMaxRange(found.range))
            @MainActor func put(_ words: String) {
                guard let now = WindowsCore.replaceTyped(found.range, with: words) else { return }
                putInField(now.words, picked: now.picked)
                session.edited(board: board)
            }
            if found.repeated {
                entries.append(.item(Words.t("Delete Repeated Word")) { put("") })
            } else {
                if found.guesses.isEmpty { entries.append(.note("Windows has no spellings to offer for this word.")) }
                for guess in found.guesses.prefix(6) { entries.append(.item(guess) { put(guess) }) }
                entries.append(.separator)
                entries.append(.item(Words.t("Ignore Spelling")) { [weak self] in WindowsCore.ignoreTyped(found.word); self?.drawTyping() })
                entries.append(.item(Words.t("Learn Spelling")) { [weak self] in WindowsCore.learnTyped(found.word); self?.drawTyping() })
            }
            entries.append(.separator)
        } else if let picked = WindowsCore.typing?.picked, i < picked.location || i > NSMaxRange(picked) {
            pickLetters(anchor: i, active: i)
        }
        let picked = (WindowsCore.typing?.picked.length ?? 0) > 0
        entries += [
            .item("Cut", shortcut: "Ctrl+X", enabled: picked) { _ = try? field.cutSelectionToClipboard() },
            .item("Copy", shortcut: "Ctrl+C", enabled: picked) { _ = try? field.copySelectionToClipboard() },
            .item("Paste", shortcut: "Ctrl+V") { _ = try? field.pasteFromClipboard() },
            .item("Select All", shortcut: "Ctrl+A") { [weak self] in self?.pickLetters(anchor: 0, active: ((self?.fieldWords ?? "") as NSString).length) },
            .separator,
        ]
        entries += formatEntries()
        entries.append(.separator)
        entries += spellingEntries()
        menus.show(at: w, entries: entries)
    }

    /// The Mac's Format menu, as entries of a right-click menu.
    func formatEntries() -> [MenuHost.Entry] {
        [
            .item("Bold", shortcut: "Ctrl+B") { [weak self] in self?.formatText(.bold) },
            .item("Italic", shortcut: "Ctrl+I") { [weak self] in self?.formatText(.italic) },
            .item("Underline", shortcut: "Ctrl+U") { [weak self] in self?.formatText(.underline) },
            .item("Strikethrough", shortcut: "Ctrl+Shift+X") { [weak self] in self?.formatText(.strikethrough) },
            .separator,
            .item("Bigger", shortcut: "Ctrl+Shift+.") { [weak self] in self?.formatText(.bigger) },
            .item("Smaller", shortcut: "Ctrl+Shift+,") { [weak self] in self?.formatText(.smaller) },
            .separator,
            .item("Bulleted List", shortcut: "Ctrl+Shift+8") { [weak self] in self?.formatText(.bulletList) },
            .item("Numbered List", shortcut: "Ctrl+Shift+7") { [weak self] in self?.formatText(.numberList) },
        ]
    }

    /// The Mac's Spelling and Grammar menu: checking the design's words one by one, and
    /// whether misspelt words are marked while typing, and words said twice with them.
    func spellingEntries() -> [MenuHost.Entry] {
        let spelling = WindowsCore.checksSpelling, grammar = WindowsCore.checksGrammar
        return [
            .item("Check Spelling…", shortcut: "F7") { [weak self] in
                self?.endEditing()
                self?.checkSpelling?()
            },
            .item("Check Spelling While Typing", checked: spelling) { [weak self] in
                WindowsCore.checksSpelling = !spelling
                self?.drawTyping()
            },
            .item("Check Grammar With Spelling", checked: grammar) { [weak self] in
                WindowsCore.checksGrammar = !grammar
                self?.drawTyping()
            },
        ]
    }

    private var pinchCount = 0

    private func wheel(_ args: PointerRoutedEventArgs?) {
        guard let current = try? args?.getCurrentPoint(stage), let properties = current.properties else { return }
        let delta = Double(properties.mouseWheelDelta)
        let p = point(args)
        // Two fingers pinched on a touchpad: Windows turns the wheel and says Ctrl is held with it
        // (VirtualKeyModifiers' Control, 1), while no key is down.
        let pinched = UInt32(truncatingIfNeeded: args?.keyModifiers.rawValue ?? 0) & 1 != 0 && !control
        // With the camera in hand, a pinch on its film brings it closer, as on the Mac; the wheel
        // with Ctrl stays the view's.
        if animating, pinched {
            syncMotion()
            if motion.pinch(by: pow(1.0015, delta), at: p) {
                pinchEnds()
                drawMotion()
                args?.handled = true
                return
            }
        }
        if control || pinched {
            zoom(to: zoom * pow(1.0015, delta), around: p)
        } else if properties.isHorizontalMouseWheel || shift {
            pan.x = CGFloat(Double(pan.x) - delta)
            place()
        } else {
            pan.y = CGFloat(Double(pan.y) + delta)
            place()
        }
        args?.handled = true
    }

    /// A pinch on the camera is held to have ended when no more of it came for a third of a
    /// second (Windows does not say where one ends): all of it is then one step.
    private func pinchEnds() {
        pinchCount += 1
        let mine = pinchCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.33) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.pinchCount == mine else { return }
                self.motion.pinchEnded()
                self.drawMotion()
            }
        }
    }

    /// The Mac's zoom range (2% to 6400%), keeping `p` (on the stage) where it is.
    private func zoom(to z: Double, around p: CGPoint) {
        let next = min(64, max(0.02, z))
        guard next != session.zoom || flyingZoom != nil else { return }
        let before = inDesign(p)
        flyingZoom = nil
        session.zoom = next
        let after = onStage(before)
        pan = CGPoint(x: Double(pan.x) + Double(p.x) - Double(after.x), y: Double(pan.y) + Double(p.y) - Double(after.y))
        drawAll()
    }

    /// The Mac's zoom steps (Operations.swift).
    private static let steps = [0.02, 0.05, 0.1, 0.125, 0.25, 0.333, 0.5, 0.667, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64]

    private func step(in grow: Bool) {
        let next = grow ? Self.steps.first { $0 > zoom + 0.001 } : Self.steps.last { $0 < zoom - 0.001 }
        zoom(to: next ?? zoom, around: CGPoint(x: root.actualWidth / 2, y: root.actualHeight / 2))
    }

    // MARK: Keys

    /// The selected shapes made one, as the Arrange card's buttons do; a beep when they cannot be.
    private func combine(_ way: String) {
        guard WindowsCore.canCombine(session.selection) else { MessageBeep(0); return }
        guard let made = WindowsCore.combine(session.selection, way) else { MessageBeep(0); return }
        session.select([made], on: session.board)
        session.edited(board: session.board)
    }

    private var control: Bool { GetKeyState(Int32(VK_CONTROL)) < 0 }
    private var shift: Bool { GetKeyState(Int32(VK_SHIFT)) < 0 }
    private var option: Bool { GetKeyState(Int32(VK_MENU)) < 0 }

    // MARK: Commands, from the keys and the right-click menu

    private func duplicate() {
        guard !session.selection.isEmpty else { return }
        session.select(WindowsCore.duplicate(session.selection), on: session.board)
        session.edited(board: session.board)
    }

    private func group() {
        guard let made = WindowsCore.group(session.selection) else { return }
        session.select([made], on: session.board)
        session.edited(board: session.board)
    }

    private func ungroup() {
        let freed = WindowsCore.ungroup(session.selection)
        guard !freed.isEmpty else { return }
        session.select(session.selection.filter { WindowsCore.board(of: $0) != nil } + freed, on: session.board)
        session.edited(board: session.board)
    }

    /// The selection made a repeat grid of one cell. A beep when it cannot be.
    private func makeRepeatGrid() {
        guard let made = WindowsCore.makeRepeatGrid(session.selection) else { MessageBeep(0); return }
        session.select([made], on: WindowsCore.board(of: made) ?? session.board)
        session.edited(board: nil)
    }

    /// The selection masked: a shape among it holding the rest. A beep when there is none.
    private func maskSelection() {
        if WindowsCore.endPreview() { session.previewed(board: nil) }
        guard let made = WindowsCore.mask(session.selection) else { MessageBeep(0); return }
        session.select([made], on: WindowsCore.board(of: made) ?? session.board)
        session.edited(board: nil)
    }

    /// The selected text laid along the selected shape, where it lies nearest it; the text is picked.
    private func rideSelection() {
        if WindowsCore.endPreview() { session.previewed(board: nil) }
        if let text = WindowsCore.ridePair(session.selection)?.text { letters.fly(text) }
        guard let text = WindowsCore.ride(session.selection) else { MessageBeep(0); return }
        session.select([text], on: WindowsCore.board(of: text) ?? session.board)
        session.edited(board: nil)
    }

    /// The selected texts straight again, those riding a shape taken off it.
    private func straightenSelection() {
        let kept = WindowsCore.straighten(session.selection)
        session.select(kept, on: kept.first.flatMap(WindowsCore.board(of:)) ?? session.board)
        session.edited(board: nil)
    }

    /// A mask taken apart; what it held, and its shape, are picked.
    private func releaseMask(_ id: UUID) {
        // A ripple runs out from its shape, as what it cut off comes back.
        maskMarks.ring(id, out: true)
        let freed = WindowsCore.releaseMask(id)
        session.select(freed, on: freed.first.flatMap(WindowsCore.board(of:)) ?? session.board)
        session.edited(board: nil)
    }

    private func takeOutOfMask() {
        let ids = session.selection
        WindowsCore.takeOutOfMask(ids)
        session.select(ids, on: ids.first.flatMap(WindowsCore.board(of:)) ?? session.board)
        session.edited(board: nil)
    }

    private func selectAll() {
        session.select(WindowsCore.selectAll(session.selection, board: session.board), on: session.board)
    }

    private func cut() {
        guard !session.selection.isEmpty else { return }
        Clipboard.copy(session.selection)
        delete()
    }

    private func delete() {
        guard !session.selection.isEmpty else { return }
        WindowsCore.delete(session.selection)
        session.select([], on: session.board)
        session.edited(board: session.board)
    }

    private func paste() {
        let visible = CGRect(origin: inDesign(.zero), size: CGSize(width: root.actualWidth / zoom, height: root.actualHeight / zoom))
        guard let pasted = Clipboard.paste(visible: visible, board: session.board), !pasted.isEmpty else { return }
        session.select(pasted, on: pasted.first.flatMap(WindowsCore.board(of:)) ?? session.board)
        session.edited(board: session.board)
    }

    private func arrange(_ how: WindowsCore.Arrange) {
        guard !session.selection.isEmpty else { return }
        WindowsCore.arrange(session.selection, how)
        session.edited(board: session.board)
    }

    private func toggleLock() {
        let layers = session.selectedLayers
        guard !layers.isEmpty else { return }
        WindowsCore.setLocked(session.selection, !layers.allSatisfy(\.locked))
        session.edited(board: session.board)
    }

    private func setHidden(_ hidden: Bool) {
        guard !session.selection.isEmpty else { return }
        WindowsCore.setHidden(session.selection, hidden)
        if hidden { session.select([], on: session.board) }
        session.edited(board: session.board)
    }

    /// The right-click menu, as the Mac's CanvasMenus: for the selection (what is under the
    /// pointer is picked first, unless it is picked already), else paste, select all and zoom.
    private func rightTapped(_ args: RightTappedRoutedEventArgs?) {
        guard let menus, let q = try? args?.getPosition(stage), let w = try? args?.getPosition(menus.layer) else { return }
        let p = CGPoint(x: Double(q.x), y: Double(q.y))
        // On the words typed into, the text view's own menu; anywhere else the typing ends.
        if editing != nil {
            if let i = WindowsCore.typingIndex(at: inDesign(p), slack: 4 / zoom) {
                typingMenu(at: CGPoint(x: Double(w.x), y: Double(w.y)), index: i)
                return
            }
            endEditing()
        }
        // On a guide: taking it away, or all of its artboard's, and locking them, as on the Mac.
        syncGuides()
        if session.tool == .select, let guide = guideHand.menu(at: p) {
            var entries: [MenuHost.Entry] = [.item("Remove Guide") { [weak self] in guide.remove(); self?.session.edited(board: nil) }]
            if let all = guide.removeAll { entries.append(.item("Remove Guides") { [weak self] in all(); self?.session.edited(board: nil) }) }
            entries += [.separator, .item("Lock Guides", checked: WindowsCore.guidesLocked) { [weak self] in
                WindowsCore.guidesLocked.toggle()
                self?.drawAids()
            }]
            menus.show(at: CGPoint(x: Double(w.x), y: Double(w.y)), entries: entries)
            return
        }
        // Animated: a key here, how keys are come to, and the motion taken away, as the Mac's
        // MotionTool menu.
        if animating {
            syncMotion()
            guard let made = motion.menu(at: p), !made.isEmpty else { return }
            menus.show(at: CGPoint(x: Double(w.x), y: Double(w.y)), width: 220, entries: FilmTimelineView.entries(made))
            drawMotion()
            return
        }
        // As a prototype: where what is under the pointer goes, as the Mac's FlowTool menu.
        if prototyping {
            syncFlow()
            guard let made = flow.menuEntries(at: p), !made.isEmpty else { return }
            var entries: [MenuHost.Entry] = []
            for e in made {
                if e.separated, !entries.isEmpty { entries.append(.separator) }
                let action = e.action
                entries.append(.item(e.title, enabled: e.enabled, checked: e.checked) { [weak self] in
                    action()
                    self?.session.edited(board: nil)
                })
            }
            drawFlow()
            menus.show(at: CGPoint(x: Double(w.x), y: Double(w.y)), entries: entries)
            return
        }
        // Inspecting: copying what is under the pointer, never changing it, as the Mac's InspectTool menu.
        if inspecting {
            syncInspect()
            guard let d = inspect.deepest(at: p) else { return }
            // What is picked stays picked when the menu opens on it, or on something in it.
            if !(session.selection.count == 1 && WindowsCore.inspectPath(d).contains(session.selection[0])) {
                session.select([d], on: WindowsCore.board(of: d) ?? WindowsCore.boardIndex(of: d))
            }
            guard let id = session.selection.first else { return }
            var entries: [MenuHost.Entry] = [
                .item("Copy CSS") { Clipboard.copyText(WindowsCore.inspectCode(id, platform: .css)) },
                .item("Copy SwiftUI") { Clipboard.copyText(WindowsCore.inspectCode(id, platform: .swiftui)) },
                .separator,
                .item("Copy Name") { Clipboard.copyText(WindowsCore.layerName(id) ?? "") },
            ]
            if let words = WindowsCore.inspectSpec(id, platform: .css)?.words, !words.isEmpty {
                entries.append(.item("Copy Text") { Clipboard.copyText(words) })
            }
            drawInspect()
            menus.show(at: CGPoint(x: Double(w.x), y: Double(w.y)), entries: entries)
            return
        }
        if let id = pick(p), !session.selection.contains(id) { session.select([id], on: WindowsCore.board(of: id)) }
        let selection = session.selection
        var entries: [MenuHost.Entry] = []
        if !selection.isEmpty {
            entries += [
                .item("Cut", shortcut: "Ctrl+X") { [weak self] in self?.cut() },
                .item("Copy", shortcut: "Ctrl+C") { Clipboard.copy(selection) },
                .item("Paste", shortcut: "Ctrl+V", enabled: Clipboard.canPaste) { [weak self] in self?.paste() },
                .item("Duplicate", shortcut: "Ctrl+D") { [weak self] in self?.duplicate() },
                .item("Delete", shortcut: "Del") { [weak self] in self?.delete() },
                .separator,
                .item("Bring to Front", shortcut: "Ctrl+Shift+]") { [weak self] in self?.arrange(.front) },
                .item("Bring Forward", shortcut: "Ctrl+]") { [weak self] in self?.arrange(.forward) },
                .item("Send Backward", shortcut: "Ctrl+[") { [weak self] in self?.arrange(.backward) },
                .item("Send to Back", shortcut: "Ctrl+Shift+[") { [weak self] in self?.arrange(.back) },
                .separator,
            ]
            let canGroup = WindowsCore.canGroup(selection), canUngroup = selection.contains(where: WindowsCore.isGroup)
            if canGroup { entries.append(.item("Group", shortcut: "Ctrl+G") { [weak self] in self?.group() }) }
            if canUngroup { entries.append(.item("Ungroup", shortcut: "Ctrl+Shift+G") { [weak self] in self?.ungroup() }) }
            // Masks, as the Mac's menu has them: pointed at, the mask shows made.
            let canMask = WindowsCore.canMask(selection), mask = WindowsCore.selectedMask(selection)
            if canMask {
                entries.append(.item("Mask", shortcut: "Ctrl+M", preview: { [weak self] on in
                    // Shown made, what it would cut off fading away, as the word offered shows it.
                    guard let self, let offer = WindowsCore.maskPlanOffer(selection) else { return }
                    self.maskMarks.preview(offer, on)
                    self.session.previewed(board: nil)
                }) { [weak self] in
                    self?.maskSelection()
                    if let made = self?.session.selection.first, WindowsCore.selectedMask([made]) == made { self?.maskMarks.committed(made) }
                })
            }
            if let mask {
                if WindowsCore.inMask(selection) {
                    entries.append(.item("Take Out of Mask") { [weak self] in self?.takeOutOfMask() })
                }
                entries.append(.item("Release Mask", shortcut: "Ctrl+Shift+M") { [weak self] in self?.releaseMask(mask) })
            }
            // Words along a shape's outline, and straight again: pointed at, the words show laid along it.
            let ridable = WindowsCore.ridePair(selection) != nil, straightens = WindowsCore.canStraighten(selection)
            if ridable {
                entries.append(.item("Put Text on Path", preview: { [weak self] on in
                    WindowsCore.previewRide(selection, on)
                    self?.session.previewed(board: nil)
                }) { [weak self] in self?.rideSelection() })
            }
            if straightens {
                entries.append(.item(WindowsCore.curveLook(selection)?.riding == true ? "Take Text off Path" : "Straighten Text") { [weak self] in
                    self?.straightenSelection()
                })
            }
            if canGroup || canUngroup || canMask || mask != nil || ridable || straightens { entries.append(.separator) }
            // Texts: the Mac's Format menu.
            if session.selectedLayers.contains(where: \.isText), WindowsCore.canFormat(selection) {
                entries += formatEntries()
                entries.append(.separator)
            }
            // Shapes and texts as paths, as the Mac's menu has it (a path itself has its points).
            if WindowsCore.canConvertToPath(selection) {
                entries += [.item("Convert to Path", shortcut: "Ctrl+8") { [weak self] in self?.convertToPath() }, .separator]
            }
            // Borders as shapes of their own, as the Mac's Object menu has it.
            if WindowsCore.canOutlineBorders(selection) {
                entries += [.item(selection.count == 1 ? "Outline Border" : "Outline Borders", shortcut: "Ctrl+Alt+O") { [weak self] in self?.outlineBorders() }, .separator]
            }
            // Repeat grids, as the Mac's menu has them.
            if WindowsCore.canRepeat(selection) {
                entries += [.item("Make Repeat Grid", shortcut: "Ctrl+R") { [weak self] in self?.makeRepeatGrid() }, .separator]
            } else if selection.count == 1, let cell = WindowsCore.cellLook(selection[0]) {
                if let slot = cell.slot, cell.kind == "text" || cell.picture {
                    entries.append(.item("Same in Every Cell") { [weak self] in WindowsCore.sameInEveryCell(selection[0]); self?.session.edited(board: nil) })
                    entries.append(.item("Shuffle Cells") { [weak self] in WindowsCore.shuffleCells(slot, in: cell.grid); self?.session.edited(board: nil) })
                }
                entries.append(.item("Select Grid") { [weak self] in self?.session.select([cell.grid], on: self?.session.board) })
                entries.append(.item("Ungroup Grid", shortcut: "Ctrl+Shift+R") { [weak self] in WindowsCore.ungroupGrid(cell.grid); self?.session.edited(board: nil) })
                entries.append(.separator)
            } else if selection.count == 1, WindowsCore.isGrid(selection[0]) {
                entries.append(.item("Ungroup Grid", shortcut: "Ctrl+Shift+R") { [weak self] in WindowsCore.ungroupGrid(selection[0]); self?.session.edited(board: nil) })
                entries.append(.separator)
            }
            // Components, as the Mac's Object menu has them.
            if WindowsCore.canMakeComponent(selection) {
                entries += [.item("Make Component", shortcut: "Ctrl+Alt+K") { [weak self] in self?.makeComponent() }, .separator]
            } else if let copy = WindowsCore.componentLook(selection) {
                entries.append(.item("New Variant") { [weak self] in
                    guard let self else { return }
                    let picked = WindowsCore.addVariant(selection)
                    self.session.select(picked, on: self.session.board)
                    self.session.edited(board: nil)
                })
                if copy.ownLooks {
                    entries.append(.item("Look Like the Others") { [weak self] in WindowsCore.resetCopy(copy.copy); self?.session.edited(board: nil) })
                }
                entries.append(.item("Unlink Copy") { [weak self] in WindowsCore.unlink(selection); self?.session.edited(board: nil) })
                entries.append(.separator)
            }
            // Decks, as the Mac's menu has them.
            if let board = WindowsCore.postableBoard(selection, focused: session.board) {
                entries.append(.item("Add Post", shortcut: "Ctrl+Shift+P") { [weak self] in self?.addPost() })
                if let deck = WindowsCore.deck(board) {
                    entries.append(.item("Show All Posts", shortcut: "Ctrl+Alt+P") { [weak self] in self?.decks.openSpread(board) })
                    if selection.count == 1, WindowsCore.inPost(selection[0]) {
                        if WindowsCore.holdsWordsOrPicture(selection[0]) {
                            entries.append(.item("Same in Every Post") { [weak self] in WindowsCore.giveEveryPost(selection); self?.session.edited(board: nil) })
                        }
                        if WindowsCore.ownWords(selection[0]) != nil {
                            entries.append(.item("Follow the Other Posts") { [weak self] in WindowsCore.followDesign(selection); self?.session.edited(board: nil) })
                        }
                    }
                    entries.append(.item("Remove This Post", enabled: deck.count > 1) { [weak self] in self?.removeFrontPost(board) })
                    entries.append(.item("Unstack", detail: "Each post an artboard") { [weak self] in
                        guard let self else { return }
                        let made = WindowsCore.spreadOut(board)
                        self.session.select(made, on: nil)
                        self.session.edited(board: nil)
                    })
                }
                entries.append(.separator)
            }
            let layers = session.selectedLayers
            let locked = !layers.isEmpty && layers.allSatisfy(\.locked)
            entries.append(.item(locked ? "Unlock" : "Lock", shortcut: "Ctrl+L") { [weak self] in self?.toggleLock() })
            if !layers.isEmpty, layers.allSatisfy(\.hidden) {
                entries.append(.item("Show") { [weak self] in self?.setHidden(false) })
            } else {
                entries.append(.item("Hide", shortcut: "Ctrl+Shift+H") { [weak self] in self?.setHidden(true) })
            }
            // Enter places a picture, as on the Mac.
            if WindowsCore.PictureHand.canPlace(session.selection) {
                let placing = pictures.editing == session.selection.first
                entries += [.separator, .item(placing ? "Done Placing Picture" : "Place Picture", shortcut: "Enter") { [weak self] in
                    guard let self else { return }
                    if placing {
                        self.pictures.editing = nil
                        self.drawPictures()
                        self.session.changed()
                    } else {
                        self.session.placePicture()
                    }
                }]
            }
            // The picture's background taken away, or given back, as on the Mac.
            let ids = session.selection
            let remove = WindowsCore.canRemoveBackground(ids), restore = WindowsCore.canRestoreBackground(ids)
            let vectorize = WindowsCore.canVectorize(ids)
            if remove || restore || vectorize {
                if !WindowsCore.PictureHand.canPlace(ids) { entries.append(.separator) }
                if remove { entries.append(.item("Remove Background") { [weak self] in self?.session.removeBackground() }) }
                if restore { entries.append(.item("Restore Background") { [weak self] in self?.session.restoreBackground() }) }
                if vectorize { entries.append(.item("Vectorize") { [weak self] in self?.session.vectorize() }) }
            }
            // A group made of a picture, while it remembers it: the picture back in its place.
            if ids.count == 1, WindowsCore.isVector(ids[0]) {
                entries += [.separator, .item("Back to Picture") { [weak self] in self?.session.backToPicture() }]
            }
        } else {
            entries += [
                .item("Paste", shortcut: "Ctrl+V", enabled: Clipboard.canPaste) { [weak self] in self?.paste() },
                .item("Select All", shortcut: "Ctrl+A", enabled: !WindowsCore.boards().isEmpty) { [weak self] in self?.selectAll() },
                .separator,
                .item("Zoom to Fit", shortcut: "Ctrl+0") { [weak self] in self?.fit() },
                .item("Actual Size", shortcut: "Ctrl+1") { [weak self] in
                    guard let self else { return }
                    self.zoom(to: 1, around: CGPoint(x: self.root.actualWidth / 2, y: self.root.actualHeight / 2))
                },
            ]
        }
        menus.show(at: CGPoint(x: Double(w.x), y: Double(w.y)), entries: entries) { [weak self] in
            // A mask pointed at and not made is taken away again.
            if WindowsCore.endPreview() { self?.session.previewed(board: nil) }
        }
    }

    func key(_ args: KeyRoutedEventArgs?) {
        // Keys typed into a text are the text's.
        guard let args, editing == nil else { return }
        // Escape puts an open note away, or lets go of one being written.
        // Escape puts every post spread out back in the stack.
        if args.key == .escape, drag == nil, decks.cancel() {
            args.handled = true
            return
        }
        if args.key == .escape, margin.notes.openThread != nil || margin.notes.draftID != nil {
            args.handled = true
            if margin.notes.draftID != nil { margin.notes.dropDraft() } else { margin.notes.openThread = nil }
            return
        }
        // Animated, a key is the film's before any tool of the design has it: Enter plays from the
        // start, Delete takes keys away, never layers, the arrows nudge what is picked or step
        // through time; Cut and Paste rest, and the tools' letters with them.
        if animating, args.key != .space {
            let raw = args.key.rawValue
            var name: String?
            switch args.key {
            case .enter: name = "enter"
            case .delete: name = "delete"
            case .back: name = "backspace"
            case .escape: name = "escape"
            case .home: name = "home"
            case .end: name = "end"
            case .left: name = "left"
            case .right: name = "right"
            case .up: name = "up"
            case .down: name = "down"
            case .k: name = "k"
            default: if raw == 188 { name = "," } else if raw == 190 { name = "." }
            }
            if let name {
                syncMotion()
                if motion.key(name, shift: shift, alt: option, ctrl: control) {
                    args.handled = true
                    drawMotion()
                    return
                }
            }
            switch args.key {
            case .x, .v:
                if control { args.handled = true; return }
            case .a, .r, .e, .l, .p, .t, .n:
                if !control, !option { args.handled = true; return }
            default:
                break
            }
        }
        // As a prototype: Delete cuts the picked layers' threads, never the layers; Escape lets go.
        if prototyping {
            switch args.key {
            case .escape:
                args.handled = true
                syncFlow()
                if !flow.cancel() { session.select([], on: session.board) }
                drawFlow()
                return
            case .delete, .back:
                args.handled = true
                syncFlow()
                flow.deleteLinks()
                session.edited(board: nil)
                return
            case .left, .right, .up, .down, .enter:
                args.handled = true
                return
            case .x, .v, .d, .g, .r, .m, .l, .b, .k, .u, .i, .s:
                if control { args.handled = true; return }
            default:
                break
            }
        }
        // Inspecting, nothing changes: Escape takes the next thing out, and the keys that would
        // change the design do nothing. Zooming, copying and undoing still work.
        if inspecting {
            switch args.key {
            case .escape:
                args.handled = true
                syncInspect()
                let up = inspect.climb()
                session.select(up, on: up.first.flatMap(WindowsCore.board(of:)) ?? up.first.flatMap(WindowsCore.boardIndex(of:)))
                drawInspect()
                return
            case .delete, .back, .left, .right, .up, .down, .enter:
                args.handled = true
                return
            case .x, .v, .d, .g, .r, .m, .l, .b, .k, .u, .i, .s:
                if control { args.handled = true; return }
            default:
                break
            }
        }
        // Space held: a press moves the canvas round.
        if args.key == .space {
            args.handled = true
            if !spaceDown {
                spaceDown = true
                spaceTap = (WindowsCore.now, false)
                if let p = lastPoint { updatePointer(at: p) }
            }
            return
        }
        // Return on one selected text types into it, every letter picked out, as on the Mac.
        if args.key == .enter, session.mode == 0, session.tool == .select, drag == nil, session.selection.count == 1,
           let id = session.selection.first, WindowsCore.isText(id), let board = WindowsCore.board(of: id) {
            args.handled = true
            beginEditing(id, board: board)
            return
        }
        // The pen's keys, and those for the points of a path being edited, first; Enter on a
        // selected path edits its points.
        let penKey: String? = switch args.key {
        case .escape: "escape"
        case .enter: "enter"
        case .delete, .back: "delete"
        case .left: "left"
        case .right: "right"
        case .up: "up"
        case .down: "down"
        default: nil
        }
        if let penKey {
            syncPen()
            // A picture first, as on the Mac: Enter on one places it, where on a path it would
            // open its points; while placing, Enter and Escape end it and the arrows move it.
            syncPictures()
            let wasPlacing = pictures.editing != nil
            if pictures.key(penKey, shift: shift, selection: session.selection,
                            free: session.tool == .select && pen.editingPath == nil && drag == nil && !builder.active) {
                args.handled = true
                if case .picture? = drag?.grab, penKey == "escape" {
                    drag = nil
                    placeHolds()
                }
                if !wasPlacing, pictures.editing != nil { session.showCard?("Fill") }
                drawPictures()
                session.changed()
                return
            }
            // Enter on a mask picks what it holds, as on the Mac.
            if penKey == "enter", session.tool == .select, pen.editingPath == nil, drag == nil,
               let held = WindowsCore.maskHeld(session.selection) {
                args.handled = true
                session.select(held, on: held.first.flatMap(WindowsCore.board(of:)) ?? session.board)
                session.changed()
                return
            }
            // Building before the knife and the pen: Enter and Escape end it, or the drag.
            if builder.active, builder.key(penKey) {
                args.handled = true
                if case .build? = drag?.grab { drag = nil }
                return
            }
            if session.tool == .knife, knife.key(penKey) {
                args.handled = true
                knifeChanged()
                return
            }
            // Escape while a guide is dragged: back as it was.
            if penKey == "escape", guideHand.pressed {
                args.handled = true
                guideHand.cancel()
                drawAids()
                return
            }
            // Escape while a layout grid is dragged: back as it was.
            if penKey == "escape", layoutHand.dragging {
                args.handled = true
                layoutHand.cancel()
                let board = drag?.board ?? -1
                drag = nil
                session.edited(board: board >= 0 ? board : nil)
                return
            }
            // Escape: a drag on the photo taken back, or the photo given back.
            if penKey == "escape", develop.cancel() {
                args.handled = true
                drag = nil
                session.edited(board: nil)
                session.changed()
                return
            }
            // Escape while a bead is swung: back as it was.
            if penKey == "escape", curveHand.dragging {
                args.handled = true
                curveHand.cancel()
                drag = nil
                session.edited(board: nil)
                return
            }
            // Escape while a grid's handle is dragged: back as it was.
            if penKey == "escape", gridHand.dragging {
                args.handled = true
                gridHand.cancel()
                let board = drag?.board ?? -1
                drag = nil
                session.edited(board: board >= 0 ? board : nil)
                return
            }
            // Escape while turning in depth: back as it was.
            if penKey == "escape", depth.dragging {
                args.handled = true
                depth.cancel()
                drag = nil
                session.edited(board: session.board)
                return
            }
            // Escape during any other drag: back as it was when it began, as on the Mac.
            if penKey == "escape", let d = drag {
                args.handled = true
                cancelDrag(d.grab, moved: d.moved)
                return
            }
            if pen.key(penKey, shift: shift) {
                args.handled = true
                penChanged()
                return
            }
            // Escape with nothing picked and nothing in hand: what is looked at from the side,
            // from the front again, as on the Mac.
            if penKey == "escape", session.mode == 0, session.selection.isEmpty, WindowsCore.lookFromTheFront() {
                args.handled = true
                lookChanged(nil)
                return
            }
        }
        let step = shift ? 10.0 : 1.0
        let selection = session.selection
        var edited = true
        var undoing = false
        switch args.key {
        case .delete, .back:
            delete()
            args.handled = true
            return
        // Decks, as the Mac's Object menu has them: Ctrl+Alt+arrows and Page Up and Down turn,
        // Ctrl+Shift+P adds a post, Ctrl+Alt+P spreads every post out.
        case .left where control && option: turnPage(-1); args.handled = true; return
        case .right where control && option: turnPage(1); args.handled = true; return
        case .pageUp: turnPage(-1); args.handled = true; return
        case .pageDown: turnPage(1); args.handled = true; return
        case .p where control && shift: addPost(); args.handled = true; return
        case .p where control && option: showAllPosts(); args.handled = true; return
        case .left: WindowsCore.move(selection, dx: -step, dy: 0)
        case .right: WindowsCore.move(selection, dx: step, dy: 0)
        case .up: WindowsCore.move(selection, dx: 0, dy: -step)
        case .down: WindowsCore.move(selection, dx: 0, dy: step)
        // The Mac's Format menu, on the selected texts: Ctrl+B, I and U, Ctrl+Shift+X, 8 and 7.
        case .b where control && !option && !shift && WindowsCore.canFormat(selection): formatText(.bold); args.handled = true; return
        case .i where control && !option && !shift && WindowsCore.canFormat(selection): formatText(.italic); args.handled = true; return
        case .u where control && !option && !shift && WindowsCore.canFormat(selection): formatText(.underline); args.handled = true; return
        case .x where control && shift && !option && WindowsCore.canFormat(selection): formatText(.strikethrough); args.handled = true; return
        case .number8 where control && shift && WindowsCore.canFormat(selection): formatText(.bulletList); args.handled = true; return
        case .number7 where control && shift && WindowsCore.canFormat(selection): formatText(.numberList); args.handled = true; return
        // The Mac's Edit and Object menus, Ctrl for Command and Alt for Option.
        case .b where control && option: toggleBuild(); args.handled = true; return
        case .k where control && option: makeComponent(); args.handled = true; return
        case .u where control && option: combine("union"); args.handled = true; return
        case .s where control && option: combine("subtract"); args.handled = true; return
        case .i where control && option: combine("intersect"); args.handled = true; return
        case .x where control && option: combine("exclude"); args.handled = true; return
        case .o where control && option: outlineBorders(); args.handled = true; return
        case .number8 where control && !shift && !option: convertToPath(); args.handled = true; return
        case .m where control && shift:
            if let mask = WindowsCore.selectedMask(selection) { releaseMask(mask) } else { MessageBeep(0) }
            args.handled = true
            return
        case .m where control: maskSelection(); args.handled = true; return
        case .r where control && shift:
            if let id = selection.first, let grid = WindowsCore.isGrid(id) ? id : WindowsCore.cellLook(id)?.grid {
                WindowsCore.ungroupGrid(grid)
                session.edited(board: nil)
            } else {
                MessageBeep(0)
            }
            args.handled = true
            return
        case .r where control: makeRepeatGrid(); args.handled = true; return
        case .d where control: duplicate(); args.handled = true; return
        case .g where control && shift: ungroup(); args.handled = true; return
        case .g where control: group(); args.handled = true; return
        case .a where control: selectAll(); args.handled = true; return
        case .c where control: Clipboard.copy(selection); args.handled = true; return
        case .x where control: cut(); args.handled = true; return
        case .v where control: paste(); args.handled = true; return
        case .l where control: toggleLock(); args.handled = true; return
        case .h where control && shift: setHidden(true); args.handled = true; return
        case .z where control: edited = shift ? WindowsCore.redo() : WindowsCore.undo(); undoing = true
        case .y where control: edited = WindowsCore.redo(); undoing = true
        case .o where control: session.onOpen?(); args.handled = true; return
        case .number0 where control: fit(); args.handled = true; return
        case .number1 where control: zoom(to: 1, around: CGPoint(x: root.actualWidth / 2, y: root.actualHeight / 2)); args.handled = true; return
        case .number2 where control: fitSelection(); args.handled = true; return
        default:
            let raw = args.key.rawValue
            // Bigger and smaller, Ctrl+Shift with the full stop and the comma (⇧⌘. and ⇧⌘, on the Mac).
            if control, shift, raw == 190 || raw == 188, WindowsCore.canFormat(selection) {
                formatText(raw == 190 ? .bigger : .smaller)
                args.handled = true
                return
            }
            if control, raw == 187 || raw == 107 { self.step(in: true); args.handled = true; return }   // = and the keypad's +
            if control, raw == 189 || raw == 109 { self.step(in: false); args.handled = true; return }  // − and the keypad's −
            // Ctrl+] and Ctrl+[ bring forward and send backward, with Shift to the front and back
            // (the keys beside P, as ] and [ lie on an English keyboard).
            if control, raw == 221 || raw == 219, !selection.isEmpty {
                arrange(raw == 221 ? (shift ? .front : .forward) : (shift ? .back : .backward))
                args.handled = true
                return
            }
            guard !control, let tool = Glyphs.Tool.allCases.first(where: { UInt32($0.key.unicodeScalars.first!.value) == UInt32(raw) }) else { return }
            session.tool = tool
            args.handled = true
            return
        }
        args.handled = true
        // Undone or done again, what is picked and still there stays picked, on the artboard it
        // is on now.
        if edited, undoing {
            let kept = session.selection.filter { WindowsCore.board(of: $0) != nil }
            session.select(kept, on: kept.first.flatMap(WindowsCore.board(of:)) ?? session.board)
        }
        if edited { session.edited(board: undoing ? nil : session.board) }
    }
}

// MARK: - Looking back

extension DesignCanvas {
    private static let sepia: UInt32 = 0xA86E38

    /// The versions changed: what the canvas shows, what it marks, and the notes, away while
    /// looking back, as they are of now.
    func versionsChanged() {
        let back = WindowsCore.versions.lookingBack
        margin.layer.visibility = back ? .collapsed : .visible
        if !back { timeHovered = nil }
        drawTime(WindowsCore.timeTable.changes())
        drawTimeMarks()
        tickTime()
    }

    private func hoverTime(_ id: UUID?) {
        guard id != timeHovered else { return }
        timeHovered = id
        drawTimeMarks()
    }

    /// The artboards a moment of the glide changed drawn again: those by index, or all.
    private func drawTime(_ changed: [Int]?) {
        guard let changed else { return }
        let known = Set(boards.map(\.index))
        if changed.isEmpty || changed.contains(where: { !known.contains($0) }) || WindowsCore.boards().count != boards.count {
            drawAll()
        } else {
            for k in changed { redraw(board: k) }
        }
    }

    /// Frame by frame while the layers glide, the marks are inked or layers brought back land.
    private func tickTime() {
        guard timeTicking == nil, WindowsCore.timeTable.moving || WindowsCore.versions.landing() != nil else { return }
        timeTicking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                // Behind another tab, the core has another design: the glide goes on once back.
                guard let self, self.session.isFront else { return }
                self.drawTime(WindowsCore.timeTable.frame(at: WindowsCore.now))
                self.drawTimeMarks()
                if !WindowsCore.timeTable.moving, WindowsCore.versions.landing() == nil {
                    self.timeTicking?.dispose()
                    self.timeTicking = nil
                    self.drawTimeMarks()
                }
            }
        }
    }

    private func onStage(rect r: CGRect) -> CGRect {
        let a = onStage(r.origin)
        return CGRect(x: Double(a.x), y: Double(a.y), width: Double(r.width) * zoom, height: Double(r.height) * zoom)
    }

    /// What differs from now, as the Mac's TimeTable marks it: pencil crop marks at the corners
    /// of what changed, sepia for what has gone since, a wash and a tick on what is picked to
    /// bring back, a faint dotted outline where what was made since will be, and, for the layer
    /// pointed at, a thread to where it is now. Layers just brought back land with their corners.
    private func drawTimeMarks() {
        if !holds(overlay, timeMarks) {
            timeMarks.isHitTestVisible = false
            overlay.children.append(timeMarks)
        }
        timeMarks.children.clear()
        let versions = WindowsCore.versions
        if let landing = versions.landing() {
            let p = landing.age / 1.1
            for f in landing.frames {
                let r = onStage(rect: f).insetBy(dx: -4 - 6 * p, dy: -4 - 6 * p)
                timeMarks.children.append(cropMarks(r, arm: 9 + 4 * p, brush: Theme.brush(Theme.selection, 1 - p), width: 1.6))
            }
        }
        guard versions.lookingBack else { return }
        let inked = WindowsCore.timeTable.inked
        let sight = CGRect(x: 0, y: 0, width: stage.actualWidth, height: stage.actualHeight)
        if inked > 0 {
            for f in versions.madeSince() {
                let r = onStage(rect: f)
                guard r.intersects(sight), r.width > 4 || r.height > 4 else { continue }
                let box = Rectangle()
                box.width = max(Double(r.width) - 1, 1)
                box.height = max(Double(r.height) - 1, 1)
                box.stroke = Theme.brush(Theme.ink, 0.22 * inked)
                box.strokeThickness = 1
                let dashes = DoubleCollection()
                dashes.append(1.5)
                dashes.append(3)
                box.strokeDashArray = dashes
                try? Canvas.setLeft(box, Double(r.minX) + 0.5)
                try? Canvas.setTop(box, Double(r.minY) + 0.5)
                timeMarks.children.append(box)
            }
        }
        for m in versions.marks() {
            let r = onStage(rect: m.frame)
            guard r.insetBy(dx: -12, dy: -12).intersects(sight), r.width > 2 || r.height > 2 else { continue }
            let ink: UInt32 = m.gone ? Self.sepia : Theme.selection
            let pointed = timeHovered == m.id
            if m.picked {
                let wash = Rectangle()
                wash.width = Double(r.width) + 1.5
                wash.height = Double(r.height) + 1.5
                wash.fill = Theme.brush(ink, 0.12)
                wash.stroke = Theme.brush(ink)
                wash.strokeThickness = 1.5
                try? Canvas.setLeft(wash, Double(r.minX) - 0.75)
                try? Canvas.setTop(wash, Double(r.minY) - 0.75)
                timeMarks.children.append(wash)
                timeMarks.children.append(tick(at: CGPoint(x: r.maxX, y: r.minY), ink: ink))
            } else if inked > 0 {
                timeMarks.children.append(cropMarks(r.insetBy(dx: -4, dy: -4), arm: 9 * inked, brush: Theme.brush(ink, pointed ? 1 : 0.85),
                                                    width: pointed ? 1.6 : 1.25))
            }
            if pointed, !m.gone, let now = m.now { whereItIsNow(then: r, now: onStage(rect: now)) }
        }
    }

    /// Crop marks at a rectangle's corners, their arms `arm` long.
    private func cropMarks(_ r: CGRect, arm: Double, brush: Brush, width: Double) -> WinUI.Path {
        let path = WinUI.Path()
        path.stroke = brush
        path.strokeThickness = width
        path.strokeStartLineCap = .round
        path.strokeEndLineCap = .round
        path.strokeLineJoin = .round
        let geometry = PathGeometry()
        let a = min(arm, Double(r.width) / 2, Double(r.height) / 2)
        if a > 0.2 {
            for (c, sx, sy) in [(CGPoint(x: r.minX, y: r.minY), 1.0, 1.0), (CGPoint(x: r.maxX, y: r.minY), -1.0, 1.0),
                                (CGPoint(x: r.maxX, y: r.maxY), -1.0, -1.0), (CGPoint(x: r.minX, y: r.maxY), 1.0, -1.0)] {
                let figure = PathFigure()
                figure.startPoint = Point(x: Float(Double(c.x)), y: Float(Double(c.y) + a * sy))
                for q in [(Double(c.x), Double(c.y)), (Double(c.x) + a * sx, Double(c.y))] {
                    let segment = LineSegment()
                    segment.point = Point(x: Float(q.0), y: Float(q.1))
                    figure.segments.append(segment)
                }
                geometry.figures.append(figure)
            }
        }
        path.data = geometry
        path.isHitTestVisible = false
        return path
    }

    /// An open line through points on the stage.
    private func line(through points: [(Double, Double)]) -> WinUI.Path {
        let path = WinUI.Path()
        let geometry = PathGeometry()
        if let first = points.first {
            let figure = PathFigure()
            figure.startPoint = Point(x: Float(first.0), y: Float(first.1))
            for q in points.dropFirst() {
                let segment = LineSegment()
                segment.point = Point(x: Float(q.0), y: Float(q.1))
                figure.segments.append(segment)
            }
            geometry.figures.append(figure)
        }
        path.data = geometry
        path.isHitTestVisible = false
        return path
    }

    /// A small round tick at a picked layer's corner.
    private func tick(at c: CGPoint, ink: UInt32) -> FrameworkElement {
        let holder = Canvas()
        let r = 7.5
        let disc = Ellipse()
        disc.width = r * 2
        disc.height = r * 2
        disc.fill = Theme.brush(ink)
        try? Canvas.setLeft(disc, Double(c.x) - r)
        try? Canvas.setTop(disc, Double(c.y) - r)
        holder.children.append(disc)
        let mark = line(through: [(-3.2, 0.2), (-0.9, 2.6), (3.4, -2.4)].map { (Double(c.x) + $0.0, Double(c.y) + $0.1) })
        mark.stroke = Theme.brush(0xFFFFFF)
        mark.strokeThickness = 1.6
        mark.strokeStartLineCap = .round
        mark.strokeEndLineCap = .round
        mark.strokeLineJoin = .round
        holder.children.append(mark)
        holder.isHitTestVisible = false
        return holder
    }

    /// A layer that has changed since, pointed at: where it is now, faintly, and a pencil thread
    /// from where it was to there.
    private func whereItIsNow(then: CGRect, now: CGRect) {
        guard then != now else { return }
        let box = Rectangle()
        box.width = max(Double(now.width) - 1, 1)
        box.height = max(Double(now.height) - 1, 1)
        box.stroke = Theme.brush(Theme.selection, 0.55)
        box.strokeThickness = 1
        let dashes = DoubleCollection()
        dashes.append(3)
        dashes.append(3)
        box.strokeDashArray = dashes
        try? Canvas.setLeft(box, Double(now.minX) + 0.5)
        try? Canvas.setTop(box, Double(now.minY) + 0.5)
        timeMarks.children.append(box)
        let a = (Double(then.midX), Double(then.midY)), b = (Double(now.midX), Double(now.midY))
        guard ((b.0 - a.0) * (b.0 - a.0) + (b.1 - a.1) * (b.1 - a.1)).squareRoot() > 12 else { return }
        // A thread that bows a little, as one held loosely does.
        let mid = ((a.0 + b.0) / 2 - (b.1 - a.1) * 0.18, (a.1 + b.1) / 2 + (b.0 - a.0) * 0.18)
        let thread = line(through: (0...24).map { k in
            let t = Double(k) / 24, u = 1 - t
            return (u * u * a.0 + 2 * u * t * mid.0 + t * t * b.0, u * u * a.1 + 2 * u * t * mid.1 + t * t * b.1)
        })
        thread.stroke = Theme.brush(Theme.selection, 0.8)
        thread.strokeThickness = 1.25
        thread.strokeStartLineCap = .round
        thread.strokeEndLineCap = .round
        timeMarks.children.append(thread)
        for (c, r, alpha) in [(b, 3.0, 1.0), (a, 2.0, 0.35)] {
            let dot = Ellipse()
            dot.width = r * 2
            dot.height = r * 2
            dot.fill = Theme.brush(Theme.selection, alpha)
            try? Canvas.setLeft(dot, c.0 - r)
            try? Canvas.setTop(dot, c.1 - r)
            timeMarks.children.append(dot)
        }
    }
}

// MARK: - Decks

extension DesignCanvas {
    /// Leaves a deck's artboard to the cards the deck layer draws over it, or shows it again.
    fileprivate func hideSheet(_ id: UUID, _ hide: Bool) {
        guard let k = boards.firstIndex(where: { $0.id == id }), let sheet = sheets[k] else { return }
        sheet.image.view.opacity = hide ? 0 : 1
        sheet.shadow.view.opacity = hide ? 0 : 1
    }
}

extension DesignCanvas {
    /// Adds a post to the deck being worked on, or makes the artboard selected a deck.
    fileprivate func addPost() {
        guard let board = WindowsCore.postableBoard(session.selection, focused: session.board) else { MessageBeep(0); return }
        let ids = WindowsCore.addPost(to: board, selection: session.selection)
        session.select(ids, on: WindowsCore.boardIndex(of: board) ?? session.board)
        session.edited(board: nil)
    }

    /// Turns the deck being worked on `by` posts on, or back.
    fileprivate func turnPage(_ by: Int) {
        guard let deck = WindowsCore.turnableDeck(session.selection, focused: session.board),
              let ids = WindowsCore.turnPage(by: by, deck: deck, selection: session.selection) else { return }
        session.select(ids, on: session.board)
        session.previewed(board: nil)
    }

    fileprivate func showAllPosts() {
        guard let deck = WindowsCore.turnableDeck(session.selection, focused: session.board) else { MessageBeep(0); return }
        decks.openSpread(deck)
    }

    fileprivate func removeFrontPost(_ deckID: UUID) {
        guard let deck = WindowsCore.deck(deckID), let front = deck.front else { return }
        let ids = WindowsCore.removePost(front, from: deckID, selection: session.selection)
        session.select(ids, on: session.board)
        session.edited(board: nil)
    }
}

// MARK: - Resources carried in

extension DesignCanvas {
    /// What shows of the canvas, on the canvas.
    private var visibleOnCanvas: CGRect {
        let a = inDesign(CGPoint(x: 0, y: 0)), b = inDesign(CGPoint(x: stage.actualWidth, y: stage.actualHeight))
        return CGRect(x: Double(a.x), y: Double(a.y), width: Double(b.x - a.x), height: Double(b.y - a.y))
    }

    /// Where the pointer is on the stage, if it is over it.
    private func overStage(_ args: PointerRoutedEventArgs?) -> CGPoint? {
        guard let args, let point = try? args.getCurrentPoint(stage) else { return nil }
        let p = CGPoint(x: Double(point.position.x), y: Double(point.position.y))
        guard Double(p.x) >= 0, Double(p.y) >= 0, Double(p.x) <= stage.actualWidth, Double(p.y) <= stage.actualHeight else { return nil }
        return p
    }

    /// A thing from the resources panel carried over the canvas: shown where it will land.
    func carryResource(_ thing: WindowsCore.Thing, _ args: PointerRoutedEventArgs?) {
        guard session.mode == 0, let p = overStage(args) else { clearGhost(); return }
        let c = inDesign(p)
        let target = WindowsCore.pick(c, selection: [], zoom: zoom)
        guard let plan = WindowsCore.plan(thing, at: c, over: target, focused: session.board, visible: visibleOnCanvas) else { clearGhost(); return }
        let old = ghostPlan
        ghostPlan = plan
        // A change of how it fits, or of where, eases; otherwise it stays under the pointer.
        let jumped = old.map { $0.fitted != plan.fitted || $0.board != plan.board || $0.swap != plan.swap } ?? false
        if ghostShown == nil || !jumped && ghostTicking == nil {
            ghostShown = (DeckSpring(Double(plan.frame.minX)), DeckSpring(Double(plan.frame.minY)), DeckSpring(Double(plan.frame.width)), DeckSpring(Double(plan.frame.height)))
        } else {
            ghostShown?.x.target = Double(plan.frame.minX)
            ghostShown?.y.target = Double(plan.frame.minY)
            ghostShown?.w.target = Double(plan.frame.width)
            ghostShown?.h.target = Double(plan.frame.height)
            startGhostEasing()
        }
        // Drawn again only when what it makes changes.
        let key = "\(thing) \(Int(plan.frame.width))x\(Int(plan.frame.height)) \(plan.fitted) \(plan.board?.uuidString ?? "") \(Int(zoom * 1000))"
        if ghost?.key != key {
            let image = Inspector.rendered(CGSize(width: Double(plan.frame.width), height: Double(plan.frame.height))) { _, fill in
                WindowsCore.planPicture(thing, at: c, over: target, focused: self.session.board, visible: self.visibleOnCanvas,
                                        scale: max(self.zoom * self.pixelScale, 0.05), into: fill)
            }
            image.stretch = .fill
            ghost = (key, image)
        }
        drawGhost()
    }

    func dropResource(_ thing: WindowsCore.Thing, _ args: PointerRoutedEventArgs?) {
        clearGhost()
        guard session.mode == 0, let p = overStage(args) else { return }
        // Put in once the release is over: the step redraws the panel the press began in.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                let c = self.inDesign(p)
                let target = WindowsCore.pick(c, selection: [], zoom: self.zoom)
                guard let made = WindowsCore.place(thing, at: c, over: target, focused: self.session.board, visible: self.visibleOnCanvas) else { return }
                self.session.select([made], on: WindowsCore.board(of: made) ?? WindowsCore.boardIndex(of: made))
                self.session.edited(board: nil)
                self.takeKeys()
            }
        }
    }

    /// A click in the panel: the thing onto the artboard in view, in the middle of what shows of
    /// it; an icon onto the icon selected, in its place.
    func pickResource(_ thing: WindowsCore.Thing) {
        guard session.mode == 0 else { return }
        var target: UUID?
        if case .icon = thing, session.selection.count == 1, WindowsCore.isIcon(session.selection[0]) { target = session.selection[0] }
        guard let made = WindowsCore.place(thing, at: nil, over: target, focused: session.board, visible: visibleOnCanvas) else { return }
        session.select([made], on: WindowsCore.board(of: made) ?? WindowsCore.boardIndex(of: made))
        session.edited(board: nil)
        takeKeys()
    }

    private func clearGhost() {
        ghostPlan = nil
        ghostShown = nil
        ghost = nil
        ghostTicking?.dispose()
        ghostTicking = nil
        resourceGhost.children.clear()
    }

    /// A spring a little short of still, so a bar settling on an edge lands with the faintest give.
    private func startGhostEasing() {
        guard ghostTicking == nil else { return }
        var last = WindowsCore.now
        ghostTicking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, var s = self.ghostShown else { return }
                let now = WindowsCore.now, dt = min(now - last, 1.0 / 30)
                last = now
                for k in 0..<4 {
                    switch k {
                    case 0: s.x.step(dt, stiffness: 520, damping: 38)
                    case 1: s.y.step(dt, stiffness: 520, damping: 38)
                    case 2: s.w.step(dt, stiffness: 520, damping: 38)
                    default: s.h.step(dt, stiffness: 520, damping: 38)
                    }
                }
                self.ghostShown = s
                self.drawGhost()
                if s.x.settled && s.y.settled && s.w.settled && s.h.settled {
                    self.ghostTicking?.dispose()
                    self.ghostTicking = nil
                }
            }
        }
    }

    private func drawGhost() {
        if !holds(overlay, resourceGhost) {
            resourceGhost.isHitTestVisible = false
            overlay.children.append(resourceGhost)
        }
        resourceGhost.children.clear()
        guard let plan = ghostPlan, let s = ghostShown, let ghost else { return }
        // The artboard it goes onto, or the icon it replaces, outlined in pencil.
        if let swap = plan.swapFrame {
            let r = onStage(rect: swap).insetBy(dx: -3, dy: -3)
            resourceGhost.children.append(outline(r, alpha: 1, width: 1.5))
        } else if let board = plan.boardFrame {
            let r = onStage(rect: board).insetBy(dx: -1, dy: -1)
            resourceGhost.children.append(outline(r, alpha: plan.fitted ? 0.75 : 0.4, width: plan.fitted ? 2 : 1.5))
        }
        let r = onStage(rect: CGRect(x: s.x.value, y: s.y.value, width: s.w.value, height: s.h.value))
        let image = ghost.image
        image.width = Double(r.width)
        image.height = Double(r.height)
        image.opacity = plan.swap == nil ? 0.94 : 0.85
        try? Canvas.setLeft(image, Double(r.minX))
        try? Canvas.setTop(image, Double(r.minY))
        // Docked or stretched, it stays on the artboard, as it will.
        if plan.fitted, let board = plan.boardFrame {
            let b = onStage(rect: board).intersection(r)
            let clip = RectangleGeometry()
            clip.rect = Rect(x: Float(Double(b.minX - r.minX)), y: Float(Double(b.minY - r.minY)), width: Float(max(Double(b.width), 0)), height: Float(max(Double(b.height), 0)))
            image.clip = clip
        } else {
            image.clip = nil
        }
        if !holds(resourceGhost, image) { resourceGhost.children.append(image) }
        // The same small pencil pill the picture drops use, under the ghost, kept on screen.
        let label = Theme.text(plan.label, size: 11.5, weight: 500)
        label.foreground = Theme.brush(0xFFFFFF)
        label.verticalAlignment = .center
        let pill = Border()
        pill.height = 22
        pill.cornerRadius = Theme.corners(7)
        pill.padding = Theme.inset(9, 0, 9, 0)
        pill.background = Theme.brush(Theme.selection)
        pill.child = label
        try? pill.measure(Size(width: 600, height: 40))
        let w = Double(pill.desiredSize.width)
        var x = (Double(r.midX) - w / 2).rounded(), y = (Double(r.maxY) + 12).rounded()
        x = min(max(x, 8), stage.actualWidth - w - 8)
        if y + 22 > stage.actualHeight - 8 { y = max(8, (Double(r.minY) - 34).rounded()) }
        try? Canvas.setLeft(pill, x)
        try? Canvas.setTop(pill, y)
        resourceGhost.children.append(pill)
    }

    private func outline(_ r: CGRect, alpha: Double, width: Double) -> FrameworkElement {
        let box = Rectangle()
        box.width = max(Double(r.width), 1)
        box.height = max(Double(r.height), 1)
        box.stroke = Theme.brush(Theme.selection, alpha)
        box.strokeThickness = width
        try? Canvas.setLeft(box, Double(r.minX))
        try? Canvas.setTop(box, Double(r.minY))
        box.isHitTestVisible = false
        return box
    }
}

// MARK: - The live room

extension DesignCanvas {
    /// The others in the design's live room, as the Mac's canvas draws them (LiveCanvas.swift):
    /// pools of light on the table under the artboards, marks over the design, tokens on the rim;
    /// what they drag drawn where they have it; the view flown to them and along with them.
    private func wireLive() {
        let live = liveCanvas
        var at: UInt32 = 0
        if (try? stage.children.indexOf(paper, &at)) == true { try? stage.children.insertAt(at + 1, live.lights) } else { try? stage.children.insertAt(0, live.lights) }
        if (try? root.children.indexOf(overlay, &at)) == true { try? root.children.insertAt(at + 1, live.marks) } else { root.children.append(live.marks) }
        root.children.append(live.rim)
        live.view = { [weak self] in
            guard let self else { return (.zero, 1, .zero) }
            let z = self.zoom
            return (CGPoint(x: -Double(self.pan.x) / z, y: -Double(self.pan.y) / z), z, CGSize(width: self.stage.actualWidth, height: self.stage.actualHeight))
        }
        live.presence = { [weak self] in
            guard let self else { return (.zero, [], "select", "looking") }
            let doing = self.editing != nil ? "typing" : self.drag?.moved == true ? (self.session.tool == .select ? "moving" : "drawing") : "looking"
            return (self.visibleOnCanvas, self.session.selection, self.session.tool.rawValue, doing)
        }
        live.move = { [weak self] origin, z, last in self?.flyView(origin, z, last: last) }
        live.redraw = { [weak self] places in self?.redrawLive(places) }
        live.develop = { [weak self] scene in self?.drawDeveloping(scene) }
        live.rulers = { WindowsCore.showsRulers ? Rulers.thickness : 0 }
    }

    /// Pictures on their way drawn where they are, developing (Host/Developing.swift): into the
    /// artboard's own picture, over what it shows there, so the grain and the light mix with the
    /// photo as on the Mac; every frame while they clear at first or come into focus, a dozen
    /// times a second as their grain moves otherwise. An artboard that had some and has none now
    /// is drawn again without.
    func drawDeveloping(_ scene: WindowsCore.LiveScene) {
        let now = Dictionary(grouping: scene.developing, by: \.place)
        let gone = Set(developingShown.keys).subtracting(now.keys)
        let changed = now.mapValues { $0.map(\.box) } != developingShown.mapValues { $0.map(\.box) }
        developingShown = now
        for (k, board) in boards.enumerated() where gone.contains(board.index) { draw(k) }
        if loose.contains(where: { gone.contains($0.index) }) { drawLoose() }
        guard scene.developingMoves || scene.grainFrame != developingFrame || changed else { return }
        developingFrame = scene.grainFrame
        for (k, board) in boards.enumerated() where now[board.index] != nil { developInto(k) }
        for item in loose where now[item.index] != nil { developInto(loose: item) }
    }

    /// Artboard `k`'s picture with its pictures on their way drawn developing over it.
    func developInto(_ k: Int) {
        guard boards.indices.contains(k), let image = sheets[k]?.image else { return }
        develop(place: boards[k].index, into: image)
    }

    /// A layer on the canvas's picture with its pictures on their way drawn developing over it.
    func developInto(loose item: WindowsCore.Loose) {
        guard let surface = looseSheets[item.index] else { return }
        develop(place: item.index, into: surface)
    }

    /// The picture of the design's layer at `place`, `drawn` over that part of the canvas, with its
    /// pictures on their way drawn developing over it, as far as they are in sight, on its own pixels.
    private func develop(place: Int, into surface: CanvasSurface) {
        guard let items = developingShown[place], let area = surface.area, let bitmap = surface.bitmap else { return }
        let drawn = area.rect, s = area.scale
        let w = Int(bitmap.pixelWidth), h = Int(bitmap.pixelHeight)
        let box = items.map(\.box).reduce(CGRect.null) { $0.union($1) }.intersection(drawn)
        guard !box.isNull else { return }
        let x0 = max(0, Int((Double(box.minX - drawn.minX) * s).rounded(.down))), x1 = min(w, Int((Double(box.maxX - drawn.minX) * s).rounded(.up)))
        let y0 = max(0, Int((Double(box.minY - drawn.minY) * s).rounded(.down))), y1 = min(h, Int((Double(box.maxY - drawn.minY) * s).rounded(.up)))
        guard x1 > x0, y1 > y0, let target = (try? bitmap.pixelBuffer.buffer).flatMap({ $0 }) else { return }
        // On the artboard picture's own pixels, so what is drawn again lines up with the rest.
        let part = CGRect(x: Double(drawn.minX) + Double(x0) / s, y: Double(drawn.minY) + Double(y0) / s,
                          width: Double(x1 - x0) / s, height: Double(y1 - y0) / s)
        var patch = [UInt8](repeating: 0, count: (x1 - x0) * (y1 - y0) * 4)
        var drew = false
        WindowsCore.drawingOthersMotion {
            drew = patch.withUnsafeMutableBytes { p in
                WindowsCore.drawDeveloping(place: place, part: part, scale: s, zoom: zoom, hiding: hiding(on: place)) { pw, ph in
                    pw == x1 - x0 && ph == y1 - y0 ? p.baseAddress : nil
                }
            }
        }
        guard drew else { return }
        let row = (x1 - x0) * 4
        patch.withUnsafeBytes { p in
            for y in 0..<(y1 - y0) {
                UnsafeMutableRawPointer(target).advanced(by: ((y0 + y) * w + x0) * 4).copyMemory(from: p.baseAddress!.advanced(by: y * row), byteCount: row)
            }
        }
        try? bitmap.invalidate()
    }

    /// The view the live room's camera gives: placed at once, drawn again at its zoom once it rests.
    private func flyView(_ origin: CGPoint, _ z: Double, last: Bool) {
        if last {
            guard let landed = flyingZoom else { return }
            flyingZoom = nil
            session.zoom = landed
            drawAll()
            return
        }
        let z = min(64, max(0.02, z))
        flyingZoom = abs(z - session.zoom) > 1e-9 ? z : nil
        pan = CGPoint(x: -Double(origin.x) * z, y: -Double(origin.y) * z)
        place()
    }

    /// The artboards and loose layers at these places in the design drawn again, with what the
    /// others drag where they have it this moment.
    private func redrawLive(_ places: Set<Int>) {
        WindowsCore.drawingOthersMotion {
            boards = WindowsCore.boards()
            for (k, board) in boards.enumerated() where places.contains(board.index) { draw(k) }
            if loose.contains(where: { places.contains($0.index) }) { drawLoose() }
        }
        place()
    }
}
