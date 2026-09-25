import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = ShelfCoordinator()
    private var statusItem: NSStatusItem?
    private var shelfStatusItem: NSMenuItem?
    private var projectStatusItem: NSMenuItem?
    private var openProjectFinderItem: NSMenuItem?
    private var openProjectTerminalItem: NSMenuItem?
    private var clearProjectItem: NSMenuItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        coordinator.onShelfChanged = { [weak self] count in
            self?.updateShelfStatus(count: count)
        }
        coordinator.onProjectChanged = { [weak self] url in
            self?.updateProjectStatus(url: url)
        }

        coordinator.start()
        updateProjectStatus(url: coordinator.recentProjectURL)
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator.stop()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "tray.full.fill",
            accessibilityDescription: "NotchShelf"
        )

        let menu = NSMenu()
        menu.delegate = self

        let shelf = NSMenuItem(title: "Shelf: Empty", action: nil, keyEquivalent: "")
        shelf.isEnabled = false
        menu.addItem(shelf)
        shelfStatusItem = shelf

        let clear = NSMenuItem(title: "Clear Shelf", action: #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let project = NSMenuItem(title: "Project: None", action: nil, keyEquivalent: "")
        project.isEnabled = false
        menu.addItem(project)
        projectStatusItem = project

        let openFinder = NSMenuItem(
            title: "Open Project in Finder",
            action: #selector(openProjectInFinder),
            keyEquivalent: ""
        )
        openFinder.target = self
        menu.addItem(openFinder)
        openProjectFinderItem = openFinder

        let openTerminal = NSMenuItem(
            title: "Open Project in Terminal",
            action: #selector(openProjectInTerminal),
            keyEquivalent: ""
        )
        openTerminal.target = self
        menu.addItem(openTerminal)
        openProjectTerminalItem = openTerminal

        let clearProject = NSMenuItem(
            title: "Clear Recent Project",
            action: #selector(clearRecentProject),
            keyEquivalent: ""
        )
        clearProject.target = self
        menu.addItem(clearProject)
        clearProjectItem = clearProject

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit NotchShelf",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item

        updateShelfStatus(count: 0)
        updateProjectStatus(url: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateShelfStatus(count: coordinator.stagedCount)
        updateProjectStatus(url: coordinator.recentProjectURL)
    }

    private func updateShelfStatus(count: Int) {
        shelfStatusItem?.title = count == 0
            ? "Shelf: Empty"
            : "Shelf: \(count) item\(count == 1 ? "" : "s")"

        statusItem?.button?.image = NSImage(
            systemSymbolName: count == 0 ? "tray" : "tray.full.fill",
            accessibilityDescription: "NotchShelf"
        )
    }

    private func updateProjectStatus(url: URL?) {
        let hasProject = url != nil
        projectStatusItem?.title = url.map { "Project: \($0.lastPathComponent)" }
            ?? "Project: None"
        openProjectFinderItem?.isEnabled = hasProject
        openProjectTerminalItem?.isEnabled = hasProject
        clearProjectItem?.isEnabled = hasProject
    }

    @objc private func clearShelf() {
        coordinator.clearShelf()
    }

    @objc private func openProjectInFinder() {
        coordinator.openRecentProjectInFinder()
    }

    @objc private func openProjectInTerminal() {
        coordinator.openRecentProjectInTerminal()
    }

    @objc private func clearRecentProject() {
        coordinator.clearRecentProject()
    }
}
