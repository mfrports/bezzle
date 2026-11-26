import Foundation
import CoreGraphics

// Editing layers, shared by every Bezzle: the Mac's inspector and canvas call these, and so do
// the Windows app and the browser's core, so a layer turns, sizes, flips and follows its handles
// the same way everywhere. What only draws or listens to the pointer stays with each app.
//
// These are on the main actor, as the apps that call them are: a text's size is worked out by
// its layout, which is.

extension Geometry {
    /// An angle between −180 and 180, to a hundredth of a degree.
    nonisolated static func normalized(_ degrees: Double) -> Double {
        var d = degrees.truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d <= -180 { d += 360 }
        return (d * 100).rounded() / 100
    }
}

nonisolated extension CGRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

// MARK: - Turning, sizing, copying

extension Node {
    /// Turned to `degrees`, as the Frame card's turn field does it: a repeat grid turns with its
    /// copies, a group turns what it holds about the middle of its box as it is seen turned.
    mutating func turn(to degrees: Double) {
        if let turn = grid?.turn {
            self = RepeatGrid.turned(self, by: Geometry.normalized(degrees) - turn, about: frame.center)
        } else if isGroup {
            let (box, turn) = BezzleDocument.turnedBox(of: self)
            self = BezzleDocument.turned(self, by: Geometry.normalized(degrees) - turn, about: box.center)
        } else {
            rotation = Geometry.normalized(degrees)
        }
    }

    /// At a new size, as the Frame card's fields size it. Text wraps its words to a new width, or
    /// grows its letters and lines (`byHeight`: the height is what was given); a carousel is as
    /// high as its slides and as wide as whole slides; a group's layers and a grid's gaps
    /// stretch with it. An artboard only takes the size: laying its design out again for it is
    /// the app's (Adapting).
    mutating func resize(to size: CGSize, byHeight: Bool) {
        // A carousel is as high as its slides, which take the height, and as wide as whole slides.
        if isCarousel, let slide = slideSize, slide.width > 0 {
            setSlideSize(CGSize(width: slide.width, height: size.height))
            frame.size = carouselSize(count: Int((size.width / slide.width).rounded()))
            return
        }
        let old = frame
        if kind == .text, old.height > 0, old.width > 0 {
            resizeText(to: size, byHeight: byHeight)
        } else if isGroup, !isRepeatGrid, case let (box, turn) = BezzleDocument.turnedBox(of: self), turn != 0 {
            // A group seen turned stretches along its turn, from its box's top left as anything turned does.
            self = BezzleDocument.scaled(self, turned: turn, from: box, to: CGRect(origin: box.origin, size: size))
        } else {
            // A group's layers stretch with it, and a grid's gaps.
            if isGroup {
                children = BezzleDocument.scaled(children, from: old.size, to: size)
                mask = mask.map { BezzleDocument.scaled($0, from: old.size, to: size) }
                if old.width > 0 { grid?.columnGap *= size.width / old.width }
                if old.height > 0 { grid?.rowGap *= size.height / old.height }
            }
            frame.size = size
        }
    }

    /// The same layer, and what lies on it, with new identities.
    func freshCopy() -> Node {
        var n = self
        // A copy of a component stays one, its layers keyed from the component as every copy's are.
        if instance != nil { return Components.freshCopy(of: self) }
        n.id = UUID()
        // A grid's cells stay copies of its first, each with what it holds; so do a deck's posts.
        n.children = isRepeatGrid ? RepeatGrid.freshCells(of: self) : isDeck ? Deck.freshPosts(of: self) : children.map { $0.freshCopy() }
        return n
    }
}

extension Components {
    /// A copy of a component made again with new identities: its layers keyed from the component
    /// with a key of its own, as every copy's are, each keeping what it holds.
    static func freshCopy(of copy: Node) -> Node {
        guard let k = key(of: copy), let inst = copy.instance else { return copy }
        let next = freshKey()
        var n = RepeatGrid.copy(copy, k ^ next)
        n.id = inst.of.mixed(next)
        return n
    }
}

// MARK: - Flipping

extension BezzleDocument {
    /// Mirrors layers left to right, or top to bottom, where they are: one about its own middle,
    /// several about the middle of the box round them all. Artboards and locked layers stay.
    mutating func flip(_ ids: [UUID], horizontally: Bool) {
        let ids = ids.filter { node($0).map { !$0.locked && !$0.isArtboard } == true }
        guard let box = bounds(of: ids) else { return }
        for id in ids {
            // The line in the layer's parent's own coordinates.
            let o = parentOrigin(of: id)
            let axis = horizontally ? box.midX - o.x : box.midY - o.y
            // What a shape's keys do to its outline in a film is turned over with it.
            update(id) { $0 = BezzleDocument.flipped($0, horizontally: horizontally, about: axis).shapeKeysFlipped(from: $0, horizontally: horizontally) }
        }
    }

