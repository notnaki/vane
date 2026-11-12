from pathlib import Path
import os

source = Path('Sources/Vane/FolderIcon.swift').read_text()
prefix = '''import AppKit
import SwiftUI
enum Motion { static let reduced = true }
enum UIAnimation { case feedback; func duration(_ seconds: Double) -> Double { seconds } }
'''
diagnostic = r'''
@main struct Diagnose {
    @MainActor static func main() throws {
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["VANE_DIAGNOSTIC_OUTPUT"]!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var report: [[String: Any]] = []
        func bytes(_ image: CGImage) -> [UInt8] {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            data.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return data
        }
        func render<V: View>(_ view: V, _ name: String) throws -> [UInt8] {
            let renderer = ImageRenderer(content: view.frame(width: 16, height: 16)
                .padding(8).background(Color.black))
            renderer.scale = 32
            let image = renderer.cgImage!
            let bitmap = NSBitmapImageRep(cgImage: image)
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: output.appendingPathComponent(name + ".png"))
            return bytes(image)
        }
        func count(_ ink: [UInt8], _ mask: [UInt8]? = nil) -> Int {
            stride(from: 0, to: ink.count, by: 4).reduce(0) { result, index in
                result + ((ink[index] > 0 && (mask == nil || mask![index] == 255)) ? 1 : 0)
            }
        }
        for frame in [0, 25, 50, 75, 100] {
            let p = CGFloat(frame) / 100
            let tag = "p\(frame)"
            let front = FolderFace.panel(p)
            let style = StrokeStyle(lineWidth: 1.5 - 0.25 * p, lineCap: .round, lineJoin: .round)
            let border = front.strokedPath(StrokeStyle(lineWidth: style.lineWidth + 0.02,
                                                       lineCap: .round, lineJoin: .round))
            let ink = FolderArtwork(openness: p).path(in: CGRect(x: 0, y: 0, width: 16, height: 16))
            let intrusion = ink.intersection(front).subtracting(border)
            let native = try render(ink.fill(Color.white), tag + "-native")
            let bridged = try render(Path(ink.cgPath).fill(Color.white), tag + "-cg")
            let mask = try render(front.fill(Color.white).overlay(border.fill(Color.black)), tag + "-mask")
            let computed = try render(intrusion.fill(Color.white), tag + "-intrusion-native")
            let computedCG = try render(Path(intrusion.cgPath).fill(Color.white), tag + "-intrusion-cg")
            let entry: [String: Any] = ["pose": p,
                "nativeInteriorPixels": count(native, mask),
                "cgInteriorPixels": count(bridged, mask),
                "intrusionNativePixels": count(computed),
                "intrusionCGPixels": count(computedCG),
                "intrusionCGEmpty": intrusion.cgPath.isEmpty,
                "intrusionBounds": NSStringFromRect(intrusion.cgPath.boundingBoxOfPath)]
            report.append(entry)
            print(entry)
        }
        let square = Path(CGRect(x: 2, y: 2, width: 12, height: 12))
        let empty = square.subtracting(square)
        let pixels = try render(empty.fill(Color.white), "simple-subtract-self")
        print("Simple subtract self: cgEmpty=\(empty.cgPath.isEmpty), pixels=\(count(pixels))")
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("report.json"))
    }
}
'''
Path(os.environ['VANE_DIAGNOSTIC_SOURCE']).write_text(prefix + source + diagnostic)
