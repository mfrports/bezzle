import Foundation

/// A piece of a canvas surface on the same pixel grid as the whole surface.
struct CanvasRasterArea: Equatable {
    let bounds: CGRect
    let scale: Double
    let pixels: CGRect

    var whole: Bool {
        pixels.origin == .zero && pixels.width == max(1, (bounds.width * scale).rounded())
            && pixels.height == max(1, (bounds.height * scale).rounded())
    }

    var rect: CGRect {
        if whole { return bounds }
        return CGRect(x: bounds.minX + pixels.minX / scale, y: bounds.minY + pixels.minY / scale,
                      width: pixels.width / scale, height: pixels.height / scale)
    }

    static func select(bounds: CGRect, visible: CGRect, margin: Double, scale: Double,
                       keeping old: Self?, flying: Bool = false) -> Self? {
        guard let needed = pixels(in: visible, bounds: bounds, scale: scale) else { return nil }
        if let old, old.bounds == bounds, (old.scale == scale || flying),
           old.pixels.width <= ((visible.width + 4 * margin) * old.scale).rounded(.up) + 1,
           old.pixels.height <= ((visible.height + 4 * margin) * old.scale).rounded(.up) + 1,
           let atOldScale = pixels(in: visible, bounds: bounds, scale: old.scale), old.pixels.contains(atOldScale) {
            return old
        }
        let larger = visible.insetBy(dx: -margin, dy: -margin)
        return Self(bounds: bounds, scale: scale, pixels: pixels(in: larger, bounds: bounds, scale: scale) ?? needed)
    }

    private static func pixels(in rect: CGRect, bounds: CGRect, scale: Double) -> CGRect? {
        let part = rect.intersection(bounds)
        guard !part.isEmpty, !part.isNull, part.minX.isFinite, part.minY.isFinite,
              part.maxX.isFinite, part.maxY.isFinite, scale.isFinite, scale > 0 else { return nil }
        let fullWidth = max(1, (bounds.width * scale).rounded())
        let fullHeight = max(1, (bounds.height * scale).rounded())
        let left = min(fullWidth - 1, ((part.minX - bounds.minX) * scale).rounded(.down))
        let top = min(fullHeight - 1, ((part.minY - bounds.minY) * scale).rounded(.down))
        let right = min(fullWidth, ((part.maxX - bounds.minX) * scale).rounded(.up))
        let bottom = min(fullHeight, ((part.maxY - bounds.minY) * scale).rounded(.up))
        let width = right - left, height = bottom - top
        guard left.isFinite, top.isFinite, width > 0, height > 0,
              width * height <= Double(Int32.max) / 4 else { return nil }
        return CGRect(x: left, y: top, width: width, height: height)
    }
}
