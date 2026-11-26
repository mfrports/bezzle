import AppKit
import Observation

/// The canvas: artboards lying on a table, drawn with Core Graphics, and everything the pointer
/// and keyboard do to them. The document itself only changes through the store.
final class CanvasView: NSView, NSTextViewDelegate, NSMenuItemValidation {
    let store: DocumentStore
    /// Opens one of Bezzle's own menus at a point in the window (y measured from the top).
    var onContextMenu: ((CGPoint, [MenuEntry]) -> Void)?

    private enum Interaction {
        case none
        case pan(startOrigin: CGPoint, startView: CGPoint)
        case marquee(start: CGPoint, base: [UUID], inside: UUID?)
        case move(start: CGPoint, originals: [UUID: CGRect], bounds: CGRect, targets: SnapTargets, started: Bool, duplicate: Bool)
        case resize(handle: Handle, originals: [UUID: Node], absolute: [UUID: CGRect], bounds: CGRect, rotation: Double, targets: SnapTargets)
        case rotate(center: CGPoint, startAngle: CGFloat, originals: [UUID: Node], absolute: [UUID: CGRect])
        case lineEnd(id: UUID, fixed: CGPoint, targets: SnapTargets)
        case create(tool: Tool, start: CGPoint, id: UUID?, board: UUID?, targets: SnapTargets)
        /// `radii` are the corners as they were, for when Option rounds only the one dragged.
        case corner(id: UUID, frame: CGRect, rotation: Double, corner: Handle, radii: [CGFloat])
        case shadow(id: UUID, start: CGPoint, original: CGPoint, started: Bool)
    }

    private var interaction: Interaction = .none
    /// A note begun with the note tool: where it was pressed, and the loop drawn round part of the
    /// design since, if the pointer went on.
    private var noteCircling: (points: [CGPoint], target: UUID?, start: CGPoint, view: CGPoint)?
    private var spaceHeld = false
    /// Whether the pointer is on the selected rectangle, so the dots that round its corners show.
    private var showsCornerDots = false
    /// Even gaps while something is moved, and the widths of those beside it last time.
    private let gapMarks = GapMarks()
    private var gapsCaught: Set<Int> = []
    /// A move with Control held pushes what is dragged away or pulls it nearer (`DepthPushing`):
    /// how far, and each layer's height, and the heights around it, when the drag began.
    private var pushing = DepthPushing()
    private var pushedFrom: [UUID: Transform3D?] = [:]
    private var pushLevels: [UUID: [CGFloat]] = [:]
    /// The heights the push has given them, kept as they were when Control was let go.
    private var pushedTo: [UUID: CGFloat] = [:]
    /// Where the move had taken them across, caught and all, which a push in depth keeps.
    private var movedAcross = CGPoint.zero
    /// Whether the pointer is on the selected layer's shadow, so its outline shows.
    private var onShadow = false
    private var lastViewPoint: CGPoint = .zero
    private var mouseDownView: CGPoint = .zero
    private var laidOut = false
    /// A preview eases in and out, drawn again each frame while it does.
    private let previewMotion = PreviewMotion()
    /// The table while looking back through the design's versions: the light, the wave, the marks.
    private(set) lazy var timeTable = TimeTable(store: store)
    /// Layers moving to where a design laid out again puts them, and what was understood of it.
    let adaptTool = AdaptTool()
    /// The artboards being resized by an edge, each one's design laid out again as it goes.
    private var adaptSessions: [UUID: Adapting.Session] = [:]
    private var easing: CADisplayLink?
    /// Whether a style's wave still has artboards as they looked before it to draw, and its course
    /// in the view as it was last worked out.
    private var washing = false
    private var washCourse: (token: UUID, viewport: Viewport, size: CGSize, course: WaveCourse)?

    // Text being typed into, in a text view laid over the canvas.
    private var editorHost: FlippedView?
    private var editor: NSTextView?
    private var editorUndo = UndoManager()
    /// What the editor shows, to tell when the layer has been changed from elsewhere.
    private var editorShown: Shown?
    private var editingAction: LocalizedStringResource = "Typing"
    /// The text typed into before its handle was pressed, and what was picked out in it, to type
    /// on once the handle is let go.
    private var typingResumes: (id: UUID, range: NSRange)?
    /// The text a press with the Text tool began on: a click types into it.
    private var textUnderPress: UUID?

