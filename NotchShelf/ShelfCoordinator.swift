import AppKit
import Foundation
import UniformTypeIdentifiers

struct DropOpenerMenuOption {
    let id: String
    let displayName: String
    let isAvailable: Bool
    let isSelected: Bool
}

private struct DropOpenerDefinition {
    enum Behavior {
        case finder
        case application(terminalLike: Bool)
    }

    let id: String
    let displayName: String
    let bundleIdentifier: String?
    let behavior: Behavior
}

private struct ResolvedDropOpener {
    let id: String
    let displayName: String
    let appURL: URL?
    let appIcon: NSImage?
    let behavior: DropOpenerDefinition.Behavior
}

@MainActor
final class ShelfCoordinator {
    private static let recentProjectDefaultsKey = "NotchShelf.recentProjectPath"
    private static let defaultOpenerDefaultsKey = "NotchShelf.defaultDropOpener"
    private static let customOpenerPathDefaultsKey = "NotchShelf.customDropOpenerPath"

    private static let openerCatalog: [DropOpenerDefinition] = [
        .init(id: "finder", displayName: "Finder", bundleIdentifier: "com.apple.finder", behavior: .finder),
        .init(id: "terminal", displayName: "Terminal", bundleIdentifier: "com.apple.Terminal", behavior: .application(terminalLike: true)),
        .init(id: "iterm2", displayName: "iTerm2", bundleIdentifier: "com.googlecode.iterm2", behavior: .application(terminalLike: true)),
        .init(id: "vscode", displayName: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", behavior: .application(terminalLike: false)),
        .init(id: "cursor", displayName: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", behavior: .application(terminalLike: false)),
        .init(id: "xcode", displayName: "Xcode", bundleIdentifier: "com.apple.dt.Xcode", behavior: .application(terminalLike: false)),
        .init(id: "intellij", displayName: "IntelliJ IDEA", bundleIdentifier: "com.jetbrains.intellij", behavior: .application(terminalLike: false)),
        .init(id: "webstorm", displayName: "WebStorm", bundleIdentifier: "com.jetbrains.WebStorm", behavior: .application(terminalLike: false)),
        .init(id: "pycharm", displayName: "PyCharm", bundleIdentifier: "com.jetbrains.PyCharm", behavior: .application(terminalLike: false)),
        .init(id: "goland", displayName: "GoLand", bundleIdentifier: "com.jetbrains.goland", behavior: .application(terminalLike: false)),
        .init(id: "rider", displayName: "Rider", bundleIdentifier: "com.jetbrains.rider", behavior: .application(terminalLike: false)),
        .init(id: "datagrip", displayName: "DataGrip", bundleIdentifier: "com.jetbrains.datagrip", behavior: .application(terminalLike: false)),
        .init(id: "warp", displayName: "Warp", bundleIdentifier: "dev.warp.Warp-Stable", behavior: .application(terminalLike: true)),
        .init(id: "zed", displayName: "Zed", bundleIdentifier: "dev.zed.Zed", behavior: .application(terminalLike: false)),
    ]

    private let store = ShelfStore()
    private let finder = FinderBridge()
    private let mover = FileMoveService()
    private let overlay = NotchOverlayController()
    private let shortcuts = ShortcutMonitor()
    private let projectDropTarget = ProjectDropTarget()

    private var recentProject: URL?
    private var projectPreviewTask: DispatchWorkItem?

    var onShelfChanged: ((Int) -> Void)?
    var onProjectChanged: ((URL?) -> Void)?
    var onDropOpenerChanged: (() -> Void)?

    var stagedCount: Int { store.count }
    var recentProjectURL: URL? { validatedRecentProject() }
    var defaultDropOpenerName: String { resolveDefaultOpener().displayName }

    var dropOpenerMenuOptions: [DropOpenerMenuOption] {
        let selectedID = resolveDefaultOpener().id
        var options = Self.openerCatalog.map { definition in
            DropOpenerMenuOption(
                id: definition.id,
                displayName: definition.displayName,
                isAvailable: definition.behavior.isFinder || applicationURL(for: definition) != nil,
                isSelected: selectedID == definition.id
            )
        }

        if let custom = resolveCustomOpener() {
            options.append(
                DropOpenerMenuOption(
                    id: "custom",
                    displayName: "Custom: \(custom.displayName)",
                    isAvailable: true,
                    isSelected: selectedID == "custom"
                )
            )
        }

        return options
    }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.recentProjectDefaultsKey) {
            recentProject = URL(fileURLWithPath: path).standardizedFileURL
        }

        shortcuts.isFinderFrontmost = { [weak self] in
            self?.finder.isFinderFrontmost ?? false
        }
        shortcuts.shouldCapturePaste = { [weak self] in
            !(self?.store.isEmpty ?? true)
        }
        shortcuts.onCut = { [weak self] in self?.cutFromFinder() }
        shortcuts.onPaste = { [weak self] in self?.pasteIntoFinder() }

        projectDropTarget.onDragEntered = { [weak self] url in
            self?.previewProjectDrop(url)
        }
        projectDropTarget.onDragExited = { [weak self] in
            self?.restoreShelfOverlay()
        }
        projectDropTarget.onItemDropped = { [weak self] url in
            self?.handleDroppedItem(url)
        }
    }

