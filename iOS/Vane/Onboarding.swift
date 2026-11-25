import SwiftUI

/// First launch: three short pages on the Space's wash. Nothing here is required: sync and
/// the default browser can each be skipped and found again in Settings.
struct Onboarding: View {
    @Environment(Sync.self) private var sync
    let done: () -> Void
    @State private var page = 0

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $page) {
                card(tag: 0, symbol: nil, title: "Welcome to Vane",
                     text: "Your Spaces, favourites and pinned tabs, on your iPhone. Slide along the bar to move between Spaces; it shrinks away while you read.")
                card(tag: 1, symbol: "icloud", title: "Bring your Mac along",
                     text: sync.available
                        ? "Sync Spaces, favourites, pinned tabs, bookmarks and open tabs through your own iCloud. Nothing goes anywhere else."
                        : "Sign in to iCloud in Settings to sync your Spaces with Vane on your Mac. You can turn it on later in Vane's Settings.")
                card(tag: 2, symbol: "safari", title: "Open links in Vane",
                     text: "Choose Vane as your default browser and links from other apps open here. You can change it any time in Settings.")
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .indexViewStyle(.page(backgroundDisplayMode: .interactive))

            VStack(spacing: 10) {
                Button(action: primary) {
                    Text(primaryTitle).fontWeight(.semibold).frame(maxWidth: .infinity).frame(height: 50)
                        .background(GroundFill(strength: 2.2), in: RoundedRectangle(cornerRadius: Look.pillRadius, style: .continuous))
                }
                .buttonStyle(PressFill())
                Button("Not Now", action: next)
                    .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).frame(height: 32)
                    .opacity(skippable ? 1 : 0).allowsHitTesting(skippable)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)
        }
        .background(Wash(space: nil))
        .animation(.smooth, value: page)
    }

    private var skippable: Bool { page == 2 || (page == 1 && sync.available) }

    private var primaryTitle: String {
        switch page {
        case 0: "Continue"
        case 1: sync.available ? "Turn On iCloud Sync" : "Continue"
        default: "Open Settings"
        }
    }

    private func primary() {
        switch page {
        case 1 where sync.available:
            sync.enabled = true
            Task { await sync.run() }
            next()
        case 2:
            // Vane's page in Settings, where "Default Browser App" lives once Apple grants the entitlement.
            if let url = URL(string: UIApplication.openDefaultApplicationsSettingsURLString) { UIApplication.shared.open(url) }
            done()
        default: next()
        }
    }

    private func next() { if page < 2 { page += 1 } else { done() } }

    private func card(tag: Int, symbol: String?, title: String, text: String) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Group {
                if let symbol { Image(systemName: symbol).font(.system(size: 54, weight: .light)) }
                else { Image("Preview-AppIcon").resizable().frame(width: 96, height: 96).clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)) }
            }
            .frame(height: 100)
            Text(title).font(.largeTitle.weight(.semibold)).multilineTextAlignment(.center)
            Text(text).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
            Spacer(); Spacer()
        }
        .padding(.horizontal, 32)
        .tag(tag)
    }
}
