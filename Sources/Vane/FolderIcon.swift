import SwiftUI

/// An upright closed folder whose front flap leans forward as it opens.
struct FolderIcon: View {
    var open: Bool

    var body: some View {
        FolderOutline(openness: open ? 1 : 0)
            .stroke(style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
            .animation(Motion.reduced ? nil : Look.quick, value: open)
            .transaction { if Motion.reduced { $0.disablesAnimations = true } }
            .accessibilityHidden(true)
    }
}

private struct FolderOutline: Shape {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
        }
        let left = 0.10 + openness * 0.08
        let right = 0.88 - openness * 0.08
        let shoulder = 0.10 - openness * 0.06
        let backRight = 0.88 - openness * 0.13
        let top = 0.29 + openness * 0.10
        let frontLeft = 0.10 + openness * 0.20
        let frontRight = 0.88 + openness * 0.08
        var path = Path()
        // Back panel and tab retain their identity throughout the transform.
        path.move(to: point(left, 0.82))
        path.addLine(to: point(shoulder, 0.19))
        path.addQuadCurve(to: point(shoulder + 0.08, 0.11),
                          control: point(shoulder - 0.01, 0.11))
        path.addLine(to: point(shoulder + 0.28, 0.11))
        path.addQuadCurve(to: point(shoulder + 0.35, 0.15),
                          control: point(shoulder + 0.32, 0.11))
        path.addLine(to: point(shoulder + 0.41, 0.22))
        path.addLine(to: point(backRight - 0.07, 0.22))
        path.addQuadCurve(to: point(backRight, 0.29), control: point(backRight, 0.22))
        path.addLine(to: point(backRight, top))
        // The same front panel moves, rather than swapping closed/open glyphs.
        path.move(to: point(left, 0.82))
        path.addLine(to: point(frontLeft, top + 0.07))
        path.addQuadCurve(to: point(frontLeft + 0.07, top),
                          control: point(frontLeft, top))
        path.addLine(to: point(frontRight - 0.07, top))
        path.addQuadCurve(to: point(frontRight, top + 0.07),
                          control: point(frontRight + openness * 0.02, top))
        path.addLine(to: point(right, 0.82))
        path.addQuadCurve(to: point(right - 0.06, 0.88), control: point(right, 0.88))
        path.addLine(to: point(left + 0.06, 0.88))
        path.addQuadCurve(to: point(left, 0.82), control: point(left, 0.88))
        path.closeSubpath()
        return path
    }
}
