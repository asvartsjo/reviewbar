import SwiftUI

@main
struct ReviewBarApp: App {
    @StateObject private var vm = ReviewViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(vm)
        } label: {
            // One Text: the menu bar may only render the first view of a multi-view label.
            if vm.prs.isEmpty {
                Image(systemName: "eye")
            } else {
                Text("\(Image(systemName: "eye")) \(vm.prs.count)")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
