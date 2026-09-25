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
    @Published var hardwareWidth: CGFloat = 200
    @Published var hardwareHeight: CGFloat = 32
    @Published var fileIcon: NSImage?
}

/// Physical-notch measurement adapted from Glance's notch geometry.
/// NotchShelf deliberately has no pill fallback: no physical notch, no overlay.
private struct NotchHardwareGeometry {
    let screen: NSScreen
    let width: CGFloat
    let height: CGFloat

    static func preferred() -> NotchHardwareGeometry? {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) else {
            return nil
        }

        let leftWidth = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightWidth = screen.auxiliaryTopRightArea?.width ?? 0
        let measuredWidth = screen.frame.width - leftWidth - rightWidth

        return NotchHardwareGeometry(
            screen: screen,
            width: max(measuredWidth, 200),
            height: screen.safeAreaInsets.top
        )
    }
}

@MainActor
final class NotchOverlayController {
    // Fixed envelope. Like Glance, this window never resizes; SwiftUI animates
    // only the black notch silhouette inside it.
    private static let panelSize = CGSize(width: 380, height: 82)

    private let model = NotchOverlayModel()
    private let panel: NSPanel
    private var dismissTask: DispatchWorkItem?
    private var returnToStagedTask: DispatchWorkItem?
    private var closeTask: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.level = .mainMenu + 3
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: NotchShelfView(model: model))
    }

    func showStaged(items: [URL]) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .staged
        model.itemCount = items.count
        model.fileIcon = fileIcon(for: items)
        revealFromHardwareNotchIfNeeded()
    }

    func showMoving(items: [URL], destination: URL) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .moving
        model.itemCount = items.count
        model.fileIcon = fileIcon(for: items)
        revealFromHardwareNotchIfNeeded()
    }

    func showSuccess(count: Int) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .success
        model.itemCount = count
        model.fileIcon = nil
        revealFromHardwareNotchIfNeeded()
        scheduleDismiss(after: 0.72)
    }

    func showFailure(_ message: String, remainingItems: [URL]) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .failure
        model.itemCount = remainingItems.count
        model.fileIcon = nil
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
        guard panel.isVisible else { return }
        animateClosedAndOrderOut()
    }

    @discardableResult
    private func preparePanel() -> Bool {
        guard let geometry = NotchHardwareGeometry.preferred() else {
            panel.orderOut(nil)
            NSLog("[NotchShelf] No physical notch detected. Overlay not shown; pill fallback is disabled.")
            return false
        }

        model.hardwareWidth = geometry.width
        model.hardwareHeight = geometry.height
        positionPanel(on: geometry.screen)
        return true
    }

    private func revealFromHardwareNotchIfNeeded() {
        if panel.isVisible {
            model.presented = true
            return
        }

        // Render one frame at the exact hardware-notch footprint, then expand.
        // This mirrors Glance's fixed-window approach and avoids a detached-card flash.
        model.presented = false
        panel.orderFrontRegardless()
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        DispatchQueue.main.async { [weak self] in
            self?.model.presented = true
        }
    }

    private func animateClosedAndOrderOut() {
        model.presented = false

        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
        }
        closeTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.48, execute: work)
    }

    private func positionPanel(on screen: NSScreen) {
        let size = Self.panelSize
        panel.setFrameOrigin(NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        ))
    }

    private func fileIcon(for items: [URL]) -> NSImage? {
        guard items.count == 1, let url = items.first else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 20, height: 20)
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
        dismissTask?.cancel()
        returnToStagedTask?.cancel()
        closeTask?.cancel()
        dismissTask = nil
        returnToStagedTask = nil
        closeTask = nil
    }
}
