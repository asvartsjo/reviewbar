import SwiftUI

@main
struct ReviewBarApp: App {
    @StateObject private var vm = ReviewViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(vm)
        } label: {
            Image(systemName: "eye")
            if !vm.prs.isEmpty { Text("\(vm.prs.count)") }
        }
        .menuBarExtraStyle(.window)
    }
}