    /// Whether flipping them would change them. Words read forwards whichever way they are
    /// flipped, so a text layer on its own stays as it is.
    func canFlip(_ ids: [UUID]) -> Bool {
        let nodes = ids.compactMap { node($0) }.filter { !$0.locked && !$0.isArtboard }
        return nodes.count > 1 || nodes.contains { $0.kind != .text }
    }
}

// MARK: - A selection on the canvas

extension BezzleDocument {
    /// The box round layers on the canvas, each as far as it reaches turned.
    func bounds(of ids: [UUID]) -> CGRect? {
        var bounds: CGRect?
        for id in ids {
            guard let n = node(id) else { continue }
            let o = parentOrigin(of: id)
            let r = Geometry.bounds(of: n, eye: eye(forParentOf: id)).offsetBy(dx: o.x, dy: o.y)
            bounds = bounds?.union(r) ?? r
        }
        return bounds
    }

    /// A layer's outline as it shows on the canvas, in canvas points: its corners turned in the
    /// page and in depth, a group's box as it is seen turned, a line's two ends. `turnedBox` may
    /// be a canvas's own, which keeps what it has worked out.
    func shownCorners(of id: UUID, turnedBox: @MainActor (Node) -> (frame: CGRect, rotation: Double) = BezzleDocument.turnedBox) -> [CGPoint]? {
        guard let node = node(id) else { return nil }
        let points: [CGPoint]
        let eye = eye(forParentOf: id)
        if node.kind == .line {
            let (a, b) = node.lineEnds
            let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
            points = [a, b].map { Perspective.shown(Geometry.rotated($0, about: c, by: node.rotation), of: node, eye: eye) }
        } else if node.isGroup, case let (box, turn) = turnedBox(node), turn != 0 {
            points = Geometry.corners(of: box, rotation: turn).map { Perspective.shown($0, of: node, eye: eye) }
        } else {
            points = Perspective.corners(of: node, eye: eye)
        }
        return points.map { shown($0, inParentOf: id) }
    }

    /// The frame the handles sit on, on the canvas, and its turn: one layer's own (a group whose
    /// layers are turned is seen turned with them), the box round them all for several.
    func handleFrame(of ids: [UUID], turnedBox: @MainActor (Node) -> (frame: CGRect, rotation: Double) = BezzleDocument.turnedBox) -> (frame: CGRect, rotation: Double, single: Node?)? {
        guard !ids.isEmpty else { return nil }
        if ids.count == 1, let node = node(ids[0]) {
            let (box, turn) = turnedBox(node)
            let o = parentOrigin(of: node.id)
            return (box.offsetBy(dx: o.x, dy: o.y), turn, node)
        }
        return bounds(of: ids).map { ($0, 0, nil) }
    }

    /// Whether a layer is text as wide as its words, which has one handle, at its bottom, as XD has it.
    static func pointText(_ node: Node?) -> Bool {
        guard let node, node.kind == .text, node.curve == nil else { return false }
        return (node.style?.sizing ?? .autoWidth) == .autoWidth
    }

    /// The handles a selection shows, and where on the canvas, at `zoom`; `every` gives text as
    /// wide as its words those of any other layer, for turning it from just outside them. None
    /// for a line (its ends are its handles), a locked layer or a repeat grid (which has its own).
    func handlePoints(of ids: [UUID], zoom: CGFloat, every: Bool = false,
                      turnedBox: @MainActor (Node) -> (frame: CGRect, rotation: Double) = BezzleDocument.turnedBox) -> [(Handle, CGPoint)] {
        guard let (frame, rotation, single) = handleFrame(of: ids, turnedBox: turnedBox) else { return [] }
        if single?.kind == .line || single?.locked == true { return [] }
        if single?.isRepeatGrid == true { return [] }
        let size = CGSize(width: frame.width * zoom, height: frame.height * zoom)
        let point = !every && Self.pointText(single)
        return Handle.allCases.compactMap { h in
            if point, h != .bottom { return nil }
            // Small things keep only their corners, so the handles do not pile up; a text keeps
            // its bottom, which fits its box to its words.
            if !h.isCorner && !(single?.kind == .text && h == .bottom && !every) &&
                ((h.unit.x == 0.5 && size.width < 28) || (h.unit.y == 0.5 && size.height < 28)) { return nil }
            let at = Geometry.point(h.unit, of: frame, rotation: rotation)
            return (h, single.map { shownOnCanvas(at, of: $0) } ?? at)
        }
    }

