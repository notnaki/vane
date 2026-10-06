import AppKit
import ObjectiveC
import WebKit

/// Hosts WebKit's live video before the system window is presented when supported.
/// The deferred WebKit close is delivered when our host actually returns the video.
@MainActor enum NativePiPHostBridge {
    private final class Owner {
        weak var session: Session?
        init(_ session: Session) { self.session = session }
    }
    private static var owners: [ObjectIdentifier: Owner] = [:]
    private static var installed = false
    private static var entryInstalled = false
    private final class Source {
        weak var tab: Tab?
        weak var web: WKWebView?
        init(tab: Tab, web: WKWebView) { self.tab = tab; self.web = web }
    }
    private static var sources: [UUID: Source] = [:]
    private static var captures: [UUID: DirectCapture] = [:]
    private typealias Present = @convention(c) (AnyObject, Selector, NSViewController) -> Void

    @MainActor final class DirectCapture {
        weak var web: WKWebView?
        let parent: NSView
        let video: NSView
        let originalFrame: NSRect
        let frame: NSRect
        let sourceFrame: NSRect
        let session: Session
        fileprivate var ready = false
        init(web: WKWebView, parent: NSView, video: NSView, frame: NSRect, sourceFrame: NSRect, session: Session) {
            self.web = web; self.parent = parent; self.video = video
            self.originalFrame = video.frame; self.frame = frame; self.sourceFrame = sourceFrame; self.session = session
        }
    }

    static func register(tab: Tab, web: WKWebView) {
        sources = sources.filter { $0.value.tab != nil && $0.value.web != nil }
        if captures[tab.id]?.web !== web { cancel(for: tab.id) }
        sources[tab.id] = Source(tab: tab, web: web)
        installEntry()
    }

    static func cancel(for id: UUID) {
        captures.removeValue(forKey: id)?.session.endPresentation()
    }

    static func claim(for tab: Tab) -> DirectCapture? {
        guard let capture = captures[tab.id], capture.ready else { return nil }
        captures[tab.id] = nil
        guard capture.web === tab.existingWeb, tab.pictureInPicture else {
            capture.session.endPresentation()
            return nil
        }
        return capture
    }

