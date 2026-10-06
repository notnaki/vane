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
    private var hasTouchID: Bool {
        control.context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

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
                HStack(spacing: 10) {
                    if hasTouchID {
                        EmbeddedFolderAuthentication(context: control.context)
                            .id(ObjectIdentifier(control.context))
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "key.fill").font(.system(size: 13))
                    }
                    Button(control.authenticating ? "Unlocking…" : (hasTouchID ? "Unlock with Touch ID" : "Unlock folder…")) {
                        unlock(password: !hasTouchID)
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .disabled(control.authenticating)
                }
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Look.pillFill, in: .rect(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(Look.inkTertiary.opacity(0.15))
                }
                HStack(spacing: 16) {
                    if hasTouchID {
                        Button("More unlock options…") { unlock(password: true) }
                            .help("Opens macOS authentication, where you can use your Mac login password.")
                            .disabled(control.authenticating)
                    }
                    if store.folderUnlockRequest != nil {
                        Button("Cancel") { store.cancelFolderUnlock(); control.cancel() }
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11))
                .foregroundStyle(Look.inkSecondary)
                .padding(.top, 14)
                if !hasTouchID {
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
        .onDisappear {
            control.context.invalidate()
            store.cancelFolderUnlock()
        }
    }

    private func unlock(password: Bool) {
        if store.folderUnlockRequest == nil { store.unlockFolder(folder.id) }
        control.authenticating = true
        control.failed = false
        let authenticate: FolderAuthentication.Authenticator
        if password {
            // A new, unattached context deliberately permits the macOS password dialog.
            authenticate = FolderAuthentication.systemAuthentication
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
        store.runFolderUnlock(using: authenticate) { success in
            Motion.list { control.finish(success) }
            if success, let current = store.current { store.current = current }
        }
    }
}

/// A successful LAContext can reuse its credential. Retire it after each attempt so a
/// nested lock screen that remains mounted cannot unlock again with an old fingerprint.
@MainActor final class FolderUnlockControl: ObservableObject {
    @Published var context = LAContext()
    @Published var authenticating = false
    @Published var failed = false

    func finish(_ success: Bool) {
        cancel()
        failed = !success
    }

    func cancel() {
        context.invalidate()
        context = LAContext()
        authenticating = false
        failed = false
    }
}

/// The context is attached before the button can evaluate it, keeping biometric UI inline.
private struct EmbeddedFolderAuthentication: NSViewRepresentable {
    let context: LAContext
    func makeNSView(context: Context) -> LAAuthenticationView {
        LAAuthenticationView(context: self.context, controlSize: .small)
    }
    func updateNSView(_ view: LAAuthenticationView, context: Context) {}
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
        let small = NSImage(size: size)
        small.lockFocus()
        source.draw(in: NSRect(origin: .zero, size: size))
        small.unlockFocus()
        guard let data = small.tiffRepresentation, let input = CIImage(data: data) else { return nil }
        let blur = CIFilter.gaussianBlur()
        blur.inputImage = input.clampedToExtent()
        blur.radius = 3
        guard let output = blur.outputImage?.cropped(to: input.extent),
              let cg = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: cg, size: source.size)
    }
}
