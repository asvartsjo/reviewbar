import SwiftUI
import AppKit
import Combine

/// Keeps the panel open when you click elsewhere; it then closes with the icon or Esc.
enum StayOpen {
    static let key = "stayOpen"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
}

/// Opens a normal, movable and resizable window instead of the popup; it stays open until closed.
enum AsWindow {
    static let key = "openAsWindow"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }
    /// The popup's fixed size, and the window's smallest.
    static let minimumSize = NSSize(width: 480, height: 580)
}

/// The menu bar icon and its panel, in AppKit rather than SwiftUI's MenuBarExtra, which always
/// opens at the icon's left edge and draws the panel as translucent glass.
/// One view is moved between the popup and the window, so switching keeps what's on screen.
@MainActor
final class MenuBarController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let host: NSView
    private let panel: Panel
    private var window: NSWindow?
    private var watch: AnyCancellable?
    private var resignObserver: NSObjectProtocol?

    init(vm: ReviewViewModel) {
        let host = NSHostingView(rootView: ContentView().environmentObject(vm))
        host.wantsLayer = true
        host.layer?.masksToBounds = true
        // The container sets the size; SwiftUI only sets the minimum.
        host.sizingOptions = [.minSize]
        self.host = host
        panel = Panel(contentRect: NSRect(origin: .zero, size: AsWindow.minimumSize))
        super.init()
        panel.onEscape = { [weak self] in self?.close() }

        item.button?.target = self
        item.button?.action = #selector(toggle)
        updateIcon(vm.badgeCount)
        // badgeCount is derived from several published lists: re-read it after any change.
        // Settings › Menu bar number changes it too, without touching the lists.
        watch = vm.objectWillChange
            .merge(with: NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).map { _ in })
            .receive(on: RunLoop.main)
            .sink { [weak self, weak vm] _ in if let vm { self?.updateIcon(vm.badgeCount) } }

        // Clicking anywhere else closes it, like a menu, unless Settings keep it open.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if !StayOpen.isOn { self?.close() } }
        }
    }

    private func updateIcon(_ count: Int) {
        item.button?.image = MenuBarIcon.image(count: count)
    }

    /// When the panel last closed. Clicking the icon to close it first makes the panel lose
    /// focus (closing it), then delivers the click: that click must not reopen it.
    private var closedAt = Date.distantPast

    /// Set while a file dialog is open from Settings, so the panel stays open behind it.
    static var keepOpen = false

    private func close() {
        guard panel.isVisible, !Self.keepOpen, panel.attachedSheet == nil else { return }
        panel.orderOut(nil)
        closedAt = Date()
    }

    @objc private func toggle() {
        if AsWindow.isOn { showWindow(); return }
        window?.orderOut(nil)
        if panel.isVisible { close(); return }
        if Date().timeIntervalSince(closedAt) < 0.3 { return }
        guard let button = item.button, let buttonWindow = button.window else { return }
        if panel.contentView !== host {
            host.layer?.cornerRadius = 12
            panel.contentView = host
        }
        let icon = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        panel.setFrameOrigin(Self.origin(icon: icon, size: panel.frame.size,
                                         visible: buttonWindow.screen?.visibleFrame))
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Clicking the icon brings the window to the front; only its close button closes it.
    private func showWindow() {
        if panel.isVisible { close() }
        let window = self.window ?? Self.makeWindow()
        self.window = window
        if window.contentView !== host {
            host.layer?.cornerRadius = 0
            window.contentView = host
        }
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    /// Remembers where it was and how big, across launches.
    private static func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: AsWindow.minimumSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "ReviewBar"
        w.isReleasedWhenClosed = false
        let name = "ReviewBarWindow"
        if !w.setFrameUsingName(name) { w.center() }
        w.setFrameAutosaveName(name)
        return w
    }

    /// Top-right corner under the icon's right edge, kept on screen. Pure, for tests.
    nonisolated static func origin(icon: NSRect, size: NSSize, visible: NSRect?) -> NSPoint {
        var x = icon.maxX - size.width
        if let v = visible { x = min(max(x, v.minX + 4), v.maxX - size.width - 4) }
        return NSPoint(x: x, y: icon.minY - size.height - 4)
    }

    /// Borderless, solid, can take keyboard focus (for text fields in Settings).
    final class Panel: NSPanel {
        init(contentRect: NSRect) {
            super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                       backing: .buffered, defer: false)
            isOpaque = false
            backgroundColor = .clear
            hasShadow = true
            level = .popUpMenu
            collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            isReleasedWhenClosed = false
            // Panels hide when the app loses focus by default; closing is up to MenuBarController.
            hidesOnDeactivate = false
        }
        override var canBecomeKey: Bool { true }
        var onEscape: (() -> Void)?
        /// Esc closes it, like a menu.
        override func cancelOperation(_ sender: Any?) { onEscape?() }
    }
}
