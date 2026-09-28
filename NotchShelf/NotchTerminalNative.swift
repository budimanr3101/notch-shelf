import AppKit
import Carbon.HIToolbox
import SwiftTerm
import SwiftUI

// MARK: - Native terminal shortcut

struct NotchTerminalShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = NotchTerminalShortcut(
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

        let safeGlobalModifiers = UInt32(cmdKey | optionKey | controlKey)
        guard modifiers & safeGlobalModifiers != 0 else { return nil }

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
        modifiers == UInt32(cmdKey)
            && (keyCode == UInt32(kVK_ANSI_X) || keyCode == UInt32(kVK_ANSI_V))
    }
}

// MARK: - SwiftTerm session

private enum NotchTerminalNativeActivityEvent {
    case started(String)
    case finished(Int32)
}

private final class NotchShelfLocalTerminalView: LocalProcessTerminalView {
    var onActivityEvent: ((NotchTerminalNativeActivityEvent) -> Void)?
    private var activityBuffer = ""

    override func dataReceived(slice: ArraySlice<UInt8>) {
        inspectActivityMarkers(slice)
        super.dataReceived(slice: slice)
    }

    private func inspectActivityMarkers(_ bytes: ArraySlice<UInt8>) {
        activityBuffer += String(decoding: bytes, as: UTF8.self)
        let prefix = "\u{1B}]777;notchshelf;"
        let terminator = "\u{7}"

        while let marker = activityBuffer.range(of: prefix),
              let end = activityBuffer.range(
                of: terminator,
                range: marker.upperBound..<activityBuffer.endIndex
              ) {
            let payload = String(activityBuffer[marker.upperBound..<end.lowerBound])
            if payload.hasPrefix("start;") {
                onActivityEvent?(.started(String(payload.dropFirst("start;".count))))
            } else if payload.hasPrefix("finish;"),
                      let status = Int32(payload.dropFirst("finish;".count)) {
                onActivityEvent?(.finished(status))
            }
            activityBuffer.removeSubrange(activityBuffer.startIndex..<end.upperBound)
        }

        if activityBuffer.count > 4096 {
            activityBuffer = String(activityBuffer.suffix(1024))
        }
    }
}

@MainActor
private final class NotchTerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    @Published var sessionAlive = false
    @Published var presented = false
    @Published var directoryLabel = "~"

    let terminalView: NotchShelfLocalTerminalView
    var onActivityChanged: (() -> Void)?

    private let workingDirectoryProvider: () -> URL?
    private var configurationDirectory: URL?
    private var restartRequested = false
    private let activityID = "notchshelf-native-terminal"

    init(workingDirectoryProvider: @escaping () -> URL?) {
        self.workingDirectoryProvider = workingDirectoryProvider
        terminalView = NotchShelfLocalTerminalView(frame: .zero)
        super.init()

        terminalView.processDelegate = self
        terminalView.autoresizingMask = [.width, .height]
        terminalView.onActivityEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .started(let command):
                    NotchTerminalActivityController.shared.begin(
                        id: self.activityID,
                        command: command.isEmpty ? "zsh task" : command
                    )
                case .finished(let status):
                    NotchTerminalActivityController.shared.finish(
                        id: self.activityID,
                        status: status
                    )
                }
                self.onActivityChanged?()
            }
        }
    }

    func ensureSession() {
        guard !sessionAlive else { return }
        startShell()
    }

    func restart() {
        restartRequested = true
        NotchTerminalActivityController.shared.finishSession(status: 130)
        if sessionAlive {
            terminalView.terminate()
        } else {
            restartRequested = false
            startShell()
        }
    }

    func stop() {
        restartRequested = false
        if sessionAlive {
            terminalView.terminate()
        }
        sessionAlive = false
        cleanupConfiguration()
    }

    func focus() {
        guard let window = terminalView.window else { return }
        window.makeFirstResponder(terminalView)
    }

    private func startShell() {
        cleanupConfiguration()

        let directory = initialDirectory()
        directoryLabel = displayDirectory(directory)

        do {
            let environment = try makeShellEnvironment()
            sessionAlive = true
            terminalView.startProcess(
                executable: "/bin/zsh",
                args: ["-l"],
                environment: environment,
                execName: "zsh",
                currentDirectory: directory.path
            )
            DispatchQueue.main.async { [weak self] in
                self?.focus()
            }
        } catch {
            sessionAlive = false
            NSLog("[NotchShelf] Native terminal setup failed: %@", error.localizedDescription)
        }
    }

    private func makeShellEnvironment() throws -> [String] {
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PROCESS_LAUNCHED_BY_Q"] = "1"
        environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? "UTF-8"

        let originalZDOTDIR = environment["ZDOTDIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let configuration = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshelf-native-zsh-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: configuration,
            withIntermediateDirectories: true
        )
        configurationDirectory = configuration

        func quote(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }

        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let original = URL(fileURLWithPath: originalZDOTDIR)
                .appendingPathComponent(file)
                .path
            var contents = "[[ -f " + quote(original) + " ]] && source " + quote(original) + "\n"
            contents += "export ZDOTDIR=" + quote(configuration.path) + "\n"

            if file == ".zlogin" {
                contents += """
                autoload -Uz add-zsh-hook
                function _notchshelf_preexec() {
                    printf '\\e]777;notchshelf;start;%s\\a' "$1"
                }
                function _notchshelf_precmd() {
                    local result=$?
                    printf '\\e]777;notchshelf;finish;%s\\a' "$result"
                    return $result
                }
                add-zsh-hook preexec _notchshelf_preexec
                add-zsh-hook precmd _notchshelf_precmd
                """
            }

            try contents.write(
                to: configuration.appendingPathComponent(file),
                atomically: true,
                encoding: .utf8
            )
        }

        environment["ZDOTDIR"] = configuration.path
        return environment.map { "\($0.key)=\($0.value)" }.sorted()
    }

    private func cleanupConfiguration() {
        guard let configurationDirectory else { return }
        try? FileManager.default.removeItem(at: configurationDirectory)
        self.configurationDirectory = nil
    }

    private func initialDirectory() -> URL {
        if let recent = workingDirectoryProvider() {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: recent.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? recent : recent.deletingLastPathComponent()
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private func displayDirectory(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if url.path == home { return "~" }
        if url.path.hasPrefix(home + "/") {
            return "~/" + String(url.path.dropFirst(home.count + 1))
        }
        return url.path
    }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let directory, !directory.isEmpty else { return }
        if let url = URL(string: directory), url.isFileURL {
            directoryLabel = displayDirectory(url)
        } else {
            directoryLabel = directory
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.sessionAlive = false
            NotchTerminalActivityController.shared.finishSession(status: exitCode ?? 1)
            self.cleanupConfiguration()

            guard self.restartRequested else { return }
            self.restartRequested = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.startShell()
            }
        }
    }
}

