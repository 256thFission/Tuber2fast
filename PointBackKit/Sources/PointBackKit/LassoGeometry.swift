import Foundation

public enum LassoGeometry {
    public static let minimumArea = 0.0025
    public static let closeDistance = 0.06

    public static func closedPath(from captured: [PagePoint]) -> [PagePoint]? {
        guard captured.count >= 3, captured.allSatisfy(\.isValid) else { return nil }
        var closed = captured
        guard let first = closed.first, let last = closed.last,
              hypot(last.x - first.x, last.y - first.y) <= closeDistance else { return nil }
        closed[closed.count - 1] = first
        guard abs(signedArea(of: closed)) >= minimumArea else { return nil }
        return closed
    }

    public static func pageBounds(of path: [PagePoint]) -> PageRect? {
        guard let minX = path.map(\.x).min(), let maxX = path.map(\.x).max(),
              let minY = path.map(\.y).min(), let maxY = path.map(\.y).max(),
              maxX > minX, maxY > minY else { return nil }
        let bounds = PageRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return bounds.isValid ? bounds : nil
    }

    public static func cropPointToPage(_ point: CropPoint, cropBounds: PageRect) -> PagePoint {
        PagePoint(
            x: cropBounds.x + point.x * cropBounds.width,
            y: cropBounds.y + point.y * cropBounds.height
        )
    }

    public static func cropRectToPage(_ rect: CropRect, cropBounds: PageRect) -> PageRect {
        PageRect(
            x: cropBounds.x + rect.x * cropBounds.width,
            y: cropBounds.y + rect.y * cropBounds.height,
            width: rect.width * cropBounds.width,
            height: rect.height * cropBounds.height
        )
    }

    public static func roundTripMaximumError(path: [PagePoint], bounds: PageRect) -> Double {
        path.reduce(0) { result, point in
            let crop = CropPoint(
                x: (point.x - bounds.x) / bounds.width,
                y: (point.y - bounds.y) / bounds.height
            )
            let restored = cropPointToPage(crop, cropBounds: bounds)
            return max(result, abs(restored.x - point.x), abs(restored.y - point.y))
        }
    }

    private static func signedArea(of path: [PagePoint]) -> Double {
        zip(path, path.dropFirst()).reduce(0) { area, pair in
            area + pair.0.x * pair.1.y - pair.1.x * pair.0.y
        } / 2
    }
}
