import Foundation

// How a selection shows on the canvas and how its handles pull it: the Mac's own code, shared in
// Bezzle/Model/LayerEditing.swift; here only what the Windows canvas asks for, in canvas points.

extension WindowsCore {
    /// The handles in the canvas's order: the corners clockwise from the top left, then the
    /// middles of the top, the right, the bottom and the left.
    static let handleOrder: [Handle] = [.topLeft, .topRight, .bottomRight, .bottomLeft, .top, .right, .bottom, .left]

    /// A selection as it shows: each layer's outline (a line's two ends), drawn in the colour of
    /// component copies when it is one; for several, the box round them all; and its handles, by
    /// their place in `handleOrder`. `round` handles: a line's two ends (by 0 and 1), or the one
    /// of text as wide as its words.
    public struct Shown {
        public let outlines: [(points: [CGPoint], closed: Bool, copy: Bool)]
        public let bounds: [CGPoint]?
        public let handles: [(index: Int, point: CGPoint)]
        public let round: Bool
    }

    public static func shown(_ ids: [UUID], zoom: Double) -> Shown? {
        guard let doc = design, let (frame, _, single) = doc.handleFrame(of: ids) else { return nil }
        let outlines = ids.compactMap { id in
            (doc.gridOutline(of: id) ?? doc.shownCorners(of: id)).map { (points: $0, closed: $0.count > 2, copy: doc.node(id)?.isCopy == true) }
        }
        let bounds = ids.count > 1 ? Geometry.corners(of: frame, rotation: 0) : nil
        if let single, single.kind == .line, !single.locked, let ends = outlines.first?.points {
            return Shown(outlines: outlines, bounds: nil, handles: ends.enumerated().map { ($0.offset, $0.element) }, round: true)
        }
        let handles = doc.handlePoints(of: ids, zoom: CGFloat(zoom)).compactMap { h, p in
            handleOrder.firstIndex(of: h).map { (index: $0, point: p) }
        }
        return Shown(outlines: outlines, bounds: bounds, handles: handles, round: BezzleDocument.pointText(single))
    }

    /// Layers pulled by handle `index` (in `handleOrder`) to `p` on the canvas, made again from
    /// where the gesture began, as the Mac's canvas resizes them (`BezzleDocument.pull`, then
    /// `BezzleDocument.resized` for each): in proportion with `keep`, from the middle with
    /// `fromCenter`, the edges catching on what is around them unless `snapping` is off (between
    /// `beginPull` and `endPull`). An artboard's design is laid out again for its new size as it
    /// goes. The guides to draw.
    @discardableResult
    public static func resize(_ ids: [UUID], handle index: Int, to p: CGPoint, keep shift: Bool, fromCenter option: Bool,
                              snapping: Bool = false, zoom: Double = 1) -> [GuideLine] {
        guard let doc = Editing.gestureStart ?? design, handleOrder.indices.contains(index),
              let (bounds, rotation, _) = doc.handleFrame(of: ids) else { return [] }
        let handle = handleOrder[index]
        var originals: [UUID: Node] = [:], absolute: [UUID: CGRect] = [:]
        for id in ids {
            guard let n = doc.node(id), !n.locked, let f = doc.absoluteFrame(of: id) else { continue }
            originals[id] = n
            absolute[id] = f
        }
        guard !originals.isEmpty else { return [] }
        let keep = shift || BezzleDocument.keepsAspect(Array(originals.values), handle)
        let carousel = originals.count == 1 ? originals.values.first.flatMap { $0.isCarousel ? $0 : nil } : nil
        let (frame, guides) = BezzleDocument.pull(bounds, rotation: rotation, handle: handle, to: p, keep: keep, fromCenter: option,
                                                  carousel: carousel, snapping: snapping && pullTargets != nil,
                                                  targets: pullTargets ?? SnapTargets(), threshold: 5 / CGFloat(zoom))
        edit { d in
            for (id, original) in originals {
                guard let whole = absolute[id] else { continue }
                let o = d.parentOrigin(of: id)
                var next = originals.count == 1 ? frame : Geometry.map(whole, from: bounds, to: frame)
                if originals.count > 1 { next = Geometry.snapToPixels(next) }
                d.update(id) {
                    $0 = BezzleDocument.resized(original, to: next, whole: whole, origin: o, bounds: bounds, rotation: rotation,
                                                handle: handle, single: originals.count == 1, fromCenter: option, carousel: carousel != nil, keep: keep)
                }
                if original.isArtboard, let session = adapting[id] {
                    // Its design is laid out again for the size it is being given; a deck's posts
                    // stay as the last step made them, which the deck makes again from its design.
                    let (r, _) = session.compose(next.size)
                    let last = design?.node(id)
                    d.update(id) { b in b.children = Adapting.merged(r.board, into: last ?? b, from: session.source) }
                } else if original.isArtboard {
                    // An artboard's contents stay where they are on the canvas as its edges move.
                    d.update(id) { $0 = BezzleDocument.keepingLayers($0, from: original, to: next) }
                }
            }
        }
        return guides.map { GuideLine(from: $0.from, to: $0.to, field: $0.field) }
    }

    /// A line's end `index` (0 or 1) dragged to `p` on the canvas, from where the gesture began,
    /// as the Mac's line ends move: a turned line is straightened into its ends, the other end
    /// stays, and with `constrain` the line keeps to the nearest eighth of a turn.
    public static func moveLineEnd(_ id: UUID, end index: Int, to p: CGPoint, constrain: Bool) {
        guard let doc = Editing.gestureStart ?? design, let node = doc.node(id), node.kind == .line else { return }
        let o = doc.parentOrigin(of: id)
        let c = CGPoint(x: node.frame.midX, y: node.frame.midY)
        let (a, b) = node.lineEnds
        let ends = [a, b].map { Geometry.rotated($0, about: c, by: node.rotation) + o }
        let fixed = ends[1 - index]
        var end = Geometry.lineEnd(from: fixed, to: p, constrain: constrain)
        end = CGPoint(x: end.x.rounded(), y: end.y.rounded())
        edit { d in d.update(id) { $0.rotation = 0; $0.setLineEnds(fixed - o, end - o) } }
    }
}