    private static func installEntry() {
        guard !entryInstalled else { return }
        if NSClassFromString("PIPViewController") == nil {
            _ = Bundle(path: "/System/Library/PrivateFrameworks/PIP.framework")?.load()
        }
        let selector = NSSelectorFromString("presentViewControllerAsPictureInPicture:")
        guard let type = NSClassFromString("PIPViewController"),
              let method = class_getInstanceMethod(type, selector), signature(method) == "v24@0:8@16",
              install() else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: Present.self)
        let intercept: @convention(block) (NSViewController, NSViewController) -> Void = { controller, child in
            if Thread.isMainThread {
                let handled = MainActor.assumeIsolated { capture(controller: controller, child: child) }
                if handled { return }
            }
            original(controller, selector, child)
        }
        method_setImplementation(method, imp_implementationWithBlock(intercept))
        entryInstalled = true
    }

    private static func capture(controller: NSViewController, child: NSViewController) -> Bool {
        let video = child.view
        guard NSStringFromClass(type(of: video)) == "WebVideoViewContainer", video.layer != nil,
              let parent = video.superview, let window = video.window, parent === window.contentView,
              let delegate = validatedDelegate(controller),
              let getter = class_getInstanceMethod(type(of: video), NSSelectorFromString("videoViewContainerDelegate")),
              signature(getter) == "@16@0:8",
              video.value(forKey: "videoViewContainerDelegate") as? NSObject === delegate,
              let resize = class_getInstanceMethod(type(of: video), NSSelectorFromString("resizeWithOldSuperviewSize:")),
              let baseResize = class_getInstanceMethod(NSView.self, NSSelectorFromString("resizeWithOldSuperviewSize:")),
              signature(resize) == signature(baseResize),
              method_getImplementation(resize) != method_getImplementation(baseResize),
              let boundsChanged = class_getInstanceMethod(type(of: delegate), NSSelectorFromString("boundsDidChangeForVideoViewContainer:")),
              signature(boundsChanged) == "v24@0:8@16" else { return false }
        // Visible split views can share a window. Only consume a presentation whose
        // inline rectangle identifies one registered source; ambiguous hosts stay native.
        // WebKit passes rootViewToWindow's rectangle unchanged to this container.
        // Its frame is already in window coordinates, even under a flipped host.
        let rect = video.frame
        let candidates = sources.values.filter {
            guard let tab = $0.tab, let web = $0.web, tab.existingWeb === web, web.window === window else { return false }
            return web.convert(web.bounds, to: nil).contains(NSPoint(x: rect.midX, y: rect.midY))
        }
        guard candidates.count == 1, let source = candidates.first, let tab = source.tab, let web = source.web,
              captures[tab.id] == nil else { return false }
        let sourceFrame = window.convertToScreen(rect)
        var frame = sourceFrame
        guard frame.width > 0, frame.height > 0,
              [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy({ $0.isFinite }),
              let aspectGetter = class_getInstanceMethod(type(of: controller), NSSelectorFromString("aspectRatio")),
              signature(aspectGetter) == "{CGSize=dd}16@0:8",
              let aspect = (controller.value(forKey: "aspectRatio") as? NSValue)?.sizeValue,
              aspect.width.isFinite, aspect.height.isFinite, aspect.width > 0, aspect.height > 0 else { return false }
        // The page can crop or stretch its inline CSS box. PiP keeps the actual
        // media aspect ratio WebKit supplied to the native controller.
        let top = frame.maxY
        frame.size.height = frame.width * aspect.height / aspect.width
        frame.origin.y = top - frame.height
        guard frame.height.isFinite, frame.origin.y.isFinite else { return false }
        let session = Session(controller: controller, delegate: delegate, close: nil)
        owners = owners.filter { $0.value.session != nil }
        owners[ObjectIdentifier(controller)] = Owner(session)
        let capture = DirectCapture(web: web, parent: parent, video: video, frame: frame, sourceFrame: sourceFrame, session: session)
        captures[tab.id] = capture
        Task { @MainActor [weak tab, weak web] in
            // WebKit sets EnteringPIP after this intercepted call returns. Its normal
            // resize callback then acknowledges entry without presenting PIPAgent.
            guard let tab, let web, tab.existingWeb === web, captures[tab.id] === capture,
                  controller.value(forKey: "delegate") as? NSObject === delegate else {
                if let tab, captures[tab.id] === capture { captures[tab.id] = nil }
                session.endPresentation()
                return
            }
            video.resize(withOldSuperviewSize: parent.bounds.size)
            controller.setValue(nil, forKey: "delegate")
            capture.ready = true
            try? await Task.sleep(for: .seconds(3))
            if captures[tab.id] === capture {
                captures[tab.id] = nil
                session.endPresentation()
            }
        }
        return true
    }

    private static func validatedDelegate(_ controller: NSViewController) -> NSObject? {
        guard NSStringFromClass(type(of: controller)) == "PIPViewController",
              controller.responds(to: NSSelectorFromString("delegate")),
              controller.responds(to: NSSelectorFromString("setDelegate:")),
              let delegate = controller.value(forKey: "delegate") as? NSObject,
              let exit = class_getInstanceMethod(type(of: delegate), NSSelectorFromString("exitPIP")),
              signature(exit) == "v16@0:8",
              let didClose = class_getInstanceMethod(type(of: delegate), NSSelectorFromString("pipDidClose:")),
              signature(didClose) == "v24@0:8@16" else { return nil }
        return delegate
    }
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
              let delegate = validatedDelegate(controller),
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
        private let close: Close?
        private var timeout: Task<Void, Never>?
        var returnAnimation: (@MainActor (NSRect?, NSWindow?, @escaping @MainActor () -> Void) -> Void)?
        var isExiting: Bool { requestedExit || phase == .finishing || phase == .finished }
        fileprivate init(controller: NSViewController, delegate: NSObject, close: Close?) {
            self.controller = controller; self.delegate = delegate; self.close = close
            if close == nil { phase = .hidden }
        }

        func closeShell(then: @escaping @MainActor (Bool) -> Void) {
            if close == nil, phase == .hidden { then(true); return }
            guard phase == .live, let close else { then(false); return }
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
                let finish: @MainActor () -> Void = { [self] in
                    guard phase == .finishing else { return }
                    _ = delegate.perform(NSSelectorFromString("pipDidClose:"), with: controller)
                    phase = .finished
                }
                let animation = returnAnimation
                returnAnimation = nil
                if let animation {
                    // WebKit computes this rectangle at exit, including iframe offsets,
                    // scrolling and the current browser-window position. Validate the
                    // private getters before touching their values on a different OS.
                    let rectGetter = class_getInstanceMethod(type(of: controller), NSSelectorFromString("replacementRect"))
                    let windowGetter = class_getInstanceMethod(type(of: controller), NSSelectorFromString("replacementWindow"))
                    let valid = rectGetter.map(signature) == "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8"
                        && windowGetter.map(signature) == "@16@0:8"
                    let rect = valid ? (controller.value(forKey: "replacementRect") as? NSValue)?.rectValue : nil
                    let window = valid ? controller.value(forKey: "replacementWindow") as? NSWindow : nil
                    animation(rect, window, finish)
                } else { finish() }
            }
        }
    }
}
