import SwiftUI

/// A rounded, upright folder whose front panel leans forward when unfolded.
struct FolderIcon: View {
    var open: Bool
    var previewing = false

    var body: some View {
        let openness: CGFloat = open ? 1 : previewing ? 0.22 : 0
        FolderOutline(openness: openness)
            .stroke(style: StrokeStyle(lineWidth: 1.5 - 0.25 * openness,
                                       lineCap: .round, lineJoin: .round))
            .animation(Motion.reduced ? nil : Look.quick, value: open)
            .animation(Motion.reduced ? nil : Look.feedback, value: previewing)
            .transaction { if Motion.reduced { $0.disablesAnimations = true } }
            .accessibilityHidden(true)
    }
}

/// The front and its contents share one projection, including throughout animation.
/// Coordinates are in the row's 16pt favicon slot, with optical overshoot at the edges.
enum FolderFace {
    static let bounds = CGRect(x: -0.5, y: 3.5, width: 17.75, height: 13.5)
    static let badgeOffset = CGSize(width: 0.375, height: 2.25)

    static func projection(_ openness: CGFloat) -> CGAffineTransform {
        let scaleX: CGFloat = 14 / bounds.width
        let scaleY: CGFloat = 11.5 / bounds.height
        let shear: CGFloat = -3.5 / bounds.height
        return CGAffineTransform(a: 1 + (scaleX - 1) * openness, b: 0,
                                 c: shear * openness, d: 1 + (scaleY - 1) * openness,
                                 tx: (6 - scaleX * bounds.minX - shear * bounds.minY) * openness,
                                 ty: (4 - scaleY * bounds.minY) * openness)
    }
}

struct FolderFaceProjection: GeometryEffect {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(FolderFace.projection(openness))
    }
}

private struct FolderOutline: Shape {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        func between(_ closed: CGPoint, _ open: CGPoint) -> CGPoint {
            CGPoint(x: closed.x + (open.x - closed.x) * openness,
                    y: closed.y + (open.y - closed.y) * openness)
        }
        func point(_ cx: CGFloat, _ cy: CGFloat, _ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            between(CGPoint(x: cx, y: cy), CGPoint(x: ox, y: oy))
        }
        var path = Path()
        // The back tab's curves are independent of the front's rounded corners.
        path.move(to: point(0.25, 5, 2.75, 15.35))
        path.addLine(to: point(0.25, 1.25, -1.05, 2.6))
        path.addCurve(to: point(1.75, -0.25, -0.55, 1.15),
                      control1: point(0.25, 0.25, -1.85, 1.65),
                      control2: point(0.75, -0.25, -1.6, 1.15))
        path.addLine(to: point(7, -0.25, 4, 1.15))
        path.addCurve(to: point(8.5, 0.5, 5.55, 1.9),
                      control1: point(7.75, -0.25, 4.6, 1.15),
                      control2: point(8, 0, 5, 1.5))
        path.addLine(to: point(10, 1.75, 6.5, 2.7))
        path.addLine(to: point(15, 1.75, 10.1, 2.7))
        path.addCurve(to: point(17, 3.75, 12.65, 3.75),
                      control1: point(16.5, 1.75, 11.5, 2.7),
                      control2: point(17, 2.25, 12.5, 3.3))
        // End behind the front's top edge, rather than drawing through the panel.
        path.addLine(to: point(17, 5, 12.7, 3.75))
        let frontBounds = CGRect(x: -0.25 - 0.25 * openness, y: 3.375 + 0.125 * openness,
                                 width: 17.5 + 0.25 * openness, height: 13.25 + 0.25 * openness)
        let topRadius = 2.25 - 0.5 * openness
        let bottomRadius = 2.75 - 0.75 * openness
        let front = UnevenRoundedRectangle(topLeadingRadius: topRadius,
                                           bottomLeadingRadius: bottomRadius,
                                           bottomTrailingRadius: bottomRadius,
                                           topTrailingRadius: topRadius,
                                           style: .circular)
            .path(in: frontBounds)
            .applying(FolderFace.projection(openness))
        path.addPath(front)
        return path.applying(CGAffineTransform(a: rect.width / 16, b: 0,
                                              c: 0, d: rect.height / 16,
                                              tx: rect.minX, ty: rect.minY))
    }
}

/// Three geometric dots keep their diameter and spacing independent of SF font metrics.
struct FolderArrivalDots: View {
    var body: some View {
        HStack(spacing: 1.75) {
            ForEach(0..<3) { _ in Circle().frame(width: 2.5, height: 2.5) }
        }
        .fixedSize()
        .accessibilityHidden(true)
    }
}
