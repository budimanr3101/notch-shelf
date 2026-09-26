import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Shortcut

struct PocketbookV3Shortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = PocketbookV3Shortcut(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: UInt32(optionKey),
        keyLabel: "K"
    )

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
    }

    init?(event: NSEvent) {
        var modifiers: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        guard modifiers != 0 else { return nil }

        let characters = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let label = (characters?.isEmpty == false ? characters : nil) ?? "Key \(event.keyCode)"
        self.init(keyCode: UInt32(event.keyCode), modifiers: modifiers, keyLabel: label)
    }

    var displayString: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        return value + keyLabel
    }

    var conflictsWithFileShelf: Bool {
        return modifiers == UInt32(cmdKey)
            && (keyCode == UInt32(kVK_ANSI_X) || keyCode == UInt32(kVK_ANSI_V))
    }
}

// MARK: - Feature controller

@MainActor
final class PocketbookFeatureV3 {
    private static let keyCodeKey = "NotchShelf.Pocketbook.keyCode"
    private static let modifiersKey = "NotchShelf.Pocketbook.modifiers"
    private static let labelKey = "NotchShelf.Pocketbook.keyLabel"
    private let signature: OSType = 0x4E535033 // NSP3

    private let configuration = PocketbookV3Configuration.shared
    private lazy var model = PocketbookV3Model(configuration: configuration)
    private var shortcut: PocketbookV3Shortcut
    private var hotKey: EventHotKeyRef?
    private var panel: PocketbookV3Panel?
    private var keyMonitor: Any?
    private var settingsController: PocketbookV3SettingsWindowController?
    private var started = false
    private var requestedVisible = false
    private var pendingPresentation: DispatchWorkItem?
    private var pendingDismissal: DispatchWorkItem?

