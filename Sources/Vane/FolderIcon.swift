import SwiftUI

/// A rounded, upright folder whose front panel leans forward when unfolded.
struct FolderIcon: View {
    var open: Bool
    var previewing = false

    var body: some View {
        let openness: CGFloat = open ? 1 : previewing ? 0.22 : 0
        FolderArtwork(openness: openness)
            .fill()
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

    static func panelBounds(_ openness: CGFloat) -> CGRect {
        CGRect(x: -0.25 - 0.25 * openness, y: 3.375 + 0.125 * openness,
               width: 17.5 + 0.25 * openness, height: 13.25 + 0.25 * openness)
    }

    static func panel(_ openness: CGFloat) -> Path {
        FolderPanel(openness: openness).path
    }

    // The recording keeps this lower-right spine corner and the bottom edge planted.
    static let hinge = CGPoint(x: 17.25, y: 16.625)

    static func projection(_ openness: CGFloat) -> CGAffineTransform {
        var transform = unanchoredProjection(openness)
        let offset = hingeOffset(openness)
        transform.tx += offset.width
        transform.ty += offset.height
        return transform
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
        // Travel along the actual left boundary, ending on the rounded lower
        // corner rather than its imaginary sharp vertex.
        let closedY = bounds.minY + topRadius * (1 - (1 - pow(7.0 / 9, 2)).squareRoot())
        let openY = bounds.maxY - bottomRadius + bottomRadius / CGFloat(2).squareRoot()
        let y = closedY + (openY - closedY) * openness
        let radius: CGFloat
        let centerY: CGFloat
        if y < bounds.minY + topRadius {
            radius = topRadius
            centerY = bounds.minY + radius
        } else if y > bounds.maxY - bottomRadius {
            radius = bottomRadius
            centerY = bounds.maxY - radius
        } else {
            return CGPoint(x: bounds.minX, y: y).applying(FolderFace.projection(openness))
        }
        let dy = y - centerY
        let x = bounds.minX + radius - max(0, radius * radius - dy * dy).squareRoot()
        return CGPoint(x: x, y: y).applying(FolderFace.projection(openness))
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
        func point(_ cx: CGFloat, _ cy: CGFloat, _ ox: CGFloat, _ oy: CGFloat) -> CGPoint {
            CGPoint(x: cx + (ox - cx) * openness + offset.width,
                    y: cy + (oy - cy) * openness + offset.height)
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
