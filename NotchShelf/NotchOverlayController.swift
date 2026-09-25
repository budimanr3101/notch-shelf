import AppKit
import SwiftUI

@MainActor
final class NotchOverlayModel: ObservableObject {
    enum State {
        case staged
        case moving
        case success
        case failure
    }

    @Published var state: State = .staged
    @Published var title = ""
    @Published var subtitle = ""
    @Published var itemCount = 0
    @Published var compact = false
    @Published var presented = false
    @Published var hardwareWidth: CGFloat = 200
    @Published var hardwareHeight: CGFloat = 32
    @Published var fileIcon: NSImage?
}

/// Physical-notch geometry, following the same approach used by Glance:
/// safe-area height + the two menu-bar regions flanking the camera housing.
/// There is deliberately no floating-pill fallback in NotchShelf.
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

        // The auxiliary-area calculation can be odd on unusual display layouts.
        // A real Apple notch should never be narrower than this in points.
        let width = max(measuredWidth, 200)
        let height = max(screen.safeAreaInsets.top, 28)

        return NotchHardwareGeometry(screen: screen, width: width, height: height)
    }
}

@MainActor
final class NotchOverlayController {
    private static let panelSize = CGSize(width: 460, height: 132)

    private let model = NotchOverlayModel()
    private let panel: NSPanel
    private var compactTask: DispatchWorkItem?
    private var dismissTask: DispatchWorkItem?
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
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.contentView = NSHostingView(rootView: NotchShelfView(model: model))
    }

    func showStaged(items: [URL]) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .staged
        model.itemCount = items.count
        model.title = items.count == 1 ? (items.first?.lastPathComponent ?? "File") : "\(items.count) items"
        model.subtitle = items.count == 1 ? "Ready to move" : "Ready to move together"
        model.fileIcon = fileIcon(for: items)
        model.compact = false

        revealFromHardwareNotch()

        let work = DispatchWorkItem { [weak self] in
            self?.model.compact = true
        }
        compactTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.05, execute: work)
    }

    func showMoving(items: [URL], destination: URL) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .moving
        model.itemCount = items.count
        model.title = items.count == 1 ? "Moving \(items.first?.lastPathComponent ?? "item")" : "Moving \(items.count) items"
        let destinationName = destination.lastPathComponent.isEmpty ? destination.path : destination.lastPathComponent
        model.subtitle = "to \(destinationName)"
        model.fileIcon = fileIcon(for: items)
        model.compact = false

        if panel.isVisible {
            model.presented = true
        } else {
            revealFromHardwareNotch()
        }
    }

    func showSuccess(count: Int) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .success
        model.itemCount = count
        model.title = count == 1 ? "Moved" : "Moved \(count) items"
        model.subtitle = ""
        model.fileIcon = nil
        model.compact = false

        if panel.isVisible {
            model.presented = true
        } else {
            revealFromHardwareNotch()
        }

        scheduleDismiss(after: 0.95)
    }

    func showFailure(_ message: String, remainingItems: [URL]) {
        cancelTimers()
        guard preparePanel() else { return }

        model.state = .failure
        model.itemCount = remainingItems.count
        model.title = "Couldn't move"
        model.subtitle = message
        model.fileIcon = nil
        model.compact = false

        if panel.isVisible {
            model.presented = true
        } else {
            revealFromHardwareNotch()
        }

        guard !remainingItems.isEmpty else {
            scheduleDismiss(after: 2.0)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showStaged(items: remainingItems)
        }
        compactTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
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
            NSLog("[NotchShelf] No physical notch detected. Overlay intentionally not shown; floating-pill fallback is disabled.")
            return false
        }

        model.hardwareWidth = geometry.width
        model.hardwareHeight = geometry.height
        positionPanel(on: geometry.screen)
        return true
    }

    private func revealFromHardwareNotch() {
        // First render exactly on top of the hardware notch. On the next run-loop
        // turn, animate the same silhouette outward/downward. This avoids the
        // detached-card flash that the old implementation had.
        model.presented = false
        panel.orderFrontRegardless()

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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32, execute: work)
    }

    private func positionPanel(on screen: NSScreen) {
        let size = Self.panelSize
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func fileIcon(for items: [URL]) -> NSImage? {
        guard items.count == 1, let url = items.first else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 24, height: 24)
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
        compactTask?.cancel()
        dismissTask?.cancel()
        closeTask?.cancel()
        compactTask = nil
        dismissTask = nil
        closeTask = nil
    }
}
