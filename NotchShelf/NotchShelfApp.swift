import AppKit
import SwiftUI

@main
struct NotchShelfApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        Task { @MainActor in
            NotchTerminalActivityController.shared.start()
        }
    }

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

// MARK: - Background terminal activity

private struct NotchTerminalForegroundProcess: Equatable {
    let pid: Int32
    let command: String
}

private enum NotchTerminalActivityKind: Equatable {
    case running
    case finished
}

private struct NotchTerminalActivityPresentation: Equatable {
    let kind: NotchTerminalActivityKind
    let command: String
    let startedAt: Date
}

private enum NotchTerminalActivityAnimation {
    case packets
    case terminalBot
    case waveform

    static func style(for command: String) -> NotchTerminalActivityAnimation {
        let value = command.lowercased()

        if value.contains("ping")
            || value.contains("curl")
            || value.contains("wget")
            || value.contains("ssh")
            || value.contains("scp")
            || value.contains("rsync")
            || value.contains("kubectl logs")
            || value.contains("kubectl port-forward")
            || value.contains("tail -f") {
            return .packets
        }

        if value.contains("docker")
            || value.contains("npm")
            || value.contains("pnpm")
            || value.contains("yarn")
            || value.contains("terraform")
            || value.contains("tofu")
            || value.contains("brew")
            || value.contains("git clone")
            || value.contains("make")
            || value.contains("xcodebuild") {
            return .terminalBot
        }

        return .waveform
    }
}

@MainActor
private final class NotchTerminalActivityController: ObservableObject {
    static let shared = NotchTerminalActivityController()

    @Published private(set) var presentation: NotchTerminalActivityPresentation?

    private static let panelIdentifier = NSUserInterfaceItemIdentifier("NotchTerminalActivityPanel")
    private static let minimumVisibleRuntime: TimeInterval = 0.65
    private static let finishedDisplayDuration: TimeInterval = 2.2

