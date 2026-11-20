import Foundation
import CBezzleHost

// Layers lying on the canvas itself, outside any artboard, as the Mac's canvas shows them: each
// drawn on its own, as far as it reaches with its shadows and blur, and picked and selected as
// layers on an artboard are, its place in the design standing for the artboard.

extension WindowsCore {
    /// A layer on the canvas: its place among the design's layers, and the part of the canvas it
    /// paints, shadows and blur included.
    nonisolated public struct Loose: Sendable {
        public let index: Int
        public let reach: CGRect
    }

    /// The layers lying on the canvas, back to front, hidden ones left out.
    public static func looseLayers() -> [Loose] {
        guard let doc = design else { return [] }
        return doc.nodes.enumerated().compactMap { k, n in
            guard !n.isArtboard, !n.hidden else { return nil }
            return Loose(index: k, reach: Renderer.reach(of: n).integral)
        }
    }

    /// Whether the layer at `index` among the design's lies on the canvas rather than being an artboard.
    public static func isLoose(_ index: Int) -> Bool {
        guard let doc = design, doc.nodes.indices.contains(index) else { return false }
        return !doc.nodes[index].isArtboard
    }

    /// Draws a layer lying on the canvas (`index` among the design's) over its reach, at `scale`
    /// pixels a point, into pixels as `render(board:)` does.
    public static func render(loose index: Int, scale: Double, hiding: Set<UUID> = [], part: CGRect? = nil,
                              into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        guard let doc = design, doc.nodes.indices.contains(index), !doc.nodes[index].isArtboard else { return false }
        let node = doc.nodes[index]
        let r = part ?? Renderer.reach(of: node).integral
        let size = CGSize(width: max(1, (r.width * CGFloat(scale)).rounded()), height: max(1, (r.height * CGFloat(scale)).rounded()))
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let ctx = Renderer.bitmap(size) else { return false }
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
        ctx.translateBy(x: -r.minX, y: -r.minY)
        Renderer.withFlippedContext(ctx) {
            // Left out, the layers `hiding`, and the layer itself when it is one of them.
            var options = Renderer.Options(deviceScale: CGFloat(scale), assets: assets)
            options.skipping = hiding
            Renderer.drawNode(node, in: ctx, options: options)
        }
        guard let image = ctx.makeImage() else { return false }
        for picture in Images.shared.list where picture.id >= first { send(picture) }
        defer { forget(before: first) }
        guard let pixels = fill(image.width, image.height) else { return false }
        return bz_picture_read(Int32(image.id), Int32(image.width), Int32(image.height), 1, pixels) == 0
    }
}
