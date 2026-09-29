import SwiftUI
import AppKit
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon or app switcher entry, also when started with `swift run`
        // (the .app bundle from scripts/make-app.sh sets LSUIElement as well).
        NSApp.setActivationPolicy(.accessory)
        if Notifier.isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    /// Show banners even though the app counts as frontmost while its popover is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Clicking a notification opens the PR on GitHub.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let s = response.notification.request.content.userInfo[Notifier.urlKey] as? String,
           let url = URL(string: s), url.scheme == "https", url.host == "github.com" {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}

@main
struct ReviewBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = ReviewViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(vm)
        } label: {
            // One Text: the menu bar may only render the first view of a multi-view label.
            if vm.badgeCount == 0 {
                Image(systemName: "eye")
            } else {
                Text("\(Image(systemName: "eye")) \(vm.badgeCount)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