    var onShortcutChanged: (() -> Void)?
    var shortcutDescription: String { return shortcut.displayString }
    var isVisible: Bool { return requestedVisible && panel?.isVisible == true }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.keyCodeKey) != nil,
           defaults.object(forKey: Self.modifiersKey) != nil {
            shortcut = PocketbookV3Shortcut(
                keyCode: UInt32(defaults.integer(forKey: Self.keyCodeKey)),
                modifiers: UInt32(defaults.integer(forKey: Self.modifiersKey)),
                keyLabel: defaults.string(forKey: Self.labelKey) ?? "?"
            )
        } else {
            shortcut = .defaultShortcut
        }
    }

    func start() {
        guard !started else { return }

        let handlerStatus = CarbonHotKeyCenter.shared.setHandler(
            signature: signature,
            id: 1
        ) { [weak self] in
            guard let self = self else { return OSStatus(eventNotHandledErr) }
            self.toggle()
            return noErr
        }
        guard handlerStatus == noErr else {
            NSLog("[NotchShelf] Pocketbook shared hotkey handler failed: %d", handlerStatus)
            return
        }

        started = true
        let registerStatus = registerShortcut()
        if registerStatus != noErr {
            CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
            started = false
        }

        NSLog(registerStatus == noErr
            ? "[NotchShelf] Pocketbook ready on \(shortcut.displayString)"
            : "[NotchShelf] Pocketbook shortcut unavailable: \(shortcut.displayString)")
    }

    func stop() {
        requestedVisible = false
        pendingPresentation?.cancel()
        pendingPresentation = nil
        pendingDismissal?.cancel()
        pendingDismissal = nil
        removeKeyMonitor()
        panel?.ignoresMouseEvents = true
        panel?.makeFirstResponder(nil)
        panel?.orderOut(nil)
        model.presented = false

        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
        hotKey = nil
        panel = nil
        started = false
    }

    func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    func show() {
        if isVisible {
            panel?.ignoresMouseEvents = false
            panel?.makeKeyAndOrderFront(nil)
            return
        }

        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        configuration.reloadCustom()
        model.resetForPresentation()

        pendingDismissal?.cancel()
        pendingDismissal = nil
        pendingPresentation?.cancel()
        requestedVisible = true

        let metrics = PocketbookV3Metrics(geometry: geometry, screen: screen)
        let frame = NSRect(
            x: screen.frame.midX - metrics.windowSize.width / 2,
            y: screen.frame.maxY - metrics.windowSize.height,
            width: metrics.windowSize.width,
            height: metrics.windowSize.height
        )

        if panel?.frame != frame {
            panel?.makeFirstResponder(nil)
            panel?.orderOut(nil)
            panel = PocketbookV3Panel(
                frame: frame,
                model: model,
                geometry: geometry,
                metrics: metrics,
                onClose: { [weak self] in self?.hide() },
                onSettings: { [weak self] in self?.showSettings() }
            )
        }

        guard let panel = panel else { return }
        installKeyMonitor()
        panel.ignoresMouseEvents = false
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.displayIfNeeded()

        let presentation = DispatchWorkItem { [weak self, weak panel] in
            guard let self = self, self.requestedVisible,
                  self.panel === panel else { return }
            self.model.presented = true
            self.pendingPresentation = nil
        }
        pendingPresentation = presentation
        DispatchQueue.main.async(execute: presentation)
    }

    func hide() {
        guard requestedVisible, let panel = panel, panel.isVisible else { return }
        requestedVisible = false
        pendingPresentation?.cancel()
        pendingPresentation = nil
        removeKeyMonitor()
        panel.ignoresMouseEvents = true
        panel.makeFirstResponder(nil)
        panel.resignKey()
        pendingDismissal?.cancel()
        model.presented = false

        let dismissal = DispatchWorkItem { [weak self, weak panel] in
            guard let self = self, self.panel === panel,
                  !self.requestedVisible else { return }
            panel?.orderOut(nil)
            self.pendingDismissal = nil
        }
        pendingDismissal = dismissal

        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? PocketbookV3Motion.reducedDuration
            : PocketbookV3Motion.closeDuration
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dismissal)
    }

    func showSettings() {
        let wasVisible = isVisible
        if wasVisible { hide() }

        if settingsController == nil {
            settingsController = PocketbookV3SettingsWindowController(
                configuration: configuration,
                shortcutDescription: { [weak self] in self?.shortcutDescription ?? "" },
                configureShortcut: { [weak self] in self?.showShortcutRecorder() },
                onChanged: { [weak self] in
                    guard let self = self else { return }
                    self.model.reloadConfiguration(preferDefault: false)
                }
            )
        }

        let showBlock = { [weak self] in
            self?.settingsController?.show()
        }
        if wasVisible {
            DispatchQueue.main.asyncAfter(deadline: .now() + PocketbookV3Motion.closeDuration, execute: showBlock)
        } else {
            showBlock()
        }
    }

    func showShortcutRecorder() {
        let alert = NSAlert()
        alert.messageText = "Pocketbook Shortcut"
        alert.informativeText = "Press a shortcut using ⌘, ⌥, ⌃, or ⇧. It works globally from any app."
        let recorder = PocketbookV3ShortcutCaptureView(current: shortcut)
        alert.accessoryView = recorder
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)

        guard alert.runModal() == .alertFirstButtonReturn,
              let captured = recorder.captured else { return }
        guard setShortcut(captured) else {
            let error = NSAlert()
            error.messageText = "Shortcut Unavailable"
            error.informativeText = "\(captured.displayString) is already used or reserved."
            error.alertStyle = .warning
            error.runModal()
            return
        }
        onShortcutChanged?()
    }

    private func setShortcut(_ newValue: PocketbookV3Shortcut) -> Bool {
        guard !newValue.conflictsWithFileShelf else { return false }
        let previous = shortcut
        if let hotKey = hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        shortcut = newValue
        guard registerShortcut() == noErr else {
            shortcut = previous
            _ = registerShortcut()
            return false
        }

        let defaults = UserDefaults.standard
        defaults.set(Int(newValue.keyCode), forKey: Self.keyCodeKey)
        defaults.set(Int(newValue.modifiers), forKey: Self.modifiersKey)
        defaults.set(newValue.keyLabel, forKey: Self.labelKey)
        return true
    }

    private func registerShortcut() -> OSStatus {
        guard started else { return OSStatus(eventNotHandledErr) }
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            identifier,
            GetApplicationEventTarget(),
            OptionBits(0),
            &reference
        )
        if status == noErr { hotKey = reference }
        return status
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if event.keyCode == UInt16(kVK_Escape) {
                if self.model.selectedID != nil { self.model.selectedID = nil }
                else { self.hide() }
                return nil
            }

            if event.keyCode == UInt16(kVK_Return),
               self.model.selectedID == nil,
               self.model.currentBook != nil {
                self.model.selectedID = self.model.results.first?.id
                return nil
            }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command),
               event.keyCode == UInt16(kVK_ANSI_C),
               let entry = self.model.selected {
                self.model.copy(entry)
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor = keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}
