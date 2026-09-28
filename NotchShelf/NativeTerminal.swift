import AppKit
import Carbon.HIToolbox
import SwiftTerm
import SwiftUI

@MainActor
final class NotchNativeTerminalState: ObservableObject {
    @Published var presented = false
    @Published var sessionAlive = false
    @Published var directoryLabel = "~"
}

fileprivate enum NotchNativeTerminalActivityEvent {
    case began(id: String, command: String)
    case finished(id: String, status: Int32)
}

/// SwiftTerm owns the PTY, keyboard input, ZLE, cursor, and VT rendering.
/// This subclass only mirrors NotchShelf's private OSC 777 activity messages.
fileprivate final class NotchShelfLocalTerminalView: LocalProcessTerminalView {
    var onActivityEvent: ((NotchNativeTerminalActivityEvent) -> Void)?

    private var oscState = 0
    private var oscBuffer: [UInt8] = []

    override func dataReceived(slice: ArraySlice<UInt8>) {
        scanActivityEvents(slice)
        super.dataReceived(slice: slice)
    }

    private func scanActivityEvents(_ bytes: ArraySlice<UInt8>) {
        for byte in bytes {
            switch oscState {
            case 0:
                if byte == 0x1B { oscState = 1 }
            case 1:
                if byte == 0x5D {
                    oscBuffer.removeAll(keepingCapacity: true)
                    oscState = 2
                } else {
                    oscState = byte == 0x1B ? 1 : 0
                }
            default:
                if byte == 0x07 {
                    handleOSC(oscBuffer)
                    oscBuffer.removeAll(keepingCapacity: true)
                    oscState = 0
                } else if oscBuffer.count < 4096 {
                    oscBuffer.append(byte)
                } else {
                    oscBuffer.removeAll(keepingCapacity: true)
                    oscState = 0
                }
            }
        }
    }

    private func handleOSC(_ bytes: [UInt8]) {
        let payload = String(decoding: bytes, as: UTF8.self)
        let pieces = payload.split(
            separator: ";",
            maxSplits: 4,
            omittingEmptySubsequences: false
        ).map(String.init)

        guard pieces.count == 5,
              pieces[0] == "777",
              pieces[1] == "notchshelf" else { return }

        switch pieces[2] {
        case "begin":
            onActivityEvent?(.began(id: pieces[3], command: pieces[4]))
        case "done":
            guard let status = Int32(pieces[4]) else { return }
            onActivityEvent?(.finished(id: pieces[3], status: status))
        default:
            break
        }
    }
}

@MainActor
final class NotchNativeTerminalController: NSObject, @preconcurrency LocalProcessTerminalViewDelegate {
    let state = NotchNativeTerminalState()
    fileprivate let terminalView: NotchShelfLocalTerminalView

    private var configurationDirectory: URL?
    private var ignoreNextTermination = false

    override init() {
        terminalView = NotchShelfLocalTerminalView(frame: .zero)
        super.init()

        terminalView.processDelegate = self
        terminalView.nativeForegroundColor = NSColor.white.withAlphaComponent(0.92)
        terminalView.nativeBackgroundColor = .black
        terminalView.caretColor = .systemGreen
        terminalView.getTerminal().setCursorStyle(.steadyBar)
        terminalView.onActivityEvent = { event in
            DispatchQueue.main.async {
                switch event {
                case let .began(id, command):
                    NotchTerminalActivityController.shared.begin(id: id, command: command)
                case let .finished(id, status):
                    NotchTerminalActivityController.shared.finish(id: id, status: status)
                }
            }
        }
    }

    func ensureSession(at directory: URL) {
        guard !terminalView.process.running else {
            state.sessionAlive = true
            focus()
            return
        }
        startSession(at: directory)
    }

