import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let defaultOpenerDefaultsKey = "NotchShelf.defaultDropOpener"
    private static let customOpenerPathDefaultsKey = "NotchShelf.customDropOpenerPath"

    private let coordinator = ShelfCoordinator()
    private let pocketbook = PocketbookFeatureV3()

    private var statusItem: NSStatusItem?
    private var shelfStatusItem: NSMenuItem?
    private var projectStatusItem: NSMenuItem?
    private var defaultDropAppItem: NSMenuItem?
    private var openRecentItem: NSMenuItem?
    private var clearProjectItem: NSMenuItem?
    private var pocketbookShortcutItem: NSMenuItem?

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
        pocketbook.onShortcutChanged = { [weak self] in
            self?.updatePocketbookUI()
        }

        coordinator.start()
        pocketbook.start()
        updateProjectStatus(url: coordinator.recentProjectURL)
        updateDropOpenerUI()
        updatePocketbookUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pocketbook.stop()
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
            title: "Open Recent With",
            action: nil,
            keyEquivalent: ""
        )
        openRecent.submenu = NSMenu(title: "Open Recent With")
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

        let pocketHeader = NSMenuItem(title: "Pocketbook", action: nil, keyEquivalent: "")
        pocketHeader.isEnabled = false
        menu.addItem(pocketHeader)

        let openPocketbook = NSMenuItem(
            title: "Open Pocketbook",
            action: #selector(openPocketbookAction),
            keyEquivalent: ""
        )
        openPocketbook.target = self
        menu.addItem(openPocketbook)

        let pocketbookSettings = NSMenuItem(
            title: "Pocketbook Settings…",
            action: #selector(openPocketbookSettings),
            keyEquivalent: ""
        )
        pocketbookSettings.target = self
        menu.addItem(pocketbookSettings)

        let shortcutItem = NSMenuItem(
            title: "Shortcut: \(pocketbook.shortcutDescription)…",
            action: #selector(configurePocketbookShortcut),
            keyEquivalent: ""
        )
        shortcutItem.target = self
        menu.addItem(shortcutItem)
        pocketbookShortcutItem = shortcutItem

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
        updatePocketbookUI()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateShelfStatus(count: coordinator.stagedCount)
        updateProjectStatus(url: coordinator.recentProjectURL)
        updateDropOpenerUI()
        updatePocketbookUI()
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
    }

    private func updateDropOpenerUI() {
        defaultDropAppItem?.title = "Default Drop App: \(coordinator.defaultDropOpenerName)"

        let availableOptions = coordinator.dropOpenerMenuOptions.filter { $0.isAvailable }

        if let submenu = defaultDropAppItem?.submenu {
            submenu.removeAllItems()

            for option in availableOptions {
                let item = NSMenuItem(
                    title: option.displayName,
                    action: #selector(selectDropOpener(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
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

        if let recentMenu = openRecentItem?.submenu {
            recentMenu.removeAllItems()

            for option in availableOptions {
                let item = NSMenuItem(
                    title: option.displayName,
                    action: #selector(openRecentWithOpener(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                recentMenu.addItem(item)
            }

            recentMenu.addItem(.separator())

            let chooseOther = NSMenuItem(
                title: "Choose Other App…",
                action: #selector(chooseOtherAppForRecent),
                keyEquivalent: ""
            )
            chooseOther.target = self
            recentMenu.addItem(chooseOther)
        }
    }

    private func updatePocketbookUI() {
        pocketbookShortcutItem?.title = "Shortcut: \(pocketbook.shortcutDescription)…"
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

    @objc private func openRecentWithOpener(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        performRecentOpen(usingTemporaryOpenerID: id)
    }

    @objc private func chooseOtherAppForRecent() {
        let picker = NSOpenPanel()
        picker.title = "Open Recent With"
        picker.message = "Choose an application for this open only. Your default Drop Zone app will not change."
        picker.prompt = "Open"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let appURL = picker.url else { return }

        let defaults = UserDefaults.standard
        let previousDefault = defaults.string(forKey: Self.defaultOpenerDefaultsKey)
        let previousCustomPath = defaults.string(forKey: Self.customOpenerPathDefaultsKey)

        defaults.set(appURL.path, forKey: Self.customOpenerPathDefaultsKey)
        defaults.set("custom", forKey: Self.defaultOpenerDefaultsKey)

        coordinator.openRecentWithDefaultApp()

        restoreDefaults(
            previousDefault: previousDefault,
            previousCustomPath: previousCustomPath
        )
        updateDropOpenerUI()
    }

    private func performRecentOpen(usingTemporaryOpenerID id: String) {
        let defaults = UserDefaults.standard
        let previousDefault = defaults.string(forKey: Self.defaultOpenerDefaultsKey)

        defaults.set(id, forKey: Self.defaultOpenerDefaultsKey)
        coordinator.openRecentWithDefaultApp()

        if let previousDefault = previousDefault {
            defaults.set(previousDefault, forKey: Self.defaultOpenerDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultOpenerDefaultsKey)
        }

        updateDropOpenerUI()
    }

    private func restoreDefaults(previousDefault: String?, previousCustomPath: String?) {
        let defaults = UserDefaults.standard

        if let previousDefault = previousDefault {
            defaults.set(previousDefault, forKey: Self.defaultOpenerDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultOpenerDefaultsKey)
        }

        if let previousCustomPath = previousCustomPath {
            defaults.set(previousCustomPath, forKey: Self.customOpenerPathDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.customOpenerPathDefaultsKey)
        }
    }

    @objc private func clearRecentProject() {
        coordinator.clearRecentProject()
    }

    @objc private func openPocketbookAction() {
        pocketbook.toggle()
    }

    @objc private func openPocketbookSettings() {
        pocketbook.showSettings()
    }

    @objc private func configurePocketbookShortcut() {
        pocketbook.showShortcutRecorder()
        updatePocketbookUI()
    }
}
