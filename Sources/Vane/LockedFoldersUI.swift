import SwiftUI
import CoreImage.CIFilterBuiltins
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// Only a frozen, heavily obscured image is drawn behind the unlock control. The live
/// WebView has already been released, so it cannot receive clicks, focus, or accessibility.
struct LockedFolderPage: View {
    @EnvironmentObject var store: TabStore
    let folder: Folder
    @StateObject private var control = FolderUnlockControl()
    @State private var usingPassword = false
    @AppStorage(FolderUnlockMethod.key, store: UserDefaults.vane) private var method = FolderUnlockMethod.touchID
    private var hasTouchID: Bool {
        control.context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    private var usesInline: Bool { method == .touchID && hasTouchID }

    var body: some View {
        ZStack {
            Color(nsColor: Look.pageGround)
            if let image = store.lockedFolderBackdrop {
                Image(nsImage: image).resizable().scaledToFill()
                    .blur(radius: 28, opaque: true)
                    .overlay(Color(nsColor: Look.pageGround).opacity(0.35))
                    .accessibilityHidden(true)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 0) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Look.inkSecondary)
                    .accessibilityHidden(true)
                    .padding(.bottom, 22)
                Text(folder.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(2)
                Text("Unlock this folder to see its tabs.")
                    .font(.system(size: 12))
                    .foregroundStyle(Look.inkSecondary)
                    .padding(.top, 6)
                    .padding(.bottom, 24)
                InlineUnlockButton(
                    context: control.context, inline: usesInline, authenticating: control.authenticating,
                    title: control.authenticating ? (usingPassword ? "Unlocking…" : "Touch the Touch ID sensor")
                        : (usesInline ? "Unlock with Touch ID" : "Unlock folder…"),
                    attached: {
                        if control.beginAutomaticUnlock(for: folder.id, usingInline: usesInline) {
                            unlock(password: false)
                        }
                    }
                ) { unlock(password: !usesInline) }
                HStack(spacing: 16) {
                    if usesInline {
                        Button("More unlock options…") {
                            if control.authenticating {
                                // Retire the pending scan without dismissing the sidebar request.
                                store.folderAuthentication.lock(folder.id, profile: store.profileID)
                                control.cancel()
                            }
                            unlock(password: true)
                        }
                            .help("Opens macOS authentication, where you can use your Mac login password.")
                            .disabled(control.authenticating && usingPassword)
                    }
                    if store.folderUnlockRequest != nil {
                        Button("Cancel") { store.cancelFolderUnlock(); control.cancel() }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11))
                .foregroundStyle(Look.inkSecondary)
                .padding(.top, 14)
                if !usesInline {
                    Text("Use your Mac login password.")
                        .font(.system(size: 11)).foregroundStyle(Look.inkSecondary)
                        .padding(.top, 8)
                }
                if control.failed {
                    Text("Couldn’t unlock. Please try again.")
                        .font(.system(size: 11)).foregroundStyle(Look.inkSecondary)
                        .padding(.top, 12).transition(.opacity)
                }
            }
            .multilineTextAlignment(.center)
            .padding(32)
            .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityElement(children: .contain)
        .onChange(of: folder.id) { control.cancel() }
        .onDisappear {
            control.cancel(leavingPage: true)
            store.cancelFolderUnlock()
        }
    }

    private func unlock(password: Bool) {
        usingPassword = password
        control.authenticating = true
        control.failed = false
        let attemptedContext = control.context
        if store.folderUnlockRequest == nil, !store.usesInlineFolderUnlock {
            store.unlockFolder(folder.id) { success in finish(success, from: attemptedContext) }
            return
        }
        if store.folderUnlockRequest == nil { store.unlockFolder(folder.id) }
        let authenticate: FolderAuthentication.Authenticator
        if password {
            // A new, unattached context deliberately permits the macOS password dialog.
            authenticate = store.folderAuthentication.systemAuthenticator
        } else {
            let embedded = control.context
            authenticate = { reason, reply in
                let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
                guard embedded.canEvaluatePolicy(policy, error: nil) else { reply(false); return nil }
                embedded.evaluatePolicy(policy, localizedReason: reason) { success, _ in
                    Task { @MainActor in reply(success) }
                }
                return embedded
            }
        }
        store.runFolderUnlock(using: authenticate) { success in finish(success, from: attemptedContext) }
    }

    private func finish(_ success: Bool, from attemptedContext: LAContext) {
        guard control.context === attemptedContext else { return }
        Motion.list { control.finish(success, from: attemptedContext) }
        if success, let current = store.current { store.current = current }
    }
}

/// A successful LAContext can reuse its credential. Retire it after each attempt so a
/// nested lock screen that remains mounted cannot unlock again with an old fingerprint.
@MainActor final class FolderUnlockControl: ObservableObject {
    @Published var context = LAContext()
    @Published var authenticating = false
    @Published var failed = false
    private var automaticFolder: UUID?