    /// Where a point of a layer's frame (on the canvas, lying flat) shows, the layer and what
    /// holds it turned in depth or not.
    func shownOnCanvas(_ p: CGPoint, of node: Node) -> CGPoint {
        let o = parentOrigin(of: node.id)
        return shown(Perspective.shown(p - o, of: node, eye: eye(forParentOf: node.id)), inParentOf: node.id)
    }

    /// The other way: where on the layer, lying flat, a point of the canvas is. Nil past its horizon.
    func flatOnCanvas(_ p: CGPoint, of node: Node) -> CGPoint? {
        let o = parentOrigin(of: node.id)
        let eye = eye(forParentOf: node.id)
        return placed(p, inParentOf: node.id).flatMap { Perspective.flat($0, of: node, eye: eye) }.map { $0 + o }
    }
}

// MARK: - Moving

/// A line the canvas draws while something snaps to it, in canvas points.
nonisolated struct Guide: Equatable {
    var from: CGPoint
    var to: CGPoint
    /// For a gap as wide as another, rather than edges lined up: the space between the two sides
    /// facing across it, which the canvas fills, `from` and `to` running across its middle.
    var field: CGRect? = nil
    /// Whether the gap is beside what is being moved, rather than one it is as wide as.
    var mine = false

    var gap: Bool { field != nil }
}

extension SnapTargets {
    /// How far a drag by `delta` moves layers whose box on the canvas is `bounds`, as the canvas
    /// moves them, and the guides to draw: `constrain` (Shift) keeps to across or down, whichever
    /// is further; `snapping` catches the box's edges and middle on what is around it within
    /// `threshold` (canvas points; the Mac's is 5 on the screen), and gaps as wide as others; a
    /// text sitting on a baseline stays on it; otherwise whole points.
    func move(_ bounds: CGRect, by delta: CGPoint, constrain: Bool, snapping: Bool, threshold: CGFloat) -> (delta: CGPoint, guides: [Guide]) {
        var dx = delta.x, dy = delta.y
        if constrain { if abs(dx) > abs(dy) { dy = 0 } else { dx = 0 } }
        var guides: [Guide] = []
        if snapping {
            let (shiftBy, g) = snap(moving: bounds.offsetBy(dx: dx, dy: dy), threshold: threshold)
            dx += constrain && dx == 0 ? 0 : shiftBy.x
            dy += constrain && dy == 0 ? 0 : shiftBy.y
            guides = g
        }
        let onBaseline = snapping && sitsOnBaseline(bounds.offsetBy(dx: dx, dy: dy))
        dx = dx.rounded()
        if !onBaseline { dy = dy.rounded() }
        if snapping { guides += gapGuides(for: bounds.offsetBy(dx: dx, dy: dy)) }
        return (CGPoint(x: dx, y: dy), guides)
    }
}

extension BezzleDocument {
    /// Layers set where they were when a drag began (`originals`, their frames on the canvas),
    /// moved by `delta`.
    mutating func place(_ originals: [UUID: CGRect], movedBy delta: CGPoint) {
        for (id, frame) in originals {
            let o = parentOrigin(of: id)
            update(id) { $0.frame.origin = CGPoint(x: frame.minX + delta.x - o.x, y: frame.minY + delta.y - o.y) }
        }
    }
}

// MARK: - Pulling a handle

extension BezzleDocument {
    /// Whether a pull by `handle` keeps the proportions by itself: text as wide as its words (or
    /// along a curve) pulled by its top or bottom grows its letters, so it grows both ways.
    nonisolated static func keepsAspect(_ originals: [Node], _ handle: Handle) -> Bool {
        guard originals.count == 1, let text = originals.first, text.kind == .text else { return false }
        return handle.unit.x == 0.5 && (text.curve != nil || (text.style?.sizing ?? .autoWidth) == .autoWidth)
    }

