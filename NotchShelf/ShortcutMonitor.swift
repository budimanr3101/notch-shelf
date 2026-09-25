import AppKit
import Carbon.HIToolbox

@MainActor
final class ShortcutMonitor {
    private enum HotKeyKind: UInt32 {
        case cut = 1
        case paste = 2
    }

    /// "NSHF". Used to make sure we only handle hotkeys registered by NotchShelf.
    private let hotKeySignature: OSType = 0x4E534846

    private var cutHotKey: EventHotKeyRef?
    private var pasteHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var activationObserver: NSObjectProtocol?

    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var shouldCapturePaste: (() -> Bool)?
    var isFinderFrontmost: (() -> Bool)?

    func start() {
        guard eventHandler == nil else {
            refreshRegistrations()
            return
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else {
                    return OSStatus(eventNotHandledErr)
                }

                var hotKeyID = EventHotKeyID()
                let readStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard readStatus == noErr else { return readStatus }

                let monitor = Unmanaged<ShortcutMonitor>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                return MainActor.assumeIsolated {
                    monitor.handle(hotKeyID)
                }
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )

        guard status == noErr else {
            NSLog("[NotchShelf] Could not install Carbon hotkey handler (OSStatus \(status))")
            return
        }

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshRegistrations()
            }
        }

        refreshRegistrations()
        NSLog("[NotchShelf] Hotkey monitor started — no Accessibility or Input Monitoring permission required")
    }

    func stop() {
        unregisterCut()
        unregisterPaste()

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    /// Re-evaluates which shortcuts NotchShelf should own right now.
    ///
    /// Cmd+X is only registered while Finder is frontmost. Cmd+V is even narrower:
    /// it is only registered while Finder is frontmost AND the shelf contains files.
    /// That means normal paste behavior remains untouched whenever the shelf is empty.
    func refreshRegistrations() {
        let finderIsFrontmost = isFinderFrontmost?()
            ?? (NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder")

        guard finderIsFrontmost else {
            unregisterCut()
            unregisterPaste()
            return
        }

        registerCutIfNeeded()

        if shouldCapturePaste?() == true {
            registerPasteIfNeeded()
        } else {
            unregisterPaste()
        }
    }

    private func registerCutIfNeeded() {
        guard cutHotKey == nil else { return }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: HotKeyKind.cut.rawValue)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_X),
            UInt32(cmdKey),
            id,
            GetApplicationEventTarget(),
            OptionBits(0),
            &ref
        )

        guard status == noErr else {
            NSLog("[NotchShelf] Could not register Cmd+X (OSStatus \(status))")
            return
        }

        cutHotKey = ref
        NSLog("[NotchShelf] Cmd+X registered for Finder")
    }

    private func registerPasteIfNeeded() {
        guard pasteHotKey == nil else { return }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: hotKeySignature, id: HotKeyKind.paste.rawValue)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            UInt32(cmdKey),
            id,
            GetApplicationEventTarget(),
            OptionBits(0),
            &ref
        )

        guard status == noErr else {
            NSLog("[NotchShelf] Could not register Cmd+V (OSStatus \(status))")
            return
        }

        pasteHotKey = ref
        NSLog("[NotchShelf] Cmd+V captured while shelf has staged items")
    }

    private func unregisterCut() {
        guard let cutHotKey else { return }
        UnregisterEventHotKey(cutHotKey)
        self.cutHotKey = nil
    }

    private func unregisterPaste() {
        guard let pasteHotKey else { return }
        UnregisterEventHotKey(pasteHotKey)
        self.pasteHotKey = nil
    }

    private func handle(_ hotKeyID: EventHotKeyID) -> OSStatus {
        guard hotKeyID.signature == hotKeySignature else {
            return OSStatus(eventNotHandledErr)
        }

        switch hotKeyID.id {
        case HotKeyKind.cut.rawValue:
            onCut?()
            return noErr

        case HotKeyKind.paste.rawValue:
            guard shouldCapturePaste?() == true else {
                refreshRegistrations()
                return OSStatus(eventNotHandledErr)
            }
            onPaste?()
            return noErr

        default:
            return OSStatus(eventNotHandledErr)
        }
    }
}
