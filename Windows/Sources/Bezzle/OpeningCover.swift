import Foundation
import WinUI
import WinAppSDK
import UWP
import WindowsFoundation
import WinSDK
import BezzleCore

/// The paper over a design's tab while the design opens, Bezzle's mark pressed into it, as the
/// Mac's (Views/OpeningCoverView.swift): the icon's three sheets struck into the paper in turn,
/// the deepest inked, the name set letter by letter, a slow breath after, and when the design is
/// there the mark pressed flat and the paper cleared. Its pictures are the shared drawing
/// (`OpeningPlan.picture`) and its letters the serif's, but every move is the compositor's
/// (`OpeningPlan`), handed over at once as it shows, so it goes on while the window's thread is
/// busy opening the design. The window lays it over the tab's page, under the bar (BezzleApp).
@MainActor
final class OpeningCover {
    /// The paper, which takes clicks while it covers the design.
    let root = Grid()
    let plan: OpeningPlan.Cover
    /// Whether it is lifting, the design ready.
    private(set) var lifting = false
    private let calm: Bool
    private let stage = Canvas()
    private let mark = Canvas()
    private var sheets: [Canvas] = []
    private var parts: [(sheet: Int, part: OpeningPlan.Part, image: Image)] = []
    private let ink = Canvas()
    private let word = StackPanel()
    private var letters: [TextBlock] = []
    private var pressed = false
    private var shown = false
    private var waiting: CheckedContinuation<Void, Never>?
    private var ticking: EventCleanup?

