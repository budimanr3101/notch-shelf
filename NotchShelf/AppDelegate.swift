import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let coordinator = ShelfCoordinator()

    private var statusItem: NSStatusItem?
    private var shelfStatusItem: NSMenuItem?
    private var projectStatusItem: NSMenuItem?
    private var defaultDropAppItem: NSMenuItem?
    private var openRecentItem: NSMenuItem?
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
        coordinator.onDropOpenerChanged = { [weak self] in
            self?.updateDropOpenerUI()
        }

        coordinator.start()
        updateProjectStatus(url: coordinator.recentProjectURL)
        updateDropOpenerUI()
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

        let clear = NSMenuItem(
            title: "Clear Shelf",
            action: #selector(clearShelf),
            keyEquivalent: ""
        )
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let dropHeader = NSMenuItem(title: "Developer Drop Zone", action: nil, keyEquivalent: "")
        dropHeader.isEnabled = false
        menu.addItem(dropHeader)

        let defaultApp = NSMenuItem(
            title: "Default Drop App",
            action: nil,
            keyEquivalent: ""
        )
        defaultApp.submenu = NSMenu(title: "Default Drop App")
        menu.addItem(defaultApp)
        defaultDropAppItem = defaultApp

        let project = NSMenuItem(title: "Recent: None", action: nil, keyEquivalent: "")
        project.isEnabled = false
        menu.addItem(project)
        projectStatusItem = project

        let openRecent = NSMenuItem(
            title: "Open Recent",
            action: #selector(openRecentWithDefaultApp),
            keyEquivalent: ""
        )
        openRecent.target = self
        menu.addItem(openRecent)
        openRecentItem = openRecent

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
        updateDropOpenerUI()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateShelfStatus(count: coordinator.stagedCount)
        updateProjectStatus(url: coordinator.recentProjectURL)
        updateDropOpenerUI()
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
        projectStatusItem?.title = url.map { "Recent: \($0.lastPathComponent)" }
            ?? "Recent: None"
        openRecentItem?.isEnabled = hasProject
        clearProjectItem?.isEnabled = hasProject
        openRecentItem?.title = "Open Recent in \(coordinator.defaultDropOpenerName)"
    }

    private func updateDropOpenerUI() {
        defaultDropAppItem?.title = "Default Drop App: \(coordinator.defaultDropOpenerName)"
        openRecentItem?.title = "Open Recent in \(coordinator.defaultDropOpenerName)"

        guard let submenu = defaultDropAppItem?.submenu else { return }
        submenu.removeAllItems()

        for option in coordinator.dropOpenerMenuOptions {
            let item = NSMenuItem(
                title: option.displayName,
                action: #selector(selectDropOpener(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = option.id
            item.isEnabled = option.isAvailable
            item.state = option.isSelected ? .on : .off
            submenu.addItem(item)
        }

        submenu.addItem(.separator())

        let custom = NSMenuItem(
            title: "Choose Custom App…",
            action: #selector(chooseCustomDropApp),
            keyEquivalent: ""
        )
        custom.target = self
        submenu.addItem(custom)
    }

    @objc private func clearShelf() {
        coordinator.clearShelf()
    }

    @objc private func selectDropOpener(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        coordinator.setDefaultDropOpener(id: id)
    }

    @objc private func chooseCustomDropApp() {
        coordinator.chooseCustomDropApp()
    }

    @objc private func openRecentWithDefaultApp() {
        coordinator.openRecentWithDefaultApp()
    }

    @objc private func clearRecentProject() {
        coordinator.clearRecentProject()
    }
}
