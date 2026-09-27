import AppKit
import Carbon.HIToolbox
import Darwin

/// Prepares the embedded terminal to behave like an interactive zsh session
/// instead of replaying login-only startup files inside NotchShelf.app.
///
/// `NotchTerminalShell` currently creates a temporary ZDOTDIR and mirrors the
/// user's startup files into it. By pointing its source directory at this
/// bridge, only the startup files an interactive shell actually needs are
/// forwarded: `.zshenv` and `.zshrc`. Login-only `.zprofile` / `.zlogin` are
/// intentionally omitted so app-launch automation and macOS/TCC side effects
/// are not replayed every time the notch terminal starts.
private enum NotchTerminalZshEnvironment {
    private static let bridgeFolderName = "notchshelf-interactive-zdotdir"

    static func prepare() {
        let fileManager = FileManager.default
        let bridge = fileManager.temporaryDirectory
            .appendingPathComponent(bridgeFolderName, isDirectory: true)

        let inheritedZDOTDIR = ProcessInfo.processInfo.environment["ZDOTDIR"]
        if inheritedZDOTDIR == bridge.path {
            return
        }

        let original = inheritedZDOTDIR.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? fileManager.homeDirectoryForCurrentUser

        do {
            if fileManager.fileExists(atPath: bridge.path) {
                try fileManager.removeItem(at: bridge)
            }
            try fileManager.createDirectory(
                at: bridge,
                withIntermediateDirectories: true
            )

            try zshenvBridge(original: original).write(
                to: bridge.appendingPathComponent(".zshenv"),
                atomically: true,
                encoding: .utf8
            )
            try zshrcBridge(original: original).write(
                to: bridge.appendingPathComponent(".zshrc"),
                atomically: true,
                encoding: .utf8
            )

            bridge.path.withCString { path in
                _ = setenv("ZDOTDIR", path, 1)
            }
            NSLog(
                "[NotchShelf] Embedded zsh startup: interactive config only (.zshenv + .zshrc)"
            )
        } catch {
            NSLog(
                "[NotchShelf] Could not prepare embedded zsh config bridge: %@",
                error.localizedDescription
            )
        }
    }

    private static func zshenvBridge(original: URL) -> String {
        let directory = shellQuote(original.path)
        let zshenv = shellQuote(original.appendingPathComponent(".zshenv").path)

        return """
        _NOTCHSHELF_SESSION_ZDOTDIR="$ZDOTDIR"
        export ZDOTDIR=\(directory)
        [[ -f \(zshenv) ]] && source \(zshenv)
        _NOTCHSHELF_USER_ZDOTDIR="$ZDOTDIR"
        export ZDOTDIR="$_NOTCHSHELF_SESSION_ZDOTDIR"
        unset _NOTCHSHELF_SESSION_ZDOTDIR
        """ + "\n"
    }

    private static func zshrcBridge(original: URL) -> String {
        let fallback = shellQuote(original.path)

        return """
        _NOTCHSHELF_SESSION_ZDOTDIR="$ZDOTDIR"
        if [[ -z ${_NOTCHSHELF_USER_ZDOTDIR-} ]]; then
            _NOTCHSHELF_USER_ZDOTDIR=\(fallback)
        fi
        export ZDOTDIR="$_NOTCHSHELF_USER_ZDOTDIR"
        [[ -f "$ZDOTDIR/.zshrc" ]] && source "$ZDOTDIR/.zshrc"
        export ZDOTDIR="$_NOTCHSHELF_SESSION_ZDOTDIR"
        unset _NOTCHSHELF_SESSION_ZDOTDIR
        """ + "\n"
    }