    /// A carousel pulled by a handle to `p` on the canvas: across, as many whole slides as the
    /// pointer reaches past half of one; up or down, the slides' height, which `caught` may catch
    /// on a format's proportions. The side across from the handle stays put.
    nonisolated static func pulledCarousel(_ carousel: Node, slide: CGSize, handle: Handle, to p: CGPoint, bounds: CGRect,
                                           caught: (CGFloat) -> CGFloat = { $0 }) -> CGRect {
        let u = handle.unit
        let count = u.x == 0.5 ? carousel.slideCount : Int(((u.x == 0 ? bounds.maxX - p.x : p.x - bounds.minX) / slide.width).rounded())
        var height = u.y == 0.5 ? slide.height : max((u.y == 0 ? bounds.maxY - p.y : p.y - bounds.minY).rounded(), 1)
        if u.y != 0.5 { height = caught(height) }
        let width = carousel.carouselSize(count: count).width
        return CGRect(x: u.x == 0 ? bounds.maxX - width : bounds.minX, y: u.y == 0 ? bounds.maxY - height : bounds.minY, width: width, height: height)
    }

    /// The box a pull by `handle` to `p` gives layers whose box on the canvas was `bounds`
    /// (turned by `rotation`), as the canvas pulls it, and the guides to draw. Along a turned
    /// box's own sides; in proportion with `keep`; from the middle with `fromCenter`. A carousel
    /// keeps whole slides, its height catching on each format's proportions. Upright and lying
    /// flat (not `flat`, turned in depth), its edges catch on what is around it within `threshold`
    /// when `snapping` (and not from the middle), in proportion from the corner or side across
    /// from the handle, and it keeps to whole pixels.
    static func pull(_ bounds: CGRect, rotation: Double, handle: Handle, to p: CGPoint, keep: Bool, fromCenter option: Bool,
                     carousel: Node?, flat: Bool = false, snapping: Bool, targets: SnapTargets, threshold: CGFloat) -> (frame: CGRect, guides: [Guide]) {
        var frame = Geometry.resize(bounds, rotation: rotation, handle: handle, to: p, keepAspect: keep, fromCenter: option)
        var guides: [Guide] = []
        if let carousel, let slide = carousel.slideSize, slide.width > 0 {
            let snaps = snapping && !option
            frame = pulledCarousel(carousel, slide: slide, handle: handle, to: p, bounds: bounds) { height in
                guard snaps, let caught = Carousel.formats.map({ (slide.width * $0.size.height / $0.size.width).rounded() })
                        .min(by: { abs($0 - height) < abs($1 - height) }), abs(caught - height) <= threshold else { return height }
                return caught
            }
        } else if rotation == 0 && !flat {
            if snapping && !option {
                if keep, bounds.width > 0, bounds.height > 0 {
                    // Its proportions hold whatever it catches on: the nearest catch sizes it,
                    // the other side following, from the corner or side across from the handle.
                    let u = handle.unit
                    let still = CGPoint(x: bounds.minX + (1 - u.x) * bounds.width, y: bounds.minY + (1 - u.y) * bounds.height)
                    (frame, guides) = targets.snap(frame, keeping: bounds.width / bounds.height, anchor: still,
                                                   along: (u.x != 0.5, u.y != 0.5), threshold: threshold)
                } else {
                    (frame, guides) = targets.snap(resizing: frame, handle: handle, threshold: threshold)
                }
            }
            frame = Geometry.snapToPixels(frame)
        }
        return (frame, guides)
    }

    /// One layer as a pull by `handle` leaves it, made again from `original`: `next` is its new box
    /// on the canvas and `whole` its old one; `bounds` and `rotation` are the box the handles sat
    /// on, `origin` its parent's place on the canvas. Groups stretch what they hold (along their
    /// turn when seen turned); text follows XD: as wide as its words, its letters grow and it
    /// settles round the side across from the handle (the middle, `fromCenter` or turned); a
    /// fixed width pulled by its top, bottom or a corner becomes a box of fixed size. A line keeps
    /// which way it rises. Pulled in proportion (`keep`), its corners grow and shrink with it, and
    /// those of everything in it, so it keeps its look. An artboard's layers are the caller's to
    /// keep in place (`keepingLayers`), or to lay out again.
    static func resized(_ original: Node, to next: CGRect, whole: CGRect, origin o: CGPoint, bounds: CGRect, rotation: Double,
                        handle: Handle, single: Bool, fromCenter option: Bool, carousel: Bool, keep: Bool) -> Node {
        var node = pulled(original, to: next, whole: whole, origin: o, bounds: bounds, rotation: rotation,
                          handle: handle, single: single, fromCenter: option, carousel: carousel)
        if keep, !original.isArtboard {
            // How far the box the handles sat on grew: one layer's is that box itself, each of
            // several is mapped from it.
            let from = single ? bounds.size : whole.size
            let k = from.width >= from.height ? next.width / from.width : next.height / from.height
            if k.isFinite, k > 0, k != 1 { node.scaleCorners(by: k) }
        }
        return node
    }

