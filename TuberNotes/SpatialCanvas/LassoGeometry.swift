import CoreGraphics
import Foundation

/// Deterministic lasso math in page-normalized space. Pure functions so the
/// selection a user sees is provably the region the refinement acts on.
enum LassoGeometry {
    /// Minimum enclosed area (normalized units) for a lasso to count as a region.
    static let minimumArea: CGFloat = 0.0025
    /// Maximum start/end gap (normalized units) for a lasso to count as closed.
    static let closeDistance: CGFloat = 0.06

    /// Validates a captured lasso as a closed polygon: finite points, ends near
    /// enough to snap together, and enough enclosed area to be a real region.
    /// Returns the closed path (last point snapped onto the first), or nil.
    static func closedPath(from captured: [CGPoint]) -> [CGPoint]? {
        guard captured.count >= 3,
              captured.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return nil }
        var closed = captured
        guard let first = closed.first, let last = closed.last,
              hypot(last.x - first.x, last.y - first.y) <= closeDistance else { return nil }
        closed[closed.count - 1] = first
        guard abs(signedArea(of: closed)) >= minimumArea else { return nil }
        return closed
    }

    static func bounds(of path: [CGPoint]) -> CGRect? {
        guard let minX = path.map(\.x).min(), let maxX = path.map(\.x).max(),
              let minY = path.map(\.y).min(), let maxY = path.map(\.y).max(),
              maxX > minX, maxY > minY else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Even-odd ray cast. Points on an edge may land on either side; the
    /// containment rule tolerates that by requiring every stroke point inside.
    static func contains(_ point: CGPoint, in closedPath: [CGPoint]) -> Bool {
        guard closedPath.count >= 4 else { return false }
        var inside = false
        var j = closedPath.count - 1
        for i in 0..<closedPath.count {
            let a = closedPath[i]
            let b = closedPath[j]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    static func signedArea(of path: [CGPoint]) -> CGFloat {
        guard path.count >= 3 else { return 0 }
        var area: CGFloat = 0
        for index in 0..<(path.count - 1) {
            let current = path[index]
            let next = path[index + 1]
            area += current.x * next.y - next.x * current.y
        }
        return area / 2
    }
}
