import AppKit
import SwiftUI

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
}

final class NotchOverlayController {
    private let model = NotchOverlayModel()
    private let panel: NSPanel
    private var compactTask: DispatchWorkItem?
    private var dismissTask: DispatchWorkItem?

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
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
        panel.contentView = NSHostingView(rootView: NotchShelfView(model: model))
    }

    func showStaged(items: [URL]) {
        cancelTimers()
        model.state = .staged
        model.itemCount = items.count
        model.title = items.count == 1 ? "File staged" : "\(items.count) items staged"
        model.subtitle = items.count == 1
            ? (items.first?.lastPathComponent ?? "")
            : items.prefix(2).map(\.lastPathComponent).joined(separator: "  •  ")
        model.compact = false
        showPanel()

        let work = DispatchWorkItem { [weak self] in
            self?.model.compact = true
        }
        compactTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15, execute: work)
    }

    func showMoving(items: [URL], destination: URL) {
        cancelTimers()
        model.state = .moving
        model.itemCount = items.count
        model.title = items.count == 1 ? "Moving 1 item" : "Moving \(items.count) items"
        model.subtitle = "to \(destination.lastPathComponent.isEmpty ? destination.path : destination.lastPathComponent)"
        model.compact = false
        showPanel()
    }

    func showSuccess(count: Int) {
        cancelTimers()
        model.state = .success
        model.itemCount = count
        model.title = count == 1 ? "Moved" : "Moved \(count) items"
        model.subtitle = "Done"
        model.compact = false
        showPanel()
        scheduleDismiss(after: 1.35)
    }

    func showFailure(_ message: String, remainingItems: [URL]) {
        cancelTimers()
        model.state = .failure
        model.itemCount = remainingItems.count
        model.title = "Move failed"
        model.subtitle = message
        model.compact = false
        showPanel()

        guard !remainingItems.isEmpty else {
            scheduleDismiss(after: 2.5)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.showStaged(items: remainingItems)
        }
        compactTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    func hide() {
        cancelTimers()
        panel.orderOut(nil)
    }

    private func showPanel() {
        positionPanel()
        panel.orderFrontRegardless()
    }

    private func positionPanel() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
        guard let screen else { return }
        let size = panel.frame.size
        let x = screen.frame.midX - size.width / 2
        let y = screen.frame.maxY - size.height
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func scheduleDismiss(after delay: TimeInterval) {
        let work = DispatchWorkItem { [weak self] in
            self?.panel.orderOut(nil)
        }
        dismissTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelTimers() {
        compactTask?.cancel()
        dismissTask?.cancel()
        compactTask = nil
        dismissTask = nil
    }
}
