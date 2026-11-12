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
        path.move(to: point(0, 6, 2.75, 15.35))
        path.addLine(to: point(0, 1.75, -1.05, 2.6))
        path.addCurve(to: point(2.25, -0.25, -0.55, 1.15),
                      control1: point(0, 0.4, -1.85, 1.65),
                      control2: point(1, -0.25, -1.6, 1.15))
        path.addLine(to: point(6.1, -0.25, 4, 1.15))
        path.addCurve(to: point(7.8, 0.55, 5.55, 1.9),
                      control1: point(7, -0.25, 4.6, 1.15),
                      control2: point(7.4, 0.2, 5, 1.5))
        path.addLine(to: point(9.1, 1.65, 6.5, 2.7))
        path.addLine(to: point(13.75, 1.65, 10.1, 2.7))
        path.addCurve(to: point(16.75, 4, 12.65, 3.75),
                      control1: point(15.4, 1.65, 11.5, 2.7),
                      control2: point(16.75, 2.4, 12.5, 3.3))
        // End behind the front's top edge, rather than drawing through the panel.
        path.addLine(to: point(16.75, 6, 12.7, 3.75))
        let bottomRadius = 2.75 - 0.75 * openness
        let front = UnevenRoundedRectangle(topLeadingRadius: 1.75,
                                           bottomLeadingRadius: bottomRadius,
                                           bottomTrailingRadius: bottomRadius,
                                           topTrailingRadius: 1.75,
                                           style: .circular)
            .path(in: FolderFace.bounds)
            .applying(FolderFace.projection(openness))
        path.addPath(front)
        return path.applying(CGAffineTransform(a: rect.width / 16, b: 0,
                                              c: 0, d: rect.height / 16,
                                              tx: rect.minX, ty: rect.minY))
    }
}
