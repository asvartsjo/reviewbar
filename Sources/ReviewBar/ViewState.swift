import SwiftUI

/// SwiftUI's `State` property wrapper under another name. From the macOS 27 SDK, `@State`
/// resolves to a macro whose plugin ships only with Xcode, so it doesn't compile with just the
/// Command Line Tools. A typealias can't name the macro, so `@ViewState` is always the wrapper.
typealias ViewState = SwiftUI.State