    func start() {
        shortcuts.start()
        projectDropTarget.start()
        onProjectChanged?(validatedRecentProject())
        onDropOpenerChanged?()
    }

    func stop() {
        shortcuts.stop()
        projectDropTarget.stop()
        projectPreviewTask?.cancel()
        projectPreviewTask = nil
    }

    func clearShelf() {
        cancelProjectPreviewRestore()
        store.clear()
        shortcuts.refreshRegistrations()
        overlay.hide()
        onShelfChanged?(0)
    }

    func setDefaultDropOpener(id: String) {
        guard id != "custom" else {
            if resolveCustomOpener() != nil {
                UserDefaults.standard.set("custom", forKey: Self.defaultOpenerDefaultsKey)
                onDropOpenerChanged?()
                showOpenerChangedFeedback()
            }
            return
        }

        guard let definition = Self.openerCatalog.first(where: { $0.id == id }),
              definition.behavior.isFinder || applicationURL(for: definition) != nil else {
            NSSound.beep()
            return
        }

        UserDefaults.standard.set(id, forKey: Self.defaultOpenerDefaultsKey)
        onDropOpenerChanged?()
        showOpenerChangedFeedback()
    }

    func chooseCustomDropApp() {
        let picker = NSOpenPanel()
        picker.title = "Choose Default Drop App"
        picker.message = "Folders and files dropped into NotchShelf will open with this application."
        picker.prompt = "Choose App"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let url = picker.url else { return }

        UserDefaults.standard.set(url.path, forKey: Self.customOpenerPathDefaultsKey)
        UserDefaults.standard.set("custom", forKey: Self.defaultOpenerDefaultsKey)
        onDropOpenerChanged?()
        showOpenerChangedFeedback()
    }

    func openRecentWithDefaultApp() {
        guard let url = validatedRecentProject() else {
            NSSound.beep()
            return
        }
        openItemWithAnimatedFeedback(url)
    }

    func clearRecentProject() {
        recentProject = nil
        UserDefaults.standard.removeObject(forKey: Self.recentProjectDefaultsKey)
        onProjectChanged?(nil)

        overlay.showNotice(
            title: "Recent project cleared",
            subtitle: "Drop Zone is ready",
            icon: NSImage(systemSymbolName: "folder.badge.minus", accessibilityDescription: nil)
        )
        scheduleRestore(after: 1.0)
        NSLog("[NotchShelf] Cleared recent project")
    }

    private func cutFromFinder() {
        cancelProjectPreviewRestore()
        do {
            let urls = try finder.selectedFileURLs()
            store.stage(urls)
            shortcuts.refreshRegistrations()
            overlay.showStaged(items: urls)
            onShelfChanged?(store.count)
            NSLog("[NotchShelf] Staged \(urls.count) item(s)")
        } catch {
            NSSound.beep()
            overlay.showFailure(error.localizedDescription, remainingItems: store.items)
            NSLog("[NotchShelf] Cut failed: \(error.localizedDescription)")
        }
    }