    func restart(at directory: URL) {
        if terminalView.process.running {
            ignoreNextTermination = true
            terminalView.terminate()
        }
        removeConfigurationDirectory()
        state.sessionAlive = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.startSession(at: directory)
        }
    }

    func stop() {
        if terminalView.process.running {
            ignoreNextTermination = true
            terminalView.terminate()
        }
        state.sessionAlive = false
        state.presented = false
        removeConfigurationDirectory()
    }

    func focus() {
        guard let window = terminalView.window, window.isVisible else { return }
        window.makeFirstResponder(terminalView)
    }

    private func startSession(at directory: URL) {
        guard !terminalView.process.running else { return }

        do {
            let configuration = try makeZshConfiguration()
            configurationDirectory = configuration

            var environment = ProcessInfo.processInfo.environment
            environment["TERM"] = "xterm-256color"
            environment["COLORTERM"] = "truecolor"
            environment["TERM_PROGRAM"] = "NotchShelf"
            environment["PROCESS_LAUNCHED_BY_Q"] = "1"
            environment["ZDOTDIR"] = configuration.path
            environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? "UTF-8"

            state.directoryLabel = displayDirectory(directory)
            state.sessionAlive = true

            terminalView.startProcess(
                executable: "/bin/zsh",
                args: [],
                environment: environment.map { "\($0.key)=\($0.value)" },
                execName: "-zsh",
                currentDirectory: directory.path
            )
            focus()
        } catch {
            state.sessionAlive = false
            terminalView.feed(text: "Unable to start zsh: \(error.localizedDescription)\r\n")
        }
    }

    private func makeZshConfiguration() throws -> URL {
        removeConfigurationDirectory()

        let originalRoot = ProcessInfo.processInfo.environment["ZDOTDIR"]
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        let configuration = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchshelf-native-zsh-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: configuration,
            withIntermediateDirectories: true
        )

        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let original = URL(fileURLWithPath: originalRoot)
                .appendingPathComponent(file)
                .path
            var contents = "[[ -f " + shellQuote(original) + " ]] && source " + shellQuote(original) + "\n"
            contents += "export ZDOTDIR=" + shellQuote(configuration.path) + "\n"

            if file == ".zlogin" {
                contents += """

                autoload -Uz add-zsh-hook
                typeset -g _notchshelf_active_id=""

                function _notchshelf_preexec() {
                    local cmd="$1"
                    cmd="${cmd//$'\\a'/ }"
                    cmd="${cmd//$'\\e'/ }"
                    cmd="${cmd//;/,}"
                    _notchshelf_active_id="$$-$RANDOM-$SECONDS"
                    printf '\\e]777;notchshelf;begin;%s;%s\\a' "$_notchshelf_active_id" "$cmd"
                }

                function _notchshelf_precmd() {
                    local result=$?
                    if [[ -n ${_notchshelf_active_id-} ]]; then
                        printf '\\e]777;notchshelf;done;%s;%s\\a' "$_notchshelf_active_id" "$result"
                        _notchshelf_active_id=""
                    fi
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

        return configuration
    }

    private func removeConfigurationDirectory() {
        if let configurationDirectory {
            try? FileManager.default.removeItem(at: configurationDirectory)
        }
        configurationDirectory = nil
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
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
            state.directoryLabel = displayDirectory(url)
        } else {
            state.directoryLabel = directory
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        if ignoreNextTermination {
            ignoreNextTermination = false
            return
        }
        state.sessionAlive = false
        NotchTerminalActivityController.shared.finishSession(status: exitCode ?? 1)
    }
}

private struct NotchNativeTerminalRepresentable: NSViewRepresentable {
    let controller: NotchNativeTerminalController

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        controller.terminalView.removeFromSuperview()
        return controller.terminalView
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {}
}

private struct NotchNativeTerminalMetrics {
    let wingWidth: CGFloat
    let depth: CGFloat
    let maxDepth: CGFloat
    let contentWidth: CGFloat
    let windowSize: CGSize

    init(geometry: NotchGeometry, screen: NSScreen) {
        let availableHalfWidth = max(
            160,
            (screen.frame.width - geometry.hardwareWidth - 48) / 2
        )
        wingWidth = min(240, availableHalfWidth - NotchGeometry.topRadius)
        depth = 350
        maxDepth = 358
        contentWidth = geometry.hardwareWidth + 2 * wingWidth
        windowSize = CGSize(
            width: geometry.hardwareWidth + 2 * (wingWidth + NotchGeometry.topRadius) + 32,
            height: geometry.hardwareHeight + maxDepth + 4
        )
    }
}

@MainActor
final class NotchNativeTerminalFeature {
    private static let keyCodeKey = "NotchShelf.Terminal.keyCode"
    private static let modifiersKey = "NotchShelf.Terminal.modifiers"
    private static let labelKey = "NotchShelf.Terminal.keyLabel"

    private let signature: OSType = 0x4E535454 // NSTT
    private let workingDirectoryProvider: () -> URL?
    private let beforeShow: () -> Void
    private let controller = NotchNativeTerminalController()
    private var shortcut: NotchTerminalShortcut
    private var hotKey: EventHotKeyRef?
    private var panel: NotchNativeTerminalPanel?
    private var started = false
    private var requestedVisible = false
    private var pendingDismissal: DispatchWorkItem?

    var onShortcutChanged: (() -> Void)?
    var shortcutDescription: String { shortcut.displayString }
    var isVisible: Bool { requestedVisible && panel?.isVisible == true }

    init(
        workingDirectoryProvider: @escaping () -> URL?,
        beforeShow: @escaping () -> Void = {}
    ) {
        self.workingDirectoryProvider = workingDirectoryProvider
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
            NSLog("[NotchShelf] Native terminal hotkey handler failed: %d", handlerStatus)
            return
        }

        started = true
        let registerStatus = registerShortcut()
        if registerStatus != noErr {
            CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
            started = false
        }
    }

    func stop() {
        requestedVisible = false
        pendingDismissal?.cancel()
        pendingDismissal = nil
        controller.state.presented = false
        controller.stop()
        panel?.orderOut(nil)
        panel = nil

        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
        started = false
    }

    func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    func show() {
        if isVisible {
            panel?.makeKeyAndOrderFront(nil)
            controller.focus()
            return
        }

        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        beforeShow()
        controller.ensureSession(at: initialDirectory())
        pendingDismissal?.cancel()
        pendingDismissal = nil
        requestedVisible = true

        let metrics = NotchNativeTerminalMetrics(geometry: geometry, screen: screen)
        let frame = NSRect(
            x: screen.frame.midX - metrics.windowSize.width / 2,
            y: screen.frame.maxY - metrics.windowSize.height,
            width: metrics.windowSize.width,
            height: metrics.windowSize.height
        )

        if panel == nil {
            panel = NotchNativeTerminalPanel(
                frame: frame,
                controller: controller,
                geometry: geometry,
                metrics: metrics,
                onClose: { [weak self] in self?.hide() }
            )
        } else {
            panel?.setFrame(frame, display: false)
        }

        panel?.ignoresMouseEvents = false
        panel?.makeKeyAndOrderFront(nil)
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedVisible else { return }
            self.controller.state.presented = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                self?.controller.focus()
            }
        }
    }

    func hide() {
        guard requestedVisible, let panel, panel.isVisible else { return }
        requestedVisible = false
        panel.ignoresMouseEvents = true
        panel.makeFirstResponder(nil)
        panel.resignKey()
        controller.state.presented = false
        pendingDismissal?.cancel()

        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self,
                  !self.requestedVisible,
                  self.panel === panel else { return }
            panel?.orderOut(nil)
            self.pendingDismissal = nil
        }
        pendingDismissal = work

        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.26
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func restartShell() {
        controller.restart(at: initialDirectory())
        if !isVisible { show() }
    }

    func showShortcutRecorder() {
        let alert = NSAlert()
        alert.messageText = "Notch Terminal Shortcut"
        alert.informativeText = "Press a global shortcut using ⌘, ⌥, or ⌃. Shift may be added."
        let recorder = NotchNativeTerminalShortcutCaptureView(current: shortcut)
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

    private func initialDirectory() -> URL {
        if let recent = workingDirectoryProvider() {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: recent.path, isDirectory: &isDirectory) {
                return isDirectory.boolValue ? recent : recent.deletingLastPathComponent()
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

@MainActor
private final class NotchNativeTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(
        frame: NSRect,
        controller: NotchNativeTerminalController,
        geometry: NotchGeometry,
        metrics: NotchNativeTerminalMetrics,
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
            rootView: NotchNativeTerminalView(
                controller: controller,
                geometry: geometry,
                metrics: metrics,
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

private struct NotchNativeTerminalView: View {
    @ObservedObject private var state: NotchNativeTerminalState

    let controller: NotchNativeTerminalController
    let geometry: NotchGeometry
    let metrics: NotchNativeTerminalMetrics
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shoulderExpansion: CGFloat = 0
    @State private var bridgeExpansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var pendingMotion: [DispatchWorkItem] = []

    init(
        controller: NotchNativeTerminalController,
        geometry: NotchGeometry,
        metrics: NotchNativeTerminalMetrics,
        onClose: @escaping () -> Void
    ) {
        self.controller = controller
        self.geometry = geometry
        self.metrics = metrics
        self.onClose = onClose
        _state = ObservedObject(wrappedValue: controller.state)
    }

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
                .frame(
                    width: metrics.windowSize.width,
                    height: metrics.windowSize.height,
                    alignment: .top
                )
                .mask(surface)
                .opacity(contentVisible ? 1 : 0)
                .offset(y: reduceMotion || contentVisible ? 0 : -5)
                .allowsHitTesting(state.presented && contentVisible)
        }
        .frame(
            width: metrics.windowSize.width,
            height: metrics.windowSize.height,
            alignment: .top
        )
        .clipped()
        .opacity(reduceMotion && !state.presented ? 0 : 1)
        .onChange(of: state.presented) { visible in
            animatePresentation(visible)
            if visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    controller.focus()
                }
            }
        }
        .onDisappear { cancelMotion() }
    }

    private var content: some View {
        VStack(spacing: 8) {
            header

            NotchNativeTerminalRepresentable(controller: controller)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

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
                Text(state.directoryLabel)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(state.sessionAlive ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(state.sessionAlive ? "zsh" : "offline")
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

    private var footer: some View {
        HStack(spacing: 9) {
            Text("Tab Complete")
            Text("•")
            Text("↑↓ History")
            Text("•")
            Text("⌃R Search")
            Text("•")
            Text("⌃L Clear")
            Spacer()
            Text("× or shortcut to close")
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

@MainActor
private final class NotchNativeTerminalShortcutCaptureView: NSView {
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
