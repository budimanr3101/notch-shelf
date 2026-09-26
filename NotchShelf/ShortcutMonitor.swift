import AppKit
import Carbon.HIToolbox
import SwiftUI

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

    private init() {}

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
        guard let callback = callbacks[key(signature: hotKeyID.signature, id: hotKeyID.id)] else {
            return OSStatus(eventNotHandledErr)
        }
        return callback()
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

// MARK: - iTerm notch terminal shortcut

struct ITermNotchShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = ITermNotchShortcut(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(controlKey | optionKey),
        keyLabel: "T"
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

@MainActor
final class ITermNotchConfiguration: ObservableObject {
    static let shared = ITermNotchConfiguration()

    private static let profileKey = "NotchShelf.iTerm.profileName"
    private static let widthKey = "NotchShelf.iTerm.width"
    private static let heightKey = "NotchShelf.iTerm.height"
    private static let recentProjectKey = "NotchShelf.iTerm.useRecentProject"

    @Published var profileName: String {
        didSet { UserDefaults.standard.set(profileName, forKey: Self.profileKey) }
    }

    @Published var terminalWidth: Double {
        didSet { UserDefaults.standard.set(terminalWidth, forKey: Self.widthKey) }
    }

    @Published var terminalHeight: Double {
        didSet { UserDefaults.standard.set(terminalHeight, forKey: Self.heightKey) }
    }

    @Published var useRecentProject: Bool {
        didSet { UserDefaults.standard.set(useRecentProject, forKey: Self.recentProjectKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        profileName = defaults.string(forKey: Self.profileKey) ?? "Hotkey Window"
        terminalWidth = defaults.object(forKey: Self.widthKey) == nil ? 660 : defaults.double(forKey: Self.widthKey)
        terminalHeight = defaults.object(forKey: Self.heightKey) == nil ? 330 : defaults.double(forKey: Self.heightKey)
        useRecentProject = defaults.object(forKey: Self.recentProjectKey) == nil ? true : defaults.bool(forKey: Self.recentProjectKey)
    }
}

private struct ITermNotchRequest {
    let profileName: String
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let initialDirectory: String?
}

private enum ITermNotchBridgeResult {
    case success(String)
    case failure(String)
}

private enum ITermNotchAppleScriptBridge {
    static func execute(_ source: String) -> ITermNotchBridgeResult {
        guard let script = NSAppleScript(source: source) else {
            return .failure("Could not create AppleScript.")
        }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error = error {
            let message = error[NSAppleScript.errorMessage] as? String ?? error.description
            return .failure(message)
        }

        return .success(result.stringValue ?? "OK")
    }

    static func toggleScript(_ request: ITermNotchRequest) -> String {
        let profile = appleScriptString(request.profileName)
        let directoryCommand: String
        if let directory = request.initialDirectory {
            let command = "cd -- \(shellQuoted(directory))"
            directoryCommand = """
            try
                tell current session of targetWindow to write text \"\(appleScriptString(command))\"
            end try
"""
        } else {
            directoryCommand = ""
        }

        return """
tell application "iTerm2"
    set targetWindow to missing value
    repeat with candidate in windows
        try
            if (is hotkey window of candidate) is true then
                if ((hotkey window profile of candidate) as text) is "\(profile)" then
                    set targetWindow to candidate
                    exit repeat
                end if
            end if
        end try
    end repeat

    if targetWindow is missing value then
        try
            set targetWindow to (create hotkey window with profile "\(profile)")
        on error errorMessage number errorNumber
            return "ERROR|" & errorNumber & "|" & errorMessage
        end try
        set position of targetWindow to {\(request.x), \(request.y)}
        set size of targetWindow to {\(request.width), \(request.height)}
        \(directoryCommand)
        tell targetWindow to reveal hotkey window
        return "CREATED"
    else
        set position of targetWindow to {\(request.x), \(request.y)}
        set size of targetWindow to {\(request.width), \(request.height)}
        tell targetWindow to toggle hotkey window
        return "TOGGLED"
    end if
end tell
"""
    }

    static func revealScript(_ request: ITermNotchRequest) -> String {
        let profile = appleScriptString(request.profileName)
        return """
tell application "iTerm2"
    repeat with candidate in windows
        try
            if (is hotkey window of candidate) is true then
                if ((hotkey window profile of candidate) as text) is "\(profile)" then
                    set position of candidate to {\(request.x), \(request.y)}
                    set size of candidate to {\(request.width), \(request.height)}
                    tell candidate to reveal hotkey window
                    return "REVEALED"
                end if
            end if
        end try
    end repeat
    return "NOT_FOUND"
end tell
"""
    }

    private static func appleScriptString(_ value: String) -> String {
        return value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func shellQuoted(_ value: String) -> String {
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

@MainActor
final class ITermNotchTerminalFeature {
    private static let keyCodeKey = "NotchShelf.iTerm.keyCode"
    private static let modifiersKey = "NotchShelf.iTerm.modifiers"
    private static let labelKey = "NotchShelf.iTerm.keyLabel"
    private let signature: OSType = 0x4E535449 // NSTI

    private let configuration = ITermNotchConfiguration.shared
    private let workingDirectoryProvider: () -> URL?
    private var shortcut: ITermNotchShortcut
    private var hotKey: EventHotKeyRef?
    private var settingsController: ITermNotchSettingsWindowController?
    private var started = false
    private var busy = false

    var onShortcutChanged: (() -> Void)?
    var shortcutDescription: String { return shortcut.displayString }

    init(workingDirectoryProvider: @escaping () -> URL?) {
        self.workingDirectoryProvider = workingDirectoryProvider
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.keyCodeKey) != nil,
           defaults.object(forKey: Self.modifiersKey) != nil {
            shortcut = ITermNotchShortcut(
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
        let handlerStatus = CarbonHotKeyCenter.shared.setHandler(signature: signature, id: 1) { [weak self] in
            guard let self = self else { return OSStatus(eventNotHandledErr) }
            self.toggle()
            return noErr
        }
        guard handlerStatus == noErr else {
            NSLog("[NotchShelf] iTerm hotkey handler failed: %d", handlerStatus)
            return
        }

        started = true
        let registerStatus = registerShortcut()
        if registerStatus != noErr {
            CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
            started = false
        }
        NSLog(registerStatus == noErr
            ? "[NotchShelf] iTerm notch terminal ready on \(shortcut.displayString)"
            : "[NotchShelf] iTerm notch shortcut unavailable: \(shortcut.displayString)")
    }

    func stop() {
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
        hotKey = nil
        started = false
        busy = false
    }

    func toggle() {
        guard !busy else { return }
        guard isITermInstalled else {
            showITermMissingAlert()
            return
        }
        guard let request = makeRequest() else {
            NSSound.beep()
            return
        }

        busy = true
        let source = ITermNotchAppleScriptBridge.toggleScript(request)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ITermNotchAppleScriptBridge.execute(source)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                self.handle(result)
            }
        }
    }

    func reveal() {
        guard !busy else { return }
        guard isITermInstalled else {
            showITermMissingAlert()
            return
        }
        guard let request = makeRequest() else { return }

        busy = true
        let source = ITermNotchAppleScriptBridge.revealScript(request)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = ITermNotchAppleScriptBridge.execute(source)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                switch result {
                case .success(let value) where value == "NOT_FOUND":
                    self.toggle()
                default:
                    self.handle(result)
                }
            }
        }
    }

    func showSettings() {
        if settingsController == nil {
            settingsController = ITermNotchSettingsWindowController(
                configuration: configuration,
                shortcutDescription: { [weak self] in self?.shortcutDescription ?? "" },
                configureShortcut: { [weak self] in self?.showShortcutRecorder() },
                testTerminal: { [weak self] in self?.reveal() },
                openITerm: { [weak self] in self?.openITermApplication() }
            )
        }
        settingsController?.show()
    }

    func showShortcutRecorder() {
        let alert = NSAlert()
        alert.messageText = "iTerm Notch Shortcut"
        alert.informativeText = "Press a global shortcut using ⌘, ⌥, ⌃, or ⇧."
        let recorder = ITermNotchShortcutCaptureView(current: shortcut)
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

    var isITermInstalled: Bool {
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
    }

    private func openITermApplication() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") else {
            showITermMissingAlert()
            return
        }
        let openConfiguration = NSWorkspace.OpenConfiguration()
        openConfiguration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: openConfiguration) { _, error in
            if let error = error {
                NSLog("[NotchShelf] Could not open iTerm2: %@", error.localizedDescription)
            }
        }
    }

    private func makeRequest() -> ITermNotchRequest? {
        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else { return nil }

        let requestedWidth = CGFloat(configuration.terminalWidth)
        let requestedHeight = CGFloat(configuration.terminalHeight)
        let width = min(max(440, requestedWidth), screen.frame.width - 36)
        let height = min(max(220, requestedHeight), max(220, screen.frame.height - geometry.hardwareHeight - 60))
        let desktopTop = NSScreen.screens.map { $0.frame.maxY }.max() ?? screen.frame.maxY
        let screenTopOffset = desktopTop - screen.frame.maxY
        let x = screen.frame.minX + (screen.frame.width - width) / 2
        let y = screenTopOffset + geometry.hardwareHeight + 2
        let trimmedProfile = configuration.profileName.trimmingCharacters(in: .whitespacesAndNewlines)

        return ITermNotchRequest(
            profileName: trimmedProfile.isEmpty ? "Hotkey Window" : trimmedProfile,
            x: Int(x.rounded()),
            y: Int(y.rounded()),
            width: Int(width.rounded()),
            height: Int(height.rounded()),
            initialDirectory: resolvedInitialDirectory()
        )
    }

    private func resolvedInitialDirectory() -> String? {
        guard configuration.useRecentProject,
              let recent = workingDirectoryProvider() else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recent.path, isDirectory: &isDirectory) else { return nil }
        return isDirectory.boolValue ? recent.path : recent.deletingLastPathComponent().path
    }

    private func handle(_ result: ITermNotchBridgeResult) {
        switch result {
        case .success(let value):
            if value.hasPrefix("ERROR|") {
                showProfileSetupAlert(detail: value)
            } else {
                NSLog("[NotchShelf] iTerm notch terminal: %@", value)
            }
        case .failure(let message):
            if message.localizedCaseInsensitiveContains("not authorized")
                || message.localizedCaseInsensitiveContains("AppleEvent") {
                showAutomationPermissionAlert(detail: message)
            } else {
                showProfileSetupAlert(detail: message)
            }
        }
    }

    private func showITermMissingAlert() {
        let alert = NSAlert()
        alert.messageText = "iTerm2 Not Found"
        alert.informativeText = "Install iTerm2 first, then configure a Dedicated Hotkey Window profile."
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showProfileSetupAlert(detail: String) {
        let alert = NSAlert()
        alert.messageText = "Set Up iTerm2 Hotkey Window"
        alert.informativeText = "NotchShelf expects an iTerm2 Dedicated Hotkey Window profile named ‘\(configuration.profileName)’. In iTerm2 open Settings → Keys → Create a Dedicated Hotkey Window. For the cleanest notch look, use No Title Bar and All Spaces.\n\n\(detail)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open iTerm2")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openITermApplication() }
    }

    private func showAutomationPermissionAlert(detail: String) {
        let alert = NSAlert()
        alert.messageText = "Allow NotchShelf to Control iTerm2"
        alert.informativeText = "macOS must allow Automation access so NotchShelf can reveal and position the iTerm2 hotkey window. Check System Settings → Privacy & Security → Automation.\n\n\(detail)"
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func setShortcut(_ newValue: ITermNotchShortcut) -> Bool {
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
}

@MainActor
final class ITermNotchSettingsWindowController: NSObject {
    private let configuration: ITermNotchConfiguration
    private let shortcutDescription: () -> String
    private let configureShortcut: () -> Void
    private let testTerminal: () -> Void
    private let openITerm: () -> Void
    private var window: NSWindow?

    init(
        configuration: ITermNotchConfiguration,
        shortcutDescription: @escaping () -> String,
        configureShortcut: @escaping () -> Void,
        testTerminal: @escaping () -> Void,
        openITerm: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.shortcutDescription = shortcutDescription
        self.configureShortcut = configureShortcut
        self.testTerminal = testTerminal
        self.openITerm = openITerm
    }

    func show() {
        if window == nil {
            let frame = NSRect(x: 0, y: 0, width: 520, height: 470)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "iTerm Notch Terminal"
            window.isReleasedWhenClosed = false
            window.center()
            window.contentView = NSHostingView(
                rootView: ITermNotchSettingsView(
                    configuration: configuration,
                    shortcutDescription: shortcutDescription,
                    configureShortcut: configureShortcut,
                    testTerminal: testTerminal,
                    openITerm: openITerm
                )
            )
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct ITermNotchSettingsView: View {
    @ObservedObject var configuration: ITermNotchConfiguration
    let shortcutDescription: () -> String
    let configureShortcut: () -> Void
    let testTerminal: () -> Void
    let openITerm: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("iTerm Notch Terminal")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Use the real iTerm2 hotkey window as a terminal attached to the MacBook notch.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                settingsCard(title: "iTerm2") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Hotkey Window profile", text: $configuration.profileName)
                            .textFieldStyle(.roundedBorder)
                        Text("Create a Dedicated Hotkey Window in iTerm2 Settings → Keys. The profile name above must match. No Title Bar + All Spaces gives the cleanest result.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Open iTerm2", action: openITerm)
                            Button("Test Terminal", action: testTerminal)
                        }
                    }
                }

                settingsCard(title: "Notch Window") {
                    VStack(alignment: .leading, spacing: 12) {
                        Stepper("Width: \(Int(configuration.terminalWidth)) pt", value: $configuration.terminalWidth, in: 440...1000, step: 20)
                        Stepper("Height: \(Int(configuration.terminalHeight)) pt", value: $configuration.terminalHeight, in: 220...700, step: 20)
                        Toggle("Start a new terminal in the recent Drop Zone project", isOn: $configuration.useRecentProject)
                    }
                    .font(.system(size: 11.5))
                }

                settingsCard(title: "Shortcut") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Global terminal shortcut")
                                .font(.system(size: 12, weight: .medium))
                            Text(shortcutDescription())
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                        }
                        Spacer()
                        Button("Change…", action: configureShortcut)
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 440)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }
}

@MainActor
final class ITermNotchShortcutCaptureView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Press a new shortcut")
    var captured: ITermNotchShortcut?

    override var acceptsFirstResponder: Bool { return true }

    init(current: ITermNotchShortcut) {
        captured = current
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 74))
        shortcutLabel.stringValue = current.displayString
        shortcutLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        shortcutLabel.alignment = .center
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        [shortcutLabel, hint].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            shortcutLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            shortcutLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.topAnchor.constraint(equalTo: shortcutLabel.bottomAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let value = ITermNotchShortcut(event: event),
              !value.conflictsWithFileShelf else {
            NSSound.beep()
            hint.stringValue = "Use modifier + key. Cmd+X / Cmd+V are reserved."
            return
        }
        captured = value
        shortcutLabel.stringValue = value.displayString
        hint.stringValue = "Ready to save"
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
