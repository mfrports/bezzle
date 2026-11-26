import Testing
import CoreGraphics
import Foundation
@testable import Bezzle

/// Pulled in proportion (Shift, or text that keeps its proportions by itself), a layer's corners
/// grow and shrink with it, and those of everything in it.
@MainActor
struct ProportionalCornersTests {
    private func rect(_ frame: CGRect, radius: CGFloat = 0, corners: [CGFloat]? = nil) -> Node {
        var n = Node(kind: .rectangle, name: "R", frame: frame)
        if let corners { n.radii = corners } else { n.cornerRadius = radius }
        return n
    }

    /// One layer pulled by its bottom right corner from `from` to `to`, as the canvas pulls it.
    private func pull(_ n: Node, to next: CGRect, keep: Bool) -> Node {
        BezzleDocument.resized(n, to: next, whole: n.frame, origin: .zero, bounds: n.frame, rotation: 0,
                               handle: .bottomRight, single: true, fromCenter: false, carousel: false, keep: keep)
    }

    @Test func cornersGrowWithTheLayerInProportion() {
        let n = rect(CGRect(x: 0, y: 0, width: 100, height: 50), radius: 10)
        let grown = pull(n, to: CGRect(x: 0, y: 0, width: 200, height: 100), keep: true)
        #expect(grown.cornerRadius == 20)
        let shrunk = pull(n, to: CGRect(x: 0, y: 0, width: 30, height: 15), keep: true)
        #expect(shrunk.cornerRadius == 3)
    }

    @Test func cornersStayWhenPulledFreely() {
        let n = rect(CGRect(x: 0, y: 0, width: 100, height: 50), radius: 10)
        let pulled = pull(n, to: CGRect(x: 0, y: 0, width: 200, height: 100), keep: false)
        #expect(pulled.cornerRadius == 10)
    }

    @Test func cornersOfTheirOwnKeepTheirProportions() {
        let n = rect(CGRect(x: 0, y: 0, width: 100, height: 100), corners: [4, 8, 12, 0])
        let pulled = pull(n, to: CGRect(x: 0, y: 0, width: 150, height: 150), keep: true)
        #expect(pulled.radii == [6, 12, 18, 0])
    }

    @Test func everythingInAGroupFollows() {
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        var inner = Node(kind: .group, name: "Inner", frame: CGRect(x: 100, y: 0, width: 100, height: 100))
        inner.children = [rect(CGRect(x: 0, y: 0, width: 100, height: 100), corners: [10, 10, 0, 0])]
        group.children = [rect(CGRect(x: 0, y: 0, width: 100, height: 100), radius: 16), inner]
        let shrunk = pull(group, to: CGRect(x: 0, y: 0, width: 100, height: 50), keep: true)
        #expect(shrunk.children[0].cornerRadius == 8)
        #expect(shrunk.children[1].children[0].radii == [5, 5, 0, 0])
        #expect(shrunk.children[0].frame == CGRect(x: 0, y: 0, width: 50, height: 50))
    }

    @Test func namedCornersStayAsTheirNameHasThem() {
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var named = rect(CGRect(x: 0, y: 0, width: 100, height: 100), radius: 12)
        named.cornersNamed = UUID()
        group.children = [named]
        let grown = pull(group, to: CGRect(x: 0, y: 0, width: 200, height: 200), keep: true)
        #expect(grown.children[0].cornerRadius == 12)
    }

    @Test func aComponentsCopyKeepsItsComponentsCorners() {
        var group = Node(kind: .group, name: "G", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        var copy = Node(kind: .group, name: "Copy", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        copy.instance = Instance(of: UUID(), box: CGRect(x: 0, y: 0, width: 100, height: 100))
        copy.children = [rect(CGRect(x: 0, y: 0, width: 100, height: 100), radius: 6)]
        group.children = [copy, rect(CGRect(x: 0, y: 0, width: 50, height: 50), radius: 6)]
        let grown = pull(group, to: CGRect(x: 0, y: 0, width: 200, height: 200), keep: true)
        #expect(grown.children[0].children[0].cornerRadius == 6)
        #expect(grown.children[1].cornerRadius == 12)
    }

    @Test func eachOfSeveralGrowsAsTheirBoxDoes() {
        let a = rect(CGRect(x: 0, y: 0, width: 50, height: 50), radius: 5)
        let b = rect(CGRect(x: 100, y: 0, width: 100, height: 100), radius: 9)
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100), frame = CGRect(x: 0, y: 0, width: 300, height: 150)
        func pulled(_ n: Node) -> Node {
            let next = Geometry.snapToPixels(Geometry.map(n.frame, from: bounds, to: frame))
            return BezzleDocument.resized(n, to: next, whole: n.frame, origin: .zero, bounds: bounds, rotation: 0,
                                          handle: .bottomRight, single: false, fromCenter: false, carousel: false, keep: true)
        }
        #expect(pulled(a).cornerRadius == 7.5)
        #expect(pulled(b).cornerRadius == 13.5)
    }

    @Test func onTheCanvasShiftPullsTheCornersAlong() {
        var r = CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50))
        r.cornerRadius = 10
        let bench = Bench(extra: [r])
        bench.click(CGPoint(x: 130, y: 130))
        // The bottom right handle sits at 160,160 on the canvas; Command keeps it from catching.
        bench.drag(CGPoint(x: 160, y: 160), CGPoint(x: 210, y: 210), flags: [.shift, .command])
        #expect(bench.node("R")?.frame == CGRect(x: 10, y: 10, width: 100, height: 100))
        #expect(bench.node("R")?.cornerRadius == 20)
        // Pulled freely, they stay as they are.
        bench.drag(CGPoint(x: 210, y: 210), CGPoint(x: 260, y: 230), flags: [.command])
        #expect(bench.node("R")?.cornerRadius == 20)
        // Undone, they are as they were.
        bench.undo.undo()
        bench.undo.undo()
        #expect(bench.node("R")?.cornerRadius == 10)
    }

    @Test func anArtboardKeepsItsCorners() {
        var board = Node(kind: .artboard, name: "A", frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        board.children = [rect(CGRect(x: 0, y: 0, width: 40, height: 40), radius: 8)]
        let grown = pull(board, to: CGRect(x: 0, y: 0, width: 200, height: 200), keep: true)
        #expect(grown.children[0].cornerRadius == 8)
    }
}