    private func pasteIntoFinder() {
        cancelProjectPreviewRestore()
        guard !store.isEmpty else {
            shortcuts.refreshRegistrations()
            return
        }

        do {
            let destination = try finder.currentDestinationURL()
            let staged = store.items
            overlay.showMoving(items: staged, destination: destination)

            mover.move(staged, to: destination) { [weak self] result in
                guard let self else { return }

                if let errorMessage = result.errorMessage {
                    self.store.replace(with: result.remaining)
                    self.shortcuts.refreshRegistrations()
                    self.overlay.showFailure(errorMessage, remainingItems: result.remaining)
                    self.onShelfChanged?(self.store.count)
                    NSSound.beep()
                    NSLog("[NotchShelf] Move failed: \(errorMessage)")
                    return
                }

                self.store.clear()
                self.shortcuts.refreshRegistrations()
                self.overlay.showSuccess(count: result.moved.count)
                self.onShelfChanged?(0)
                NSLog("[NotchShelf] Moved \(result.moved.count) item(s) to \(destination.path)")
            }
        } catch {
            shortcuts.refreshRegistrations()
            overlay.showFailure(error.localizedDescription, remainingItems: store.items)
            NSSound.beep()
            NSLog("[NotchShelf] Paste failed: \(error.localizedDescription)")
        }
    }

    private func previewProjectDrop(_ url: URL) {
        cancelProjectPreviewRestore()
        let opener = resolveDefaultOpener()
        overlay.showDropHover(
            item: url,
            targetAppName: opener.displayName,
            targetAppIcon: opener.appIcon
        )
        NSLog("[NotchShelf] Drop target: %@ -> %@", url.lastPathComponent, opener.displayName)
    }

    private func handleDroppedItem(_ url: URL) {
        cancelProjectPreviewRestore()
        let item = url.standardizedFileURL
        let project = projectDirectory(for: item)
        recentProject = project
        UserDefaults.standard.set(project.path, forKey: Self.recentProjectDefaultsKey)
        onProjectChanged?(project)

        openItemWithAnimatedFeedback(item)
        NSLog("[NotchShelf] Dropped item: %@", item.path)
    }

    private func openItemWithAnimatedFeedback(_ item: URL) {
        cancelProjectPreviewRestore()
        let opener = resolveDefaultOpener()

        overlay.showDropOpening(
            item: item,
            targetAppName: opener.displayName,
            targetAppIcon: opener.appIcon
        )

        open(item, with: opener) { [weak self] success, message in
            guard let self else { return }

            if success {
                self.overlay.showDropSuccess(
                    item: item,
                    targetAppName: opener.displayName,
                    targetAppIcon: opener.appIcon
                )
                self.scheduleRestore(after: 1.2)
                NSLog("[NotchShelf] Opened %@ in %@", item.lastPathComponent, opener.displayName)
            } else {
                self.overlay.showDropFailure(
                    item: item,
                    targetAppName: opener.displayName,
                    targetAppIcon: opener.appIcon,
                    message: message ?? "Could not open item"
                )
                self.scheduleRestore(after: 1.6)
                NSSound.beep()
                NSLog("[NotchShelf] Open failed: %@", message ?? "unknown error")
            }
        }
    }

