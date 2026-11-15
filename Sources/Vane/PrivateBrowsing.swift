import Foundation

/// All private stores participate, including Little Vane, Peek and popup windows.
/// The store registry calls this only when its last private context is removed.
@MainActor enum PrivateBrowsing {
    static func endSession() {
        DownloadLibrary.endPrivateSession()
        TidyTitles.forget(Profile.incognito.id)
        DeveloperMode.clearPrivateState()
        WebsiteDataWindow.closePrivate()
    }
}
