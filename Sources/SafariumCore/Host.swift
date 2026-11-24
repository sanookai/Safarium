import AppKit

public enum HostApp {
    /// Makes this process a windowless, focus-less background app. Call once on the main thread before creating a `Page`.
    /// `.prohibited` = no Dock icon, no menu bar, can never become frontmost, so it never steals focus.
    @MainActor public static func prepare() {
        let app = NSApplication.shared
        if app.activationPolicy() != .prohibited { app.setActivationPolicy(.prohibited) }
    }
}
