import AppKit
import Foundation

@MainActor
final class ShelfCoordinator {
    private static let recentProjectDefaultsKey = "NotchShelf.recentProjectPath"

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

    var stagedCount: Int { store.count }
    var recentProjectURL: URL? { validatedRecentProject() }

    init() {
        if let path = UserDefaults.standard.string(forKey: Self.recentProjectDefaultsKey) {
            recentProject = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }

        shortcuts.isFinderFrontmost = { [weak self] in
            self?.finder.isFinderFrontmost ?? false
        }
        shortcuts.shouldCapturePaste = { [weak self] in
            !(self?.store.isEmpty ?? true)
        }
        shortcuts.onCut = { [weak self] in
            self?.cutFromFinder()
        }
        shortcuts.onPaste = { [weak self] in
            self?.pasteIntoFinder()
        }

        projectDropTarget.onDragEntered = { [weak self] url in
            self?.previewProjectDrop(url)
        }
        projectDropTarget.onDragExited = { [weak self] in
            self?.restoreShelfOverlay()
        }
        projectDropTarget.onProjectDropped = { [weak self] url in
            self?.saveProject(url)
        }
    }

    func start() {
        shortcuts.start()
        projectDropTarget.start()
        onProjectChanged?(validatedRecentProject())
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

    func openRecentProjectInFinder() {
        guard let url = validatedRecentProject() else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openRecentProjectInTerminal() {
        guard let url = validatedRecentProject(),
              let terminalURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.Terminal"
              ) else {
            NSSound.beep()
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(
            [url],
            withApplicationAt: terminalURL,
            configuration: configuration
        ) { _, error in
            if let error {
                NSLog("[NotchShelf] Could not open project in Terminal: %@", error.localizedDescription)
            }
        }
    }

    func clearRecentProject() {
        recentProject = nil
        UserDefaults.standard.removeObject(forKey: Self.recentProjectDefaultsKey)
        onProjectChanged?(nil)
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
        overlay.showStaged(items: [url])
        NSLog("[NotchShelf] Project drop target: %@", url.lastPathComponent)
    }

    private func saveProject(_ url: URL) {
        cancelProjectPreviewRestore()

        let project = url.standardizedFileURL
        recentProject = project
        UserDefaults.standard.set(project.path, forKey: Self.recentProjectDefaultsKey)
        onProjectChanged?(project)

        // Reuse the polished staged presentation for the first version of Project
        // Drop Zone: folder icon on the left and the project name in the footer.
        overlay.showStaged(items: [project])
        NSLog("[NotchShelf] Saved recent project: %@", project.path)

        let work = DispatchWorkItem { [weak self] in
            self?.restoreShelfOverlay()
        }
        projectPreviewTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: work)
    }

    private func restoreShelfOverlay() {
        cancelProjectPreviewRestore()

        if store.isEmpty {
            overlay.hide()
        } else {
            overlay.showStaged(items: store.items)
        }
    }

    private func cancelProjectPreviewRestore() {
        projectPreviewTask?.cancel()
        projectPreviewTask = nil
    }

    private func validatedRecentProject() -> URL? {
        guard let recentProject else { return nil }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: recentProject.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }

        return recentProject
    }
}

// MARK: - Project Drop Zone

/// A tiny transparent drag destination that lives exactly over the physical
/// camera cutout. It does not cover the left/right menu bar wings, so regular
/// menu-bar interaction remains untouched.
@MainActor
final class ProjectDropTarget {
    var onDragEntered: ((URL) -> Void)?
    var onDragExited: (() -> Void)?
    var onProjectDropped: ((URL) -> Void)?

    private var panel: ProjectDropPanel?
    private var screenObserver: NSObjectProtocol?

    func start() {
        guard screenObserver == nil else {
            rebuildTarget()
            return
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.rebuildTarget()
            }
        }

        rebuildTarget()
    }

    func stop() {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        panel?.orderOut(nil)
        panel = nil
    }

    private func rebuildTarget() {
        panel?.orderOut(nil)
        panel = nil

        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSLog("[NotchShelf] Project drop zone disabled: no physical notch")
            return
        }

        // A few extra points make the target forgiving without covering useful
        // menu-bar controls on either side of the camera housing.
        let targetSize = CGSize(
            width: geometry.hardwareWidth + 12,
            height: geometry.hardwareHeight
        )
        let frame = NSRect(
            x: screen.frame.midX - targetSize.width / 2,
            y: screen.frame.maxY - targetSize.height,
            width: targetSize.width,
            height: targetSize.height
        )

        let dropView = ProjectDropView(frame: NSRect(origin: .zero, size: targetSize))
        dropView.autoresizingMask = [.width, .height]
        dropView.onHover = { [weak self] url in
            Task { @MainActor in
                self?.onDragEntered?(url)
            }
        }
        dropView.onExit = { [weak self] in
            Task { @MainActor in
                self?.onDragExited?()
            }
        }
        dropView.onDrop = { [weak self] url in
            Task { @MainActor in
                self?.onProjectDropped?(url)
            }
        }

        let panel = ProjectDropPanel(frame: frame, dropView: dropView)
        self.panel = panel
        panel.orderFrontRegardless()

        NSLog(
            "[NotchShelf] Project drop zone ready: %@",
            NSStringFromRect(frame)
        )
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
        level = .mainMenu + 4
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
        guard let url = projectURL(from: sender) else {
            currentURL = nil
            return []
        }

        currentURL = url
        onHover?(url)
        return .link
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let url = projectURL(from: sender) else {
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
        guard let url = projectURL(from: sender) else { return false }

        completedDrop = true
        currentURL = nil
        onDrop?(url)
        return true
    }

    private func projectURL(from sender: NSDraggingInfo) -> URL? {
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
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: url.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            return nil
        }

        return url
    }
}
