import Foundation
import ObjectiveC
import WebKit
@testable import vane

/// A single real explicit-fill reply, held between WebKit execution and its
/// native consumer. This helper is linked only into the XCTest bundle.
@MainActor final class PasswordFillCompletionHold {
    private typealias Reply = @convention(block) (AnyObject?, NSError?) -> Void
    private typealias Evaluate = @convention(c) (WKWebView, Selector, NSString, WKFrameInfo?, WKContentWorld, Reply?) -> Void
    private typealias Intercept = @convention(block) (WKWebView, NSString, WKFrameInfo?, WKContentWorld, Reply?) -> Void
    enum Failure: Error { case unavailableABI, alreadyOwned, ownershipChanged, duplicateCall, invalidReply, inFlight }

    private static weak var owner: PasswordFillCompletionHold?
    private static let selector = NSSelectorFromString("evaluateJavaScript:inFrame:inContentWorld:completionHandler:")
    private let method: Method
    private let original: IMP
    private weak var web: WKWebView?
    private let script: String
    private let world: WKContentWorld
    private var trampoline: IMP?
    private var installed = false
    private var active = true
    private var invocationDepth = 0
    private var pending = 0
    private var held: (Reply, AnyObject?, NSError?)?
    private var failure: Failure?
    private(set) var matchedCalls = 0
    private(set) var capturedReplies = 0
    private(set) var deliveredReplies = 0
    private(set) var restored = false
    var isHoldingReply: Bool { held != nil }
    var pendingReplies: Int { pending }

    init(web: WKWebView, script: String, world: WKContentWorld = Autofill.world) throws {
        guard Self.owner == nil else { throw Failure.alreadyOwned }
        guard let method = class_getInstanceMethod(WKWebView.self, Self.selector),
              let encoding = method_getTypeEncoding(method),
              String(cString: encoding) == "v48@0:8@16@24@32@?40" else { throw Failure.unavailableABI }
        self.method = method
        original = method_getImplementation(method)
        self.web = web
        self.script = script
        self.world = world
        let originalCall = unsafeBitCast(original, to: Evaluate.self)
        let selector = Self.selector
        let intercept: Intercept = { [weak self] receiver, source, frame, world, completion in
            // The public SDK method is UI-actor isolated. Preserve any unrelated
            // off-main call unchanged rather than assuming actor isolation for it.
            if Thread.isMainThread {
                let forwarded = MainActor.assumeIsolated {
                    self?.evaluate(receiver, source: source, frame: frame, world: world,
                                   completion: completion, originalCall: originalCall) ?? false
                }
                if forwarded { return }
            }
            originalCall(receiver, selector, source, frame, world, completion)
        }
        let replacement = imp_implementationWithBlock(intercept)
        trampoline = replacement
        Self.owner = self
        method_setImplementation(method, replacement)
        installed = true
    }

    private func evaluate(_ receiver: WKWebView, source: NSString, frame: WKFrameInfo?,
                          world: WKContentWorld, completion: Reply?, originalCall: Evaluate) -> Bool {
        invocationDepth += 1
        defer { invocationDepth -= 1 }
        guard active, receiver === web, source as String == script, frame == nil,
              world === self.world, let completion else {
            originalCall(receiver, Self.selector, source, frame, world, completion)
            return true
        }
        matchedCalls += 1
        guard matchedCalls == 1 else {
            failure = .duplicateCall
            originalCall(receiver, Self.selector, source, frame, world, completion)
            return true
        }
        pending += 1
        let reply: Reply = { [self] value, error in
            MainActor.assumeIsolated {
                pending -= 1
                guard active, error == nil, value as? Bool == true else {
                    if active { failure = .invalidReply }
                    deliveredReplies += 1
                    completion(value, error)
                    return
                }
                capturedReplies += 1
                held = (completion, value, error)
            }
        }
        originalCall(receiver, Self.selector, source, frame, world, reply)
        return true
    }

    func check() throws { if let failure { throw failure } }

    func release() {
        // Clear before invoking client code: it can reenter release/close.
        guard let reply = held else { return }
        held = nil
        deliveredReplies += 1
        reply.0(reply.1, reply.2)
    }

    func close() throws {
        active = false
        if installed {
            guard Self.owner === self, let trampoline,
                  method_getImplementation(method) == trampoline else {
                release()
                throw Failure.ownershipChanged
            }
            method_setImplementation(method, original)
            installed = false
            restored = true
            Self.owner = nil
        }
        release()
    }

    /// Dispose outside any SDK invocation/reply. Restoring and releasing are
    /// separate so a consumer can safely close reentrantly inside its reply.
    func dispose() throws {
        guard !active, !installed, pending == 0, held == nil, invocationDepth == 0 else {
            throw Failure.inFlight
        }
        if let trampoline {
            imp_removeBlock(trampoline)
            self.trampoline = nil
        }
    }
}
