import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = ShelfCoordinator()
    private var statusItem: NSStatusItem?
    private var shelfStatusItem: NSMenuItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        coordinator.onShelfChanged = { [weak self] count in
            self?.updateShelfStatus(count: count)
        }
        coordinator.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: "NotchShelf")

        let menu = NSMenu()
        menu.delegate = self

        let shelf = NSMenuItem(title: "Shelf: Empty", action: nil, keyEquivalent: "")
        shelf.isEnabled = false
        menu.addItem(shelf)
        shelfStatusItem = shelf

        let clear = NSMenuItem(title: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        let permissions = NSMenuItem(title: "Request Accessibility Access", action: #selector(requestAccessibility), keyEquivalent: "")
        permissions.target = self
        menu.addItem(permissions)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit NotchShelf", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        item.menu = menu
        statusItem = item
        updateShelfStatus(count: 0)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateShelfStatus(count: coordinator.stagedCount)
    }

    private func updateShelfStatus(count: Int) {
        shelfStatusItem?.title = count == 0 ? "Shelf: Empty" : "Shelf: \(count) item\(count == 1 ? "" : "s")"
        statusItem?.button?.image = NSImage(
            systemSymbolName: count == 0 ? "tray" : "tray.full.fill",
            accessibilityDescription: "NotchShelf"
        )
    }

    @objc private func clearShelf() {
        coordinator.clearShelf()
    }

    @objc private func requestAccessibility() {
        ShortcutMonitor.requestAccessibilityPrompt()
    }
}
