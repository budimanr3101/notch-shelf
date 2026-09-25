import AppKit
import SwiftUI

@MainActor
final class NotchOverlayModel: ObservableObject {
    enum State: Equatable {
        case staged
        case moving
        case success
        case failure
    }

    @Published var state: State = .staged
    @Published var itemCount = 0
    @Published var presented = false
    @Published var geometry: NotchGeometry?
    @Published var fileIcon: NSImage?
    @Published var visualProgress: CGFloat = 0
}

struct NotchGeometry: Equatable {
    let hardwareWidth: CGFloat
    let hardwareHeight: CGFloat

    static let wingWidth: CGFloat = 42
    static let topRadius: CGFloat = 8
    static let bottomRadius: CGFloat = 12
    static let connectionOverlap: CGFloat = 10
    static let progressDepth: CGFloat = 10
    static let progressBottomSlack: CGFloat = 2

    var expandedWidth: CGFloat {
        hardwareWidth + 2 * (Self.wingWidth + Self.topRadius)
    }

    /// Fixed for one display configuration. Width includes room for horizontal
    /// spring overshoot. Height includes the maximum subtle progress extension,
    /// but staged/idle pixels remain transparent below the hardware notch band.
    var windowSize: CGSize {
        CGSize(
            width: expandedWidth + 32,
            height: hardwareHeight + Self.progressDepth + Self.progressBottomSlack
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

/// Fixed transparent panel anchored to the physical notch band.
/// The panel never resizes during an animation; SwiftUI changes only the surface
/// drawn inside this envelope.
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
        // We intentionally draw inside the display's unsafe camera-cutout band.
        // Leaving the default safe area enabled can shift the whole SwiftUI root
        // below the physical notch and create the detached-pill look.
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        contentView = hosting
    }
}

@MainActor
final class NotchOverlayController {
    private let model = NotchOverlayModel()
    private var panel: NotchWindow?
    private var dismissTask: DispatchWorkItem?
    private var returnToStagedTask: DispatchWorkItem?
    private var closeTask: DispatchWorkItem?
    private var revealTask: DispatchWorkItem?
    private var progressTask: DispatchWorkItem?
    private var lastLoggedGeometryKey: String?

    init() {
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

    func showStaged(items: [URL]) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .staged
        model.itemCount = items.count
        model.fileIcon = fileIcon(for: items)
        model.visualProgress = 0
        revealFromHardwareNotchIfNeeded()
    }

    func showMoving(items: [URL], destination: URL) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .moving
        model.itemCount = items.count
        model.fileIcon = fileIcon(for: items)
        model.visualProgress = 0.08
        revealFromHardwareNotchIfNeeded()
        startVisualProgress()
    }

    func showSuccess(count: Int) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .success
        model.itemCount = count
        model.visualProgress = 1
        revealFromHardwareNotchIfNeeded()
        scheduleDismiss(after: 0.95)
    }

    func showFailure(_ message: String, remainingItems: [URL]) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .failure
        model.itemCount = remainingItems.count
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

    func hide() {
        cancelTimers()
        guard panel?.isVisible == true else { return }
        animateClosedAndOrderOut()
    }

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
                "[NotchShelf] Geometry: screen=%@ frame=%@ safeTop=%.1f leftAux=%@ rightAux=%@ hardware=%.1fx%.1f window=%@ expanded=%.1fx%.1f overlap=%.1f progressDepth=%.1f",
                screen.localizedName,
                NSStringFromRect(screen.frame),
                screen.safeAreaInsets.top,
                NSStringFromRect(screen.auxiliaryTopLeftArea ?? .zero),
                NSStringFromRect(screen.auxiliaryTopRightArea ?? .zero),
                geometry.hardwareWidth,
                geometry.hardwareHeight,
                NSStringFromRect(panel.frame),
                geometry.expandedWidth,
                geometry.hardwareHeight,
                NotchGeometry.connectionOverlap,
                NotchGeometry.progressDepth
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

        // Frame zero is completely transparent. The next run-loop turn grows only
        // the software surface from the physical notch edges.
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
        model.presented = false

        let work = DispatchWorkItem { [weak self] in
            self?.panel?.orderOut(nil)
        }
        closeTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    /// FileManager does not currently expose byte-level progress through our move
    /// service, so the notch uses a visual progress curve: advance smoothly toward
    /// 90% while the operation is in flight, then complete to 100% on success.
    /// This avoids a frozen indeterminate spinner while never claiming completion
    /// before the move actually finishes.
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
            let step = max(0.006, remaining * 0.14)
            self.model.visualProgress = min(ceiling, self.model.visualProgress + step)

            if self.model.visualProgress < ceiling - 0.002 {
                self.scheduleProgressTick()
            }
        }

        progressTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    private func fileIcon(for items: [URL]) -> NSImage? {
        guard items.count == 1, let url = items.first else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 18, height: 18)
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
        dismissTask?.cancel()
        returnToStagedTask?.cancel()
        closeTask?.cancel()
        dismissTask = nil
        returnToStagedTask = nil
        closeTask = nil
    }
}