    /// The pen, and the points of a path being edited.
    private(set) lazy var pathTool: PathTool = {
        let tool = PathTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// A picture being placed inside the layer it fills.
    private(set) lazy var pictureTool: PictureTool = {
        let tool = PictureTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        tool.clicked = { [weak self] v in self?.cutoutTool.click(at: v) }
        return tool
    }()

    /// A picture being cut out, and the subjects of one cut out being picked.
    private(set) lazy var cutoutTool: CutoutTool = {
        let tool = CutoutTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// A picture being made shapes.
    private(set) lazy var vectorTool = VectorTool(store: store)

    /// The picture as the control while the Photo card is open.
    private(set) lazy var developTool: DevelopTool = {
        let tool = DevelopTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Cutting shapes apart along a line.
    private(set) lazy var knifeTool: KnifeTool = {
        let tool = KnifeTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Joining and wiping away the pieces overlapping shapes make.
    private(set) lazy var shapeBuilder: ShapeBuilder = {
        let tool = ShapeBuilder(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Rounding a path's corners, and pulling a shape's outline out or in.
    private(set) lazy var outlineTool: OutlineTool = {
        let tool = OutlineTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Turning layers in depth: the knob a turned layer's face points with, and the sides' grips.
    private(set) lazy var depthTool: DepthTool = {
        let tool = DepthTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        tool.pick = { [weak self] p in self?.pick(p) }
        return tool
    }()

    /// Looking at an artboard from the side: the drag that turns the look, the posts under what
    /// stands off the page, and the word that looks from the front again.
    private(set) lazy var lookTool: LookTool = {
        let tool = LookTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// A selected repeat grid's handles and gaps, and the copies of a layer selected in one of its cells.
    private(set) lazy var gridTool: GridTool = {
        let tool = GridTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// A deck's stack of posts, the strip that turns them, and every post spread out at once.
    private(set) lazy var deckTool: DeckTool = {
        let tool = DeckTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// The rulers along the top and left, measuring the artboard being worked on.
    private(set) lazy var rulers = Rulers(store: store)

    /// Guides pulled out of the rulers onto artboards.
    private(set) lazy var guideTool: GuideTool = {
        let tool = GuideTool(store: store, rulers: rulers)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        tool.click = { [weak self] v, flags in self?.clickThrough(at: v, flags: flags) }
        tool.under = { [weak self] v in
            let p = self?.store.viewport.toCanvas(v) ?? .zero
            guard let self, let id = self.pick(p) else { return nil }
            return self.store.doc.absoluteFrame(of: id) ?? CGRect(origin: p, size: .zero)
        }
        tool.menu = { [weak self] v, entries in
            guard let self else { return }
            self.onContextMenu?(self.windowPoint(v), entries)
        }
        return tool
    }()

    /// Artboards' layout grids: their columns, rows and baselines.
    private(set) lazy var layoutTool: LayoutTool = {
        let tool = LayoutTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Masks: what is dragged held over a shape goes into it, the word offering one, and the
    /// ghost of what a mask cuts off.
    /// Components: copies outlined as such, the light running between them as one changes them
    /// all, a selected copy's variants under it, and the word offered after a change to one.
    private(set) lazy var componentTool: ComponentTool = {
        let tool = ComponentTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    private(set) lazy var maskTool: MaskTool = {
        let tool = MaskTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// Words along curves: bending a text by its beads, catching it on a shape's edge and sliding
    /// it along, and every letter springing to its place as that changes.
    private(set) lazy var curveTool: CurveTool = {
        let tool = CurveTool(store: store)
        tool.redraw = { [weak self] in
            self?.needsDisplay = true
            if self?.curveTool.animating == true { self?.keepEasing() }
        }
        return tool
    }()

    /// Files dragged in from elsewhere, shown doing what they would do before they are let go.
    /// A part or an icon dragged in from the resources panel, shown as it will land.
    private(set) lazy var resourceDropTool: ResourceDropTool = {
        let tool = ResourceDropTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    /// The prototype: threads from layers to the screens they go to, pulled out of them by hand.
    private(set) lazy var flowTool: FlowTool = {
        let tool = FlowTool(store: store)
        tool.redraw = { [weak self] in
            self?.needsDisplay = true
            if self?.flowTool.isAnimating == true { self?.keepEasing() }
        }
        tool.pick = { [weak self] p in self?.pick(p) }
        tool.pickInside = { [weak self] p, group in self?.hit(p, in: group) }
        tool.titleHit = { [weak self] v in self?.titleHit(v) }
        tool.menu = { [weak self] v, entries in
            guard let self else { return }
            self.onContextMenu?(self.windowPoint(v), entries)
        }
        return tool
    }()

    /// The design inspected: measured where the pointer is, read and never changed.
    private(set) lazy var inspectTool: InspectTool = {
        let tool = InspectTool(store: store)
        tool.redraw = { [weak self] in
            self?.needsDisplay = true
            if self?.inspectTool.isAnimating == true { self?.keepEasing() }
        }
        tool.titleHit = { [weak self] v in self?.titleHit(v) }
        return tool
    }()

    /// The design animated: layers and the camera posed at the playhead. See `MotionTool`.
    private(set) lazy var motionTool: MotionTool = {
        let tool = MotionTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        tool.titleHit = { [weak self] v in self?.titleHit(v) }
        return tool
    }()

    /// The film's stage, which lies under the canvas and shows through a window cut over the
    /// artboard being animated. See `FilmStageView`.
    private(set) lazy var filmStage = FilmStageView(store: store)
    /// The space bar pressed and let go without moving the view plays the film, in Animate.
    private var spaceTap: (at: TimeInterval, moved: Bool)?

    /// An artboard's name typed into where it shows.
    private(set) lazy var naming: BoardNaming = {
        let tool = BoardNaming(store: store)
        tool.redraw = { [weak self] in
            self?.syncNaming()
            self?.needsDisplay = true
        }
        return tool
    }()

    private(set) lazy var dropTool: DropTool = {
        let tool = DropTool(store: store)
        tool.redraw = { [weak self] in self?.needsDisplay = true }
        return tool
    }()

    init(store: DocumentStore) {
        self.store = store
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        // The table is a well pressed into the paper, with soft corners.
        layer?.cornerRadius = 12
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        // Tiles are drawn on other threads, and the canvas is drawn again as they come.
        tiles.maker = TileMaker.shared
        tiles.arrived = { [weak self] in self?.redrawForArrivals() }
        registerForDraggedTypes([.fileURL, .string, ResourceDrag.type])
    }

    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// Every press on the canvas is its own, never the window's. SwiftUI's window does not ask,
    /// though, so the window is also held still under the title bar (see `holdWindow`).
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if holdsWindow { window?.isMovable = true }
        holdsWindow = false
        super.viewWillMove(toWindow: newWindow)
    }

    /// The design's own history, which its tab keeps, rather than the window's, which all the
    /// tabs share.
    override var undoManager: UndoManager? { store.undoManager ?? super.undoManager }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            window?.makeFirstResponder(self)
        } else {
            // Taken out of its window with something still easing, as when its tab is closed:
            // the link is ended here, since no frame will come to end it.
            easing?.invalidate()
            easing = nil
        }
        holdWindow()
    }

    // MARK: - Under the title bar

    /// The strip of the canvas the title bar reaches down over. The window's empty toolbar makes
    /// the title bar taller than the top bar (66 points against 52 on macOS 27), so it covers most
    /// of the top ruler and the set square.
    private var underTitleBar: CGRect {
        guard let window else { return .zero }
        let content = convert(window.contentLayoutRect, from: nil)
        return CGRect(x: 0, y: 0, width: bounds.width, height: min(bounds.height, max(0, content.minY)))
    }

    private var holdsWindow = false
    private lazy var titleBarWatch = TitleBarWatch(canvas: self)

    /// A drag in the title bar moves the window, and the window server starts it before the canvas
    /// hears of the press. So while the pointer is in that strip, the window holds still, and a
    /// guide can be pulled out of the ruler there as anywhere else. Asks where the pointer really
    /// is each time, so the window can never be left unable to move.
    fileprivate func holdWindow() {
        guard let window else { return }
        let hold = underTitleBar.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        guard hold != holdsWindow else { return }
        holdsWindow = hold
        window.isMovable = !hold
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A tab's kept canvas is sized to nothing for a moment as it goes back into the window.
        // Taken for a resize, that would move its view by half the canvas each time.
        guard newSize.width > 0, newSize.height > 0 else { return }
        let old = store.canvasSize
        store.canvasSize = newSize
        if !laidOut {
            laidOut = true
            #if DEBUG
            DebugHooks.opening("canvas laid out")
            #endif
            // A design opens where it was left, unless nothing of it could be seen from there.
            let lost = store.doc.contentBounds.map { !store.visibleCanvasRect.intersects($0) } ?? false
            if store.doc.viewport == nil || lost { store.lookFirst() }
        } else if old.width > 0 {
            // The view keeps its centre when the window is resized.
            var v = store.viewport
            v.origin.x -= (newSize.width - old.width) / 2 / v.zoom
            v.origin.y -= (newSize.height - old.height) / 2 / v.zoom
            store.viewport = v
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
        // Also in a window in the background, whose ruler a first click can pull a guide from.
        let strip = underTitleBar
        if !strip.isEmpty {
            addTrackingArea(NSTrackingArea(rect: strip, options: [.mouseEnteredAndExited, .activeAlways], owner: titleBarWatch))
        }
        holdWindow()
    }

    // MARK: - Drawing

    #if DEBUG
    /// How often the canvas was drawn, for a test run to tell (`AnimateHooks`).
    private(set) var drawsMade = 0
    #endif

    override func draw(_ dirtyRect: NSRect) {
        #if DEBUG
        drawsMade += 1
        if drawsMade == 1 { DebugHooks.opening("canvas first drawn") }
        #endif
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            // Told as something the canvas shows is about to change. On the main thread, where the
            // design is changed, the canvas is marked there and then, so the frame being put
            // together draws the change. Marked a moment later, as it was, the canvas was often
            // drawn twice for one step of a pan: with the frame, which already showed the step,
            // and again for the mark. A second drawing within one frame of the screen waits for
            // the screen, and so the step after it came a frame late.
            let here = Thread.isMainThread
            if here { MainActor.assumeIsolated { self?.needsDisplay = true } }
            Task { @MainActor in
                if !here { self?.needsDisplay = true }
                self?.syncEditor()
                self?.syncNaming()
            }
        }
    }

    private var deviceScale: CGFloat { window?.backingScaleFactor ?? 2 }

    private func keepEasing() {
        // Only in a window: the link keeps the canvas until its own next frame ends it, and a
        // canvas in no window has no next frame, so it would be kept, with its whole design, for good.
        guard easing == nil, window != nil else { return }
        let link = displayLink(target: self, selector: #selector(easeStep))
        link.add(to: .main, forMode: .common)
        easing = link
    }

    @objc private func easeStep(_ link: CADisplayLink) {
        needsDisplay = true
        if !previewMotion.isMoving && !deckTool.isAnimating && !gapMarks.isAnimating && !helpersAnimating && !maskTool.animating && !adaptTool.isAnimating && !componentTool.isAnimating && !curveTool.animating && !flowTool.isAnimating && !(store.sharing?.live?.marks.isAnimating ?? false) && !timeTable.isAnimating && !washing {
            link.invalidate()
            easing = nil
        }
    }

    private func render() {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let vp = store.viewport
        // Seen as a prototype, the table is a stage, and the screens are lit on it.
        _ = store.prototyping
        ctx.setFillColor(flowTool.table(CanvasInk.table))
        ctx.fill(bounds)
        flowTool.drawStage(ctx, in: bounds, scale: deviceScale)
        deckTool.drawStacks(ctx, in: bounds)
        // Where the others in a live room look, as light on the table.
        let live = store.sharing?.live
        if let live { live.marks.drawLight(ctx, room: live, store: store, in: bounds) }

        ctx.saveGState()
        ctx.scaleBy(x: vp.zoom, y: vp.zoom)
        ctx.translateBy(x: -vp.origin.x, y: -vp.origin.y)
        var options = Renderer.Options()
        options.artboardShadows = true
        options.deviceScale = deviceScale
        options.visible = store.visibleCanvasRect
        options.screen = options.visible
        options.assets = store.assets
        // Tiles drawn on other threads cannot ask the window whether it is light or dark.
        options.artboardShadowInk = RGBA(CanvasInk.shadow)
        // A picture wanted at a new size is read away from here; what showed it is made again then.
        options.picturesLater = true
        // Artboards looked at from the side: here alone, on the canvas.
        if !store.looks.isEmpty { options.looks = store.looks }
        if store.assets.ready == nil {
            store.assets.ready = { [weak self] name in
                self?.tiles.forget(showing: name)
                BlurCache.shared.forget(showing: name)
                self?.needsDisplay = true
            }
        }
        if let editing = store.editingText { options.skipping = [editing] }
        // Letters springing to new places are drawn on their way over the design, not in it.
        curveTool.step(store.shownDoc)
        options.skipping.formUnion(curveTool.flying)
        if let id = store.editingText, let host = editorHost {
            let alpha: CGFloat = curveTool.flying.contains(id) ? 0 : 1
            if host.alphaValue != alpha { host.alphaValue = alpha }
        }
        var shown = adaptTool.frame(of: previewMotion.frame(of: store.shownDoc, preview: store.preview, at: CACurrentMediaTime()), at: CACurrentMediaTime())
        // Looking back, the design gliding from one version to the next.
        shown = timeTable.frame(of: shown, in: bounds, at: CACurrentMediaTime())
        // What others are dragging, moving as they drag it.
        if let live { shown = live.marks.overlaid(shown, room: live, store: store) }
        options.settling = previewMotion.isMoving || adaptTool.isMoving || (live?.marks.isMoving ?? false) || timeTable.isMoving
        drawDesign(shown, in: ctx, options: options)
        ctx.restoreGState()
        drawWashes(ctx)
        // Animated, the artboard's film shows from under the canvas, through a window cut here.
        if let film = filmStage.sync(scale: deviceScale) { ctx.clear(film) }
        if previewMotion.isMoving || deckTool.isAnimating || adaptTool.isAnimating || timeTable.isAnimating { keepEasing() }
        cutoutTool.draw(ctx, scale: deviceScale)
        if cutoutTool.animating { redrawSoon() }
        vectorTool.draw(ctx, scale: deviceScale)
        if vectorTool.animating { redrawSoon() }
        maskTool.draw(ctx, scale: deviceScale, in: bounds)
        if maskTool.animating { keepEasing() }
        curveTool.draw(ctx, scale: deviceScale)
        if curveTool.animating { keepEasing() }

        drawSlideCuts(ctx)
        // Seen as a prototype, nothing of drawing: its screens, their names and the flows.
        if store.prototyping {
            drawArtboardTitles(ctx)
            // Animated, the film and what is posed in it; none of the prototype's threads.
            if store.animating {
                _ = (store.film.time, store.film.playing, store.film.camera)
                motionTool.draw(ctx, scale: deviceScale, in: bounds)
                drawLive(ctx, live)
                return
            }
            drawThreads(ctx)
            inspectTool.draw(ctx, scale: deviceScale, in: bounds)
            if inspectTool.isAnimating { keepEasing() }
            deckTool.draw(ctx, scale: deviceScale, in: bounds)
            if deckTool.isAnimating { keepEasing() }
            drawLive(ctx, live)
            return
        }
        // Layout grids and guides over the work, under the marks drawn over what is selected.
        let helpers = Helpers.shared
        _ = (helpers.rulers, helpers.guides, helpers.grids, helpers.guidesLocked)
        if !deckTool.spreading {
            layoutTool.draw(ctx, scale: deviceScale, in: bounds)
            guideTool.draw(ctx, scale: deviceScale)
        }
        drawFound(ctx)
        drawArtboardTitles(ctx)
        drawHover(ctx)
        drawSelection(ctx)
        pathTool.draw(ctx, scale: deviceScale)
        pictureTool.draw(ctx, scale: deviceScale)
        developTool.draw(ctx, scale: deviceScale)
        if developTool.animating { redrawSoon() }
        outlineTool.draw(ctx, scale: deviceScale)
        depthTool.draw(ctx, scale: deviceScale)
        if !store.prototyping { lookTool.draw(ctx, in: bounds) }
        gridTool.draw(ctx, scale: deviceScale)
        dropTool.draw(ctx, scale: deviceScale, in: bounds)
        resourceDropTool.draw(ctx, scale: deviceScale, in: bounds)
        shapeBuilder.draw(ctx, scale: deviceScale)
        knifeTool.draw(ctx, scale: deviceScale)
        if pictureTool.animating { redrawSoon() }
        drawGuides(ctx)
        adaptTool.draw(ctx, viewport: store.viewport, scale: deviceScale)
        drawMarquee(ctx)
        drawMeasurement(ctx)
        if !deckTool.spreading { componentTool.draw(ctx, scale: deviceScale, in: bounds) }
        if componentTool.isAnimating { keepEasing() }
        deckTool.draw(ctx, scale: deviceScale, in: bounds)
        if deckTool.isAnimating { keepEasing() }
        drawLive(ctx, live)
        timeTable.drawMarks(ctx, in: bounds, scale: deviceScale, at: CACurrentMediaTime())
        if !deckTool.spreading { rulers.draw(ctx, in: bounds, scale: deviceScale, tabs: guideTool.tabs()) }
        if helpersAnimating { keepEasing() }
        // The threads drawing back into their layers, coming out of the prototype.
        if flowTool.active { drawThreads(ctx) }
        inspectTool.draw(ctx, scale: deviceScale, in: bounds)
        if inspectTool.isAnimating { keepEasing() }
        _ = store.tool
    }

    /// Ahead of a style's wave, the artboards as they looked before the change, washed away behind
    /// its front over a soft edge. Drawn here with the design, never over the canvas, so that the
    /// change and what hides it until the wave comes always reach the screen in the same frame.
    private func drawWashes(_ ctx: CGContext) {
        washing = false
        guard let wave = store.styleShow.wave, !wave.washes.isEmpty else { return }
        let vp = store.viewport, size = bounds.size
        if let made = washCourse, made.token == wave.token, made.viewport == vp, made.size == size {} else {
            washCourse = (wave.token, vp, size, WaveCourse(wave, in: store.seenDoc, viewport: vp, size: size))
        }
        guard let course = washCourse?.course else { return }
        let r = course.radius(at: Date().timeIntervalSince(wave.start))
        for wash in wave.washes {
            let rect = vp.toView(wash.rect)
            guard course.reaches(rect, at: r), let mask = course.mask(for: rect, at: r, scale: deviceScale / 4) else { continue }
            washing = true
            ctx.saveGState()
            // The view counts down from its top; a picture is drawn the right way up.
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            let local = CGRect(origin: .zero, size: rect.size)
            ctx.clip(to: local, mask: mask)
            ctx.draw(wash.image, in: local)
            ctx.restoreGState()
        }
        if washing { keepEasing() }
    }

    /// The prototype's threads, fading as the design is inspected and back.
    private func drawThreads(_ ctx: CGContext) {
        let alpha = inspectTool.threadsAlpha
        if alpha > 0.001 {
            let fading = alpha < 0.999
            if fading {
                ctx.saveGState()
                ctx.setAlpha(alpha)
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            }
            flowTool.draw(ctx, scale: deviceScale, in: bounds)
            if fading {
                ctx.endTransparencyLayer()
                ctx.restoreGState()
            }
        }
        if flowTool.isAnimating { keepEasing() }
    }

    /// The others in a live room: their hands, what they hold, what they changed, and their winks.
    private func drawLive(_ ctx: CGContext, _ live: LiveRoom?) {
        guard let live else { return }
        live.marks.draw(ctx, room: live, store: store, in: bounds, scale: deviceScale)
        if live.marks.isAnimating { keepEasing() }
    }

    /// Whether the rulers, a guide or a layout grid are on their way somewhere.
    private var helpersAnimating: Bool { rulers.isAnimating || guideTool.isAnimating || layoutTool.isAnimating }

    /// A point in the window, measured from its top, as the menus are placed.
    private func windowPoint(_ v: CGPoint) -> CGPoint {
        let inWindow = convert(v, to: nil)
        return CGPoint(x: inWindow.x, y: (window?.contentView?.bounds.height ?? 0) - inWindow.y)
    }

    /// A click that came to nothing else, such as on a guide without dragging it: what lies under it is picked.
    private func clickThrough(at v: CGPoint, flags: NSEvent.ModifierFlags) {
        let id = titleHit(v) ?? pick(store.viewport.toCanvas(v))
        if flags.contains(.shift) {
            if let id { if store.selection.contains(id) { store.selection.removeAll { $0 == id } } else { store.selection.append(id) } }
        } else {
            store.selection = id.map { [$0] } ?? []
        }
    }

    /// The design: each artboard from its tiles, so that moving about a large design draws a few
    /// pictures; loose layers, and an artboard being typed on, as they are.
    private func drawDesign(_ doc: BezzleDocument, in ctx: CGContext, options: Renderer.Options) {
        let now = CACurrentMediaTime()
        // While the view moves, a frame makes only as many tiles as leave it smooth, measured by
        // the screen's own frames: a ProMotion display shows one every 8 ms, and 12 spent on tiles
        // would miss every other. Once it has stayed put, more, so what is in sight is sharp sooner.
        if store.viewport != lastViewport {
            lastViewport = store.viewport
            viewportMoved = now
        }
        let still = now - viewportMoved > 0.3 && !store.inGesture
        let frame = 1 / CFTimeInterval(max(window?.screen?.maximumFramesPerSecond ?? 60, 30))
        let deadline = now + (still ? 0.03 : max(frame - 0.005, 0.002))
        let visible = options.visible ?? .infinite
        // The artboard being typed on, and those with letters on their way, are drawn whole, as
        // they change from frame to frame, leaving those layers out.
        let typingOn = Set(([store.editingText].compactMap { $0 } + curveTool.flying).compactMap { doc.artboard(of: $0)?.id })
        var again = false
        // Tiles are kept in the colours of the screen the window is on (`Renderer.onScreen`); on
        // another screen, all of them are made again.
        let space = window?.colorSpace?.cgColorSpace
        if !Self.sameSpace(space, tileSpace.space) {
            tileSpace = TileSpace(space: space)
            tiles.forget()
        }
        let screen = tileSpace
        tiles.begin(scale: store.viewport.zoom * deviceScale, now: now, artboards: Set(doc.nodes.lazy.filter(\.isArtboard).map(\.id)))
        for whole in doc.nodes where !whole.hidden {
            guard whole.isArtboard else {
                if Geometry.bounds(of: whole).insetBy(dx: -64, dy: -64).intersects(visible) { Renderer.drawNode(whole, in: ctx, options: options) }
                continue
            }
            // A deck shows the post in front of it.
            let node = whole.isDeck ? whole.showing(store.front(of: whole)) : whole
            guard node.frame.insetBy(dx: -40 / store.viewport.zoom, dy: -40 / store.viewport.zoom).intersects(visible) else { continue }
            // A deck whose posts are out of the stack as cards, flying or turning, is left to them:
            // drawn unseen, so that its tiles are ready when they land.
            let away = deckTool.hides(whole)
            if away {
                ctx.saveGState()
                ctx.setAlpha(0)
            }
            defer { if away { ctx.restoreGState() } }
            if typingOn.contains(node.id) {
                Renderer.drawArtboard(node, in: ctx, options: options)
                continue
            }
            var alone = options
            alone.settling = false
            let more = tiles.draw(node, in: ctx, visible: visible, shadowPixels: 28 * deviceScale, now: now, deadline: deadline,
                                  live: options.settling, still: still, look: options.looks?[node.id], make: { rect, step, changing in
                var making = options
                // While it is being changed, its background blurs show what they last showed, and
                // catch up once it is left alone.
                making.settling = changing
                return Renderer.tile(of: node, rect: rect, scale: step, options: making, screen: screen.space)
            }, away: { [alone] rect, step in Renderer.tile(of: node, rect: rect, scale: step, options: alone, screen: screen.space) })
            again = again || more
        }
        if again { redrawSoon() }
        // The design shown in full for the first time: its tab may uncover it (`OpeningCover`).
        if let drawn = store.whenDrawn, tiles.drewInFull {
            store.whenDrawn = nil
            drawn()
        }
    }

    let tiles = BoardTiles()
    /// The screen's colours, which the tiles are kept in; handed to the threads that make them.
    private struct TileSpace: @unchecked Sendable {
        let space: CGColorSpace?
    }
    private var tileSpace = TileSpace(space: nil)

    private static func sameSpace(_ a: CGColorSpace?, _ b: CGColorSpace?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): a === b || CFEqual(a, b)
        default: false
        }
    }

    private var lastViewport = Viewport()
    private var viewportMoved: CFTimeInterval = 0
    private var redrawPending = false

    /// Draws again next frame, to make the tiles that had to wait; each frame makes only as many
    /// as leave the pointer and keys free. A timer of the run loop's own, so it also fires while a
    /// menu is open or the window is being resized.
    private func redrawSoon() {
        guard !redrawPending else { return }
        redrawPending = true
        let timer = Timer(timeInterval: 0.016, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.redrawPending = false
                self?.redrawForArrivals()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// How long after a step of the view the canvas counts as moving still.
    private static let moving: CFTimeInterval = 0.05

    /// Something made away from the main thread has come (tiles, a film's pictures), or more is
    /// wanted with the next frame: the canvas is drawn again. Not while the view moves, though:
    /// each step of a pan or zoom draws the canvas anyway, with whatever has come by then, and a
    /// drawing more in between is a second one within one frame of the screen, which waits for the
    /// screen and makes the next step late. So it waits until the view has paused.
    func redrawForArrivals() {
        if CACurrentMediaTime() - viewportMoved < Self.moving { redrawSoon() } else { needsDisplay = true }
    }

    private static let titleFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    private var titleWidths: [String: CGFloat] = [:]

    /// Room at the right of a carousel's first slide for its number, which the name stops short of.
    private static let slideNumberRoom: CGFloat = 28
    /// The line over an artboard its name stands in, and a carousel's slide numbers: from how far
    /// above its top, and how tall.
    static let titleRise: CGFloat = 19, titleHeight: CGFloat = 16

    /// Whether a carousel's slide numbers are drawn at this zoom: only once a slide leaves room
    /// for the name's least width beside its number.
    static func showsSlideNumbers(_ board: Node, zoom: CGFloat) -> Bool {
        board.isCarousel && (board.slideSize.map { $0.width * zoom >= slideNumberRoom + 40 } ?? false)
    }

    private func titleRect(of board: Node) -> CGRect {
        var r = store.viewport.toView(board.frame)
        if board.isCarousel, let slide = board.slideSize { r.size.width = slide.width * store.viewport.zoom - Self.slideNumberRoom }
        let measured = titleWidths[board.name] ?? {
            let w = (board.name as NSString).size(withAttributes: [.font: Self.titleFont]).width
            if titleWidths.count > 2000 { titleWidths.removeAll() }
            titleWidths[board.name] = w
            return w
        }()
        return CGRect(x: r.minX, y: r.minY - Self.titleRise, width: min(measured + 2, max(r.width, 40)), height: Self.titleHeight)
    }

    /// Keeps the field an artboard is being renamed in over its name as the view moves, and takes
    /// it away should the artboard go, undone or hidden.
    private func syncNaming() {
        guard let id = naming.board else { return }
        guard let board = store.node(id), board.isArtboard, !board.hidden else {
            naming.end(keep: false)
            return
        }
        let zoom = store.viewport.zoom
        let width = board.isCarousel ? (board.slideSize?.width ?? board.frame.width) * zoom - Self.slideNumberRoom : board.frame.width * zoom
        naming.place(titleRect(of: board), boardWidth: width)
    }

    private func drawArtboardTitles(_ ctx: CGContext) {
        let selected = Set(store.selection)
        for board in store.doc.artboards where !board.hidden {
            // Too small on screen for its name to be read.
            guard board.frame.width * store.viewport.zoom >= 30 else { continue }
            let rect = titleRect(of: board)
            let on = selected.contains(board.id) || store.hovered == board.id
            let color = flowTool.labelColor(selected: on, design: on ? CanvasInk.labelSelected : CanvasInk.label)
            if board.isCarousel { drawSlideNumbers(board, color: color) }
            // Being renamed, the name is in its field.
            guard rect.intersects(bounds), board.id != naming.board else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (board.name as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                          attributes: [.font: Self.titleFont, .foregroundColor: color, .paragraphStyle: paragraph])
        }
    }

    /// Each slide's number over its top right corner, in the line the artboard's name is in.
    private func drawSlideNumbers(_ board: Node, color: NSColor) {
        let zoom = store.viewport.zoom
        guard Self.showsSlideNumbers(board, zoom: zoom) else { return }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: color]
        for (i, rect) in board.slideRects.enumerated() {
            let r = store.viewport.toView(rect.offsetBy(dx: board.frame.minX, dy: board.frame.minY))
            guard r.maxX >= bounds.minX, r.minX <= bounds.maxX else { continue }
            let number = "\(i + 1)" as NSString
            let w = number.size(withAttributes: attributes).width
            number.draw(at: CGPoint(x: r.maxX - w, y: r.minY - Self.titleRise), withAttributes: attributes)
        }
    }

    /// Where a carousel will be cut into slides: a dashed line down each cut, over what is on it.
    /// Only on the canvas; nothing of it is exported.
    private func drawSlideCuts(_ ctx: CGContext) {
        let zoom = store.viewport.zoom
        for board in store.doc.artboards where !board.hidden && board.isCarousel && board.slideCount > 1 {
            guard let slide = board.slideSize, slide.width * zoom >= 4 else { continue }
            let r = store.viewport.toView(board.frame)
            guard r.intersects(bounds) else { continue }
            ctx.saveGState()
            for i in 1..<board.slideCount {
                let x = crisp(CGPoint(x: r.minX + CGFloat(i) * slide.width * zoom, y: 0)).x
                guard x >= bounds.minX, x <= bounds.maxX else { continue }
                ctx.move(to: CGPoint(x: x, y: max(r.minY, bounds.minY)))
                ctx.addLine(to: CGPoint(x: x, y: min(r.maxY, bounds.maxY)))
            }
            guard let cuts = ctx.path else { ctx.restoreGState(); continue }
            ctx.setLineWidth(1)
            // A light line under the blue dashes keeps the cut in sight on dark slides and light ones.
            ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.7).cgColor)
            ctx.strokePath()
            ctx.addPath(cuts)
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineDash(phase: 0, lengths: [4, 3])
            ctx.strokePath()
            ctx.restoreGState()
        }
    }

    /// A layer's outline on screen: its four corners, turned with it in the page and in depth,
    /// and with any group above it that is turned in depth.
    private func viewCorners(of id: UUID) -> [CGPoint]? {
        store.doc.shownCorners(of: id) { turnedBox(of: $0) }?.map(store.viewport.toView)
    }

    /// Each group's turned box (`BezzleDocument.turnedBox`) as last worked out, by layer, for the
    /// version of the document it was worked out for: the pointer asks for it at every move.
    private var boxesWorkedOut: (version: Int, boxes: [UUID: (frame: CGRect, rotation: Double)]) = (-1, [:])

    private func turnedBox(of node: Node) -> (frame: CGRect, rotation: Double) {
        guard node.isGroup else { return (node.frame, node.rotation) }
        if boxesWorkedOut.version != store.version { boxesWorkedOut = (store.version, [:]) }
        if let box = boxesWorkedOut.boxes[node.id] { return box }
        let box = BezzleDocument.turnedBox(of: node)
        boxesWorkedOut.boxes[node.id] = box
        return box
    }

    /// Where a point of a layer, given on the canvas as it would lie flat, shows: turned in depth
    /// with it and with any group above it.
    private func shownOnCanvas(_ p: CGPoint, of node: Node) -> CGPoint {
        store.doc.shownOnCanvas(p, of: node)
    }

    /// The other way: where on the layer, lying flat, a point of the canvas is. Nil past its horizon.
    private func flatOnCanvas(_ p: CGPoint, of node: Node) -> CGPoint? {
        store.doc.flatOnCanvas(p, of: node)
    }

    /// Moves where a layer pinned by its corners shows, by one of its handles pulled to a canvas
    /// point: a corner goes there, and a side's two corners move as its middle does. Only a
    /// layer pinned and not also turned; false for any other, which the handle resizes. A pull
    /// that would fold the layer over itself leaves it as it was.
    private func repin(_ id: UUID, _ original: Node, _ handle: Handle, to p: CGPoint) -> Bool {
        guard var t = original.transform3D, t.pinned, t.x == 0, t.y == 0, t.z == 0, var corners = t.corners, corners.count == 4,
              original.frame.width > 0, original.frame.height > 0, let q = store.doc.placed(p, inParentOf: id) else { return false }
        let f = original.frame
        func fraction(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - f.minX) / f.width, y: (p.y - f.minY) / f.height) }
        let order: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]
        if let k = order.firstIndex(of: handle) {
            corners[k] = fraction(q)
        } else {
            let sides: [Handle: (Int, Int)] = [.top: (0, 1), .right: (1, 2), .bottom: (2, 3), .left: (3, 0)]
            guard let (a, b) = sides[handle], let shown = Perspective(original, eye: store.doc.eye(forParentOf: id)) else { return false }
            let u = handle.unit, was = shown.shown(CGPoint(x: f.minX + u.x * f.width, y: f.minY + u.y * f.height))
            let d = CGPoint(x: (q.x - was.x) / f.width, y: (q.y - was.y) / f.height)
            for k in [a, b] { corners[k] = CGPoint(x: corners[k].x + d.x, y: corners[k].y + d.y) }
        }
        // Still a four-sided shape turning one way all round.
        let turns = (0..<4).map { i -> CGFloat in
            let a = corners[i], b = corners[(i + 1) % 4], c = corners[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 }) else { return true }
        t.corners = corners.map { CGPoint(x: ($0.x * 10_000).rounded() / 10_000, y: ($0.y * 10_000).rounded() / 10_000) }
        store.edit(order.contains(handle) ? "Move Corner" : "Move Side") { doc in
            doc.update(id) { node in
                node = original
                node.transform3D = t
            }
        }
        return true
    }

    /// Whether a layer shows anywhere but where its frame says, turned in depth or in a group that is.
    private func inDepth(_ node: Node) -> Bool { store.doc.inDepth(node) }

    private func outlinePath(_ points: [CGPoint], closed: Bool) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: points.map(crisp))
        if closed { p.closeSubpath() }
        return p
    }

    /// Lines of one pixel fall on whole pixels.
    private func crisp(_ p: CGPoint) -> CGPoint {
        let s = deviceScale
        return CGPoint(x: (p.x * s).rounded() / s + 0.5 / s, y: (p.y * s).rounded() / s + 0.5 / s)
    }

    private func drawHover(_ ctx: CGContext) {
        guard case .none = interaction, let id = store.hovered, !store.selection.contains(id),
              let points = viewCorners(of: id) else { return }
        ctx.saveGState()
        if let node = store.node(id), node.kind == .path, !inDepth(node) {
            // A path is outlined along itself rather than round its frame.
            let vp = store.viewport, o = store.doc.parentOrigin(of: id)
            var t = CGAffineTransform(translationX: o.x, y: o.y)
                .concatenating(CGAffineTransform(scaleX: vp.zoom, y: vp.zoom).translatedBy(x: -vp.origin.x, y: -vp.origin.y))
            let outline = Renderer.placedOutline(of: node)
            ctx.addPath(outline.copy(using: &t) ?? outline)
        } else {
            ctx.addPath(outlinePath(points, closed: points.count > 2))
        }
        ctx.setStrokeColor((store.node(id)?.isCopy == true ? CanvasInk.linked : CanvasInk.pencil).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// The frame the handles sit on: the layer's own for one, the box around them all for several.
    private var handleFrame: (frame: CGRect, rotation: Double, single: Node?)? {
        store.doc.handleFrame(of: store.selection) { turnedBox(of: $0) }
    }

    /// Whether a layer is text as wide as its words, which has one handle, at its bottom, as XD has it.
    private static func pointText(_ node: Node?) -> Bool { BezzleDocument.pointText(node) }

    /// The handles the selection shows, and where; `every` gives text as wide as its words those
    /// of any other layer, for turning it from just outside them.
    private func handlePoints(every: Bool = false) -> [(Handle, CGPoint)] {
        store.doc.handlePoints(of: store.selection, zoom: store.viewport.zoom, every: every) { turnedBox(of: $0) }
            .map { ($0.0, store.viewport.toView($0.1)) }
    }

    /// Words along a curve are typed straight: the corners of the line they are typed on, on screen.
    private func typingCorners(of id: UUID) -> [CGPoint]? {
        guard let node = store.node(id), node.isCurved, let whole = store.doc.absoluteFrame(of: id) else { return nil }
        let (flat, frame) = CurvedText.straight(node, frame: whole)
        return Geometry.corners(of: frame, rotation: flat.rotation).map(store.viewport.toView)
    }

    private func drawSelection(_ ctx: CGContext) {
        let ids = store.selection
        // A path whose points show has those instead of a frame and handles.
        if ids.count == 1, ids[0] == pathTool.shownPath { return }
        // A picture being placed has its own edges and corners instead.
        if ids.count == 1, ids[0] == store.editingPicture { return }
        // Shapes being built with show their pieces instead.
        if store.building != nil { return }
        guard !ids.isEmpty, store.editingText == nil || ids.count > 1 || typingShowsHandles else {
            if let editing = store.editingText, let points = typingCorners(of: editing) ?? viewCorners(of: editing) {
                ctx.addPath(outlinePath(points, closed: true))
                ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.5).cgColor)
                ctx.setLineWidth(1)
                ctx.strokePath()
            }
            return
        }
        ctx.saveGState()
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        ctx.setLineWidth(1)
        for id in ids {
            guard let points = gridTool.outline(of: id) ?? viewCorners(of: id) else { continue }
            ctx.setStrokeColor((store.node(id)?.isCopy == true ? CanvasInk.linked : CanvasInk.pencil).cgColor)
            ctx.addPath(outlinePath(points, closed: points.count > 2))
            ctx.strokePath()
        }
        ctx.setStrokeColor(CanvasInk.pencil.cgColor)
        if ids.count > 1, let (frame, _, _) = handleFrame {
            ctx.addPath(outlinePath(Geometry.corners(of: frame, rotation: 0).map(store.viewport.toView), closed: true))
            ctx.setLineDash(phase: 0, lengths: [3, 3])
            ctx.strokePath()
            ctx.setLineDash(phase: 0, lengths: [])
        }
        ctx.restoreGState()

        if case .move(_, _, _, _, true, _) = interaction { return }
        if ids.count == 1, let node = store.node(ids[0]), node.kind == .line, !node.locked, let ends = viewCorners(of: ids[0]) {
            for p in ends { drawHandle(p, in: ctx, round: true) }
            return
        }
        // Text as wide as its words has one round handle; a box of fixed size too small for its
        // words has a red one at its bottom, which, double-clicked, fits it to them.
        let single = ids.count == 1 ? store.node(ids[0]) : nil
        let point = Self.pointText(single), hiding = single?.overflows == true
        for (h, p) in handlePoints() { drawHandle(p, in: ctx, round: point, warning: hiding && h == .bottom) }
        if case .corner = interaction { drawCornerDots(ctx) } else if case .none = interaction, showsCornerDots { drawCornerDots(ctx) }
        if onShadow || { if case .shadow(_, _, _, true) = interaction { return true } else { return false } }() { drawShadowOutline(ctx) }
    }

    /// The dots inside a selected rectangle's corners, each along the diagonal as far in as its
    /// corner is round, and never nearer a corner than ten points on screen. Only for a rectangle
    /// big enough on screen for them not to crowd it.
    private func cornerDots() -> [(Handle, CGPoint)] {
        guard store.tool == .select, store.editingText == nil else { return [] }
        return store.doc.cornerDots(of: store.selection, zoom: store.viewport.zoom).map { ($0.0, store.viewport.toView($0.1)) }
    }

    private func drawCornerDots(_ ctx: CGContext) {
        for (_, p) in cornerDots() {
            let rect = CGRect(center: p, size: CGSize(width: 7, height: 7))
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
            ctx.setFillColor(.white)
            ctx.fillEllipse(in: rect)
            ctx.restoreGState()
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The selected layer's shape where its shadow falls, dashed, while the pointer is on it.
    private func drawShadowOutline(_ ctx: CGContext) {
        guard let corners = store.doc.shadowCorners(of: store.selection, slot: store.shadowSlot) else { return }
        ctx.saveGState()
        ctx.addPath(outlinePath(corners.map(store.viewport.toView), closed: true))
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(1)
        ctx.setLineDash(phase: 0, lengths: [3, 3])
        ctx.strokePath()
        ctx.restoreGState()
    }

    /// Whether a point on screen is on the selected layer's shadow and not on the layer itself.
    private func isOnShadow(_ v: CGPoint) -> Bool {
        guard store.tool == .select, store.editingText == nil else { return false }
        return store.doc.isOnShadow(store.viewport.toCanvas(v), selection: store.selection, zoom: store.viewport.zoom, tolerance: tolerance, slot: store.shadowSlot)
    }

    private func drawHandle(_ p: CGPoint, in ctx: CGContext, round: Bool, warning: Bool = false) {
        let size: CGFloat = 8
        let rect = CGRect(center: crisp(p), size: CGSize(width: size, height: size)).offsetBy(dx: -0.5 / deviceScale, dy: -0.5 / deviceScale)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -0.5 * deviceScale), blur: 1.5 * deviceScale, color: NSColor.black.withAlphaComponent(0.18).cgColor)
        ctx.setFillColor(warning ? CanvasInk.overflow.cgColor : .white)
        if round { ctx.fillEllipse(in: rect) } else { ctx.fill(rect) }
        ctx.restoreGState()
        ctx.setStrokeColor((warning ? CanvasInk.overflow : CanvasInk.pencil).cgColor)
        ctx.setLineWidth(1)
        if round { ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5)) } else { ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5)) }
    }