// MARK: - Notch surface

private struct NotchTerminalMetrics {
    let wingWidth: CGFloat
    let depth: CGFloat
    let maxDepth: CGFloat
    let contentWidth: CGFloat
    let windowSize: CGSize

    init(geometry: NotchGeometry, screen: NSScreen) {
        let availableHalfWidth = max(190, (screen.frame.width - geometry.hardwareWidth - 48) / 2)
        wingWidth = min(258, availableHalfWidth - NotchGeometry.topRadius)
        depth = 394
        maxDepth = 402
        contentWidth = geometry.hardwareWidth + 2 * wingWidth
        windowSize = CGSize(
            width: geometry.hardwareWidth + 2 * (wingWidth + NotchGeometry.topRadius) + 32,
            height: geometry.hardwareHeight + maxDepth + 4
        )
    }
}

@MainActor
final class NotchTerminalFeature {
    private static let keyCodeKey = "NotchShelf.Terminal.keyCode"
    private static let modifiersKey = "NotchShelf.Terminal.modifiers"
    private static let labelKey = "NotchShelf.Terminal.keyLabel"
    private static let activityPanelIdentifier = "NotchTerminalActivityPanel"
    private let signature: OSType = 0x4E535454 // NSTT

    private let session: NotchTerminalSession
    private let beforeShow: () -> Void
    private var shortcut: NotchTerminalShortcut
    private var hotKey: EventHotKeyRef?
    private var panel: NotchTerminalPanel?
    private var started = false
    private var requestedVisible = false
    private var pendingDismissal: DispatchWorkItem?
    private var resignObserver: NSObjectProtocol?

    var onShortcutChanged: (() -> Void)?
    var shortcutDescription: String { shortcut.displayString }
    var isVisible: Bool { requestedVisible && panel?.isVisible == true }

    init(
        workingDirectoryProvider: @escaping () -> URL?,
        beforeShow: @escaping () -> Void = {}
    ) {
        session = NotchTerminalSession(workingDirectoryProvider: workingDirectoryProvider)
        self.beforeShow = beforeShow

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.keyCodeKey) != nil,
           defaults.object(forKey: Self.modifiersKey) != nil {
            shortcut = NotchTerminalShortcut(
                keyCode: UInt32(defaults.integer(forKey: Self.keyCodeKey)),
                modifiers: UInt32(defaults.integer(forKey: Self.modifiersKey)),
                keyLabel: defaults.string(forKey: Self.labelKey) ?? "?"
            )
        } else {
            shortcut = .defaultShortcut
        }