    init(plan: OpeningPlan.Cover) {
        self.plan = plan
        calm = Self.calm
        root.background = Theme.brush(Theme.paper)
        root.requestedTheme = Theme.dark ? .dark : .light
        root.children.append(stage)
        stage.isHitTestVisible = false
        let side = OpeningPlan.markSize
        mark.width = side
        mark.height = side
        stage.children.append(mark)
        for sheet in 0..<OpeningPlan.sheets {
            let holder = Canvas()
            holder.width = side
            holder.height = side
            for part in OpeningPlan.parts(of: sheet) {
                let image = Image()
                image.width = side
                image.height = side
                image.stretch = .fill
                parts.append((sheet, part, image))
                if part == .ink || part == .inkWalls { ink.children.append(image) } else { holder.children.append(image) }
            }
            if ink.children.size > 0, sheets.count == OpeningPlan.sheets - 1 {
                ink.width = side
                ink.height = side
                holder.children.append(ink)
            }
            sheets.append(holder)
            mark.children.append(holder)
        }
        // The name, in the serif the home tab and the website set it in, a block for each letter.
        word.orientation = .horizontal
        for ch in OpeningPlan.word {
            let letter = Theme.text(String(ch), size: OpeningPlan.wordSize, weight: 600, serif: true)
            letter.textTrimming = .none
            letter.margin = Theme.inset(0, 0, OpeningPlan.wordTracking * OpeningPlan.wordSize, 0)
            letters.append(letter)
            word.children.append(letter)
        }
        stage.children.append(word)
        root.sizeChanged.addHandler { [weak self] _, _ in MainActor.assumeIsolated { self?.place() } }
        root.loaded.addHandler { [weak self] _, _ in MainActor.assumeIsolated { self?.press() } }
        // Never shown, as in a window out of sight, the design opens all the same.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            MainActor.assumeIsolated {
                self?.press()
                self?.didShow()
            }
        }
    }

    /// Whether Windows' animation effects are off (Settings › Accessibility › Visual effects):
    /// then the mark only fades in and out, as Reduce Motion has it on the Mac.
    /// BEZZLE_REDUCE_MOTION=1 asks for that in a test copy.
    static var calm: Bool {
        if ProcessInfo.processInfo.environment["BEZZLE_REDUCE_MOTION"] != nil { return true }
        var on: WindowsBool = true
        guard SystemParametersInfoW(UINT(SPI_GETCLIENTAREAANIMATION), 0, &on, 0) else { return false }
        return !on.boolValue
    }

    // MARK: Trying it

    /// For trying it: `BEZZLE_OPEN_AT=seconds:path[;seconds:path…]` opens these designs that long
    /// after Bezzle starts, as a click on home does; `BEZZLE_OPEN_SLOW=seconds` opens each that much
    /// later, the cover waiting; `BEZZLE_NO_COVER=1` opens them as before the cover, to compare;
    /// with `BEZZLE_TRACE`, every time the window's thread was away for more than 40 ms in the
    /// eight seconds after a design was asked for is traced.
    static func openAsAsked() {
        for spec in (ProcessInfo.processInfo.environment["BEZZLE_OPEN_AT"] ?? "").split(separator: ";") {
            guard let colon = spec.firstIndex(of: ":"), let s = Double(spec[..<colon]) else { continue }
            let path = String(spec[spec.index(after: colon)...])
            DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { _ = Tabs.shared.open(URL(fileURLWithPath: path)) } }
        }
    }

    static let hold = ProcessInfo.processInfo.environment["BEZZLE_OPEN_SLOW"].flatMap(Double.init) ?? 0
    static let off = ProcessInfo.processInfo.environment["BEZZLE_NO_COVER"] != nil

    private static var watching: EventCleanup?
    private static var watchedFrom = 0.0, lastBeat = 0.0

    /// Traces the window's thread away for more than 40 ms, for eight seconds from now.
    static func watchThread() {
        guard Trace.on else { return }
        watching?.dispose()
        watchedFrom = WindowsCore.now
        lastBeat = watchedFrom
        watching = CompositionTarget.rendering.addHandler { _, _ in
            MainActor.assumeIsolated {
                let now = WindowsCore.now
                if now - lastBeat > 0.04 {
                    Trace.say("window's thread away at \(Int((lastBeat - watchedFrom) * 1000)) ms for \(Int((now - lastBeat) * 1000)) ms")
                }
                lastBeat = now
                if now - watchedFrom > 8 {
                    watching?.dispose()
                    watching = nil
                }
            }
        }
    }

    /// Waits for a frame before installing a design, even when its preparation is quick.
    func waitUntilShown() async {
        if shown { return }
        await withCheckedContinuation { waiting = $0 }
    }

    private func didShow() {
        ticking?.dispose()
        ticking = nil
        shown = true
        waiting?.resume()
        waiting = nil
    }

    // MARK: Putting it together

    /// The mark and its name together in the middle of the room, a little above it.
    private func place() {
        let width = root.actualWidth, height = root.actualHeight
        guard width > 0, height > 0 else { return }
        let cap = OpeningPlan.wordSize * 0.7
        let at = OpeningPlan.place(width: width, height: height, capHeight: cap)
        let margin = (OpeningPlan.markSize - OpeningPlan.side) / 2
        try? Canvas.setLeft(mark, at.markLeft - margin)
        try? Canvas.setTop(mark, at.markTop - margin)
        // The letters' cap height's top at its place, their baseline under it.
        let baseline = letters.first.map { Double($0.baselineOffset) } ?? OpeningPlan.wordSize
        try? Canvas.setLeft(word, (width / 2 - word.actualWidth / 2).rounded())
        try? Canvas.setTop(word, (at.wordTop + cap - baseline).rounded())
    }

    /// The pictures drawn at the screen's pixels, and every move handed to the compositor at once,
    /// from when the mark is pressed.
    private func press() {
        guard !pressed else { return }
        Trace.time("opening cover shown")
        let scale = max(Double(root.xamlRoot?.rasterizationScale ?? 1), 1)
        for (sheet, part, image) in parts {
            var bitmap: WriteableBitmap?
            let drawn = OpeningPlan.picture(part, of: sheet, dark: Theme.dark, scale: scale) { width, height in
                bitmap = WriteableBitmap(Int32(width), Int32(height))
                return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
            }
            if drawn != nil, let bitmap {
                try? bitmap.invalidate()
                image.source = bitmap
            }
        }
        try? root.updateLayout()
        place()
        let now = WindowsCore.now
        for move in OpeningPlan.pressing(calm: calm) { start(move, after: max(0, plan.marks - now)) }
        pressed = true
        Trace.time("opening cover on its way, its pictures drawn and its moves handed over")
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.didShow() } }
        }
    }

    /// The design is ready: the mark pressed flat and the paper cleared from `at` on (the app's
    /// clock), or, when the mark never came, the paper simply cleared.
    func lift(at: Double, marked: Bool) {
        guard !lifting else { return }
        lifting = true
        root.isHitTestVisible = false
        if !marked {
            mark.visibility = .collapsed
            word.visibility = .collapsed
        }
        let delay = max(0, at - WindowsCore.now)
        for move in OpeningPlan.lifting(marked: marked, calm: calm) { start(move, after: delay) }
    }

    // MARK: Moves

    private func element(_ target: OpeningPlan.Target) -> UIElement? {
        switch target {
        case .paper: root
        case .mark: mark
        case .word: word
        case .sheet(let i): sheets.indices.contains(i) ? sheets[i] : nil
        case .part(let i, let part): parts.first { $0.sheet == i && $0.part == part }?.image
        case .ink: ink
        case .letter(let i): letters.indices.contains(i) ? letters[i] : nil
        }
    }

    /// Where an element is struck about, in its own points: a sheet about its middle, the mark
    /// about its outer sheet's, a letter about its own.
    private func middle(of target: OpeningPlan.Target, _ element: UIElement) -> Vector3 {
        switch target {
        case .sheet(let i):
            let m = OpeningPlan.middle(of: i)
            return Vector3(x: Float(m.x), y: Float(m.y), z: 0)
        case .letter:
            let size = (element as? FrameworkElement).map { ($0.actualWidth, $0.actualHeight) } ?? (0, 0)
            return Vector3(x: Float(size.0 / 2), y: Float(size.1 / 2), z: 0)
        default:
            let m = OpeningPlan.markSize / 2
            return Vector3(x: Float(m), y: Float(m), z: 0)
        }
    }

    /// Hands one move to the compositor, beginning `after` seconds from now, held at its start
    /// until then.
    private func start(_ move: OpeningPlan.Move, after: Double) {
        guard let element = element(move.target), let visual = try? ElementCompositionPreview.getElementVisual(element),
              let compositor = visual.compositor else { return }
        let ease: WinAppSDK.CompositionEasingFunction? = switch move.ease {
        case .linear: try? compositor.createLinearEasingFunction()
        case .easeIn: try? compositor.createCubicBezierEasingFunction(Vector2(x: 0.42, y: 0), Vector2(x: 1, y: 1))
        case .easeOut: try? compositor.createCubicBezierEasingFunction(Vector2(x: 0, y: 0), Vector2(x: 0.58, y: 1))
        case .easeInOut: try? compositor.createCubicBezierEasingFunction(Vector2(x: 0.42, y: 0), Vector2(x: 0.58, y: 1))
        }
        // BEZZLE_SLOW=8 plays it eight times slower, to look at it frame by frame.
        func timed(_ a: WinAppSDK.KeyFrameAnimation) {
            a.duration = TimeSpan(duration: Int64(max(move.duration, 0.001) * Motion.slow * 10_000_000))
            a.delayTime = TimeSpan(duration: Int64((after + move.at) * Motion.slow * 10_000_000))
            a.delayBehavior = .setInitialValueBeforeDelay
            if move.breathing {
                a.iterationBehavior = .forever
                a.direction = .alternate
            }
        }
        // Held at its start from this very frame, before the compositor has the move.
        switch move.property {
        case .opacity:
            guard let a = try? compositor.createScalarKeyFrameAnimation() else { return }
            for key in move.keys { try? a.insertKeyFrame(Float(key.progress), Float(key.value), ease) }
            timed(a)
            visual.opacity = Float(move.from)
            try? visual.startAnimation("Opacity", a)
        case .scale:
            guard let a = try? compositor.createVector3KeyFrameAnimation() else { return }
            for key in move.keys { try? a.insertKeyFrame(Float(key.progress), Vector3(x: Float(key.value), y: Float(key.value), z: 1), ease) }
            timed(a)
            visual.centerPoint = middle(of: move.target, element)
            visual.scale = Vector3(x: Float(move.from), y: Float(move.from), z: 1)
            try? visual.startAnimation("Scale", a)
        case .drop:
            try? ElementCompositionPreview.setIsTranslationEnabled(element, true)
            guard let a = try? compositor.createVector3KeyFrameAnimation() else { return }
            for key in move.keys { try? a.insertKeyFrame(Float(key.progress), Vector3(x: 0, y: Float(key.value), z: 0), ease) }
            timed(a)
            try? visual.startAnimation("Translation", a)
        case .inked:
            // The ink runs in from the top: what is not yet inked is cut away at the foot.
            let height = Float(OpeningPlan.markSize)
            guard let clip = try? compositor.createInsetClip(), let a = try? compositor.createScalarKeyFrameAnimation() else { return }
            clip.bottomInset = height * Float(1 - move.from)
            visual.clip = clip
            for key in move.keys { try? a.insertKeyFrame(Float(key.progress), height * Float(1 - key.value), ease) }
            timed(a)
            try? clip.startAnimation("BottomInset", a)
        }
    }
}
