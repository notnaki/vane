import SwiftUI

/// Shared by the live sidebar and the incoming Space preview.
struct SidebarTidyLabel: View {
    var body: some View {
        HStack(spacing: 5) {
            TidyBroom().fill()
                .frame(width: 11, height: Look.tidyRow)
                .accessibilityHidden(true)
            Text("Tidy")
        }
    }
}

/// A filled, slightly tilted broom with small gaps between its bristles.
private struct TidyBroom: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(roundedRect: CGRect(x: 5, y: 0.5, width: 2, height: 10),
                        cornerRadius: 1)
        path.addLines([
            CGPoint(x: 3, y: 9), CGPoint(x: 9, y: 9), CGPoint(x: 10, y: 15),
            CGPoint(x: 8, y: 15), CGPoint(x: 7.5, y: 12.5),
            CGPoint(x: 7.5, y: 15), CGPoint(x: 5.5, y: 15),
            CGPoint(x: 5, y: 12.5), CGPoint(x: 5, y: 15),
            CGPoint(x: 2, y: 15)
        ])
        path.closeSubpath()
        return path
            .applying(CGAffineTransform(translationX: -6, y: -8))
            .applying(CGAffineTransform(rotationAngle: .pi / 12))
            .applying(CGAffineTransform(translationX: 6, y: 8))
            .applying(CGAffineTransform(scaleX: rect.width / 12, y: rect.height / 16))
            .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