        session.onActivityChanged = { [weak self] in
            self?.suppressActivityPanelIfNeeded()
        }
    }

    func start() {
        guard !started else { return }
        let handlerStatus = CarbonHotKeyCenter.shared.setHandler(
            signature: signature,
            id: 1
        ) { [weak self] in
            guard let self else { return OSStatus(eventNotHandledErr) }
            self.toggle()
            return noErr
        }
        guard handlerStatus == noErr else {
            NSLog("[NotchShelf] Terminal hotkey handler failed: %d", handlerStatus)
            return
        }

        started = true
        installActivitySuppressionObserver()
        let registerStatus = registerShortcut()
        if registerStatus != noErr {
            CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
            started = false
        }

        NSLog(registerStatus == noErr
            ? "[NotchShelf] Native terminal ready on \(shortcut.displayString)"
            : "[NotchShelf] Terminal shortcut unavailable: \(shortcut.displayString)")
    }

    func stop() {
        requestedVisible = false
        pendingDismissal?.cancel()
        pendingDismissal = nil
        session.presented = false
        session.stop()
        panel?.orderOut(nil)
        panel = nil

        if let observer = resignObserver {
            NotificationCenter.default.removeObserver(observer)
            resignObserver = nil
        }
        if let hotKey { UnregisterEventHotKey(hotKey) }
        CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
        self.hotKey = nil
        started = false
    }

    func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    func show() {
        if isVisible {
            panel?.makeKeyAndOrderFront(nil)
            suppressActivityPanelIfNeeded()
            DispatchQueue.main.async { [weak self] in self?.session.focus() }
            return
        }

        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        beforeShow()
        session.ensureSession()
        pendingDismissal?.cancel()
        pendingDismissal = nil
        requestedVisible = true

        let metrics = NotchTerminalMetrics(geometry: geometry, screen: screen)
        let frame = NSRect(
            x: screen.frame.midX - metrics.windowSize.width / 2,
            y: screen.frame.maxY - metrics.windowSize.height,
            width: metrics.windowSize.width,
            height: metrics.windowSize.height
        )

        if panel?.frame != frame {
            panel?.orderOut(nil)
            panel = NotchTerminalPanel(
                frame: frame,
                session: session,
                geometry: geometry,
                metrics: metrics,
                shortcutLabel: shortcut.displayString,
                onClose: { [weak self] in self?.hide() }
            )
        }

        panel?.ignoresMouseEvents = false
        panel?.makeKeyAndOrderFront(nil)
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
        suppressActivityPanelIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedVisible else { return }
            self.session.presented = true
            self.session.focus()
        }
    }

    func hide() {
        guard requestedVisible, let panel, panel.isVisible else { return }
        requestedVisible = false
        panel.ignoresMouseEvents = true
        panel.makeFirstResponder(nil)
        panel.resignKey()
        session.presented = false
        pendingDismissal?.cancel()

        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self, !self.requestedVisible, self.panel === panel else { return }
            panel?.orderOut(nil)
            self.pendingDismissal = nil
        }
        pendingDismissal = work
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.26
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func restartShell() {
        session.restart()
        if !isVisible { show() }
    }

    func showShortcutRecorder() {
        let alert = NSAlert()
        alert.messageText = "Notch Terminal Shortcut"
        alert.informativeText = "Press a global shortcut using ⌘, ⌥, or ⌃. Shift may be added."
        let recorder = NotchTerminalShortcutCaptureView(current: shortcut)
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

    private func setShortcut(_ newValue: NotchTerminalShortcut) -> Bool {
        guard !newValue.conflictsWithFileShelf else { return false }
        let previous = shortcut
        if let hotKey {
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

    private func installActivitySuppressionObserver() {
        guard resignObserver == nil else { return }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let window = note.object as? NSWindow,
                      self.panel === window else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) { [weak self] in
                    self?.suppressActivityPanelIfNeeded()
                }
            }
        }
    }

    private func suppressActivityPanelIfNeeded() {
        guard panel?.isVisible == true else { return }
        for window in NSApp.windows where window.identifier?.rawValue == Self.activityPanelIdentifier {
            window.orderOut(nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, self.panel?.isVisible == true else { return }
            for window in NSApp.windows where window.identifier?.rawValue == Self.activityPanelIdentifier {
                window.orderOut(nil)
            }
        }
    }
}

@MainActor
private final class NotchTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(
        frame: NSRect,
        session: NotchTerminalSession,
        geometry: NotchGeometry,
        metrics: NotchTerminalMetrics,
        shortcutLabel: String,
        onClose: @escaping () -> Void
    ) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = .mainMenu + 1
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false

        let hosting = NSHostingView(
            rootView: NotchTerminalView(
                session: session,
                geometry: geometry,
                metrics: metrics,
                shortcutLabel: shortcutLabel,
                onClose: onClose
            )
        )
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

