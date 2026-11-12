import SwiftUI

/// A rounded, upright folder whose front panel leans forward when unfolded.
struct FolderIcon: View {
    var open: Bool
    var previewing = false

    var body: some View {
        let opened = open || previewing
        FolderArtwork(openness: opened ? 1 : 0)
            .fill()
            .animation(Motion.reduced ? nil : FolderMotion.animation(opening: opened), value: opened)
            .transaction { if Motion.reduced { $0.disablesAnimations = true } }
            .accessibilityHidden(true)
    }
}

/// Disclosure timing is shared by the outline and the artwork on its face.
enum FolderMotion {
    struct Curve {
        let duration: Double
        let x1: Double
        let y1: Double
        let x2: Double
        let y2: Double
    }
    // Separate curves fitted to the supplied Arc recording, including its slower settle.
    static let opening = Curve(duration: 0.24, x1: 0.28, y1: 0.245, x2: 0.39, y2: 1)
    static let closing = Curve(duration: 0.24, x1: 0.185, y1: 0.04, x2: 0.25, y2: 1)

    @MainActor static func animation(opening: Bool) -> Animation {
        let curve = opening ? self.opening : closing
        return .timingCurve(curve.x1, curve.y1, curve.x2, curve.y2,
                            duration: UIAnimation.feedback.duration(curve.duration))
    }
}

/// The front and its contents share one projection, including throughout animation.
/// Coordinates are in the row's 16pt favicon slot, with optical overshoot at the edges.
enum FolderFace {
    static let bounds = CGRect(x: -0.5, y: 3.5, width: 17.75, height: 13.5)
    static let badgeOffset = CGSize(width: 0.375, height: 2.25)

    static func panelBounds(_ openness: CGFloat) -> CGRect {
        CGRect(x: -0.25 - 0.25 * openness, y: 3.375 + 0.125 * openness,
               width: 17.5 + 0.25 * openness, height: 13.25 + 0.25 * openness)
    }

    static func panel(_ openness: CGFloat) -> Path {
        FolderPanel(openness: openness).path
    }

    // The front's lower-right extent stays planted while the back joins its lower-left corner.
    static let hinge = CGPoint(x: 17.25, y: 16.625)

    static func projection(_ openness: CGFloat) -> CGAffineTransform {
        var transform = unanchoredProjection(openness)
        let offset = hingeOffset(openness)
        transform.tx += offset.width
        transform.ty += offset.height
        return transform.concatenating(rotation(openness))
    }

    static func rotation(_ openness: CGFloat) -> CGAffineTransform {
        guard openness > 0, openness < 1 else { return .identity }
        // Arc briefly rolls clockwise in transit; both settled outlines stay level.
        let angle = 1.75 * CGFloat.pi / 180 * sin(.pi * openness)
        let c = cos(angle), s = sin(angle)
        return CGAffineTransform(a: c, b: s, c: -s, d: c,
                                 tx: hinge.x - c * hinge.x + s * hinge.y,
                                 ty: hinge.y - s * hinge.x - c * hinge.y)
    }

    static func hingeOffset(_ openness: CGFloat) -> CGSize {
        let bounds = panelBounds(openness)
        let corner = CGPoint(x: bounds.maxX, y: bounds.maxY)
            .applying(unanchoredProjection(openness))
        return CGSize(width: hinge.x - corner.x, height: hinge.y - corner.y)
    }

    private static func unanchoredProjection(_ openness: CGFloat) -> CGAffineTransform {
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

/// The front silhouette and the rear joins are evaluated at the same animation time.
private struct FolderPanel {
    let openness: CGFloat
    var bounds: CGRect {
        FolderFace.panelBounds(openness)
    }
    var topRadius: CGFloat { 2.25 - 0.5 * openness }
    var bottomRadius: CGFloat { 2.75 - 0.75 * openness }
    var path: Path {
        UnevenRoundedRectangle(topLeadingRadius: topRadius,
                               bottomLeadingRadius: bottomRadius,
                               bottomTrailingRadius: bottomRadius,
                               topTrailingRadius: topRadius,
                               style: .circular)
            .path(in: bounds)
            .applying(FolderFace.projection(openness))
    }

    var leftRearJoin: CGPoint {
        // The spine always meets this material point on the rounded lower corner.
        // The closed front hides it; revealing it must not slide the join down the side.
        let inset = bottomRadius * (1 - 1 / CGFloat(2).squareRoot())
        return CGPoint(x: bounds.minX + inset, y: bounds.maxY - inset)
            .applying(FolderFace.projection(openness))
    }

    var rightRearJoin: CGPoint {
        let x = 17 - 9 * openness
        let dx = max(0, x - (bounds.maxX - topRadius))
        let y = bounds.minY + topRadius - max(0, topRadius * topRadius - dx * dx).squareRoot()
        return CGPoint(x: x, y: y).applying(FolderFace.projection(openness))
    }
}

/// Filled stroke geometry lets the front face occlude the rear at every frame.
struct FolderArtwork: Shape {
    var openness: CGFloat
    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let offset = FolderFace.hingeOffset(openness)
        let rotation = FolderFace.rotation(openness)
        func point(_ cx: CGFloat, _ cy: CGFloat, _ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            CGPoint(x: cx + (ox - cx) * openness + offset.width,
                    y: cy + (oy - cy) * openness + offset.height).applying(rotation)
        }
        let panel = FolderPanel(openness: openness)
        let front = FolderFace.panel(openness)
        var rear = Path()
        rear.move(to: panel.leftRearJoin)
        rear.addLine(to: point(0.25, 1.25, -1.05, 2.6))
        rear.addCurve(to: point(1.75, -0.25, -0.55, 1.15),
                      control1: point(0.25, 0.25, -1.85, 1.65),
                      control2: point(0.75, -0.25, -1.6, 1.15))
        rear.addLine(to: point(7, -0.25, 4, 1.15))
        rear.addCurve(to: point(8.5, 0.5, 5.55, 1.9),
                      control1: point(7.75, -0.25, 4.6, 1.15),
                      control2: point(8, 0, 5, 1.5))
        rear.addLine(to: point(10, 1.75, 6.5, 2.7))
        rear.addLine(to: point(15, 1.75, 10.1, 2.7))
        rear.addCurve(to: point(17, 3.75, 12.65, 3.75),
                      control1: point(16.5, 1.75, 11.5, 2.7),
                      control2: point(17, 2.25, 12.5, 3.3))
        rear.addLine(to: panel.rightRearJoin)
        let style = StrokeStyle(lineWidth: 1.5 - 0.25 * openness,
                                lineCap: .round, lineJoin: .round)
        // Treat the front as an opaque stencil without painting a background color.
        // Union the strokes so their intersections keep one consistent thickness.
        let ink = rear.strokedPath(style).subtracting(front)
            .union(front.strokedPath(style))
        return ink.applying(CGAffineTransform(a: rect.width / 16, b: 0,
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
