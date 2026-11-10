import AppKit
import QuartzCore

/// The cutout and outline share one short transition. Selection geometry remains
/// immediate; only the presentation paths glide, so clicks never capture an in-between frame.
@MainActor final class CaptureSelectionLayers {
    static let transitionKey = "capture-selection-path"
    let dimming = CAShapeLayer()
    let outline = CAShapeLayer()
    private(set) var target: CGRect?
    private var viewport = CGRect.zero

    init() {
        dimming.fillColor = NSColor.black.withAlphaComponent(0.36).cgColor
        dimming.fillRule = .evenOdd
        outline.fillColor = nil
        outline.strokeColor = NSColor.controlAccentColor.cgColor
        outline.lineWidth = 3
        outline.opacity = 0
    }

    func mount(in layer: CALayer) {
        layer.addSublayer(dimming)
        layer.addSublayer(outline)
    }

    func update(_ region: CGRect?, in bounds: CGRect, animated: Bool) {
        guard target != region || viewport != bounds else { return }
        let fromOutline = visiblePath(outline)
        let fromMask = visiblePath(dimming)
        let transition = animated && target != nil && region != nil && viewport == bounds
        let local = region?.offsetBy(dx: -bounds.minX, dy: -bounds.minY)
        let mask = CGMutablePath()
        mask.addRect(CGRect(origin: .zero, size: bounds.size))
        if let local { mask.addPath(rounded(local, radius: 8)) }
        let border = local.map { rounded($0.insetBy(dx: -0.5, dy: -0.5), radius: 8.5) }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        settle()
        dimming.frame = bounds
        outline.frame = bounds
        dimming.path = mask
        outline.path = border
        outline.opacity = region == nil ? 0 : 1
        target = region
        viewport = bounds
        if transition, let fromOutline, let fromMask, let border {
            animate(outline, from: fromOutline, to: border)
            animate(dimming, from: fromMask, to: mask)
        }
        CATransaction.commit()
    }

    /// A drag or a policy change takes effect immediately, including mid-transition.
    func settle() {
        outline.removeAnimation(forKey: Self.transitionKey)
        dimming.removeAnimation(forKey: Self.transitionKey)
    }

    private func visiblePath(_ layer: CAShapeLayer) -> CGPath? {
        if let path = layer.presentation()?.path { return path }
        // Before the first CA commit, the model already names the old destination.
        // Reuse its pending start so another pointer event cannot jump to that destination.
        if let animation = layer.animation(forKey: Self.transitionKey) as? CABasicAnimation,
           let start = animation.fromValue { return (start as! CGPath) }
        return layer.path
    }

    private func animate(_ layer: CAShapeLayer, from start: CGPath, to end: CGPath) {
        let animation = CABasicAnimation(keyPath: "path")
        animation.fromValue = start
        animation.toValue = end
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        layer.add(animation, forKey: Self.transitionKey)
    }

    private func rounded(_ rect: CGRect, radius: CGFloat) -> CGPath {
        CGPath(roundedRect: rect, cornerWidth: min(radius, rect.width / 2),
               cornerHeight: min(radius, rect.height / 2), transform: nil)
    }
}