    private static func pulled(_ original: Node, to next: CGRect, whole: CGRect, origin o: CGPoint, bounds: CGRect, rotation: Double,
                               handle: Handle, single: Bool, fromCenter option: Bool, carousel: Bool) -> Node {
        var node = original
        node.frame = next.offsetBy(dx: -o.x, dy: -o.y)
        // A carousel's slides are as high as it is pulled.
        if carousel { node.slideSize?.height = next.height }
        if node.isGroup, !node.isRepeatGrid, single, rotation != 0 {
            // A group seen turned stretches along its turn, its box as the handles show it.
            node = BezzleDocument.scaled(original, turned: rotation, from: bounds.offsetBy(dx: -o.x, dy: -o.y), to: next.offsetBy(dx: -o.x, dy: -o.y))
        } else if node.isGroup {
            node.children = BezzleDocument.scaled(original.children, from: original.frame.size, to: node.frame.size)
            node.mask = original.mask.map { BezzleDocument.scaled($0, from: original.frame.size, to: node.frame.size) }
        }
        if node.kind == .text {
            let sizing = original.style?.sizing ?? .autoWidth
            // As XD has it. Text as wide as its words has one handle, which grows its letters and
            // lines with its box; along a curve, on one line, every handle does. Among others,
            // such text grows by the height.
            let scales = (sizing == .autoWidth || original.curve != nil) && whole.width > 0 && whole.height > 0
            if scales {
                let byHeight = !single || handle.unit.x == 0.5
                node.scaleType(by: byHeight ? next.height / whole.height : next.width / whole.width)
            } else if single, sizing == .autoHeight, handle.unit.y != 0.5 {
                // A fixed width's sides wrap its words, as tall as its lines; pulled by its top,
                // its bottom or a corner, it is a box of fixed size. A box of fixed size is what
                // is dragged, its letters as they are.
                node.style?.sizing = .fixed
            }
            node.refit()
            // Its words settle its size to a point or so. The side across from the handle stays
            // where it was; along it, the text grows as it does with more words, from its top and
            // from the side it is aligned to. From the middle, or turned, it stays round the middle.
            if scales, single {
                let fitted = node.frame.size
                if option || rotation != 0 {
                    let box = next.offsetBy(dx: -o.x, dy: -o.y)
                    node.frame.origin = CGPoint(x: (box.midX - fitted.width / 2).rounded(), y: (box.midY - fitted.height / 2).rounded())
                } else {
                    let was = whole.offsetBy(dx: -o.x, dy: -o.y)
                    let aligned: CGFloat = switch node.style?.align ?? .left {
                    case .left, .justify: 0
                    case .center: 0.5
                    case .right: 1
                    }
                    let ax = handle.unit.x == 0.5 ? aligned : 1 - handle.unit.x, ay = handle.unit.y == 0.5 ? 0 : 1 - handle.unit.y
                    node.frame.origin = CGPoint(x: (was.minX + (was.width - fitted.width) * ax).rounded(),
                                                y: (was.minY + (was.height - fitted.height) * ay).rounded())
                }
            }
        }
        if node.kind == .line, original.frame.width > 0, original.frame.height > 0 {
            node.rising = original.rising
        }
        return node
    }

    /// An artboard whose edges moved from `original`'s to `next`, its layers staying where they
    /// are on the canvas.
    nonisolated static func keepingLayers(_ board: Node, from original: Node, to next: CGRect) -> Node {
        var b = board
        let moved = CGPoint(x: original.frame.minX - next.minX, y: original.frame.minY - next.minY)
        for i in b.children.indices { b.children[i].frame = b.children[i].frame.offsetBy(dx: moved.x, dy: moved.y) }
        return b
    }
}

extension Node {
    /// Its corners, and those of everything in it however deep, grown or shrunk by `k`, to a
    /// hundredth of a point, as a pull in proportion grows or shrinks it. Named corners stay as
    /// their name has them: changed on one layer, they would change on every layer that has them.
    /// What a component's copy holds keeps its component's corners, as the copy lays it out by its
    /// pins rather than stretching it.
    nonisolated mutating func scaleCorners(by k: CGFloat) {
        if cornersNamed == nil, cornerRadius != 0 || corners != nil {
            radii = radii.map { ($0 * k * 100).rounded() / 100 }
        }
        guard instance == nil else { return }
        for i in children.indices { children[i].scaleCorners(by: k) }
        if let held = mask { mask = held.map { var m = $0; m.scaleCorners(by: k); return m } }
    }
}
