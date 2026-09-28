import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class NotchOverlayModel: ObservableObject {
    enum State: Equatable {
        case staged
        case moving
        case success
        case failure
        case dropHover
        case dropOpening
        case dropSuccess
        case dropFailure
        case notice
    }

    @Published var state: State = .staged
    @Published var itemCount = 0
    @Published var presented = false
    @Published var geometry: NotchGeometry?
    @Published var fileIcon: NSImage?
    @Published var visualProgress: CGFloat = 0
    @Published var itemLabel = ""
    @Published var actionLabel = ""
    @Published var targetAppName = ""
    @Published var targetAppIcon: NSImage?
}

struct NotchGeometry: Equatable {
    let hardwareWidth: CGFloat
    let hardwareHeight: CGFloat

    static let wingWidth: CGFloat = 42
    static let dropWingWidth: CGFloat = 82
    static let topRadius: CGFloat = 8
    static let bottomRadius: CGFloat = 12

    // Bleed beneath the physical edge to hide display antialias seams.
    static let connectionOverlap: CGFloat = 14

    // Compact File Shelf depths.
    static let labelDepth: CGFloat = 17
    static let progressDepth: CGFloat = 23

    // Drop Zone deliberately opens farther so drag feedback is impossible to
    // miss behind the physical camera housing.
    static let dropDepth: CGFloat = 42
    static let noticeDepth: CGFloat = 31
    static let bottomSlack: CGFloat = 3

    var expandedWidth: CGFloat {
        hardwareWidth + 2 * (Self.dropWingWidth + Self.topRadius)
    }

    /// Fixed maximum envelope. Neither file-move nor Drop Zone animations resize
    /// NSPanel; they only draw different surfaces inside this transparent window.
    var windowSize: CGSize {
        CGSize(
            width: expandedWidth + 32,
            height: hardwareHeight + Self.dropDepth + Self.bottomSlack
        )
    }

    static func measure(_ screen: NSScreen) -> NotchGeometry? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              left.width > 0,
              right.width > 0 else {
            return nil
        }

        let width = screen.frame.width - left.width - right.width
        guard width > 0, width < screen.frame.width / 2 else {
            return nil
        }

        return NotchGeometry(
            hardwareWidth: width,
            hardwareHeight: screen.safeAreaInsets.top
        )
    }
}

private final class NotchWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(geometry: NotchGeometry, model: NotchOverlayModel) {
        super.init(
            contentRect: NSRect(origin: .zero, size: geometry.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        hidesOnDeactivate = false

        let hosting = NSHostingView(rootView: NotchShelfView(model: model))
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: geometry.windowSize)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

// MARK: - Primary notch surface ownership

private enum NotchPrimarySurface: String {
    case terminal
    case pocketbook
    case launcher

    var hotKeySignature: OSType {
        switch self {
        case .terminal: return 0x4E535454 // NSTT
        case .pocketbook: return 0x4E535033 // NSP3
        case .launcher: return 0x4E534C41 // NSLA
        }
    }
}

/// Keeps the physical notch single-owner. Terminal, Pocketbook, and Launcher are
/// primary surfaces and must replace one another instead of stacking NSPanels.
/// Compact File Shelf / Drop Zone / terminal activity panels are intentionally
/// excluded because they cannot become key windows.
@MainActor
private final class NotchSurfaceManager {
    static let shared = NotchSurfaceManager()

    private var keyObserver: NSObjectProtocol?
    private weak var activeWindow: NSWindow?
    private var activeSurface: NotchPrimarySurface?

    private init() {}

    func start() {
        guard keyObserver == nil else { return }

        keyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let window = note.object as? NSWindow else { return }
                self.handleDidBecomeKey(window)
            }
        }
    }

    private func handleDidBecomeKey(_ window: NSWindow) {
        guard let nextSurface = surface(for: window) else { return }

        if let previousWindow = activeWindow,
           previousWindow !== window,
           let previousSurface = activeSurface,
           previousWindow.isVisible {
            // If the previous controller has not already started hiding, route the
            // same Carbon hotkey it owns. That lets its normal hide() path clear
            // key monitors, requestedVisible, animation state, and pending work.
            if !previousWindow.ignoresMouseEvents {
                let status = sendHotKey(to: previousSurface)
                if status != noErr {
                    NSLog(
                        "[NotchShelf] Surface manager could not dismiss %@: %d",
                        previousSurface.rawValue,
                        status
                    )
                }
            }

            // hide() intentionally keeps the panel around for its closing animation.
            // A surface switch must never visually stack, so remove the old panel now;
            // its controller has already moved to the hidden state above.
            previousWindow.orderOut(nil)

            NSLog(
                "[NotchShelf] Primary surface switched: %@ -> %@",
                previousSurface.rawValue,
                nextSurface.rawValue
            )
        }

        activeWindow = window
        activeSurface = nextSurface
    }

    private func surface(for window: NSWindow) -> NotchPrimarySurface? {
        guard window.canBecomeKey else { return nil }

        switch window.level.rawValue {
        case NSWindow.Level.mainMenu.rawValue + 1:
            return .terminal
        case NSWindow.Level.mainMenu.rawValue + 2:
            return .pocketbook
        case NSWindow.Level.mainMenu.rawValue + 3:
            return .launcher
        default:
            return nil
        }
    }