    private var timer: Timer?
    private var panel: NotchTerminalActivityPanel?
    private var activeProcess: NotchTerminalForegroundProcess?
    private var activeStartedAt: Date?
    private var completionWork: DispatchWorkItem?
    private var polling = false
    private var started = false
    private var lastLoggedProcess: NotchTerminalForegroundProcess?

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        timer?.tolerance = 0.06

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.stop()
            }
        }

        poll()
        NSLog("[NotchShelf] Background terminal activity monitor ready")
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        completionWork?.cancel()
        completionWork = nil
        panel?.orderOut(nil)
        panel = nil
        presentation = nil
        activeProcess = nil
        activeStartedAt = nil
        lastLoggedProcess = nil
        started = false
    }

    private func poll() {
        guard !polling else { return }
        polling = true
        let rootPID = ProcessInfo.processInfo.processIdentifier

        Task.detached(priority: .utility) {
            let foreground = Self.detectForegroundTerminalProcess(rootPID: rootPID)
            await MainActor.run { [weak self] in
                guard let self = self else { return }
                self.polling = false
                self.logDetectionChange(foreground)
                self.apply(foreground)
            }
        }
    }

    private func logDetectionChange(_ process: NotchTerminalForegroundProcess?) {
        guard process != lastLoggedProcess else { return }
        lastLoggedProcess = process

        if let process = process {
            NSLog("[NotchShelf] Terminal activity detected pid=%d: %@", process.pid, process.command)
        } else {
            NSLog("[NotchShelf] Terminal activity idle")
        }
    }

    private func apply(_ foreground: NotchTerminalForegroundProcess?) {
        let terminalExpanded = isTerminalExpanded
        let anotherNotchSurfaceVisible = isAnotherNotchSurfaceVisible

        if let foreground = foreground {
            completionWork?.cancel()
            completionWork = nil

            if activeProcess?.pid != foreground.pid || activeProcess?.command != foreground.command {
                activeProcess = foreground
                activeStartedAt = Date()
            }

            guard let startedAt = activeStartedAt else { return }
            let runtime = Date().timeIntervalSince(startedAt)

            if terminalExpanded || anotherNotchSurfaceVisible {
                hidePanel()
                return
            }

            guard runtime >= Self.minimumVisibleRuntime else {
                hidePanel()
                return
            }

            presentation = NotchTerminalActivityPresentation(
                kind: .running,
                command: prettyCommand(foreground.command),
                startedAt: startedAt
            )
            showPanel()
            return
        }

        if let previous = activeProcess,
           let startedAt = activeStartedAt {
            let runtime = Date().timeIntervalSince(startedAt)
            activeProcess = nil
            activeStartedAt = nil

            guard runtime >= Self.minimumVisibleRuntime else {
                presentation = nil
                hidePanel()
                return
            }

            if terminalExpanded || anotherNotchSurfaceVisible {
                presentation = nil
                hidePanel()
                return
            }

            presentation = NotchTerminalActivityPresentation(
                kind: .finished,
                command: prettyCommand(previous.command),
                startedAt: startedAt
            )
            showPanel()

            completionWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self,
                      self.activeProcess == nil,
                      self.presentation?.kind == .finished else { return }
                self.presentation = nil
                self.hidePanel()
                self.completionWork = nil
            }
            completionWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.finishedDisplayDuration,
                execute: work
            )
            return
        }

        if presentation?.kind != .finished {
            presentation = nil
            hidePanel()
        }
    }

    private var isTerminalExpanded: Bool {
        let terminalLevel = NSWindow.Level.mainMenu.rawValue + 1
        return NSApp.windows.contains { window in
            guard window.isVisible,
                  window.identifier != Self.panelIdentifier else { return false }
            return window.level.rawValue == terminalLevel
                && window.frame.height > 240
                && window.frame.width > 360
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
                onOpen: { [weak self] in
                    self?.openTerminal()
                }
            )
            panel?.identifier = Self.panelIdentifier
        }

        panel?.orderFrontRegardless()
    }

    private func hidePanel() {
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

    private struct ProcessEntry {
        let pid: Int32
        let ppid: Int32
        let pgid: Int32
        let foregroundPGID: Int32
        let command: String
    }

    private nonisolated static func detectForegroundTerminalProcess(
        rootPID: Int32
    ) -> NotchTerminalForegroundProcess? {
        guard let entries = processEntries(), !entries.isEmpty else { return nil }

        let rootDescendants = descendants(of: rootPID, entries: entries)
        let scripts = entries.filter { entry in
            rootDescendants.contains(entry.pid) && isScriptProcess(entry.command)
        }

        for script in scripts.sorted(by: { $0.pid > $1.pid }) {
            let terminalDescendants = descendants(of: script.pid, entries: entries)
            let candidates = entries.filter { entry in
                terminalDescendants.contains(entry.pid)
                    && !isShellProcess(entry.command)
                    && !isTerminalHelperProcess(entry.command)
            }

            guard !candidates.isEmpty else { continue }

            // Prefer the normal foreground process group when macOS exposes it.
            if let foreground = candidates
                .filter({ $0.foregroundPGID > 0 && $0.pgid == $0.foregroundPGID })
                .sorted(by: { $0.pid > $1.pid })
                .first {
                return NotchTerminalForegroundProcess(
                    pid: foreground.pid,
                    command: foreground.command
                )
            }

            // `script(1)` can expose a PTY without a usable tpgid when stdin is a Pipe.
            // In that case the newest non-shell descendant is the command launched by
            // the interactive zsh session. This keeps ping/sleep/ssh/build jobs visible.
            if let fallback = candidates.sorted(by: { $0.pid > $1.pid }).first {
                return NotchTerminalForegroundProcess(
                    pid: fallback.pid,
                    command: fallback.command
                )
            }
        }

        return nil
    }

    private nonisolated static func processEntries() -> [ProcessEntry]? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = [
            "-axo",
            "pid=,ppid=,pgid=,tpgid=,tty=,etime=,command="
        ]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        return output.split(separator: "\n").compactMap { line in
            let parts = line.split(
                maxSplits: 6,
                whereSeparator: { $0.isWhitespace }
            )
            guard parts.count == 7,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]),
                  let pgid = Int32(parts[2]),
                  let foregroundPGID = Int32(parts[3]) else {
                return nil
            }

            return ProcessEntry(
                pid: pid,
                ppid: ppid,
                pgid: pgid,
                foregroundPGID: foregroundPGID,
                command: String(parts[6])
            )
        }
    }

    private nonisolated static func descendants(
        of root: Int32,
        entries: [ProcessEntry]
    ) -> Set<Int32> {
        var result: Set<Int32> = []
        var frontier: [Int32] = [root]

        while let parent = frontier.popLast() {
            for entry in entries where entry.ppid == parent && !result.contains(entry.pid) {
                result.insert(entry.pid)
                frontier.append(entry.pid)
            }
        }

        return result
    }

    private nonisolated static func executableName(_ command: String) -> String {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return URL(fileURLWithPath: first)
            .lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()
    }

    private nonisolated static func isScriptProcess(_ command: String) -> Bool {
        let executable = executableName(command)
        return executable == "script"
            || command.contains("/usr/bin/script")
    }

    private nonisolated static func isShellProcess(_ command: String) -> Bool {
        let executable = executableName(command)
        return executable == "zsh"
            || executable == "sh"
            || executable == "bash"
            || executable == "script"
            || executable == "stty"
    }

    private nonisolated static func isTerminalHelperProcess(_ command: String) -> Bool {
        let value = command.lowercased()
        return value.contains("kiro-cli-autocomplete")
            || value.contains("starship")
            || value.contains("zsh-autosuggest")
            || value.contains("zsh-syntax-highlighting")
            || value.contains("powerlevel10k")
            || value.contains("p10k")
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
    override var canBecomeKey: Bool { return false }
    override var canBecomeMain: Bool { return false }

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
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    activityContent(
                        presentation: presentation,
                        now: context.date
                    )
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .contentShape(Rectangle())
        .onHover { value in
            withAnimation(.easeOut(duration: 0.12)) {
                hovering = value
            }
        }
        .onTapGesture(perform: onOpen)
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
                        Text(presentation.kind == .running ? "Terminal running" : "Finished")
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
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.green)
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
        if presentation.kind == .finished {
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
                    let raw = (t * 0.55 + Double(index) * 0.13).truncatingRemainder(dividingBy: 1)
                    let phase = raw < 0 ? raw + 1 : raw
                    let emphasis = 1 - abs(0.5 - phase) * 1.45
                    let dotSize = CGFloat(3.5 + max(0, emphasis) * 2.3)
                    Circle()
                        .fill(index.isMultiple(of: 2) ? Color.cyan : Color.green)
                        .frame(width: dotSize, height: dotSize)
                        .opacity(0.25 + max(0, emphasis) * 0.75)
                        .shadow(
                            color: (index.isMultiple(of: 2) ? Color.cyan : Color.green).opacity(0.45),
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
                            x: max(CGFloat(2), CGFloat(phase) * travel - CGFloat(index * 6)),
                            y: 0
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
