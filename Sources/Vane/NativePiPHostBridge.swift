import AppKit
import ObjectiveC

/// Ends the system window's presentation while retaining WebKit's original video.
/// The deferred WebKit close is delivered when our host actually returns the video.
@MainActor enum NativePiPHostBridge {
    private final class Owner {
        weak var session: Session?
        init(_ session: Session) { self.session = session }
    }
    private static var owners: [ObjectIdentifier: Owner] = [:]
    private static var installed = false
    private static let dismissSelector = NSSelectorFromString("dismissViewController:")
    fileprivate typealias Dismiss = @convention(c) (AnyObject, Selector, AnyObject) -> Void
    fileprivate typealias Close = @convention(c) (AnyObject, Selector, @escaping @convention(block) (NSError?) -> Void) -> Void

    private static func install() -> Bool {
        if installed { return true }
        guard let method = class_getInstanceMethod(NSViewController.self, dismissSelector),
              signature(method) == "v24@0:8@16" else { return false }
        let original = unsafeBitCast(method_getImplementation(method), to: Dismiss.self)
        let intercept: @convention(block) (NSViewController, NSViewController) -> Void = { controller, child in
            if Thread.isMainThread {
                let handled = MainActor.assumeIsolated {
                    owners[ObjectIdentifier(controller)]?.session?.interceptDismissal() ?? false
                }
                if handled { return }
            }
            original(controller, dismissSelector, child)
        }
        method_setImplementation(method, imp_implementationWithBlock(intercept))
        installed = true
        return true
    }

    static func session(parent: NSView) -> Session? {
        let closeSelector = NSSelectorFromString("dismissPictureInPictureWithCompletionHandler:")
        guard let controller = parent.nextResponder as? NSViewController,
              NSStringFromClass(type(of: controller)) == "PIPViewController",
              controller.responds(to: NSSelectorFromString("delegate")),
              controller.responds(to: NSSelectorFromString("setDelegate:")),
              let delegate = controller.value(forKey: "delegate") as? NSObject,
              let exit = class_getInstanceMethod(type(of: delegate), NSSelectorFromString("exitPIP")),
              signature(exit) == "v16@0:8",
              let didClose = class_getInstanceMethod(type(of: delegate), NSSelectorFromString("pipDidClose:")),
              signature(didClose) == "v24@0:8@16",
              let close = class_getInstanceMethod(type(of: controller), closeSelector),
              signature(close) == "v24@0:8@?16", install() else { return nil }
        let session = Session(controller: controller, delegate: delegate,
                              close: unsafeBitCast(method_getImplementation(close), to: Close.self))
        owners = owners.filter { $0.value.session != nil }
        owners[ObjectIdentifier(controller)] = Owner(session)
        return session
    }

    private static func signature(_ method: Method) -> String? {
        method_getTypeEncoding(method).map { String(cString: $0) }
    }

    @MainActor final class Session {
        private enum Phase { case live, hiding, hidden, finishing, finished }
        private var phase = Phase.live
        private var initialDismissal = false
        private var requestedExit = false
        private let controller: NSViewController
        private let delegate: NSObject
        private let close: Close
        private var timeout: Task<Void, Never>?
        fileprivate init(controller: NSViewController, delegate: NSObject, close: @escaping Close) {
            self.controller = controller; self.delegate = delegate; self.close = close
        }

        func closeShell(then: @escaping @MainActor (Bool) -> Void) {
            guard phase == .live else { then(false); return }
            phase = .hiding
            // The first close belongs to the system shell. Preserve WebKit's InPIP
            // state until it asks to dismiss our retained video presentation later.
            controller.setValue(nil, forKey: "delegate")
            timeout = Task { @MainActor [self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled, phase == .hiding else { return }
                finishHiding(ok: false, then: then)
            }
            close(controller, NSSelectorFromString("dismissPictureInPictureWithCompletionHandler:")) { [self] error in
                Task { @MainActor [self] in
                    guard phase == .hiding else { return }
                    finishHiding(ok: error == nil, then: then)
                }
            }
        }

        private func finishHiding(ok: Bool, then: @escaping @MainActor (Bool) -> Void) {
            timeout?.cancel(); timeout = nil
            phase = .hidden
            then(ok)
            if requestedExit { completeExit() }
            else if !ok { endPresentation() }
        }

        fileprivate func interceptDismissal() -> Bool {
            if phase == .hiding && !initialDismissal {
                initialDismissal = true
                return false
            }
            guard phase != .live else { return false }
            requestedExit = true
            if phase == .hidden { completeExit() }
            return true
        }

        func endPresentation() {
            guard phase == .hidden || phase == .hiding else { return }
            // Uses WebKit's own exit-state transition before its deferred did-close.
            _ = delegate.perform(NSSelectorFromString("exitPIP"))
        }

        private func completeExit() {
            guard phase == .hidden else { return }
            phase = .finishing
            // exitPIP marks itself ExitingPIP after requesting dismissal. Match native
            // callback ordering so returning to the tab preserves playing state.
            Task { @MainActor [self] in
                _ = delegate.perform(NSSelectorFromString("pipDidClose:"), with: controller)
                phase = .finished
            }
        }
    }
}