    private static func shellQuote(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

/// A single Carbon event handler for every NotchShelf global hotkey.
///
/// File Shelf and Pocketbook used to install independent handlers on the same
/// application event target. Keeping one dispatcher avoids handler ordering
/// issues while still letting each feature register its own EventHotKeyRef.
@MainActor
final class CarbonHotKeyCenter {
    static let shared = CarbonHotKeyCenter()

    typealias Callback = () -> OSStatus

    private var eventHandler: EventHandlerRef?
    private var callbacks: [UInt64: Callback] = [:]

    private init() {
        NotchTerminalZshEnvironment.prepare()
    }

    func setHandler(
        signature: OSType,
        id: UInt32,
        callback: @escaping Callback
    ) -> OSStatus {
        let status = ensureEventHandler()
        guard status == noErr else { return status }
        callbacks[key(signature: signature, id: id)] = callback
        return noErr
    }

    func removeHandler(signature: OSType, id: UInt32) {
        callbacks.removeValue(forKey: key(signature: signature, id: id))
    }

    private func ensureEventHandler() -> OSStatus {
        if eventHandler != nil { return noErr }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        return InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event = event, let userData = userData else {
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

                let center = Unmanaged<CarbonHotKeyCenter>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                return MainActor.assumeIsolated {
                    center.dispatch(hotKeyID)
                }
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
    }

    private func dispatch(_ hotKeyID: EventHotKeyID) -> OSStatus {
        let signature = signatureString(hotKeyID.signature)
        NSLog(
            "[NotchShelf] Hotkey fired: %@ id=%u",
            signature,
            hotKeyID.id
        )

        guard let callback = callbacks[key(signature: hotKeyID.signature, id: hotKeyID.id)] else {
            NSLog(
                "[NotchShelf] No callback for hotkey %@ id=%u",
                signature,
                hotKeyID.id
            )
            return OSStatus(eventNotHandledErr)
        }

        let status = callback()
        NSLog(
            "[NotchShelf] Hotkey handled: %@ id=%u status=%d",
            signature,
            hotKeyID.id,
            status
        )
        return status
    }

    private func signatureString(_ signature: OSType) -> String {
        let bytes: [UInt8] = [
            UInt8((signature >> 24) & 0xFF),
            UInt8((signature >> 16) & 0xFF),
            UInt8((signature >> 8) & 0xFF),
            UInt8(signature & 0xFF),
        ]
        return String(bytes: bytes, encoding: .ascii)
            ?? String(format: "0x%08X", signature)
    }

    private func key(signature: OSType, id: UInt32) -> UInt64 {
        return (UInt64(signature) << 32) | UInt64(id)
    }
}

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
    private var activationObserver: NSObjectProtocol?
    private var started = false

    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var shouldCapturePaste: (() -> Bool)?
    var isFinderFrontmost: (() -> Bool)?

    func start() {
        if started {
            refreshRegistrations()
            return
        }

        let cutStatus = CarbonHotKeyCenter.shared.setHandler(
            signature: hotKeySignature,
            id: HotKeyKind.cut.rawValue
        ) { [weak self] in
            guard let self = self else { return OSStatus(eventNotHandledErr) }
            self.onCut?()
            return noErr
        }
        guard cutStatus == noErr else {
            NSLog("[NotchShelf] Could not install shared Cut hotkey handler (OSStatus %d)", cutStatus)
            return
        }

        let pasteStatus = CarbonHotKeyCenter.shared.setHandler(
            signature: hotKeySignature,
            id: HotKeyKind.paste.rawValue
        ) { [weak self] in
            guard let self = self else { return OSStatus(eventNotHandledErr) }
            guard self.shouldCapturePaste?() == true else {
                self.refreshRegistrations()
                return OSStatus(eventNotHandledErr)
            }
            self.onPaste?()
            return noErr
        }
        guard pasteStatus == noErr else {
            CarbonHotKeyCenter.shared.removeHandler(
                signature: hotKeySignature,
                id: HotKeyKind.cut.rawValue
            )
            NSLog("[NotchShelf] Could not install shared Paste hotkey handler (OSStatus %d)", pasteStatus)
            return
        }

        started = true
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
        NSLog("[NotchShelf] Hotkey monitor started with shared Carbon router")
    }

    func stop() {
        unregisterCut()
        unregisterPaste()

        CarbonHotKeyCenter.shared.removeHandler(
            signature: hotKeySignature,
            id: HotKeyKind.cut.rawValue
        )
        CarbonHotKeyCenter.shared.removeHandler(
            signature: hotKeySignature,
            id: HotKeyKind.paste.rawValue
        )

        if let activationObserver = activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        started = false
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
            NSLog("[NotchShelf] Could not register Cmd+X (OSStatus %d)", status)
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
            NSLog("[NotchShelf] Could not register Cmd+V (OSStatus %d)", status)
            return
        }

        pasteHotKey = ref
        NSLog("[NotchShelf] Cmd+V captured while shelf has staged items")
    }

    private func unregisterCut() {
        guard let cutHotKey = cutHotKey else { return }
        UnregisterEventHotKey(cutHotKey)
        self.cutHotKey = nil
    }

    private func unregisterPaste() {
        guard let pasteHotKey = pasteHotKey else { return }
        UnregisterEventHotKey(pasteHotKey)
        self.pasteHotKey = nil
    }
}
