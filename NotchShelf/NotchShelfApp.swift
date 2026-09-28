import AppKit
import Carbon.HIToolbox
import SwiftUI

@main
struct NotchShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Self.migrateTerminalShortcutDefaultIfNeeded()

        Task { @MainActor in
            NotchTerminalActivityController.shared.start()
        }
    }

    private static func migrateTerminalShortcutDefaultIfNeeded() {
        let defaults = UserDefaults.standard
        let keyCodeKey = "NotchShelf.Terminal.keyCode"
        let modifiersKey = "NotchShelf.Terminal.modifiers"
        let labelKey = "NotchShelf.Terminal.keyLabel"
        let migrationVersionKey = "NotchShelf.Terminal.shortcutMigrationVersion"
        let currentMigrationVersion = 1

        guard defaults.integer(forKey: migrationVersionKey) < currentMigrationVersion else {
            return
        }
        defer {
            defaults.set(currentMigrationVersion, forKey: migrationVersionKey)
        }

        let hasSavedShortcut = defaults.object(forKey: keyCodeKey) != nil
            && defaults.object(forKey: modifiersKey) != nil
        let savedKeyCode = UInt32(defaults.integer(forKey: keyCodeKey))
        let savedModifiers = UInt32(defaults.integer(forKey: modifiersKey))

        let legacyControlOptionT = savedKeyCode == UInt32(kVK_ANSI_T)
            && savedModifiers == UInt32(controlKey | optionKey)
        let legacyShiftCommandT = savedKeyCode == UInt32(kVK_ANSI_T)
            && savedModifiers == UInt32(shiftKey | cmdKey)

        guard !hasSavedShortcut || legacyControlOptionT || legacyShiftCommandT else { return }

        defaults.set(Int(kVK_ANSI_N), forKey: keyCodeKey)
        defaults.set(Int(shiftKey | cmdKey), forKey: modifiersKey)
        defaults.set("N", forKey: labelKey)
        NSLog("[NotchShelf] Terminal shortcut default migrated to ⇧⌘N")
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Background terminal activity

private enum NotchTerminalActivityKind: Equatable {
    case running
    case finished
    case failed
}

private struct NotchTerminalActivityPresentation: Equatable {
    let kind: NotchTerminalActivityKind
    let command: String
    let startedAt: Date
    var exitCode: Int32? = nil

    var statusLabel: String {
        switch kind {
        case .running: return "Terminal running"
        case .finished: return exitCode == 130 ? "Stopped" : "Finished"
        case .failed: return "Failed · exit \(exitCode ?? 1)"
        }
    }
}

private enum NotchTerminalActivityAnimation {
    case packets
    case terminalBot
    case waveform

    static func style(for command: String) -> NotchTerminalActivityAnimation {
        let value = command.lowercased()

        if value.contains("ping ")
            || value.contains("curl ")
            || value.contains("wget ")
            || value.contains("ssh ")
            || value.contains("scp ")
            || value.contains("rsync ")
            || value.contains("kubectl logs")
            || value.contains("kubectl port-forward")
            || value.contains("tail -f") {
            return .packets
        }

        if value.contains("docker ")
            || value.contains("npm ")
            || value.contains("pnpm ")
            || value.contains("yarn ")
            || value.contains("terraform ")
            || value.contains("tofu ")
            || value.contains("brew ")
            || value.contains("git clone")
            || value.contains("make ")
            || value.contains("xcodebuild") {
            return .terminalBot
        }

        return .waveform
    }
}

@MainActor
final class NotchTerminalActivityController: ObservableObject {
    static let shared = NotchTerminalActivityController()

    @Published fileprivate var presentation: NotchTerminalActivityPresentation?

    private static let panelIdentifier = NSUserInterfaceItemIdentifier("NotchTerminalActivityPanel")
    private static let finishedDisplayDuration: TimeInterval = 2.2
    private static let terminalHotKeySignature: OSType = 0x4E535454 // NSTT

    private var panel: NotchTerminalActivityPanel?
    private var commandID: String?
    private var currentCommand = ""
    private var activeStartedAt: Date?
    private var started = false
    private var terminalExpanded = false
    private var finishDismissal: DispatchWorkItem?
    private var terminalResignWork: DispatchWorkItem?
    private var observers: [NSObjectProtocol] = []

    var isRunning: Bool { commandID != nil }

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.installTerminalHotKeyRoute()
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let window = note.object as? NSWindow,
                      self.isFullTerminalWindow(window) else { return }
                self.terminalResignWork?.cancel()
                self.terminalResignWork = nil
                self.terminalExpanded = true
                self.hidePanel()
                self.scrollTerminalToBottom(window)
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let window = note.object as? NSWindow,
                      self.isFullTerminalWindow(window) else { return }
                self.scheduleTerminalCollapsed()
            }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didOrderOffScreenNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                guard let self,
                      let window = note.object as? NSWindow,
                      self.isFullTerminalWindow(window) else { return }
                self.terminalExpanded = false
                self.refreshVisibility()
            }
        })

        if NSApp.isRunning {
            DispatchQueue.main.async { [weak self] in
                self?.installTerminalHotKeyRoute()
            }
        }

        NSLog("[NotchShelf] Background terminal activity ready (event-driven)")
    }

    func begin(id: String, command: String) {
        finishDismissal?.cancel()
        finishDismissal = nil

        let now = Date()
        commandID = id
        currentCommand = command
        activeStartedAt = now
        presentation = NotchTerminalActivityPresentation(
            kind: .running,
            command: prettyCommand(command),
            startedAt: now
        )
        NSLog("[NotchShelf] command started")
        refreshVisibility()
    }

    func finish(id: String, status: Int32) {
        guard commandID == id else { return }
        commandID = nil

        presentation = NotchTerminalActivityPresentation(
            kind: status == 0 || status == 130 ? .finished : .failed,
            command: prettyCommand(currentCommand),
            startedAt: activeStartedAt ?? Date(),
            exitCode: status
        )
        NSLog("[NotchShelf] command finished: exit=%d", status)
        refreshVisibility()

        finishDismissal?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.commandID == nil else { return }
            self.presentation = nil
            self.hidePanel()
            self.finishDismissal = nil
        }
        finishDismissal = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.finishedDisplayDuration,
            execute: work
        )
    }

    func finishSession(status: Int32) {
        if let id = commandID {
            finish(id: id, status: status)
        }
    }

    private func installTerminalHotKeyRoute() {
        let status = CarbonHotKeyCenter.shared.setHandler(
            signature: Self.terminalHotKeySignature,
            id: 1
        ) {
            guard let delegate = NSApp.delegate else {
                return OSStatus(eventNotHandledErr)
            }
            let handled = NSApp.sendAction(
                NSSelectorFromString("openTerminalAction"),
                to: delegate,
                from: nil
            )
            NSLog("[NotchShelf] Terminal hotkey routed to AppDelegate handled=%d", handled ? 1 : 0)
            return handled ? noErr : OSStatus(eventNotHandledErr)
        }

        if status != noErr {
            NSLog("[NotchShelf] Terminal hotkey route failed: %d", status)
        }
    }

    private func scrollTerminalToBottom(_ window: NSWindow) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self, weak window] in
            guard let self,
                  let window,
                  window.isVisible,
                  self.isFullTerminalWindow(window) else { return }

            if self.scrollFirstScrollViewToBottom(in: window.contentView) {
                NSLog("[NotchShelf] Terminal restored at latest output")
            }
        }
    }

    @discardableResult
    private func scrollFirstScrollViewToBottom(in view: NSView?) -> Bool {
        guard let view else { return false }

        if let scrollView = view as? NSScrollView,
           let documentView = scrollView.documentView {
            documentView.layoutSubtreeIfNeeded()
            scrollView.layoutSubtreeIfNeeded()

            let clipView = scrollView.contentView
            let maximumY = max(0, documentView.bounds.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: clipView.bounds.origin.x, y: maximumY))
            scrollView.reflectScrolledClipView(clipView)
            return true
        }

        for subview in view.subviews.reversed() {
            if scrollFirstScrollViewToBottom(in: subview) {
                return true
            }
        }
        return false
    }

    private func scheduleTerminalCollapsed() {
        terminalResignWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.terminalExpanded = false
            self.terminalResignWork = nil
            self.refreshVisibility()
        }
        terminalResignWork = work

        let delay: TimeInterval = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? 0.14
            : 0.32
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func refreshVisibility() {
        guard presentation != nil,
              !terminalExpanded,
              !hasVisibleFullTerminalWindow,
              !isAnotherNotchSurfaceVisible else {
            hidePanel()
            return
        }
        showPanel()
    }

    private func isFullTerminalWindow(_ window: NSWindow) -> Bool {
        guard window.identifier != Self.panelIdentifier else { return false }
        let terminalLevel = NSWindow.Level.mainMenu.rawValue + 1
        return window.level.rawValue == terminalLevel
            && window.frame.height > 240
            && window.frame.width > 360
    }

    private var hasVisibleFullTerminalWindow: Bool {
        NSApp.windows.contains { window in
            window.isVisible && isFullTerminalWindow(window)
        }
    }

    private var isAnotherNotchSurfaceVisible: Bool {
        let pocketbookLevel = NSWindow.Level.mainMenu.rawValue + 2
        return NSApp.windows.contains { window in
            guard window.isVisible,
                  window.identifier != Self.panelIdentifier else { return false }
            return window.level.rawValue >= pocketbookLevel
                && window.frame.height > 150
                && window.frame.width > 260
        }
    }

    private func showPanel() {
        guard presentation != nil,
              !hasVisibleFullTerminalWindow,
              let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            return
        }

        let metrics = NotchTerminalActivityMetrics(geometry: geometry, screen: screen)
        let frame = NSRect(
            x: screen.frame.midX - metrics.windowSize.width / 2,
            y: screen.frame.maxY - metrics.windowSize.height,
            width: metrics.windowSize.width,
            height: metrics.windowSize.height
        )

        if panel == nil || panel?.frame != frame {
            panel?.orderOut(nil)
            panel = NotchTerminalActivityPanel(
                frame: frame,
                controller: self,
                geometry: geometry,
                metrics: metrics,
                onOpen: { [weak self] in self?.openTerminal() }
            )
            panel?.identifier = Self.panelIdentifier
        }

        guard panel?.isVisible != true else { return }
        NSLog("[NotchShelf] background activity visible")
        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
        guard panel?.isVisible == true else { return }
        panel?.orderOut(nil)
    }

    private func openTerminal() {
        hidePanel()
        guard let delegate = NSApp.delegate else { return }
        _ = NSApp.sendAction(
            NSSelectorFromString("openTerminalAction"),
            to: delegate,
            from: nil
        )
    }

    private func prettyCommand(_ raw: String) -> String {
        let pieces = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = pieces.first else { return raw }

        let executable = URL(fileURLWithPath: first).lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let tail = pieces.dropFirst().prefix(5)
        var value = ([executable] + tail).joined(separator: " ")
        if value.count > 42 {
            value = String(value.prefix(39)) + "…"
        }
        return value
    }
}