private struct NotchTerminalNativeRepresentable: NSViewRepresentable {
    let session: NotchTerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView(frame: .zero)
        let terminal = session.terminalView
        terminal.removeFromSuperview()
        terminal.frame = container.bounds
        terminal.autoresizingMask = [.width, .height]
        container.addSubview(terminal)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

private struct NotchTerminalView: View {
    @ObservedObject var session: NotchTerminalSession
    let geometry: NotchGeometry
    let metrics: NotchTerminalMetrics
    let shortcutLabel: String
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shoulderExpansion: CGFloat = 0
    @State private var bridgeExpansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var pendingMotion: [DispatchWorkItem] = []

    private var surface: PocketbookV3Wings {
        PocketbookV3Wings(
            geometry: geometry,
            expansion: shoulderExpansion,
            extraDepth: bridgeExpansion * metrics.depth,
            wingWidth: metrics.wingWidth,
            maximumDepth: metrics.maxDepth
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            surface
                .fill(Color.black)
                .overlay {
                    PocketbookV3OuterEdge(
                        geometry: geometry,
                        expansion: shoulderExpansion,
                        extraDepth: bridgeExpansion * metrics.depth,
                        wingWidth: metrics.wingWidth,
                        maximumDepth: metrics.maxDepth
                    )
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.75)
                }
                .shadow(
                    color: Color.black.opacity(0.35 * Double(bridgeExpansion)),
                    radius: 16,
                    y: 6
                )

            content
                .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
                .mask(surface)
                .opacity(contentVisible ? 1 : 0)
                .offset(y: reduceMotion || contentVisible ? 0 : -5)
                .allowsHitTesting(session.presented && contentVisible)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .clipped()
        .opacity(reduceMotion && !session.presented ? 0 : 1)
        .onChange(of: session.presented) { visible in
            animatePresentation(visible)
        }
        .onChange(of: contentVisible) { visible in
            guard visible else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                session.focus()
            }
        }
        .onDisappear { cancelMotion() }
    }

    private var content: some View {
        VStack(spacing: 8) {
            header
            terminal
            footer
        }
        .padding(.horizontal, 16)
        .padding(.top, geometry.hardwareHeight + 9)
        .padding(.bottom, 10)
        .frame(
            width: metrics.contentWidth,
            height: geometry.hardwareHeight + metrics.depth,
            alignment: .top
        )
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.green)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text("Notch Terminal")
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                Text(session.directoryLabel)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(session.sessionAlive ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(session.sessionAlive ? "zsh" : "offline")
                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 30)
    }

    private var terminal: some View {
        NotchTerminalNativeRepresentable(session: session)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 0.5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text("Tab Complete")
            Text("•")
            Text("⌃C Interrupt")
            Text("•")
            Text("vi / nvim native")
            Spacer()
            Text("\(shortcutLabel) Close")
        }
        .font(.system(size: 8.5, weight: .medium, design: .rounded))
        .foregroundStyle(.secondary)
        .frame(height: 12)
    }

    private func animatePresentation(_ visible: Bool) {
        cancelMotion()

        if reduceMotion {
            shoulderExpansion = visible ? 1 : 0
            bridgeExpansion = visible ? 1 : 0
            withAnimation(.easeOut(duration: 0.12)) {
                contentVisible = visible
            }
            return
        }

        if visible {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)) {
                shoulderExpansion = 1
            }
            schedule(after: 0.06) {
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)) {
                    bridgeExpansion = 1
                }
            }
            schedule(after: 0.15) {
                withAnimation(.easeOut(duration: 0.12)) {
                    contentVisible = true
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.09)) {
                contentVisible = false
            }
            schedule(after: 0.04) {
                withAnimation(.timingCurve(0.55, 0, 0.85, 0.40, duration: 0.17)) {
                    bridgeExpansion = 0
                }
            }
            schedule(after: 0.12) {
                withAnimation(.timingCurve(0.55, 0, 0.85, 0.40, duration: 0.14)) {
                    shoulderExpansion = 0
                }
            }
        }
    }

    private func schedule(after delay: TimeInterval, _ block: @escaping () -> Void) {
        let item = DispatchWorkItem(block: block)
        pendingMotion.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelMotion() {
        pendingMotion.forEach { $0.cancel() }
        pendingMotion.removeAll()
    }
}

// MARK: - Shortcut recorder

@MainActor
private final class NotchTerminalShortcutCaptureView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Press a new shortcut")
    var captured: NotchTerminalShortcut?

    override var acceptsFirstResponder: Bool { true }

    init(current: NotchTerminalShortcut) {
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

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let value = NotchTerminalShortcut(event: event),
              !value.conflictsWithFileShelf else {
            NSSound.beep()
            hint.stringValue = "Use ⌘, ⌥, or ⌃ + key. Cmd+X / Cmd+V are reserved."
            return
        }
        captured = value
        shortcutLabel.stringValue = value.displayString
        hint.stringValue = "Ready to save"
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}