    private func open(
        _ item: URL,
        with opener: ResolvedDropOpener,
        completion: @escaping @MainActor (Bool, String?) -> Void
    ) {
        switch opener.behavior {
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting([item])
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                completion(true, nil)
            }

        case .application(let terminalLike):
            guard let appURL = opener.appURL else {
                completion(false, "\(opener.displayName) is not installed")
                return
            }

            let target = terminalLike && !isDirectory(item)
                ? item.deletingLastPathComponent()
                : item

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true

            NSWorkspace.shared.open(
                [target],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, error in
                Task { @MainActor in
                    completion(error == nil, error?.localizedDescription)
                }
            }
        }
    }

    private func showOpenerChangedFeedback() {
        cancelProjectPreviewRestore()
        let opener = resolveDefaultOpener()
        overlay.showNotice(
            title: opener.displayName,
            subtitle: "Default Drop App",
            icon: opener.appIcon
        )
        scheduleRestore(after: 1.05)
    }

    private func restoreShelfOverlay() {
        cancelProjectPreviewRestore()
        if store.isEmpty {
            overlay.hide()
        } else {
            overlay.showStaged(items: store.items)
        }
    }

    private func scheduleRestore(after delay: TimeInterval) {
        cancelProjectPreviewRestore()
        let work = DispatchWorkItem { [weak self] in self?.restoreShelfOverlay() }
        projectPreviewTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelProjectPreviewRestore() {
        projectPreviewTask?.cancel()
        projectPreviewTask = nil
    }

    private func validatedRecentProject() -> URL? {
        guard let recentProject,
              FileManager.default.fileExists(atPath: recentProject.path) else {
            return nil
        }
        return recentProject
    }

    private func projectDirectory(for item: URL) -> URL {
        isDirectory(item) ? item : item.deletingLastPathComponent()
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func resolveDefaultOpener() -> ResolvedDropOpener {
        let requestedID = UserDefaults.standard.string(forKey: Self.defaultOpenerDefaultsKey)
            ?? "finder"

        if requestedID == "custom", let custom = resolveCustomOpener() {
            return custom
        }

        if let definition = Self.openerCatalog.first(where: { $0.id == requestedID }),
           let resolved = resolve(definition) {
            return resolved
        }

        let finder = Self.openerCatalog.first(where: { $0.id == "finder" })!
        return resolve(finder)!
    }

    private func resolve(_ definition: DropOpenerDefinition) -> ResolvedDropOpener? {
        if definition.behavior.isFinder {
            let appURL = definition.bundleIdentifier.flatMap {
                NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
            }
            return ResolvedDropOpener(
                id: definition.id,
                displayName: definition.displayName,
                appURL: appURL,
                appIcon: appURL.map { NSWorkspace.shared.icon(forFile: $0.path) },
                behavior: definition.behavior
            )
        }

        guard let appURL = applicationURL(for: definition) else { return nil }
        return ResolvedDropOpener(
            id: definition.id,
            displayName: definition.displayName,
            appURL: appURL,
            appIcon: NSWorkspace.shared.icon(forFile: appURL.path),
            behavior: definition.behavior
        )
    }

    private func resolveCustomOpener() -> ResolvedDropOpener? {
        guard let path = UserDefaults.standard.string(forKey: Self.customOpenerPathDefaultsKey) else {
            return nil
        }

        let appURL = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }

        let bundle = Bundle(url: appURL)
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        return ResolvedDropOpener(
            id: "custom",
            displayName: displayName,
            appURL: appURL,
            appIcon: NSWorkspace.shared.icon(forFile: appURL.path),
            behavior: .application(terminalLike: false)
        )
    }

    private func applicationURL(for definition: DropOpenerDefinition) -> URL? {
        guard let bundleIdentifier = definition.bundleIdentifier else { return nil }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}

private extension DropOpenerDefinition.Behavior {
    var isFinder: Bool {
        if case .finder = self { return true }
        return false
    }
}

// MARK: - Magnetic Project Drop Zone

/// The drag destination is hidden during normal use. While the user is actively
/// dragging and approaches the top-center of the display, a larger invisible
/// catch area is armed below the physical notch. This lets users release before
/// touching macOS' top-edge Mission Control / Spaces gesture.
@MainActor
final class ProjectDropTarget {
    var onDragEntered: ((URL) -> Void)?
    var onDragExited: (() -> Void)?
    var onItemDropped: ((URL) -> Void)?

    private static let magneticDepth: CGFloat = 156
    private static let magneticExtraWidth: CGFloat = 260
    private static let minimumMagneticWidth: CGFloat = 430
    private static let dragThreshold: CGFloat = 5
    private static let pollingInterval: TimeInterval = 0.035

    private var panel: ProjectDropPanel?
    private var screenObserver: NSObjectProtocol?
    private var proximityTimer: Timer?
    private var magneticFrame: NSRect = .zero
    private var pressAnchor: NSPoint?
    private var magneticActive = false

    func start() {
        if screenObserver == nil {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.rebuildTarget() }
            }
        }

        rebuildTarget()
        startProximityPolling()
    }

    func stop() {
        proximityTimer?.invalidate()
        proximityTimer = nil
        pressAnchor = nil
        magneticActive = false

        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }

        panel?.orderOut(nil)
        panel = nil
    }

    private func startProximityPolling() {
        proximityTimer?.invalidate()

        let timer = Timer.scheduledTimer(withTimeInterval: Self.pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.samplePointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        proximityTimer = timer
    }

    private func rebuildTarget() {
        panel?.orderOut(nil)
        panel = nil
        magneticActive = false
        pressAnchor = nil

        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            magneticFrame = .zero
            NSLog("[NotchShelf] Magnetic drop zone disabled: no physical notch")
            return
        }

        let targetWidth = max(
            geometry.hardwareWidth + Self.magneticExtraWidth,
            Self.minimumMagneticWidth
        )
        let targetHeight = geometry.hardwareHeight + Self.magneticDepth
        magneticFrame = NSRect(
            x: screen.frame.midX - targetWidth / 2,
            y: screen.frame.maxY - targetHeight,
            width: targetWidth,
            height: targetHeight
        )

        let dropView = ProjectDropView(
            frame: NSRect(origin: .zero, size: magneticFrame.size)
        )
        dropView.autoresizingMask = [.width, .height]
        dropView.onHover = { [weak self] url in
            Task { @MainActor in self?.onDragEntered?(url) }
        }
        dropView.onExit = { [weak self] in
            Task { @MainActor in self?.onDragExited?() }
        }
        dropView.onDrop = { [weak self] url in
            Task { @MainActor in
                self?.onItemDropped?(url)
                self?.deactivateMagnet(notifyExit: false)
            }
        }

        let panel = ProjectDropPanel(frame: magneticFrame, dropView: dropView)
        self.panel = panel
        panel.orderOut(nil)

        NSLog(
            "[NotchShelf] Magnetic drop zone ready: %@ (release before top edge)",
            NSStringFromRect(magneticFrame)
        )
    }

    private func samplePointer() {
        guard let panel, magneticFrame != .zero else { return }

        let location = NSEvent.mouseLocation
        let leftButtonDown = (NSEvent.pressedMouseButtons & 1) != 0

        guard leftButtonDown else {
            pressAnchor = nil
            if magneticActive {
                deactivateMagnet(notifyExit: false)
            }
            return
        }

        if pressAnchor == nil {
            pressAnchor = location
            return
        }

        let anchor = pressAnchor ?? location
        let distance = hypot(location.x - anchor.x, location.y - anchor.y)
        let isRealDrag = distance >= Self.dragThreshold
        let activationFrame = magneticFrame.insetBy(dx: -42, dy: -34)

        if isRealDrag && activationFrame.contains(location) {
            if !magneticActive {
                magneticActive = true
                panel.orderFrontRegardless()
                NSLog("[NotchShelf] Magnetic drop zone armed early before macOS top edge")
            }
            return
        }

        if magneticActive && !activationFrame.contains(location) {
            deactivateMagnet(notifyExit: true)
        }
    }

    private func deactivateMagnet(notifyExit: Bool) {
        guard magneticActive else { return }
        magneticActive = false
        panel?.orderOut(nil)
        if notifyExit {
            onDragExited?()
        }
    }
}

@MainActor
private final class ProjectDropPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, dropView: ProjectDropView) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = .mainMenu + 6
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        contentView = dropView
    }
}

@MainActor
private final class ProjectDropView: NSView {
    var onHover: ((URL) -> Void)?
    var onExit: (() -> Void)?
    var onDrop: ((URL) -> Void)?

    private var currentURL: URL?
    private var completedDrop = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        completedDrop = false
        guard let url = droppedURL(from: sender) else {
            currentURL = nil
            return []
        }

        currentURL = url
        onHover?(url)
        return .link
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = droppedURL(from: sender) else {
            if currentURL != nil {
                currentURL = nil
                onExit?()
            }
            return []
        }

        if currentURL != url {
            currentURL = url
            onHover?(url)
        }
        return .link
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        currentURL = nil
        if completedDrop {
            completedDrop = false
            return
        }
        onExit?()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = droppedURL(from: sender) else { return false }

        completedDrop = true
        currentURL = nil
        onDrop?(url)
        return true
    }

    private func droppedURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]

        guard let objects = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: options
        ), objects.count == 1,
              let nsURL = objects.first as? NSURL else {
            return nil
        }

        let url = (nsURL as URL).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }
}
