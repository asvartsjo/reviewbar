import SwiftUI
import AppKit

/// Menu bar only: no Dock icon or app switcher entry, also when started with `swift run`
/// (the .app bundle from scripts/make-app.sh sets LSUIElement as well).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
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
