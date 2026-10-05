import SwiftUI

struct EaselIcon: View {
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                path.move(to: CGPoint(x: 0.36, y: 0.78))
                path.addCurve(to: CGPoint(x: 0.26, y: 0.40), control1: CGPoint(x: 0.20, y: 0.59), control2: CGPoint(x: 0.14, y: 0.29))
                path.addCurve(to: CGPoint(x: 0.58, y: 0.62), control1: CGPoint(x: 0.42, y: 0.53), control2: CGPoint(x: 0.71, y: 0.82))
                path.addCurve(to: CGPoint(x: 0.42, y: 0.29), control1: CGPoint(x: 0.42, y: 0.44), control2: CGPoint(x: 0.22, y: 0.16))
                path.addCurve(to: CGPoint(x: 0.71, y: 0.39), control1: CGPoint(x: 0.56, y: 0.42), control2: CGPoint(x: 0.86, y: 0.60))
                path.addLine(to: CGPoint(x: 0.60, y: 0.22))
            }.applying(CGAffineTransform(scaleX: geometry.size.width, y: geometry.size.height))
                .stroke(.black, style: StrokeStyle(lineWidth: geometry.size.width * 0.12, lineCap: .round, lineJoin: .round))
        }.background(.white, in: .rect(cornerRadius: 4))
    }
}