    /// Context replacement reattaches the embedded view. Only a new folder may auto-start;
    /// a failure or cancellation on the same page must not cause a retry loop.
    func beginAutomaticUnlock(for folder: UUID, usingInline: Bool) -> Bool {
        guard usingInline, !authenticating, automaticFolder != folder else { return false }
        automaticFolder = folder
        authenticating = true
        failed = false
        return true
    }

    func finish(_ success: Bool, from attemptedContext: LAContext) {
        guard context === attemptedContext else { return }
        finish(success)
    }

    func finish(_ success: Bool) {
        cancel()
        failed = !success
    }

    func cancel(leavingPage: Bool = false) {
        context.invalidate()
        context = LAContext()
        authenticating = false
        failed = false
        if leavingPage { automaticFolder = nil }
    }
}

/// The unlock pill shared by locked folders and Settings → Passwords. With `inline`, the
/// embedded LocalAuthentication view sits under a fingerprint glyph inside it, so the scan
/// runs in the page rather than in a system sheet; `attached` runs once that view (for each
/// context) is attached, which is the earliest an embedded evaluation stays inline.
struct InlineUnlockButton: View {
    @Environment(\.spaceChromeTheme) private var chromeTheme
    let context: LAContext
    let inline: Bool
    let authenticating: Bool
    let title: String
    var attached: () -> Void = {}
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if inline {
                    ZStack {
                        EmbeddedFolderAuthentication(context: context, attached: attached)
                            .id(ObjectIdentifier(context))
                        // Apple's Touch ID red, as in the system's own prompt.
                        Image(systemName: "touchid")
                            .font(.system(size: 25, weight: .light))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .opacity(authenticating ? 0 : 1)
                    }
                    .frame(width: 28, height: 28)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                } else {
                    Image(systemName: "key.fill").font(.system(size: 13))
                        .task { attached() }
                }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(chromeTheme.pillFill, in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Look.inkTertiary.opacity(0.15))
            }
        }
        .buttonStyle(.plain)
        .disabled(authenticating)
        .animation(Motion.reduced ? nil : Look.quick, value: authenticating)
    }
}

/// The context is attached before `attached` evaluates it, keeping biometric UI inline.
/// The LAAuthenticationView is only made while the control is in a window: a copy SwiftUI
/// keeps alive off screen would otherwise take the shared context, and LocalAuthentication
/// pauses a scan whose view is not visible — Touch ID then never answers.
private struct EmbeddedFolderAuthentication: NSViewRepresentable {
    let context: LAContext
    let attached: () -> Void
    func makeNSView(context: Context) -> Host { Host(context: self.context, attached: attached) }
    func updateNSView(_ view: Host, context: Context) { view.attached = attached }

    final class Host: NSView {
        let laContext: LAContext
        var attached: () -> Void
        private var auth: LAAuthenticationView?
        init(context: LAContext, attached: @escaping () -> Void) {
            laContext = context
            self.attached = attached
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil, auth == nil else { return }
            let view = LAAuthenticationView(context: laContext, controlSize: .small)
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
            auth = view
            // After the view holds the context, as the old appearance task did; a turn later
            // so SwiftUI is not mid-update when the evaluation publishes.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.attached()
            }
        }
    }
}

@MainActor enum LockedFolderBackdrop {
    /// Downsample before blurring so text is never retained at readable resolution.
    static func capture(_ tab: Tab) -> NSImage? {
        let source: NSImage?
        if let snapshot = tab.windowSnapshot {
            source = snapshot
        } else if let web = tab.existingWeb, !web.bounds.isEmpty,
                  let bitmap = web.bitmapImageRepForCachingDisplay(in: web.bounds) {
            web.cacheDisplay(in: web.bounds, to: bitmap)
            let image = NSImage(size: web.bounds.size)
            image.addRepresentation(bitmap)
            source = image
        } else {
            source = nil
        }
        guard let source, source.size.width > 0, source.size.height > 0 else { return nil }
        let size = NSSize(width: 32, height: max(1, 32 * source.size.height / source.size.width))
        let small = RasterImage.make(size: size) { bounds in source.draw(in: bounds) }
        guard let data = small?.tiffRepresentation, let input = CIImage(data: data) else { return nil }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 3
        guard let output = blur.outputImage?.cropped(to: input.extent),
              let cg = CIContext.vane.createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cg, size: source.size)
    }
}