    private func sendHotKey(to surface: NotchPrimarySurface) -> OSStatus {
        var event: EventRef?
        let createStatus = CreateEvent(
            nil,
            OSType(kEventClassKeyboard),
            UInt32(kEventHotKeyPressed),
            GetCurrentEventTime(),
            EventAttributes(kEventAttributeNone),
            &event
        )
        guard createStatus == noErr, let event else { return createStatus }
        defer { ReleaseEvent(event) }

        var identifier = EventHotKeyID(signature: surface.hotKeySignature, id: 1)
        let setStatus = withUnsafePointer(to: &identifier) { pointer in
            SetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                MemoryLayout<EventHotKeyID>.size,
                pointer
            )
        }
        guard setStatus == noErr else { return setStatus }

        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }
}

@MainActor
final class NotchOverlayController {
    private static let minimumMovingPresentation: TimeInterval = 1.15

    private let model = NotchOverlayModel()
    private var panel: NotchWindow?
    private var dismissTask: DispatchWorkItem?
    private var returnToStagedTask: DispatchWorkItem?
    private var closeTask: DispatchWorkItem?
    private var revealTask: DispatchWorkItem?
    private var progressTask: DispatchWorkItem?
    private var successTask: DispatchWorkItem?
    private var movingStartedAt: TimeInterval?
    private var lastLoggedGeometryKey: String?

    init() {
        NotchSurfaceManager.shared.start()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenChanged() {
        guard model.presented else { return }
        if preparePanel() {
            panel?.orderFrontRegardless()
        }
    }

    // MARK: File Shelf

    func showStaged(items: [URL]) {
        cancelTimers()
        guard preparePanel() else { return }

        resetActionMetadata()
        model.state = .staged
        model.itemCount = items.count
        model.itemLabel = label(for: items)
        model.fileIcon = fileIcon(for: items)
        model.visualProgress = 0
        NSLog("[NotchShelf] Staged label: %@", model.itemLabel)
        revealFromHardwareNotchIfNeeded()
    }

    func showMoving(items: [URL], destination: URL) {
        cancelTimers()
        guard preparePanel() else { return }

        resetActionMetadata()
        model.state = .moving
        model.itemCount = items.count
        model.itemLabel = label(for: items)
        model.fileIcon = fileIcon(for: items)
        model.visualProgress = 0.03
        movingStartedAt = ProcessInfo.processInfo.systemUptime
        revealFromHardwareNotchIfNeeded()
        startVisualProgress()
    }

    func showSuccess(count: Int) {
        guard preparePanel() else { return }

        successTask?.cancel()
        successTask = nil

        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = movingStartedAt.map { max(0, now - $0) }
            ?? Self.minimumMovingPresentation
        let remaining = max(0, Self.minimumMovingPresentation - elapsed)

        guard remaining > 0.001 else {
            completeSuccess(count: count)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.completeSuccess(count: count)
        }
        successTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining, execute: work)
    }

    private func completeSuccess(count: Int) {
        successTask?.cancel()
        successTask = nil
        progressTask?.cancel()
        progressTask = nil
        movingStartedAt = nil

        model.state = .success
        model.itemCount = count
        model.visualProgress = 1
        revealFromHardwareNotchIfNeeded()
        scheduleDismiss(after: 1.05)
    }

