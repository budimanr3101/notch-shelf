import AppKit
import Foundation

@MainActor
final class ShelfCoordinator {
    private let store = ShelfStore()
    private let finder = FinderBridge()
    private let mover = FileMoveService()
    private let overlay = NotchOverlayController()
    private let shortcuts = ShortcutMonitor()

    var onShelfChanged: ((Int) -> Void)?
    var stagedCount: Int { store.count }

    init() {
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
    }

    func start() {
        shortcuts.start()
    }

    func stop() {
        shortcuts.stop()
    }

    func clearShelf() {
        store.clear()
        shortcuts.refreshRegistrations()
        overlay.hide()
        onShelfChanged?(0)
    }

    private func cutFromFinder() {
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
}