    private func drawGuides(_ ctx: CGContext) {
        if store.guides.contains(where: { !$0.gap }) {
            ctx.saveGState()
            ctx.setStrokeColor(CanvasInk.pencil.cgColor)
            ctx.setLineWidth(1)
            for g in store.guides where !g.gap {
                ctx.move(to: crisp(store.viewport.toView(g.from)))
                ctx.addLine(to: crisp(store.viewport.toView(g.to)))
            }
            ctx.strokePath()
            ctx.restoreGState()
        }
        gapMarks.show(store.guides)
        gapMarks.draw(ctx, viewport: store.viewport, scale: deviceScale)
        if gapMarks.isAnimating { keepEasing() }
    }

    private func drawMarquee(_ ctx: CGContext) {
        guard case .marquee(let start, _, _) = interaction else { return }
        let rect = Geometry.rect(from: store.viewport.toView(start), to: lastViewPoint)
        ctx.setFillColor(CanvasInk.pencil.withAlphaComponent(0.08).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(CanvasInk.pencil.withAlphaComponent(0.8).cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
    }

    /// The size of what is being drawn or resized, in a small pencil-blue pill under it.
    private func drawMeasurement(_ ctx: CGContext) {
        guard let (text, rect) = store.measurement else { return }
        let r = store.viewport.toView(rect)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor.white]
        let size = (text as NSString).size(withAttributes: attrs)
        let pill = CGRect(x: (r.midX - size.width / 2 - 7).rounded(), y: (r.maxY + 10).rounded(), width: (size.width + 14).rounded(), height: 20)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 6, cornerHeight: 6, transform: nil))
        ctx.setFillColor(CanvasInk.pencil.cgColor)
        ctx.fillPath()
        (text as NSString).draw(at: CGPoint(x: pill.minX + 7, y: pill.minY + (20 - size.height) / 2), withAttributes: attrs)
    }

    // MARK: - Finding things under the pointer

    private func canvasPoint(_ event: NSEvent) -> CGPoint {
        store.viewport.toCanvas(convert(event.locationInWindow, from: nil))
    }

    private var tolerance: CGFloat { 4 / store.viewport.zoom }

    /// The topmost layer under a canvas point that a click would select.
    /// What a click picks, as every Bezzle picks it (`Picking`, shared): the design as this
    /// viewer sees it, the group the selection is in looked in first.
    private var picking: Picking {
        Picking(doc: store.doc, selection: store.selection, fronts: store.fronts, zoom: store.viewport.zoom)
    }

    private func hit(_ p: CGPoint) -> UUID? { picking.hit(p) }

    /// The group the selection is in, where clicks look first, as they do after a double click into it.
    private var enteredGroup: Node? { picking.enteredGroup }

    /// What in a group lies under a canvas point, one level down.
    private func hit(_ p: CGPoint, in group: Node) -> UUID? { picking.hit(p, in: group) }

    /// What a click at a canvas point would pick, for what is placed over the canvas.
    func layer(at p: CGPoint) -> UUID? { pick(p) }

    private func pick(_ p: CGPoint) -> UUID? { picking.pick(p) }

    private func titleHit(_ viewPoint: CGPoint) -> UUID? {
        store.doc.artboards.reversed().first { !$0.hidden && titleRect(of: $0).insetBy(dx: 0, dy: -2).contains(viewPoint) }?.id
    }

    /// Whether the text being typed into shows its handles, as it does when only selected: when
    /// it has words, and lies straight.
    private var typingShowsHandles: Bool {
        guard let id = store.editingText, store.selection == [id], let node = store.node(id) else { return false }
        return !node.isCurved && !(node.text ?? "").isEmpty
    }

    private func handleHit(_ v: CGPoint) -> HandleHit? {
        guard store.editingText == nil || typingShowsHandles, store.editingPath == nil, store.editingPicture == nil, store.building == nil else { return nil }
        return store.doc.handleHit(at: v, selection: store.selection, zoom: store.viewport.zoom, toView: store.viewport.toView,
                                   selecting: store.tool == .select && store.editingText == nil, slot: store.shadowSlot) { turnedBox(of: $0) }
    }

    // MARK: - Pointer

    override func mouseMoved(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        holdWindow()
        lastViewPoint = v
        if store.prototyping {
            if store.hovered != nil { store.hovered = nil }
            if store.animating {
                motionTool.hover(v)
                (spaceHeld ? NSCursor.openHand : motionTool.cursor(at: v)).set()
                return
            }
            if store.inspecting {
                inspectTool.hover(v)
                (spaceHeld ? NSCursor.openHand : inspectTool.cursor(at: v)).set()
                return
            }
            flowTool.hover(v)
            (spaceHeld ? NSCursor.openHand : flowTool.cursor(at: v) ?? .arrow).set()
            return
        }
        // Looking back, what differs from now under the pointer, to pick.
        if store.versions.travel != nil {
            timeTable.hover(store.viewport.toCanvas(v))
            (spaceHeld ? NSCursor.openHand : timeTable.hovered != nil ? .pointingHand : .arrow).set()
            return
        }
        rulers.hover(v)
        guideTool.hover(v)
        layoutTool.hover(v)
        if rulers.part(at: v) != nil || guideTool.cursor(at: v) != nil || layoutTool.cursor(at: v) != nil {
            // On a ruler, a guide or a grid's gutter, nothing under it is outlined.
            if store.hovered != nil { store.hovered = nil }
            updateCursor(v, flags: event.modifierFlags)
            needsDisplay = true
            return
        }
        // The pointer's mark on the rulers: only they are drawn again for it.
        if Helpers.shared.rulers {
            let t = Rulers.thickness
            setNeedsDisplay(CGRect(x: 0, y: 0, width: bounds.width, height: t))
            setNeedsDisplay(CGRect(x: 0, y: 0, width: t, height: bounds.height))
        }
        updateHover(v)
        if store.tool == .pen || store.editingPath != nil { pathTool.hover(v, flags: event.modifierFlags) }
        cutoutTool.hover(at: store.editingPicture != nil ? v : nil)
        developTool.hover(at: v)
        hoverShapeTools(v, flags: event.modifierFlags)
        updateCursor(v, flags: event.modifierFlags)
        updateOverlays(v)
    }

    /// The knife, building with pieces, and a shape's corners and edge, which each show
    /// something of their own under the pointer.
    private func hoverShapeTools(_ v: CGPoint?, flags: NSEvent.ModifierFlags) {
        shapeBuilder.hover(v, flags: flags)
        outlineTool.hover(v, flags: flags)
        depthTool.hover(v, flags: flags)
        lookTool.hover(v)
        gridTool.hover(v)
        deckTool.hover(v)
        componentTool.hover(v)
        maskTool.hover(v)
        curveTool.hover(v)
        knifeTool.hover(v, flags: flags)
    }

    /// The corner dots show while the pointer is on the selected rectangle; the shadow's outline
    /// while it is on the shadow.
    private func updateOverlays(_ v: CGPoint) {
        var dots = false
        if case .none = interaction, store.selection.count == 1, let id = store.selection.first, store.node(id)?.kind == .rectangle,
           let points = viewCorners(of: id) {
            let path = CGMutablePath()
            path.addLines(between: points)
            path.closeSubpath()
            dots = path.copy(strokingWithWidth: 16, lineCap: .round, lineJoin: .round, miterLimit: 1).contains(v) || path.contains(v)
        }
        let shadow: Bool = if case .none = interaction { isOnShadow(v) && handleHit(v).map { if case .shadow = $0 { true } else { false } } ?? false } else { false }
        if dots != showsCornerDots || shadow != onShadow {
            showsCornerDots = dots
            onShadow = shadow
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        store.hovered = nil
        timeTable.hover(nil)
        flowTool.hover(nil)
        inspectTool.hover(nil)
        motionTool.hover(nil)
        developTool.hover(at: nil)
        rulers.hover(nil)
        guideTool.hover(nil)
        layoutTool.hover(nil)
        needsDisplay = true
        pathTool.hover(nil, flags: [])
        hoverShapeTools(nil, flags: [])
        NSCursor.arrow.set()
    }

    private func updateHover(_ v: CGPoint) {
        // Seen as a prototype, inspected or animated, what the pointer rests on is told that way's
        // own tool, as when the pointer moves: after a click, a scroll or a key let go, the
        // design's hover does not show through.
        if store.prototyping {
            if store.hovered != nil { store.hovered = nil }
            guard case .none = interaction else { return }
            if store.animating { motionTool.hover(v) } else if store.inspecting { inspectTool.hover(v) } else { flowTool.hover(v) }
            return
        }
        guard case .none = interaction, store.tool == .select else {
            if store.hovered != nil { store.hovered = nil }
            return
        }
        let id = titleHit(v) ?? pick(store.viewport.toCanvas(v))
        if store.hovered != id { store.hovered = id }
    }

    private func updateCursor(_ v: CGPoint, flags: NSEvent.ModifierFlags) {
        if spaceHeld { NSCursor.openHand.set(); return }
        if store.prototyping {
            let cursor = store.animating ? motionTool.cursor(at: v) : store.inspecting ? inspectTool.cursor(at: v) : flowTool.cursor(at: v) ?? .arrow
            cursor.set()
            return
        }
        if let cursor = guideTool.cursor(at: v) ?? layoutTool.cursor(at: v) { cursor.set(); return }
        if let cursor = pathTool.cursor { cursor.set(); return }
        if let cursor = pictureTool.cursor(at: v) { cursor.set(); return }
        if let cursor = developTool.cursor(at: v) { cursor.set(); return }
        if let cursor = depthTool.cursor { cursor.set(); return }
        if let cursor = gridTool.cursor(at: v) { cursor.set(); return }
        if let cursor = deckTool.cursor(at: v) { cursor.set(); return }
        if let cursor = componentTool.cursor(at: v) { cursor.set(); return }
        if let cursor = curveTool.cursor(at: v) { cursor.set(); return }
        if let cursor = maskTool.cursor(at: v) { cursor.set(); return }
        if let cursor = shapeBuilder.cursor ?? knifeTool.cursor ?? outlineTool.cursor(at: v) { cursor.set(); return }
        switch store.tool {
        case .select:
            switch handleHit(v) {
            case .resize(let h):
                let rotation = handleFrame?.rotation ?? 0
                Cursors.resize(h.angle + rotation).set()
            case .rotate(let h):
                Cursors.rotate(h.angle + (handleFrame?.rotation ?? 0)).set()
            case .lineEnd, .corner:
                NSCursor.crosshair.set()
            case .shadow:
                NSCursor.openHand.set()
            case .turnInDepth:
                Cursors.turn.set()
            case nil:
                NSCursor.arrow.set()
            }
        case .text:
            // The selected text's handles resize it with the Text tool in hand too.
            if case .resize(let h)? = handleHit(v) {
                Cursors.resize(h.angle + (handleFrame?.rotation ?? 0)).set()
            } else {
                NSCursor.iBeam.set()
            }
        default:
            NSCursor.crosshair.set()
        }
    }

    /// A press on a handle of the text being typed into is the canvas's, though the words lie under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let found = super.hitTest(point)
        guard let found, found !== self, let host = editorHost, found.isDescendant(of: host) else { return found }
        if case .resize? = handleHit(convert(point, from: superview)) { return self }
        return found
    }

    override func mouseDown(with event: NSEvent) {
        // A press anywhere on the canvas keeps the name typed into an artboard's.
        naming.end(keep: true)
        // Looking back, a press picks a layer that differs from now, to bring back; the view moves as ever.
        if store.versions.travel != nil, !spaceHeld {
            window?.makeFirstResponder(self)
            store.versions.pick(at: store.viewport.toCanvas(convert(event.locationInWindow, from: nil)))
            return
        }
        // Seen as a prototype, a press pulls a thread, moves a screen or the view, or picks.
        if store.prototyping {
            window?.makeFirstResponder(self)
            let v = convert(event.locationInWindow, from: nil)
            lastViewPoint = v
            mouseDownView = v
            if spaceHeld {
                spaceTap?.moved = true
                interaction = .pan(startOrigin: store.viewport.origin, startView: v)
                NSCursor.closedHand.set()
                return
            }
            if store.animating {
                motionTool.down(at: v, event: event)
                motionTool.cursor(at: v).set()
                return
            }
            if deckTool.spreading, deckTool.down(at: v, event: event) { return }
            if store.inspecting {
                _ = inspectTool.down(at: v, event: event)
                return
            }
            _ = flowTool.down(at: v, event: event)
            return
        }
        // A word offered after a change is taken before anything else.
        if deckTool.offerDown(at: convert(event.locationInWindow, from: nil)) { return }
        if maskTool.offerDown(at: convert(event.locationInWindow, from: nil)) { return }
        // The word by an artboard looked at from the side looks from the front again.
        if lookTool.wordDown(at: convert(event.locationInWindow, from: nil)) { return }
        if !deckTool.spreading, componentTool.down(at: convert(event.locationInWindow, from: nil)) { return }
        window?.makeFirstResponder(self)
        // A selected text's handles resize it while it is typed into, and with the Text tool in
        // hand, as when it is only selected; typing goes on after.
        if store.editingText != nil || store.tool == .text, !spaceHeld,
           case .resize(let handle)? = handleHit(convert(event.locationInWindow, from: nil)) {
            if let id = store.editingText {
                typingResumes = (id, editor?.selectedRange() ?? NSRange(location: 0, length: 0))
                endEditing()
            }
            let v = convert(event.locationInWindow, from: nil)
            lastViewPoint = v
            mouseDownView = v
            store.hovered = nil
            if event.clickCount >= 2, handle == .bottom, fitTextToWords() {
                resumeTyping()
                return
            }
            startHandleDrag(.resize(handle), at: store.viewport.toCanvas(v))
            return
        }
        if store.editingText != nil { endEditing() }
        // A click beside the note open puts it away.
        if store.openThread != nil { store.openThread = nil }
        let v = convert(event.locationInWindow, from: nil)
        let p = store.viewport.toCanvas(v)
        lastViewPoint = v
        mouseDownView = v
        store.hovered = nil

        if spaceHeld {
            spaceTap?.moved = true
            interaction = .pan(startOrigin: store.viewport.origin, startView: v)
            NSCursor.closedHand.set()
            return
        }
        // The rulers take a press whatever the tool: out of them come guides.
        if !deckTool.spreading, guideTool.rulerDown(at: v, event: event) { return }
        // Every post of a deck spread out takes every press until it is put away.
        if deckTool.spreading, deckTool.down(at: v, event: event) { return }

        switch store.tool {
        case .select:
            // Off the pieces, building is done, and the press goes on as any.
            if shapeBuilder.down(at: v, event: event) { return }
            if store.editingPicture != nil {
                if pictureTool.down(at: v, clicks: event.clickCount) { return }
                // Anywhere off the picture: out of placing, and on as any press.
                store.editingPicture = nil
            }
            if store.editingPath != nil {
                if pathTool.editDown(at: v, event: event) { return }
                // Off the path's points and outline: dragging round points, or, on another
                // layer, out of editing to pick that. A click on nothing at all leaves editing too.
                let other = titleHit(v) ?? pick(p)
                if other == nil || other == store.editingPath {
                    if event.clickCount >= 2 { store.editingPath = nil } else {
                        pathTool.startMarquee(at: v, adding: event.modifierFlags.contains(.shift), offPath: other == nil)
                    }
                    return
                }
                store.editingPath = nil
            }
            selectDown(at: p, view: v, event: event)
        case .pen:
            pathTool.penDown(at: v, event: event)
        case .knife:
            knifeTool.down(at: v, event: event)
        case .note:
            // A click is a note on whatever is under the pointer, or on the canvas itself, at that
            // spot; a loop drawn round part of the design is a note about that part.
            noteCircling = (points: [p], target: titleHit(v) ?? pick(p), start: p, view: v)
        case .text:
            // A click on a text types into it, all its words picked out; a drag, over one or not,
            // draws a new one. See `finishCreating`.
            textUnderPress = hit(p).flatMap { store.node($0)?.kind == .text ? $0 : nil }
            fallthrough
        default:
            let board = store.tool == .artboard ? nil : store.doc.artboard(at: p)?.id
            var targets = SnapTargets(doc: store.seenDoc, moving: [])
            // Drawn on an artboard, it catches on its guides and its grid as well.
            if let b = board.flatMap({ store.seenDoc.node($0) }) { targets.catchOnHelpers(of: b) }
            let start = snapped(p, targets: targets, event: event)
            store.beginGesture()
            interaction = .create(tool: store.tool, start: start, id: nil, board: board, targets: targets)
        }
    }

    private func selectDown(at p: CGPoint, view v: CGPoint, event: NSEvent) {
        let shift = event.modifierFlags.contains(.shift)

        // A deck's strip turns its posts and adds them; a word offered after a change does what it says.
        if deckTool.down(at: v, event: event) { return }
        // A selected grid's handles repeat it, and its gaps space it.
        if gridTool.down(at: v, event: event) { return }
        // A turned layer's knob aims it in depth.
        if depthTool.down(at: v, event: event) { return }
        // A selected text's beads bend it.
        if curveTool.down(at: v, event: event) { return }
        // A path's corner dots and a shape's edge with Option, unless a resize handle is in the way.
        let handle = handleHit(v)
        if case .resize = handle {} else if outlineTool.down(at: v, event: event) { return }
        if let handle {
            if event.clickCount >= 2, case .resize(.bottom) = handle, fitTextToWords() { return }
            startHandleDrag(handle, at: p)
            return
        }
        // With the Photo card open, the picture is the control.
        if developTool.down(at: v, event: event) { return }
        // With its card open, a selected artboard's grid is changed where it is drawn.
        if layoutTool.down(at: v, event: event) { return }
        // A guide's line, where no layer lies under it, or its pins past the artboard's edges.
        if guideTool.down(at: v, event: event) { return }

        // A double click on an artboard's name renames it, there.
        if event.clickCount == 2, !shift, !store.isReadOnly, let board = titleHit(v) {
            naming.begin(board, in: self, font: Self.titleFont)
            return
        }
        // A double click goes into a group, and each quick click after it one level further,
        // however fast they come; on a text, it starts typing; on a path or a shape, it opens its points.
        if event.clickCount >= 2, let id = pick(p), let node = store.node(id) {
            if node.isGroup, let inner = hit(p, in: node) {
                store.selection = [inner]
                return
            }
            if node.kind == .text {
                store.selection = [id]
                beginEditing(id, action: "Typing")
                return
            }
            // On a picture, it places the picture inside it, and a drag straight on moves it.
            if !node.isArtboard, !node.locked, node.fill.on, node.fill.image != nil {
                store.selection = [id]
                store.editPicture()
                _ = pictureTool.down(at: v, clicks: 1)
                return
            }
            if node.kind == .path {
                store.selection = [id]
                store.editingPath = id
                return
            }
            if !node.locked, node.asPath() != nil {
                store.editAsPath(id)
                return
            }
        }

        if let board = titleHit(v) ?? pick(p) {
            if shift {
                if store.selection.contains(board) { store.selection.removeAll { $0 == board } } else { store.selection.append(board) }
            } else if !store.selection.contains(board) {
                store.selection = [board]
            }
            startMove(at: p, duplicate: event.modifierFlags.contains(.option))
            return
        }

        // Inside the box around several layers, a drag moves them all.
        if store.selection.count > 1, !shift, let bounds = store.selectionBounds, bounds.contains(p) {
            startMove(at: p, duplicate: event.modifierFlags.contains(.option))
            return
        }

        // Control on nothing takes the scene and turns the look: an artboard seen from the side.
        if event.modifierFlags.contains(.control), lookTool.down(at: v) { return }

        let base = shift ? store.selection : []
        if !shift { store.selection = [] }
        interaction = .marquee(start: p, base: base, inside: store.doc.artboard(at: p)?.id)
    }

    /// The drag resizing an artboard is over: its design is laid out from the same design next
    /// time, while it is left as it is now.
    private func endAdapting() {
        guard !adaptSessions.isEmpty else { return }
        for session in adaptSessions.values {
            if let n = store.doc.node(session.id) { Adapting.remember(source: session.source, laid: n) }
        }
        adaptSessions = [:]
        adaptTool.hide()
        keepEasing()
    }

    private func startMove(at p: CGPoint, duplicate: Bool) {
        let ids = store.selection.filter { store.node($0)?.locked == false }
        guard !ids.isEmpty, let bounds = store.selectionBounds else { return }
        var originals: [UUID: CGRect] = [:]
        for id in ids { originals[id] = store.doc.absoluteFrame(of: id) }
        interaction = .move(start: p, originals: originals, bounds: bounds, targets: SnapTargets(doc: store.seenDoc, moving: Set(ids)),
                            started: false, duplicate: duplicate)
        pushing = DepthPushing()
        pushedFrom = [:]
        pushLevels = [:]
        pushedTo = [:]
        movedAcross = .zero
    }

    private func startHandleDrag(_ hit: HandleHit, at p: CGPoint) {
        let ids = store.selection
        var originals: [UUID: Node] = [:], absolute: [UUID: CGRect] = [:]
        for id in ids {
            originals[id] = store.node(id)
            absolute[id] = store.doc.absoluteFrame(of: id)
        }
        store.beginGesture()
        switch hit {
        case .resize(let handle):
            guard let (frame, rotation, _) = handleFrame else { return }
            interaction = .resize(handle: handle, originals: originals, absolute: absolute, bounds: frame, rotation: rotation,
                                  targets: SnapTargets(doc: store.seenDoc, moving: Set(ids)))
            // An artboard's design is read once, to be laid out again at each size the drag reaches.
            adaptSessions = [:]
            for (id, node) in originals { if let session = Adapting.Session(node, assets: store.assets) { adaptSessions[id] = session } }
        case .rotate:
            guard let (frame, _, _) = handleFrame else { return }
            let c = frame.center
            interaction = .rotate(center: c, startAngle: atan2(p.y - c.y, p.x - c.x), originals: originals, absolute: absolute)
        case .corner(let corner):
            guard let id = ids.first, let node = store.node(id), let frame = absolute[id] else { return }
            interaction = .corner(id: id, frame: frame, rotation: node.rotation, corner: corner, radii: node.radii)
        case .turnInDepth:
            // Not a gesture yet, as for a shadow.
            store.cancelGesture()
            depthTool.startTurn(at: store.viewport.toView(p))
        case .shadow:
            // Not a gesture yet: a click here without a drag selects what is under it.
            store.cancelGesture()
            guard let id = ids.first, let node = store.node(id), let slot = store.shadowSlot(of: node) else { return }
            interaction = .shadow(id: id, start: p, original: CGPoint(x: node[shadow: slot].x, y: node[shadow: slot].y), started: false)
        case .lineEnd(let end):
            guard let id = ids.first, let node = store.node(id) else { return }
            let o = store.doc.parentOrigin(of: id)
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            let (a, b) = node.lineEnds
            // A turned line is straightened out into its ends, so they can be dragged freely.
            let ra = Geometry.rotated(a, about: c, by: node.rotation) + o, rb = Geometry.rotated(b, about: c, by: node.rotation) + o
            store.update([id], "Move Line End") { $0.rotation = 0; $0.setLineEnds(ra - o, rb - o) }
            interaction = .lineEnd(id: id, fixed: end == 0 ? rb : ra, targets: SnapTargets(doc: store.seenDoc, moving: [id]))
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        lastViewPoint = v
        // The rulers mark where the pointer is while it drags as well.
        rulers.pointer = v
        drag(to: v, flags: event.modifierFlags)
    }

    private func drag(to v: CGPoint, flags: NSEvent.ModifierFlags) {
        if var c = noteCircling {
            c.points.append(store.viewport.toCanvas(v))
            noteCircling = c
            if hypot(v.x - c.view.x, v.y - c.view.y) > 6 {
                let xs = c.points.map(\.x), ys = c.points.map(\.y)
                store.noteCircle = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            }
            return
        }
        if motionTool.dragging {
            motionTool.drag(to: v, flags: flags)
            motionTool.cursor(at: v).set()
            return
        }
        if inspectTool.dragging {
            inspectTool.drag(to: v)
            return
        }
        if flowTool.dragging {
            flowTool.drag(to: v)
            if let cursor = flowTool.cursor(at: v) { cursor.set() }
            return
        }
        if guideTool.pressed { guideTool.drag(to: v, flags: flags); updateCursor(v, flags: flags); return }
        if layoutTool.dragging { layoutTool.drag(to: v, flags: flags); return }
        if pathTool.dragging { pathTool.drag(to: v, flags: flags); return }
        if pictureTool.dragging { pictureTool.drag(to: v, flags: flags); return }
        if developTool.dragging { developTool.drag(to: v, flags: flags); updateCursor(v, flags: flags); return }
        if shapeBuilder.dragging { shapeBuilder.drag(to: v, flags: flags); return }
        if outlineTool.dragging { outlineTool.drag(to: v, flags: flags); return }
        if depthTool.dragging { depthTool.drag(to: v, flags: flags); return }
        if lookTool.dragging { lookTool.drag(to: v, flags: flags); return }
        if curveTool.dragging { curveTool.drag(to: v, flags: flags); return }
        if gridTool.dragging { gridTool.drag(to: v, flags: flags); return }
        if deckTool.dragging { deckTool.drag(to: v, flags: flags); return }
        if knifeTool.dragging { knifeTool.drag(to: v, flags: flags); return }
        let p = store.viewport.toCanvas(v)
        let shift = flags.contains(.shift), option = flags.contains(.option)
        let snapping = !flags.contains(.command)
        let threshold = 5 / store.viewport.zoom

        switch interaction {
        case .none:
            break

        case .pan(let origin, let startView):
            store.viewport.origin = CGPoint(x: origin.x - (v.x - startView.x) / store.viewport.zoom,
                                            y: origin.y - (v.y - startView.y) / store.viewport.zoom)

        case .marquee(let start, let base, let inside):
            let picked = picking.marquee(Geometry.rect(from: start, to: p), inside: inside)
            store.selection = base + picked.filter { !base.contains($0) }
            needsDisplay = true

        case .move(let start, let originals, let bounds, let targets, let started, let duplicate):
            if !started {
                guard hypot(v.x - mouseDownView.x, v.y - mouseDownView.y) > 3 else { return }
                store.beginGesture()
                var originals = originals
                if duplicate {
                    var copies: [UUID] = []
                    store.edit("Duplicate") { doc in copies = DocumentStore.duplicate(Array(originals.keys), in: &doc, offset: .zero) }
                    let keys = Array(originals.keys)
                    var fresh: [UUID: CGRect] = [:]
                    for (old, new) in zip(keys, copies) { fresh[new] = originals[old] }
                    originals = fresh
                    store.selection = copies
                }
                // A copy catches on the layers it was made from, which stay where they were.
                let targets = duplicate ? SnapTargets(doc: store.seenDoc, moving: Set(originals.keys)) : targets
                interaction = .move(start: start, originals: originals, bounds: bounds, targets: targets, started: true, duplicate: duplicate)
                // How high each is held, and those around it, to push them in depth from.
                let layers = originals.keys.filter { store.node($0)?.isArtboard == false }
                pushedFrom = Dictionary(uniqueKeysWithValues: layers.map { ($0, store.node($0)?.transform3D) })
                pushLevels = store.doc.levels(around: layers)
                // Held from the press, it is pushed from where the press was.
                pushing.pointer(at: start, holding: flags.contains(.control) && !pushedFrom.isEmpty)
                NSCursor.arrow.set()
                drag(to: v, flags: flags)
                return
            }
            // Words held on a shape's edge catch on it, and then slide along it rather than move.
            switch curveTool.moving(Array(originals.keys), from: start, at: v) {
            case .handled:
                maskTool.cancel()
                store.guides = []
                return
            case .restart(let fresh, let freshBounds):
                maskTool.cancel()
                store.guides = []
                interaction = .move(start: start, originals: fresh, bounds: freshBounds, targets: targets, started: true, duplicate: duplicate)
                return
            case .normal:
                break
            }
            // With Control held, up brings it nearer and down sends it further, and it stays where
            // it is across; let go, it moves across again from there (`DepthPushing`, shared).
            let wasPushing = pushing.pushing
            pushing.pointer(at: p, holding: flags.contains(.control) && !pushedFrom.isEmpty)
            if pushing.pushing != wasPushing { (pushing.pushing ? NSCursor.resizeUpDown : NSCursor.arrow).set() }
            // Caught on what is around it, Shift keeping to an axis (`SnapTargets.move`, shared).
            // Pushed in depth, it stays across where the move had it, caught as it was.
            let (moved, guides) = pushing.pushing ? (movedAcross, [])
                : targets.move(bounds, by: pushing.across(from: start, to: p), constrain: shift, snapping: snapping, threshold: threshold)
            movedAcross = moved
            // Even gaps caught are felt as well as seen, once each time they catch.
            let caught = Set(guides.filter(\.mine).map { Int(hypot($0.to.x - $0.from.x, $0.to.y - $0.from.y).rounded()) })
            if caught != gapsCaught {
                if !caught.isEmpty { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now) }
                gapsCaught = caught
            }
            if pushing.pushing {
                for (id, from) in pushedFrom {
                    pushedTo[id] = pushing.height(from: from?.z ?? 0, level: pushLevels[id] ?? [], reach: 4 / store.viewport.zoom, steps: shift)
                }
            }
            let turns = pushedTo.map { id, height in (id, DepthPushing.turn(pushedFrom[id] ?? nil, at: height)) }
            let place = { (doc: inout BezzleDocument) in
                doc.place(originals, movedBy: moved)
                for (id, turn) in turns { doc.update(id) { $0.transform3D = turn } }
            }
            store.edit("Move", place)
            if pushing.pushing, let box = store.selectionBounds {
                // How high it is held, or for several held apart, how far they all went.
                let all = Set(pushedTo.values)
                let said = all.count == 1 ? CanvasView.number(all.first ?? 0)
                    : (pushing.depth >= 0 ? "+" : "") + CanvasView.number(pushing.depth.rounded())
                store.measurement = ("Z \(said)", box)
            } else if pushing.pushed {
                store.measurement = nil
            }
            // Held over a shape a moment, it goes into it; a shape it went into and was dragged off
            // lets it go again. Either way it is placed once more, as it now lies.
            if curveTool.claims { maskTool.cancel() } else if maskTool.moving(Array(originals.keys), at: v) { store.edit("Move", place) }
            store.guides = guides

        case .resize(let handle, let originals, let absolute, let bounds, let rotation, let targets):
            // Pinned by its corners, as a mockup's screen is: a corner goes where it is pulled, a
            // side's two corners with it, and the rest stay where they are pinned.
            if originals.count == 1, let (id, original) = originals.first, repin(id, original, handle, to: p) { return }
            let carousel = originals.count == 1 ? originals.values.first.flatMap { $0.isCarousel ? $0 : nil } : nil
            // Turned in depth, the pull is measured on the layer as it would lie flat, where its handle is.
            var p = p, flat = false
            if originals.count == 1, let original = originals.values.first, inDepth(original) {
                guard let onFlat = flatOnCanvas(p, of: original) else { return }
                p = onFlat
                flat = true
            }
            let keep = shift || keepsAspect(originals, handle)
            // Along its turn, caught on what is around it (`BezzleDocument.pull`, shared).
            let (frame, guides) = BezzleDocument.pull(bounds, rotation: rotation, handle: handle, to: p, keep: keep, fromCenter: option,
                                                      carousel: carousel, flat: flat, snapping: snapping, targets: targets, threshold: threshold)
            var adapted: [UUID: (result: Adapt.Result, rearranged: Bool, origin: CGPoint)] = [:]
            store.edit("Resize") { doc in
                for (id, original) in originals {
                    guard let whole = absolute[id] else { continue }
                    let o = doc.parentOrigin(of: id)
                    var next = originals.count == 1 ? frame : Geometry.map(whole, from: bounds, to: frame)
                    if originals.count > 1 { next = Geometry.snapToPixels(next) }
                    doc.update(id) {
                        $0 = BezzleDocument.resized(original, to: next, whole: whole, origin: o, bounds: bounds, rotation: rotation,
                                                    handle: handle, single: originals.count == 1, fromCenter: option, carousel: carousel != nil, keep: keep)
                    }
                    if original.isArtboard, let session = adaptSessions[id] {
                        // Its design is laid out again for the size it is being given.
                        let (r, rearranged) = session.compose(next.size)
                        // A deck's posts stay as the last step made them, which the deck then makes
                        // again from its design; set back to where the drag began, they would read
                        // as changes to carry into it.
                        let last = store.doc.node(id)
                        doc.update(id) { b in b.children = Adapting.merged(r.board, into: last ?? b, from: session.source) }
                        adapted[id] = (r, rearranged, next.origin)
                    } else if original.isArtboard {
                        // An artboard's contents stay where they are on the canvas as its edges move.
                        doc.update(id) { $0 = BezzleDocument.keepingLayers($0, from: original, to: next) }
                    }
                }
            }
            store.guides = guides
            // What was understood shows on one artboard; arranged another way, any one's layers travel there.
            if adapted.count == 1, let one = adapted.first?.value {
                adaptTool.show(one.result.skeleton, at: one.origin, rearranged: one.rearranged)
            }
            let rearranged = adapted.filter { $0.value.rearranged }.map(\.key)
            if !rearranged.isEmpty { adaptTool.move(rearranged, withBoard: false) }
            // Text ends up the size its words take, not quite the box dragged out.
            var shown = frame
            if originals.count == 1, let (id, original) = originals.first, original.kind == .text, let f = store.doc.absoluteFrame(of: id) {
                shown = f
            }
            if let carousel, let slide = carousel.slideSize, slide.width > 0 {
                let count = Int((frame.width / slide.width).rounded())
                var said = count == 1 ? String(localized: "1 slide") : String(localized: "\(count) slides")
                // Pulled up or down, what the slides are now: a format, or their size.
                if handle.unit.y != 0.5 {
                    let now = CGSize(width: slide.width, height: frame.height)
                    said += " · " + (Carousel.format(of: now).map { String(localized: $0.title) } ?? "\(Self.number(now.width)) × \(Self.number(now.height))")
                }
                store.measurement = (said, frame)
            } else {
                store.measurement = ("\(Self.number(shown.width)) × \(Self.number(shown.height))", Geometry.bounds(of: shown, rotation: rotation))
            }

        case .rotate(let center, let startAngle, let originals, let absolute):
            var delta = Double((atan2(p.y - center.y, p.x - center.x) - startAngle) * 180 / .pi)
            // How far one layer is turned already, a group or a grid as it is seen turned.
            let base = BezzleDocument.turnBase(originals)
            if shift {
                delta = ((base + delta) / 15).rounded() * 15 - base
            }
            store.edit("Rotate") { $0.turn(originals, absolute: absolute, by: delta, about: center) }
            let shown = Self.normalized(base + delta)
            store.measurement = ("\(Self.number(shown))°", store.selectionBounds ?? .zero)

        case .lineEnd(let id, let fixed, let targets):
            var end = Geometry.lineEnd(from: fixed, to: p, constrain: shift)
            var guides: [Guide] = []
            if snapping && !shift {
                let (q, x, y) = targets.snap(point: end, threshold: threshold)
                end = q
                guides = targets.guides(for: CGRect(origin: q, size: .zero), x: x, y: y)
            }
            end = CGPoint(x: end.x.rounded(), y: end.y.rounded())
            let o = store.doc.parentOrigin(of: id)
            store.edit("Move Line End") { doc in doc.update(id) { $0.setLineEnds(fixed - o, end - o) } }
            store.guides = guides
            store.measurement = ("\(Self.number(hypot(end.x - fixed.x, end.y - fixed.y)))", Geometry.rect(from: fixed, to: end))

        case .corner(let id, let frame, let rotation, let corner, let original):
            // Every corner alike, or with Option, pressed before or during the drag, only this one.
            let (radii, radius) = BezzleDocument.cornerRadii(at: p, frame: frame, rotation: rotation, corner: corner, original: original, alone: option)
            store.edit("Change Corners") { doc in doc.update(id) { $0.radii = radii } }
            store.measurement = (String(localized: "Radius \(Self.number(radius))"), Geometry.bounds(of: frame, rotation: rotation))

        case .shadow(let id, let start, let original, let started):
            if !started {
                guard hypot(v.x - mouseDownView.x, v.y - mouseDownView.y) > 3 else { return }
                store.beginGesture()
                interaction = .shadow(id: id, start: start, original: original, started: true)
                NSCursor.closedHand.set()
            }
            var dx = p.x - start.x, dy = p.y - start.y
            if shift { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
            let x = (original.x + dx).rounded(), y = (original.y + dy).rounded()
            // The shadow whose card is open, or the first under the layer.
            let slot = store.node(id).flatMap(store.shadowSlot) ?? 0
            store.edit("Move Shadow") { doc in doc.update(id) { $0[shadow: slot].x = x; $0[shadow: slot].y = y } }
            if let frame = store.doc.absoluteFrame(of: id) {
                store.measurement = (String(localized: "Shadow \(Self.number(x)), \(Self.number(y))"), frame.offsetBy(dx: x, dy: y))
            }
            needsDisplay = true

        case .create(let tool, let start, let id, let board, let targets):
            var end = p
            var guides: [Guide] = []
            if snapping, shift, tool != .line {
                // A square stays square: it catches by whichever moving edge is nearest a target,
                // the other following, and its far corner is where it is drawn to.
                let square = Geometry.drawnRect(from: start, to: p, square: true, fromCenter: option)
                let (r, g) = targets.snap(square, keeping: 1, anchor: start, along: (true, true), threshold: threshold)
                end = option ? CGPoint(x: r.maxX, y: r.maxY)
                             : CGPoint(x: abs(r.minX - start.x) < 0.01 ? r.maxX : r.minX, y: abs(r.minY - start.y) < 0.01 ? r.maxY : r.minY)
                guides = g
            } else if snapping {
                let (q, x, y) = targets.snap(point: p, threshold: threshold)
                end = q
                guides = targets.guides(for: CGRect(origin: q, size: .zero), x: x, y: y)
            }
            end = CGPoint(x: end.x.rounded(), y: end.y.rounded())
            guard hypot(v.x - mouseDownView.x, v.y - mouseDownView.y) > 3 || id != nil else { return }
            let nodeID = id ?? createNode(tool, at: start, board: board)
            if id == nil { interaction = .create(tool: tool, start: start, id: nodeID, board: board, targets: targets) }
            let o = store.doc.parentOrigin(of: nodeID)
            if tool == .line {
                end = Geometry.lineEnd(from: start, to: end, constrain: shift)
                end = CGPoint(x: end.x.rounded(), y: end.y.rounded())
                store.edit("Draw") { doc in doc.update(nodeID) { $0.setLineEnds(start - o, end - o) } }
                store.measurement = ("\(Self.number(hypot(end.x - start.x, end.y - start.y)))", Geometry.rect(from: start, to: end))
            } else {
                let rect = Geometry.snapToPixels(Geometry.drawnRect(from: start, to: end, square: shift, fromCenter: option))
                // A text's box is as it is dragged out, until words are typed into it.
                store.edit("Draw") { doc in doc.update(nodeID) { $0.frame = rect.offsetBy(dx: -o.x, dy: -o.y) } }
                store.measurement = ("\(Self.number(rect.width)) × \(Self.number(rect.height))", rect)
            }
            store.guides = guides
        }
    }

    /// Text as wide as its words, or along a curve, grows and shrinks in proportion from its top
    /// and bottom.
    private func keepsAspect(_ originals: [UUID: Node], _ handle: Handle) -> Bool {
        BezzleDocument.keepsAspect(Array(originals.values), handle)
    }

    override func mouseUp(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if let c = noteCircling {
            noteCircling = nil
            if let r = store.noteCircle, max(r.width, r.height) * store.viewport.zoom >= 10 {
                store.beginNote(around: r)
            } else {
                store.noteCircle = nil
                store.beginNote(at: c.start, on: c.target)
            }
            return
        }
        if motionTool.dragging {
            motionTool.up(at: v, flags: event.modifierFlags)
            motionTool.cursor(at: v).set()
            return
        }
        if inspectTool.dragging {
            inspectTool.up(at: v)
            inspectTool.cursor(at: v).set()
            return
        }
        if flowTool.dragging {
            flowTool.up(at: v)
            flowTool.hover(v)
            (flowTool.cursor(at: v) ?? .arrow).set()
            return
        }
        if case .pan = interaction, store.prototyping {
            interaction = .none
            NSCursor.openHand.set()
            return
        }
        if guideTool.pressed {
            guideTool.up(at: v, flags: event.modifierFlags)
            updateCursor(v, flags: event.modifierFlags)
            return
        }
        layoutTool.up()
        pathTool.up(at: v, flags: event.modifierFlags)
        pictureTool.up()
        developTool.up(at: v)
        shapeBuilder.up(at: v)
        outlineTool.up()
        depthTool.up(at: v, adding: event.modifierFlags.contains(.shift))
        lookTool.up()
        curveTool.up()
        gridTool.up()
        deckTool.up(at: v)
        knifeTool.up(at: v)
        switch interaction {
        case .none:
            break
        case .pan:
            NSCursor.openHand.set()
        case .marquee:
            needsDisplay = true
        case .move(_, let originals, _, _, let started, let duplicate):
            if started {
                let ids = Array(originals.keys)
                // Into a mask, or out of one, it is that.
                let rode = curveTool.released()
                let masked = maskTool.released()
                store.edit("Move") { doc in store.settle(ids, in: &doc) }
                // Only pushed in depth, and not moved across, it is named for what it did.
                let deepOnly = pushing.pushed && ids.allSatisfy { store.doc.absoluteFrame(of: $0)?.origin == originals[$0]?.origin }
                store.endGesture(rode ?? masked ?? (duplicate ? "Duplicate" : deepOnly ? "Move in Depth" : "Move"))
            }
        case .resize:
            store.endGesture("Resize")
            endAdapting()
        case .rotate:
            store.endGesture("Rotate")
        case .lineEnd:
            store.endGesture("Move Line End")
        case .corner:
            store.endGesture("Change Corners")
        case .shadow(_, _, _, let started):
            if started {
                store.endGesture("Move Shadow")
            } else {
                // Only a click: whatever is under the shadow is picked, as anywhere else.
                let p = store.viewport.toCanvas(v)
                let id = titleHit(v) ?? pick(p)
                if event.modifierFlags.contains(.shift) {
                    if let id, !store.selection.contains(id) { store.selection.append(id) }
                } else {
                    store.selection = id.map { [$0] } ?? []
                }
            }
        case .create(let tool, let start, let id, let board, _):
            finishCreating(tool, start: start, id: id, board: board)
        }
        // A shape just drawn, moved or resized over a picture offers to mask it.
        switch interaction {
        case .create, .resize, .move(_, _, _, _, true, _): maskTool.invite()
        default: break
        }
        interaction = .none
        store.guides = []
        gapsCaught = []
        store.measurement = nil
        updateHover(v)
        updateCursor(v, flags: event.modifierFlags)
        updateOverlays(v)
        resumeTyping()
    }

    /// Typing goes on in the text whose handle was pressed while it was typed into, with what was
    /// picked out in it then.
    private func resumeTyping() {
        guard let (id, range) = typingResumes else { return }
        typingResumes = nil
        guard store.node(id)?.kind == .text, store.selection == [id] else { return }
        beginEditing(id, action: "Typing")
        guard let text = editor, let length = text.textStorage?.length else { return }
        let at = min(range.location, length)
        text.setSelectedRange(NSRange(location: at, length: min(range.length, length - at)))
    }

    /// A selected text of a set width fitted to its words, of its own height again, as a double
    /// click on its bottom handle does in XD. Whether there was such a text.
    private func fitTextToWords() -> Bool {
        guard store.selection.count == 1, let id = store.selection.first, let node = store.node(id), node.kind == .text,
              node.curve == nil, !node.locked, let sizing = node.style?.sizing, sizing != .autoWidth else { return false }
        store.update([id], "Auto Height") { $0.setSizing(.autoHeight) }
        return true
    }

    // MARK: - Drawing new layers

    private func createNode(_ tool: Tool, at p: CGPoint, board: UUID?) -> UUID {
        let kind: Node.Kind = switch tool {
        case .artboard: .artboard
        case .ellipse: .ellipse
        case .line: .line
        case .text: .text
        default: .rectangle
        }
        var node = Node(kind: kind, name: store.doc.nextName(for: kind), frame: CGRect(origin: p, size: .zero))
        if kind == .text {
            // New text looks as the text selected, as XD has it.
            if store.selection.count == 1, let like = store.node(store.selection[0]), like.kind == .text, var style = like.style {
                style.vertical = nil
                node.style = style
                node.fill = like.fill
            }
            node.style?.sizing = .autoHeight
        }
        store.add(node, onto: board)
        return node.id
    }

    private func finishCreating(_ tool: Tool, start: CGPoint, id: UUID?, board: UUID?) {
        // A click with the Text tool on a text types into it.
        let under = textUnderPress
        textUnderPress = nil
        if tool == .text, id == nil, let under, store.node(under) != nil {
            store.endGesture("Draw")
            store.selection = [under]
            beginEditing(under, action: "Typing")
            return
        }
        var nodeID = id
        if nodeID == nil {
            // A click without a drag makes something of a sensible size.
            nodeID = createNode(tool, at: start, board: board)
            let o = store.doc.parentOrigin(of: nodeID!)
            store.edit("Draw") { doc in
                doc.update(nodeID!) { n in
                    switch n.kind {
                    case .artboard:
                        let size = store.lastPreset ?? Preset.standard.size
                        n.frame = CGRect(origin: start, size: size)
                    case .line:
                        n.setLineEnds(start - o, CGPoint(x: start.x + 100, y: start.y) - o)
                    case .text:
                        n.style?.sizing = .autoWidth
                        n.frame = CGRect(origin: start - o, size: .zero)
                        n.refit()
                        // The click is where the first line's baseline begins, as XD has it: at
                        // its left for words set left, its middle for centred ones, its right
                        // for those set right.
                        var probe = n
                        probe.text = "X"
                        n.frame.origin.y -= TextLayout.firstBaseline(probe).rounded()
                        switch n.style?.align ?? .left {
                        case .left, .justify: break
                        case .center: n.frame.origin.x -= (n.frame.width / 2).rounded()
                        case .right: n.frame.origin.x -= n.frame.width
                        }
                    default:
                        n.frame = CGRect(origin: start - o, size: CGSize(width: 100, height: 100))
                    }
                }
            }
        }
        guard let nodeID, let node = store.node(nodeID) else { store.endGesture("Draw"); return }
        // Text that was dragged out keeps at least a usable width, and the height of a line.
        if node.kind == .text, node.style?.sizing == .autoHeight {
            if node.frame.width < 20 {
                store.edit("Draw") { doc in doc.update(nodeID) { $0.style?.sizing = .autoWidth; $0.refit() } }
            } else if case let fitted = TextLayout.fittedFrame(node), node.frame.height < fitted.height {
                store.edit("Draw") { doc in doc.update(nodeID) { $0.frame.size.height = fitted.height } }
            }
        }
        // The Text tool stays in hand, as in XD: a click elsewhere is more text. Esc puts it down.
        if tool != .text { store.tool = .select }
        if node.kind == .text {
            beginEditing(nodeID, action: "Add Text")
        } else {
            store.endGesture(node.kind.adding)
        }
    }

    private func snapped(_ p: CGPoint, targets: SnapTargets, event: NSEvent) -> CGPoint {
        let q = event.modifierFlags.contains(.command) ? p : targets.snap(point: p, threshold: 5 / store.viewport.zoom).0
        return CGPoint(x: q.x.rounded(), y: q.y.rounded())
    }

    // MARK: - Context menu

    override func rightMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if store.editingText != nil { endEditing() }
        let v = convert(event.locationInWindow, from: nil)
        if store.prototyping {
            let entries = store.animating ? motionTool.menuEntries(at: v) : store.inspecting ? inspectTool.menuEntries(at: v) : flowTool.menuEntries(at: v)
            if let entries { onContextMenu?(windowPoint(v), entries) }
            return
        }
        // On the rulers, what they show; on a guide, the guide's own.
        if rulers.part(at: v) != nil {
            onContextMenu?(windowPoint(v), Helpers.shared.entries(for: store))
            return
        }
        if store.tool == .select, let entries = guideTool.menuEntries(at: v) {
            onContextMenu?(windowPoint(v), entries)
            return
        }
        if let id = titleHit(v) ?? pick(store.viewport.toCanvas(v)), !store.selection.contains(id) {
            store.selection = [id]
        }
        let inWindow = event.locationInWindow
        let point = CGPoint(x: inWindow.x, y: (window?.contentView?.bounds.height ?? 0) - inWindow.y)
        onContextMenu?(point, CanvasMenus.entries(for: store))
    }

    // MARK: - Scrolling and zooming

    override func scrollWheel(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        let flags = event.modifierFlags
        if flags.contains(.command) || flags.contains(.option) || flags.contains(.control) {
            let step = event.hasPreciseScrollingDeltas ? 0.012 : 0.1
            let factor = exp(event.scrollingDeltaY * step)
            zoomedByHand = CACurrentMediaTime()
            store.viewport.zoom(to: store.viewport.zoom * factor, keeping: v)
        } else {
            var dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            if !event.hasPreciseScrollingDeltas { dx *= 8; dy *= 8 }
            // Shift scrolls sideways. A mouse wheel usually arrives already turned by the system;
            // a trackpad, or a mouse whose driver leaves it, still scrolls up and down.
            if flags.contains(.shift), dx == 0 { dx = dy; dy = 0 }
            // Both ways in one change: each change of the view is told to everything that follows it.
            var view = store.viewport
            view.origin.x -= dx / view.zoom
            view.origin.y -= dy / view.zoom
            store.viewport = view
            // The canvas moves on under the pointer: what it rested on is left.
            if hoverWaiting == nil { leaveHover() }
        }
        hoverOnceRested()
    }

    /// The look for what the pointer rests on, waiting for a scroll to come to rest.
    private var hoverWaiting: DispatchWorkItem?

    /// What the pointer rests on is looked for once a scroll has come to rest, not at each of its
    /// steps: a search through the design at every step, and each layer passing under the pointer
    /// outlined and lit in the layers list, whose rows were then worked out again while the canvas
    /// was to move.
    private func hoverOnceRested() {
        hoverWaiting?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.hoverWaiting = nil
            // Only while the pointer is still over the canvas, in this window and nothing over it:
            // gone meanwhile, it rests on nothing here.
            guard let window = self.window, window.isVisible,
                  NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber else { return }
            let at = window.mouseLocationOutsideOfEventStream
            guard window.contentView?.hitTest(at) === self else { return }
            self.updateHover(self.convert(at, from: nil))
        }
        hoverWaiting = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    /// Nothing is pointed at for now, in whichever way the design is seen.
    private func leaveHover() {
        if store.hovered != nil { store.hovered = nil }
        guard store.prototyping, case .none = interaction else { return }
        if store.animating { motionTool.hover(nil) } else if store.inspecting { inspectTool.hover(nil) } else { flowTool.hover(nil) }
    }

    // MARK: - Middle button

    /// Holding the wheel down and dragging moves the canvas, whatever tool is in hand.
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, case .none = interaction else { return super.otherMouseDown(with: event) }
        let v = convert(event.locationInWindow, from: nil)
        store.hovered = nil
        interaction = .pan(startOrigin: store.viewport.origin, startView: v)
        NSCursor.closedHand.set()
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard event.buttonNumber == 2, case .pan = interaction else { return super.otherMouseDragged(with: event) }
        drag(to: convert(event.locationInWindow, from: nil), flags: event.modifierFlags)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, case .pan = interaction else { return super.otherMouseUp(with: event) }
        interaction = .none
        let v = convert(event.locationInWindow, from: nil)
        updateCursor(v, flags: event.modifierFlags)
        updateHover(v)
    }

    override func magnify(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        // With the camera in hand, a pinch on its film brings it closer.
        if store.animating, motionTool.magnify(event, at: v) { return }
        zoomedByHand = CACurrentMediaTime()
        store.viewport.zoom(to: store.viewport.zoom * (1 + event.magnification), keeping: v)
    }

    /// When the view was last zoomed by hand, with a pinch or the wheel, which goes on for a
    /// while: the film's stage leaves its pictures stretched meanwhile (`FilmStageView.sync`).
    var zoomedByHand: CFTimeInterval = -.infinity

    /// Two fingers turned on the film roll the camera, while it is in hand.
    override func rotate(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if store.animating, motionTool.rotate(event, at: v) { return }
        super.rotate(with: event)
    }

    /// A double tap with two fingers: in to actual size where the pointer is, or back out to everything.
    override func smartMagnify(with event: NSEvent) {
        let v = convert(event.locationInWindow, from: nil)
        if abs(store.viewport.zoom - 1) < 0.01 { store.zoomToFit() } else { store.viewport.zoom(to: 1, keeping: v) }
    }

    // MARK: - Keyboard

    /// Escape with one of the tools' own drags in hand: it is put back. False with none.
    private func cancelToolDrag() -> Bool {
        if outlineTool.dragging { outlineTool.cancel(); return true }
        if depthTool.dragging { depthTool.cancel(); return true }
        if lookTool.dragging { lookTool.cancel(); return true }
        if curveTool.dragging {
            store.cancelGesture()
            curveTool.cancel()
            return true
        }
        if gridTool.dragging { gridTool.cancel(); return true }
        if guideTool.pressed { guideTool.cancel(); return true }
        if layoutTool.dragging { layoutTool.cancel(); return true }
        return false
    }

    /// Puts back what the pointer itself has in hand of the design: a move, a resize and the like.
    private func cancelInteraction() {
        store.cancelGesture()
        maskTool.cancel()
        endAdapting()
        curveTool.cancel()
        interaction = .none
    }

    /// Escape in a mode that has keys of its own, with a drag of the design still in hand: begun
    /// before the mode came on, it is put back as in the design. False with none in hand.
    private func cancelDesignDrag() -> Bool {
        if cancelToolDrag() { return true }
        if case .none = interaction { return false }
        cancelInteraction()
        return true
    }

    override func keyDown(with event: NSEvent) {
        // With the time ruler out: Escape puts it away, and the arrows step through the versions,
        // unless at now they have something selected to move.
        if store.versions.browsing {
            let stepping = store.versions.travel != nil || store.selection.isEmpty
            switch event.keyCode {
            case 53: store.versions.leave(); return
            case 123 where stepping: store.versions.step(-1); return
            case 124 where stepping: store.versions.step(1); return
            default: if store.versions.travel != nil { return }
            }
        }
        // Animated, a key is the film's before any tool of the design has it: Return plays, where
        // on a picture, a mask or a path it would open them. Only a drag of the design still in
        // hand, begun before the mode changed, is the design's to put back.
        if store.animating, event.keyCode == 53, cancelDesignDrag() { return }
        if store.animating, motionTool.key(event) { return }
        // A picture first: Return on one places it, where on a path it would open the points.
        if pictureTool.key(event) { return }
        // Return on a mask picks what it holds.
        if maskTool.key(event) { return }
        // Building and the knife before the pen: Return ends them, where on a path it would open its points.
        if shapeBuilder.key(event) || knifeTool.key(event) { return }
        if event.keyCode == 53, cancelToolDrag() { return }
        if event.keyCode == 53, developTool.cancel() { return }
        if event.keyCode == 53, deckTool.cancel() { return }
        if pathTool.key(event) { return }
        if store.inspecting, inspectTool.key(event) { return }
        if store.prototyping, prototypeKey(event) { return }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 49: // space
            if !spaceHeld {
                spaceHeld = true
                spaceTap = (event.timestamp, false)
                NSCursor.openHand.set()
            }
        case 51, 117: // delete
            store.deleteSelection()
        case 53: // escape
            if noteCircling != nil {
                noteCircling = nil
                store.noteCircle = nil
                return
            }
            // A note open in the margin, or being written, is put away first.
            if store.openThread != nil || store.draftNote != nil {
                store.openThread = nil
                store.draftNote = nil
                return
            }
            if case .none = interaction {
                if store.tool != .select { store.tool = .select }
                else if let first = store.selection.first, store.selection.count == 1, let parent = store.doc.parent(of: first) {
                    // Out one level: from a layer to its artboard.
                    store.selection = [parent.id]
                } else if store.selection.isEmpty, !store.looks.isEmpty {
                    // Nothing picked, nothing in hand: what is looked at from the side, from the front again.
                    store.lookFromTheFront()
                } else { store.selection = [] }
            } else {
                cancelInteraction()
            }
        case 36, 76: // return
            if store.selection.count == 1, let id = store.selection.first, store.node(id)?.kind == .text {
                beginEditing(id, action: "Typing")
            }
        case 116: store.turnPage(by: -1) // page up
        case 121: store.turnPage(by: 1) // page down
        case 123: store.nudge(dx: -step, dy: 0)
        case 124: store.nudge(dx: step, dy: 0)
        case 125: store.nudge(dx: 0, dy: step)
        case 126: store.nudge(dx: 0, dy: -step)
        default:
            if flags.subtracting([.shift, .capsLock, .numericPad, .function]).isEmpty,
               let chars = event.charactersIgnoringModifiers, let tool = Tool.forKey(chars) {
                store.tool = tool
                updateCursor(lastViewPoint, flags: flags)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 {
            spaceHeld = false
            // Pressed and let go without moving the view: the film plays, or stops.
            if store.animating, let tap = spaceTap, !tap.moved, event.timestamp - tap.at < 0.4 { store.toggleFilm() }
            spaceTap = nil
            updateCursor(lastViewPoint, flags: event.modifierFlags)
        } else {
            super.keyUp(with: event)
        }
    }

    override func flagsChanged(with event: NSEvent) {
        // Shift and Option change a drag in progress at once, without waiting for the pointer to move.
        if pathTool.dragging { pathTool.drag(to: lastViewPoint, flags: event.modifierFlags); return }
        if pictureTool.dragging { pictureTool.drag(to: lastViewPoint, flags: event.modifierFlags); return }
        if shapeBuilder.dragging || outlineTool.dragging || knifeTool.dragging || depthTool.dragging || gridTool.dragging
            || guideTool.dragging || layoutTool.dragging || lookTool.dragging {
            drag(to: lastViewPoint, flags: event.modifierFlags)
            updateCursor(lastViewPoint, flags: event.modifierFlags)
            return
        }
        // Control lifts what Animate moves at once, without waiting for the pointer to move.
        if store.animating, motionTool.dragging {
            drag(to: lastViewPoint, flags: event.modifierFlags)
            updateCursor(lastViewPoint, flags: event.modifierFlags)
            return
        }
        if case .none = interaction {
            if store.tool == .pen || store.editingPath != nil { pathTool.hover(lastViewPoint, flags: event.modifierFlags) }
            hoverShapeTools(lastViewPoint, flags: event.modifierFlags)
            updateCursor(lastViewPoint, flags: event.modifierFlags)
            return
        }
        drag(to: lastViewPoint, flags: event.modifierFlags)
    }

    // MARK: - Dropping

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        store.hovered = nil
        if sender.draggingPasteboard.types?.contains(ResourceDrag.type) == true, let resource = ResourceDrag.current {
            // The canvas shows the real thing where it will land, so the small picture goes.
            resourceDropTool.begin(resource)
            setDragPicture(sender, nil)
            return draggingUpdated(sender)
        }
        dropTool.begin(Dropped(sender.draggingPasteboard))
        return draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let p = store.viewport.toCanvas(convert(sender.draggingLocation, from: nil))
        if resourceDropTool.resource != nil { return resourceDropTool.update(at: p, on: dropTarget(at: p)) ? .copy : [] }
        return dropTool.update(at: p, on: dropTarget(at: p)) ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if resourceDropTool.resource != nil, let sender { setDragPicture(sender, ResourceDrag.picture) }
        resourceDropTool.end()
        dropTool.end()
    }

    /// Changes the picture the pointer carries: none while the canvas shows the real thing.
    private func setDragPicture(_ sender: NSDraggingInfo, _ picture: NSImage?) {
        sender.enumerateDraggingItems(options: [], for: self, classes: [NSPasteboardItem.self], searchOptions: [:]) { item, _, _ in
            if let picture {
                let at = self.convert(sender.draggingLocation, from: nil)
                item.setDraggingFrame(CGRect(x: at.x - picture.size.width / 2, y: at.y - picture.size.height / 2,
                                             width: picture.size.width, height: picture.size.height), contents: picture)
            } else {
                item.imageComponentsProvider = { [] }
            }
        }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let p = store.viewport.toCanvas(convert(sender.draggingLocation, from: nil))
        if let resource = resourceDropTool.resource {
            let plan = resourceDropTool.plan ?? store.placing(resource, at: p, on: dropTarget(at: p))
            resourceDropTool.end()
            window?.makeFirstResponder(self)
            guard let plan else { return false }
            return store.place(plan, resource: resource) != nil
        }
        let dropped = dropTool.dropped ?? Dropped(sender.draggingPasteboard)
        dropTool.end()
        window?.makeFirstResponder(self)
        return store.drop(dropped, at: p, on: dropTarget(at: p))
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        resourceDropTool.end()
        dropTool.end()
    }

    /// The deepest layer under a point, through every group: what a dropped picture or list fills.
    private func dropTarget(at p: CGPoint) -> UUID? { picking.dropTarget(p) }

    // MARK: - Edit menu

    // Animated, with keys picked in the timeline, Copy and Cut are of those keys, and Paste puts
    // down keys copied (`AnimateClipboard.swift`).
    @objc func copy(_ sender: Any?) { if !store.copyFilmKeys() { store.copySelection() } }
    @objc func cut(_ sender: Any?) {
        if store.animating { store.cutFilmKeys() } else if !store.inspecting { store.cutSelection() }
    }
    @objc func paste(_ sender: Any?) {
        if store.animating { store.pasteFilmKeys() } else if !store.inspecting { store.paste() }
    }
    @objc func delete(_ sender: Any?) {
        // Seen as a prototype, what is taken away is where the picked layers go, never the layers.
        if store.inspecting { return }
        // Animated, it is keys.
        if store.animating { store.removeFilmKeys(); return }
        if store.prototyping { store.unlinkFlow(store.linkSources); return }
        if store.editingPath != nil { store.deleteSelectedPoints() } else { store.deleteSelection() }
    }

    /// A key while the design is seen as a prototype: Delete cuts the picked layers' threads,
    /// Return plays from the picked screen, Escape lets go; the space bar still moves the view, and
    /// the drawing tools' keys do nothing here.
    private func prototypeKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: return false
        case 51, 117:
            store.unlinkFlow(store.linkSources)
        case 53:
            if !flowTool.cancel() {
                if store.writingNote != nil { store.writingNote = nil } else { store.selection = [] }
            }
        case 36, 76:
            store.play()
        case 123, 124, 125, 126:
            break
        default:
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .numericPad, .function])
            // The drawing tools' letters do nothing here; anything else goes on as it would.
            if flags.isEmpty, let chars = event.charactersIgnoringModifiers, Tool.forKey(chars) != nil { return true }
            return false
        }
        return true
    }
    @objc override func selectAll(_ sender: Any?) {
        if store.editingPath != nil { store.selectAllPoints() } else { store.selectAll() }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(cut(_:)): return store.animating ? store.canCopyFilmKeys && !store.isReadOnly : !store.selection.isEmpty && !store.inspecting
        case #selector(delete(_:)): return store.animating ? store.hasKeysToRemove : !store.selection.isEmpty && !store.inspecting
        case #selector(copy(_:)): return store.canCopyFilmKeys || !store.selection.isEmpty
        case #selector(paste(_:)): return store.animating ? store.canPasteFilmKeys : store.canPaste && !store.inspecting
        case #selector(selectAll(_:)): return !store.doc.nodes.isEmpty
        default: return true
        }
    }

    // MARK: - Typing into text layers

    func beginEditing(_ id: UUID, action: LocalizedStringResource) {
        guard !store.isReadOnly, let node = store.node(id), node.kind == .text, editor == nil else { return }
        store.beginGesture()
        editingAction = action
        store.editingText = id
        store.selection = [id]

        let storage = NSTextStorage()
        let manager = TextLayout.Manager()
        manager.usesFontLeading = true
        storage.addLayoutManager(manager)
        let container = NSTextContainer(size: CGSize(width: 100_000, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)

        let text = TypingView(frame: .zero, textContainer: container)
        text.delegate = self
        // Rich, for words in bold or another colour, but what is pasted comes in as words alone,
        // looking as the letters around it.
        text.isRichText = true
        text.usesFontPanel = false
        text.usesRuler = false
        text.importsGraphics = false
        text.drawsBackground = false
        text.allowsUndo = true
        text.textContainerInset = .zero
        text.isVerticallyResizable = false
        text.isHorizontallyResizable = false
        text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isAutomaticTextReplacementEnabled = false
        text.isAutomaticSpellingCorrectionEnabled = false
        // Misspelt words are underlined as they are typed, and a right-click offers the spellings.
        let defaults = UserDefaults.standard
        text.isContinuousSpellCheckingEnabled = defaults.object(forKey: Self.checksSpelling) as? Bool ?? true
        text.isGrammarCheckingEnabled = defaults.bool(forKey: Self.checksGrammar)
        text.insertionPointColor = CanvasInk.pencil
        text.selectedTextAttributes = [.backgroundColor: CanvasInk.pencil.withAlphaComponent(0.22)]
        text.focusRingType = .none
        editorShown = nil
        editorPainted = nil
        show(node, in: text)

        let host = FlippedView()
        host.addSubview(text)
        addSubview(host)
        editorHost = host
        editor = text
        editorUndo = UndoManager()
        store.restyleTyped = { [weak self] action, change in self?.restyleTyped(action, change) }
        syncEditor()
        window?.makeFirstResponder(text)
        text.selectAll(nil)
    }

    /// Whether misspelt words are underlined while typing, and grammar checked, as last set.
    private static let checksSpelling = "BezzleChecksSpelling", checksGrammar = "BezzleChecksGrammar"

    /// What the text being typed into is like, as the editor shows it.
    private struct Shown: Equatable {
        var runs: [TextSpan]
        var style: TextStyle
        var color: RGBA
    }

    private func shown(_ node: Node) -> Shown {
        Shown(runs: TextSpan.tidy(node.runs), style: node.style ?? TextStyle(), color: node.letterColor ?? .black)
    }

    /// What the letters being typed are painted with, when it is a gradient or a picture, and
    /// where: the layer's size and how far down its lines begin.
    private struct Painted: Equatable {
        var fill: Fill
        var size: CGSize
        var down: CGFloat
    }

    private var editorPainted: Painted?

    /// Puts a text's words and how each letter looks into the editor, keeping what is picked out
    /// and, where the words are the same, the letters themselves.
    private func show(_ node: Node, in text: NSTextView) {
        guard let storage = text.textStorage else { return }
        let now = shown(node)
        let built = TextLayout.attributed(now.runs, style: now.style, color: now.color, cased: false)
        let selected = text.selectedRanges
        storage.beginEditing()
        if storage.string == built.string {
            built.enumerateAttributes(in: NSRange(location: 0, length: built.length)) { attrs, range, _ in
                storage.setAttributes(attrs, range: range)
            }
        } else {
            storage.setAttributedString(built)
        }
        storage.endEditing()
        let length = storage.length
        text.selectedRanges = selected.map { r in
            let r = r.rangeValue
            let at = min(r.location, length)
            return NSValue(range: NSRange(location: at, length: min(r.length, length - at)))
        }
        let plain = TextLayout.attributes(now.style, color: now.color)
        text.defaultParagraphStyle = plain[.paragraphStyle] as? NSParagraphStyle
        let caret = text.selectedRange().location
        text.typingAttributes = length > 0 ? storage.attributes(at: min(max(caret - 1, 0), length - 1), effectiveRange: nil) : plain
        editorShown = now
        markTrailingItem(in: text)
    }

    /// Changes the letters picked out in the editor, or with only the caret what is typed next, as
    /// a change the editor's Undo takes back. A list goes to the paragraphs the selection is in.
    private func restyleTyped(_ action: LocalizedStringResource, _ change: (inout Letters) -> Void) {
        guard let text = editor, let storage = text.textStorage, let id = store.editingText, let node = store.node(id) else { return }
        let style = node.style ?? TextStyle(), color = node.letterColor ?? .black
        var range = text.selectedRange()
        let ns = storage.string as NSString
        // What the change does to a list, tried on the letters typed next.
        let typed = (text.typingAttributes[.bezzleLook] as? LookBox)?.look ?? .plain
        var probe = typed.resolved(over: style, color: color)
        change(&probe)
        if probe.list != typed.list, range.length == 0 { range = ns.paragraphRange(for: range) }
        guard range.length > 0 else {
            var attrs = TextLayout.attributes(style, look: TextLook(probe, over: style, color: color), color: color)
            if probe.list != nil { attrs[.paragraphStyle] = text.typingAttributes[.paragraphStyle] ?? attrs[.paragraphStyle] }
            text.typingAttributes = attrs
            markTrailingItem(in: text)
            return
        }
        var restyled = node
        restyled.setRuns(TextSpan.runs(of: storage))
        restyled.restyleLetters(in: range, change)
        let built = TextLayout.attributed(TextSpan.tidy(restyled.runs), style: style, color: color, cased: false)
        guard built.string == storage.string else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let picked = text.selectedRanges
        guard text.shouldChangeText(in: whole, replacementString: nil) else { return }
        storage.beginEditing()
        built.enumerateAttributes(in: whole) { attrs, r, _ in storage.setAttributes(attrs, range: r) }
        storage.endEditing()
        editorUndo.setActionName(String(localized: action))
        text.didChangeText()
        text.selectedRanges = picked
    }

    /// Keeps the text view over its layer as the canvas moves, zooms and the layer changes.
    func syncEditor() {
        guard let host = editorHost, let text = editor else { return }
        guard let id = store.editingText, let held = store.node(id), let whole = store.doc.absoluteFrame(of: id) else {
            endEditing()
            return
        }
        // Words along a curve are typed straight, where the curve runs through the point they are placed from.
        let (node, frame) = CurvedText.straight(held, frame: whole)
        let zoom = store.viewport.zoom
        let width = max(frame.width, 1) + 6
        let r = store.viewport.toView(frame)
        // Turned while its bounds are one to one with its frame, and only then zoomed: turning it
        // with zoomed bounds puts its middle off by half the zoom's difference, and the text with it.
        let box = CGRect(x: r.minX, y: r.minY, width: width * zoom, height: max(r.height, 4))
        host.frameRotation = 0
        host.bounds = CGRect(origin: .zero, size: box.size)
        host.frame = box
        host.frameCenterRotation = -node.rotation
        // Grown since it was last placed, as with each letter typed, it is turned about the middle
        // it had before and lands off to one side, to come back only when next placed: the words
        // would shake as they are typed. Its middle goes back where it belongs.
        if let around = host.superview {
            let middle = host.convert(CGPoint(x: host.bounds.midX, y: host.bounds.midY), to: around)
            host.setFrameOrigin(CGPoint(x: host.frame.minX + box.midX - middle.x, y: host.frame.minY + box.midY - middle.y))
        }
        host.setBoundsSize(CGSize(width: width, height: max(frame.height, 4 / zoom)))
        let sizing = node.style?.sizing ?? .autoWidth
        let align = node.style?.align ?? .left
        let loose = sizing == .autoWidth && (align == .left || align == .justify)
        text.textContainer?.size = CGSize(width: loose ? 100_000 : max(frame.width, 1) + (sizing == .autoWidth ? 0.5 : 0),
                                          height: .greatestFiniteMagnitude)
        // Lines set in the middle or at the bottom of a box of fixed size are there as they are typed.
        let down = TextLayout.offset(Node.with(node, frame: frame))
        let tall = TextLayout.layout(Node.with(node, frame: frame)).usedSize.height
        text.frame = CGRect(x: 0, y: down, width: loose ? width : max(frame.width, 1), height: max(frame.height - down, tall, 1))
        // A box of fixed size too small for its words hides the rest as they are typed, as on the canvas.
        let hides = Node.with(node, frame: frame).overflows
        if host.clipsToBounds != hides { host.clipsToBounds = hides }
        if editorShown != shown(node), !text.hasMarkedText() { show(node, in: text) }
        // Letters painted with a gradient or a picture show it as they are typed.
        let painted = node.fill.on && node.fill.paints ? Painted(fill: node.fill, size: frame.size, down: down) : nil
        if painted != editorPainted, let manager = text.layoutManager as? TextLayout.Manager {
            editorPainted = painted
            manager.painting = Renderer.letterPaint(of: Node.with(node, frame: frame), options: Renderer.Options(assets: store.assets), down: down)
            text.needsDisplay = true
        }
        // Spelling as last chosen in the Edit menu.
        let defaults = UserDefaults.standard
        let spelling = defaults.object(forKey: Self.checksSpelling) as? Bool ?? true, grammar = defaults.bool(forKey: Self.checksGrammar)
        if text.isContinuousSpellCheckingEnabled != spelling { text.isContinuousSpellCheckingEnabled = spelling }
        if text.isGrammarCheckingEnabled != grammar { text.isGrammarCheckingEnabled = grammar }
    }

    func textDidChange(_ notification: Notification) {
        guard let id = store.editingText, let text = editor, let storage = text.textStorage else { return }
        let runs = TextSpan.runs(of: storage)
        store.edit(editingAction) { doc in
            doc.update(id) { n in
                n.setRuns(runs)
                n.refit()
            }
        }
        // Set again from the layer, so that new paragraphs of a list have their markers.
        if !text.hasMarkedText() { editorShown = nil }
        syncEditor()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard let text = editor else { return }
        let range = text.selectedRange()
        if store.typingSelection != range { store.typingSelection = range }
        markTrailingItem(in: text)
    }

    /// The empty line at the end of a list being typed has no letters yet, but is an item all
    /// the same: its marker shows, as the next number or a bullet.
    private func markTrailingItem(in text: NSTextView) {
        guard let manager = text.layoutManager as? TextLayout.Manager, let storage = text.textStorage else { return }
        let look = (text.typingAttributes[.bezzleLook] as? LookBox)?.look
        let atEnd = storage.length == 0 || storage.string.last.map(TextSpan.endsParagraph) == true
        var trailing: TextLayout.Manager.Trailing?
        if atEnd, let list = look?.list, let font = text.typingAttributes[.font] as? NSFont {
            var number = 1
            if list == .number, storage.length > 0 {
                // One after the last item before it, when that is numbered.
                let ns = storage.string as NSString
                let last = ns.paragraphRange(for: NSRange(location: storage.length - 1, length: 0))
                if let marker = storage.attribute(.bezzleMarker, at: last.location, effectiveRange: nil) as? ListMarker,
                   let n = Int(marker.text.dropLast()) { number = n + 1 }
            }
            let paragraph = text.typingAttributes[.paragraphStyle] as? NSParagraphStyle
            let gap = (font.pointSize * 0.5).rounded()
            trailing = .init(text: list == .number ? "\(number)." : "•", gap: gap, font: font,
                             color: text.typingAttributes[.foregroundColor] as? NSColor ?? .black,
                             indent: max(paragraph?.headIndent ?? 0, ceil(font.pointSize * 0.6 + gap)),
                             lift: text.typingAttributes[.baselineOffset] as? CGFloat ?? 0)
        }
        if manager.trailing != trailing {
            manager.trailing = trailing
            text.needsDisplay = true
        }
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(cancelOperation(_:)) {
            endEditing()
            window?.makeFirstResponder(self)
            return true
        }
        // Return on an empty item of a list, or Delete at the start of one, ends the list there.
        if selector == #selector(insertNewline(_:)) || selector == #selector(deleteBackward(_:)), let storage = textView.textStorage {
            let caret = textView.selectedRange()
            let ns = storage.string as NSString
            let paragraph = ns.paragraphRange(for: NSRange(location: caret.location, length: 0))
            let words = ns.substring(with: paragraph).trimmingCharacters(in: .newlines)
            // The empty line at the end has no letters: what is typed there says.
            let look = paragraph.length > 0 && paragraph.location < storage.length
                ? (storage.attribute(.bezzleLook, at: paragraph.location, effectiveRange: nil) as? LookBox)?.look
                : (textView.typingAttributes[.bezzleLook] as? LookBox)?.look
            let ends = selector == #selector(insertNewline(_:)) ? words.isEmpty : caret.location == paragraph.location
            if caret.length == 0, look?.list != nil, ends {
                restyleTyped("End List") { $0.list = nil }
                return true
            }
        }
        // In a deck, Tab goes on to the same words in the next post, as in a table, and Shift-Tab
        // back; past the first or the last, nothing.
        if selector == #selector(insertTab(_:)) || selector == #selector(insertBacktab(_:)),
           let id = store.editingText, let (deck, post) = store.doc.post(of: id), let post {
            typeOn(in: deck.id, from: id, post: post, forward: selector == #selector(insertTab(_:)))
            return true
        }
        return false
    }

    /// Ends typing into a text in one post of a deck and starts typing into the same text in the
    /// next post, or the one before. Past the last it makes no new post: a key pressed for
    /// something else must never add one unasked.
    private func typeOn(in deckID: UUID, from id: UUID, post: Int, forward: Bool) {
        guard let deck = store.node(deckID) else { return }
        let posts = deck.posts
        guard let i = posts.firstIndex(of: post) else { return }
        let j = i + (forward ? 1 : -1)
        guard j >= 0, j < posts.count else { return }
        endEditing()
        store.turn(deckID, to: posts[j])
        guard let now = store.node(deckID).flatMap({ store.front(of: $0) }) else { return }
        let next = id.mixed(Deck.key(from: post, to: now))
        guard store.node(next) != nil else { return }
        beginEditing(next, action: "Typing")
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndo }

    func textDidEndEditing(_ notification: Notification) {
        // Leaving the text for a field in the inspector also ends typing.
        DispatchQueue.main.async { [weak self] in
            guard let self, let editor = self.editor, self.window?.firstResponder !== editor else { return }
            self.endEditing()
        }
    }

    func endEditing() {
        guard let id = store.editingText else { return }
        store.restyleTyped = nil
        store.typingSelection = NSRange(location: 0, length: 0)
        editor?.delegate = nil
        editorHost?.removeFromSuperview()
        editorHost = nil
        editor = nil
        store.editingText = nil
        // A text left empty is not kept, but in a grid's cell or a deck's post it is that cell's,
        // or that post's, words.
        if let node = store.node(id), (node.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.grid(holding: id) == nil,
           store.doc.post(of: id)?.post == nil {
            store.edit(editingAction) { doc in _ = doc.detach(id) }
            store.selection = []
        }
        store.endGesture(editingAction)
        needsDisplay = true
    }

    // MARK: - Helpers

    /// A measurement to a tenth, as the user's language writes numbers ("12.5", "12,5"), never grouped.
    static func number(_ v: CGFloat) -> String {
        let r = (v * 10).rounded() / 10 + 0
        return Double(r).formatted(.number.precision(.fractionLength(0...1)).grouping(.never))
    }

    nonisolated static func normalized(_ degrees: Double) -> Double { Geometry.normalized(degrees) }
}

final class FlippedView: NSView {
    nonisolated override var isFlipped: Bool { true }
}

/// The text view words are typed into on the canvas. What is pasted into it comes in as words
/// alone, taking the look of the letters it goes among, as words typed do.
final class TypingView: NSTextView {
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] { [.string] }

    // Spelling checked or not here is what the Edit menu says, kept for all text.
    override func toggleContinuousSpellChecking(_ sender: Any?) {
        super.toggleContinuousSpellChecking(sender)
        UserDefaults.standard.set(isContinuousSpellCheckingEnabled, forKey: "BezzleChecksSpelling")
    }

    override func toggleGrammarChecking(_ sender: Any?) {
        super.toggleGrammarChecking(sender)
        UserDefaults.standard.set(isGrammarCheckingEnabled, forKey: "BezzleChecksGrammar")
    }
}

/// Hears the pointer come into and leave the strip of the canvas under the title bar, in a window
/// at the front or behind. Its own owner, so the canvas's hover is not reset at the strip's edge.
private final class TitleBarWatch: NSResponder {
    weak var canvas: CanvasView?

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { canvas?.holdWindow() }
    override func mouseExited(with event: NSEvent) { canvas?.holdWindow() }
}