    func showFailure(_ message: String, remainingItems: [URL]) {
        cancelTimers()
        guard preparePanel() else { return }

        resetActionMetadata()
        model.state = .failure
        model.itemCount = remainingItems.count
        model.itemLabel = remainingItems.isEmpty ? "Move failed" : label(for: remainingItems)
        model.actionLabel = message
        model.visualProgress = 0
        if !remainingItems.isEmpty {
            model.fileIcon = fileIcon(for: remainingItems)
        }
        revealFromHardwareNotchIfNeeded()

        guard !remainingItems.isEmpty else {
            scheduleDismiss(after: 1.2)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            self?.showStaged(items: remainingItems)
        }
        returnToStagedTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    // MARK: Developer Drop Zone

    func showDropHover(item: URL, targetAppName: String, targetAppIcon: NSImage?) {
        cancelTimers()
        guard preparePanel() else { return }

        configureDropMetadata(item: item, appName: targetAppName, appIcon: targetAppIcon)
        model.state = .dropHover
        model.actionLabel = "Drop to open in \(targetAppName)"
        revealFromHardwareNotchIfNeeded()
    }

    func showDropOpening(item: URL, targetAppName: String, targetAppIcon: NSImage?) {
        cancelTimers()
        guard preparePanel() else { return }

        configureDropMetadata(item: item, appName: targetAppName, appIcon: targetAppIcon)
        model.state = .dropOpening
        model.actionLabel = "Opening in \(targetAppName)…"
        revealFromHardwareNotchIfNeeded()
    }

    func showDropSuccess(item: URL, targetAppName: String, targetAppIcon: NSImage?) {
        cancelTimers()
        guard preparePanel() else { return }

        configureDropMetadata(item: item, appName: targetAppName, appIcon: targetAppIcon)
        model.state = .dropSuccess
        model.actionLabel = "Opened in \(targetAppName)"
        revealFromHardwareNotchIfNeeded()
    }

    func showDropFailure(
        item: URL,
        targetAppName: String,
        targetAppIcon: NSImage?,
        message: String
    ) {
        cancelTimers()
        guard preparePanel() else { return }

        configureDropMetadata(item: item, appName: targetAppName, appIcon: targetAppIcon)
        model.state = .dropFailure
        model.actionLabel = message.isEmpty ? "Couldn't open in \(targetAppName)" : message
        revealFromHardwareNotchIfNeeded()
    }

    func showNotice(title: String, subtitle: String, icon: NSImage?) {
        cancelTimers()
        guard preparePanel() else { return }

        resetActionMetadata()
        model.state = .notice
        model.itemLabel = title
        model.actionLabel = subtitle
        model.targetAppIcon = icon
        revealFromHardwareNotchIfNeeded()
    }

    func hide() {
        cancelTimers()
        guard panel?.isVisible == true else { return }
        animateClosedAndOrderOut()
    }

    // MARK: Presentation

    @discardableResult
    private func preparePanel() -> Bool {
        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            panel?.orderOut(nil)
            NSLog("[NotchShelf] No measurable physical notch. Overlay suppressed.")
            return false
        }

        if model.geometry != geometry || panel == nil {
            panel?.orderOut(nil)
            model.geometry = geometry
            panel = NotchWindow(geometry: geometry, model: model)
        }

        guard let panel else { return false }

        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - panel.frame.width / 2,
            y: screen.frame.maxY - panel.frame.height
        ))

        let key = "\(screen.frame)|\(geometry)|\(screen.backingScaleFactor)"
        if key != lastLoggedGeometryKey {
            lastLoggedGeometryKey = key
            NSLog(
                "[NotchShelf] Geometry: screen=%@ frame=%@ safeTop=%.1f hardware=%.1fx%.1f window=%@ overlap=%.1f dropWing=%.1f dropDepth=%.1f",
                screen.localizedName,
                NSStringFromRect(screen.frame),
                screen.safeAreaInsets.top,
                geometry.hardwareWidth,
                geometry.hardwareHeight,
                NSStringFromRect(panel.frame),
                NotchGeometry.connectionOverlap,
                NotchGeometry.dropWingWidth,
                NotchGeometry.dropDepth
            )
        }

        return true
    }

    private func revealFromHardwareNotchIfNeeded() {
        guard let panel else { return }

        if panel.isVisible {
            model.presented = true
            return
        }

        model.presented = false
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        let work = DispatchWorkItem { [weak self] in
            self?.model.presented = true
        }
        revealTask = work
        DispatchQueue.main.async(execute: work)
    }

    private func animateClosedAndOrderOut() {
        revealTask?.cancel()
        revealTask = nil
        progressTask?.cancel()
        progressTask = nil
        successTask?.cancel()
        successTask = nil
        movingStartedAt = nil
        model.presented = false

        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        closeTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    // MARK: File move visual progress

    private func startVisualProgress() {
        progressTask?.cancel()
        progressTask = nil
        scheduleProgressTick()
    }

    private func scheduleProgressTick() {
        guard model.state == .moving else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model.state == .moving else { return }

            let ceiling: CGFloat = 0.90
            let remaining = ceiling - self.model.visualProgress
            let step = max(0.008, remaining * 0.11)
            self.model.visualProgress = min(ceiling, self.model.visualProgress + step)

            if self.model.visualProgress < ceiling - 0.002 {
                self.scheduleProgressTick()
            }
        }

        progressTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.07, execute: work)
    }

    // MARK: Metadata

    private func configureDropMetadata(item: URL, appName: String, appIcon: NSImage?) {
        model.itemCount = 1
        model.itemLabel = item.lastPathComponent
        model.fileIcon = fileIcon(for: [item])
        model.targetAppName = appName
        model.targetAppIcon = appIcon
        model.visualProgress = 0
    }

    private func resetActionMetadata() {
        model.actionLabel = ""
        model.targetAppName = ""
        model.targetAppIcon = nil
    }

    private func label(for items: [URL]) -> String {
        guard items.count == 1, let item = items.first else {
            return "\(items.count) items"
        }
        return item.lastPathComponent
    }

    private func fileIcon(for items: [URL]) -> NSImage? {
        guard items.count == 1, let url = items.first else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 22, height: 22)
        return icon
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.animateClosedAndOrderOut()
        }
        dismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelTimers() {
        revealTask?.cancel()
        revealTask = nil
        progressTask?.cancel()
        progressTask = nil
        successTask?.cancel()
        successTask = nil
        movingStartedAt = nil
        dismissTask?.cancel()
        returnToStagedTask?.cancel()
        closeTask?.cancel()
        dismissTask = nil
        returnToStagedTask = nil
        closeTask = nil
    }
}
