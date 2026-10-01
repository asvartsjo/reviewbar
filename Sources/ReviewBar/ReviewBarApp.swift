import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { menuBar = MenuBarController(vm: ReviewViewModel.shared) }
        // Menu bar only: no Dock icon or app switcher entry, also when started with `swift run`
        // (the .app bundle from scripts/make-app.sh sets LSUIElement as well).
        NSApp.setActivationPolicy(.accessory)
        if Notifier.isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    /// reviewbar:// links from review pages opened in the browser.
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { urls.forEach(ReviewViewModel.shared.handle) }
    }

    // The notification delegate methods are nonisolated: macOS may call them off the main thread.

    /// Show banners even though the app counts as frontmost while its popover is open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking a notification opens the PR on GitHub.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo[Notifier.urlKey] as? String,
           let url = URL(string: s), url.scheme == "https", url.host == "github.com" {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
    }
}

@main
struct ReviewBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    // The menu bar icon and panel live in MenuBarController; an App needs at least one scene.
    // A hidden MenuBarExtra has no window; an empty Settings scene opens as a blank window at
    // launch on newer macOS.
    var body: some Scene {
        MenuBarExtra("ReviewBar", systemImage: "eye", isInserted: .constant(false)) { EmptyView() }
    }
}

/// One pre-rendered template image: an SF Symbol inside a Text label can vanish after the
/// menu bar re-renders, leaving only the number.
enum MenuBarIcon {
    static func image(count: Int) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        let eye = NSImage(systemSymbolName: "eye", accessibilityDescription: "ReviewBar")?
            .withSymbolConfiguration(config) ?? NSImage()
        guard count > 0 else { eye.isTemplate = true; return eye }
        let text = NSAttributedString(string: " \(count)", attributes: [
            .font: NSFont.menuBarFont(ofSize: 0), .foregroundColor: NSColor.black,
        ])
        let textSize = text.size()
        let height = max(eye.size.height, textSize.height)
        let size = NSSize(width: ceil(eye.size.width + textSize.width), height: ceil(height))
        let image = NSImage(size: size, flipped: false) { _ in
            eye.draw(in: NSRect(x: 0, y: (height - eye.size.height) / 2,
                                width: eye.size.width, height: eye.size.height))
            text.draw(at: NSPoint(x: eye.size.width, y: (height - textSize.height) / 2))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "ReviewBar, \(count) to review"
        return image
    }
}