private struct NotchTerminalActivityMetrics {
    let wingWidth: CGFloat
    let depth: CGFloat
    let windowSize: CGSize
    let contentWidth: CGFloat

    init(geometry: NotchGeometry, screen: NSScreen) {
        let availableHalfWidth = max(110, (screen.frame.width - geometry.hardwareWidth - 36) / 2)
        wingWidth = min(176, availableHalfWidth - NotchGeometry.topRadius)
        depth = 50
        contentWidth = geometry.hardwareWidth + 2 * wingWidth
        windowSize = CGSize(
            width: geometry.hardwareWidth + 2 * (wingWidth + NotchGeometry.topRadius) + 20,
            height: geometry.hardwareHeight + depth + 4
        )
    }
}

@MainActor
private final class NotchTerminalActivityPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(
        frame: NSRect,
        controller: NotchTerminalActivityController,
        geometry: NotchGeometry,
        metrics: NotchTerminalActivityMetrics,
        onOpen: @escaping () -> Void
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
            rootView: NotchTerminalActivityView(
                controller: controller,
                geometry: geometry,
                metrics: metrics,
                onOpen: onOpen
            )
        )
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

private struct NotchTerminalActivityView: View {
    @ObservedObject var controller: NotchTerminalActivityController
    let geometry: NotchGeometry
    let metrics: NotchTerminalActivityMetrics
    let onOpen: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var surface: PocketbookV3Wings {
        PocketbookV3Wings(
            geometry: geometry,
            expansion: 1,
            extraDepth: metrics.depth,
            wingWidth: metrics.wingWidth,
            maximumDepth: metrics.depth
        )
    }

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .top) {
                surface
                    .fill(Color.black)
                    .overlay {
                        PocketbookV3OuterEdge(
                            geometry: geometry,
                            expansion: 1,
                            extraDepth: metrics.depth,
                            wingWidth: metrics.wingWidth,
                            maximumDepth: metrics.depth
                        )
                        .stroke(Color.white.opacity(hovering ? 0.17 : 0.105), lineWidth: 0.75)
                    }
                    .shadow(color: Color.black.opacity(0.34), radius: 11, y: 4)

                if let presentation = controller.presentation {
                    TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30.0)) { context in
                        activityContent(presentation: presentation, now: context.date)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
            .contentShape(Rectangle())
            .onHover { value in
                withAnimation(.easeOut(duration: 0.12)) {
                    hovering = value
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Notch Terminal")
    }

    private func activityContent(
        presentation: NotchTerminalActivityPresentation,
        now: Date
    ) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.065))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.white.opacity(0.09), lineWidth: 0.6)
                        }

                    Image(systemName: "terminal.fill")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.88))
                }
                .frame(width: 25, height: 25)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)

                        Text(presentation.statusLabel)
                            .font(.system(size: 8.7, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.43))
                    }

                    Text(presentation.command)
                        .font(.system(size: 10.7, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            activityVisual(presentation: presentation, now: now)
                .frame(width: 92, height: 28)

            if presentation.kind == .running {
                Text(elapsed(from: presentation.startedAt, to: now))
                    .font(.system(size: 9.7, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.56))
                    .frame(minWidth: 38, alignment: .trailing)
            } else {
                Image(systemName: presentation.kind == .failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(presentation.kind == .failed ? Color.red.opacity(0.8) : Color.green)
                    .frame(minWidth: 38, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, geometry.hardwareHeight + 7)
        .frame(
            width: metrics.contentWidth,
            height: geometry.hardwareHeight + metrics.depth,
            alignment: .top
        )
        .opacity(hovering ? 1 : 0.96)
    }

    @ViewBuilder
    private func activityVisual(
        presentation: NotchTerminalActivityPresentation,
        now: Date
    ) -> some View {
        if presentation.kind == .failed {
            Image(systemName: "xmark").foregroundStyle(Color.red.opacity(0.75))
        } else if reduceMotion {
            Image(systemName: presentation.kind == .running ? "terminal" : "checkmark")
                .foregroundStyle(Color.white.opacity(0.65))
        } else if presentation.kind != .running {
            finishedAnimation(now: now)
        } else {
            switch NotchTerminalActivityAnimation.style(for: presentation.command) {
            case .packets:
                packetAnimation(now: now)
            case .terminalBot:
                terminalBotAnimation(now: now)
            case .waveform:
                waveformAnimation(now: now)
            }
        }
    }

    private func packetAnimation(now: Date) -> some View {
        GeometryReader { proxy in
            let width = max(CGFloat(1), proxy.size.width - 10)
            let t = now.timeIntervalSinceReferenceDate

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.055))
                    .frame(height: 2)
                    .padding(.horizontal, 4)

                ForEach(0..<7, id: \.self) { index in
                    let raw = (t * 0.55 + Double(index) * 0.13)
                        .truncatingRemainder(dividingBy: 1)
                    let phase = raw < 0 ? raw + 1 : raw
                    let emphasis = 1 - abs(0.5 - phase) * 1.45
                    let dotSize = CGFloat(3.5 + max(0, emphasis) * 2.3)

                    Circle()
                        .fill(index.isMultiple(of: 2) ? Color.cyan : Color.green)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(0.25 + max(0, emphasis) * 0.75)
                        .shadow(
                            color: (index.isMultiple(of: 2) ? Color.cyan : Color.green)
                                .opacity(0.45),
                            radius: CGFloat(max(0, emphasis) * 4)
                        )
                        .offset(x: 4 + CGFloat(phase) * width)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func terminalBotAnimation(now: Date) -> some View {
        GeometryReader { proxy in
            let t = now.timeIntervalSinceReferenceDate
            let travel = max(CGFloat(1), proxy.size.width - 31)
            let raw = (t * 0.32).truncatingRemainder(dividingBy: 1)
            let phase = raw < 0 ? raw + 1 : raw
            let bounce = CGFloat(abs(sin(t * 7.4)) * -1.7)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 2)
                    .padding(.horizontal, 5)

                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(Color.green.opacity(0.34 - Double(index) * 0.055))
                        .frame(width: 3, height: 3)
                        .offset(
                            x: max(
                                CGFloat(2),
                                CGFloat(phase) * travel - CGFloat(index * 6)
                            )
                        )
                }

                TerminalBotGlyph()
                    .frame(width: 27, height: 24)
                    .offset(x: CGFloat(phase) * travel, y: bounce)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func waveformAnimation(now: Date) -> some View {
        HStack(alignment: .center, spacing: 2.4) {
            ForEach(0..<11, id: \.self) { index in
                let t = now.timeIntervalSinceReferenceDate * 4.0
                let wave = (sin(t + Double(index) * 0.72) + 1) / 2

                Capsule()
                    .fill(Color.accentColor.opacity(0.38 + wave * 0.58))
                    .frame(width: 3.2, height: CGFloat(4 + wave * 16))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func finishedAnimation(now: Date) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        let pulse = CGFloat(0.94 + 0.06 * sin(t * 7.5))

        return HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.green.opacity(0.18 + Double(index) * 0.18))
                    .frame(width: 4, height: 4)
            }

            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color.green)
                .scaleEffect(pulse)

            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Color.green.opacity(0.54 - Double(index) * 0.14))
                    .frame(width: 4, height: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        let minutes = seconds / 60
        let remainder = seconds % 60

        if minutes >= 60 {
            let hours = minutes / 60
            return String(format: "%d:%02d:%02d", hours, minutes % 60, remainder)
        }

        return String(format: "%02d:%02d", minutes, remainder)
    }
}

private struct TerminalBotGlyph: View {
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.black)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.green.opacity(0.9), lineWidth: 1)
                    }
                    .shadow(color: Color.green.opacity(0.26), radius: 3)

                Text(">_")
                    .font(.system(size: 7.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.green)
            }
            .frame(width: 22, height: 16)

            HStack(spacing: 7) {
                Capsule()
                    .fill(Color.green.opacity(0.75))
                    .frame(width: 3, height: 4)
                    .rotationEffect(.degrees(16))

                Capsule()
                    .fill(Color.green.opacity(0.75))
                    .frame(width: 3, height: 4)
                    .rotationEffect(.degrees(-16))
            }
        }
    }
}
