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
    case runner
    case spinner

    static func style(for command: String) -> NotchTerminalActivityAnimation {
        let value = command.lowercased()

        if value.contains("ping ")
            || value.contains("curl ")
            || value.contains("wget ")
            || value.contains("ssh ")
            || value.contains("scp ")
            || value.contains("kubectl logs")
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
            || value.contains("git clone") {
            return .runner
        }

        return .spinner
    }
}

@MainActor
private final class NotchTerminalActivityController: ObservableObject {
    static let shared = NotchTerminalActivityController()

    @Published private(set) var presentation: NotchTerminalActivityPresentation?

    private static let panelIdentifier = NSUserInterfaceItemIdentifier("NotchTerminalActivityPanel")
    private static let minimumVisibleRuntime: TimeInterval = 0.85
    private static let finishedDisplayDuration: TimeInterval = 2.2

    private var timer: Timer?
    private var panel: NotchTerminalActivityPanel?
    private var activeProcess: NotchTerminalForegroundProcess?
    private var activeStartedAt: Date?
    private var completionWork: DispatchWorkItem?
    private var polling = false
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        timer?.tolerance = 0.08

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
                self.apply(foreground)
            }
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
        if value.count > 46 {
            value = String(value.prefix(43)) + "…"
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
            rootDescendants.contains(entry.pid)
                && entry.command.contains("/usr/bin/script")
                && entry.command.contains("/bin/zsh")
        }

        for script in scripts {
            let terminalDescendants = descendants(of: script.pid, entries: entries)
            let candidates = entries.filter { entry in
                terminalDescendants.contains(entry.pid)
                    && entry.foregroundPGID > 0
                    && entry.pgid == entry.foregroundPGID
                    && !isShellProcess(entry.command)
            }

            if let leader = candidates.first(where: { $0.pid == $0.pgid }) ?? candidates.first {
                return NotchTerminalForegroundProcess(
                    pid: leader.pid,
                    command: leader.command
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

    private nonisolated static func isShellProcess(_ command: String) -> Bool {
        let first = command.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        let executable = URL(fileURLWithPath: first)
            .lastPathComponent
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .lowercased()

        return executable == "zsh"
            || executable == "sh"
            || executable == "script"
            || executable == "stty"
    }
}

private struct NotchTerminalActivityMetrics {
    let wingWidth: CGFloat
    let depth: CGFloat
    let windowSize: CGSize
    let contentWidth: CGFloat

    init(geometry: NotchGeometry, screen: NSScreen) {
        let availableHalfWidth = max(100, (screen.frame.width - geometry.hardwareWidth - 36) / 2)
        wingWidth = min(142, availableHalfWidth - NotchGeometry.topRadius)
        depth = 46
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
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                }
                .shadow(color: Color.black.opacity(0.32), radius: 10, y: 4)

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
        .onTapGesture(perform: onOpen)
    }

    private func activityContent(
        presentation: NotchTerminalActivityPresentation,
        now: Date
    ) -> some View {
        HStack(spacing: 9) {
            activityGlyph(presentation: presentation, now: now)
                .frame(width: 34, height: 26)

            VStack(alignment: .leading, spacing: 1) {
                Text(presentation.kind == .running ? "Terminal running" : "Finished")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)

                Text(presentation.command)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)

            if presentation.kind == .running {
                Text(elapsed(from: presentation.startedAt, to: now))
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.48))
            } else {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.green)
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, geometry.hardwareHeight + 5)
        .frame(
            width: metrics.contentWidth,
            height: geometry.hardwareHeight + metrics.depth,
            alignment: .top
        )
    }

    @ViewBuilder
    private func activityGlyph(
        presentation: NotchTerminalActivityPresentation,
        now: Date
    ) -> some View {
        if presentation.kind == .finished {
            let pulse = 1 + 0.06 * sin(now.timeIntervalSinceReferenceDate * 8)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.green)
                .scaleEffect(pulse)
        } else {
            switch NotchTerminalActivityAnimation.style(for: presentation.command) {
            case .packets:
                packetAnimation(now: now)
            case .runner:
                runnerAnimation(now: now)
            case .spinner:
                spinnerAnimation(now: now)
            }
        }
    }

    private func packetAnimation(now: Date) -> some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - 6)
            let base = now.timeIntervalSinceReferenceDate * 0.72

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .frame(height: 2)

                ForEach(0..<3, id: \.self) { index in
                    let phase = (base + Double(index) * 0.31).truncatingRemainder(dividingBy: 1)
                    Circle()
                        .fill(Color.green.opacity(index == 0 ? 1 : 0.56))
                        .frame(width: index == 0 ? 5 : 4, height: index == 0 ? 5 : 4)
                        .offset(x: CGFloat(phase) * width)
                }
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
    }

    private func runnerAnimation(now: Date) -> some View {
        let t = now.timeIntervalSinceReferenceDate
        let x = sin(t * 3.4) * 7
        let y = abs(sin(t * 6.8)) * -1.8

        return Image(systemName: "hare.fill")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(Color.green)
            .offset(x: x, y: y)
    }

    private func spinnerAnimation(now: Date) -> some View {
        Circle()
            .trim(from: 0.08, to: 0.78)
            .stroke(
                Color.green,
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
            )
            .frame(width: 18, height: 18)
            .rotationEffect(
                .degrees(now.timeIntervalSinceReferenceDate * 220)
            )
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
