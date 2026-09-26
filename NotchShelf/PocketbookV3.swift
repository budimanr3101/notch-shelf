import AppKit
import Carbon.HIToolbox
import SwiftUI

private enum PocketbookV3Kind: String, CaseIterable, Identifiable {
    case all = "All"
    case yaml = "YAML"
    case kubectl = "kubectl"
    case concepts = "Concepts"

    var id: String { return rawValue }
}

private struct PocketbookV3Entry: Identifiable, Equatable {
    let id: String
    let kind: PocketbookV3Kind
    let title: String
    let subtitle: String
    let keywords: String
    let content: String
    let code: Bool
}

private struct PocketbookV3Shortcut: Equatable {
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

        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: modifiers,
            keyLabel: label
        )
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
private final class PocketbookV3Model: ObservableObject {
    @Published var presented = false
    @Published var query = ""
    @Published var kind: PocketbookV3Kind = .all
    @Published var selectedID: String?
    @Published var copiedID: String?

    let entries = PocketbookV3Library.kubernetes

    var selected: PocketbookV3Entry? {
        guard let selectedID = selectedID else { return nil }
        return entries.first(where: { $0.id == selectedID })
    }

    var results: [PocketbookV3Entry] {
        let source: [PocketbookV3Entry]
        if kind == .all {
            source = entries
        } else {
            source = entries.filter { $0.kind == kind }
        }

        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return source }

        return source.filter {
            $0.title.localizedCaseInsensitiveContains(value)
                || $0.subtitle.localizedCaseInsensitiveContains(value)
                || $0.keywords.localizedCaseInsensitiveContains(value)
                || $0.content.localizedCaseInsensitiveContains(value)
        }
    }

    func reset() {
        query = ""
        kind = .all
        selectedID = nil
        copiedID = nil
    }

    func copy(_ entry: PocketbookV3Entry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.content, forType: .string)
        copiedID = entry.id
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.95) { [weak self] in
            guard self?.copiedID == entry.id else { return }
            self?.copiedID = nil
        }
    }
}

@MainActor
final class PocketbookFeatureV3 {
    private static let keyCodeKey = "NotchShelf.Pocketbook.keyCode"
    private static let modifiersKey = "NotchShelf.Pocketbook.modifiers"
    private static let labelKey = "NotchShelf.Pocketbook.keyLabel"
    private let signature: OSType = 0x4E535033 // NSP3

    private let model = PocketbookV3Model()
    private var shortcut: PocketbookV3Shortcut
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var panel: PocketbookV3Panel?
    private var keyMonitor: Any?
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
        guard handler == nil else { return }

        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
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

                let feature = Unmanaged<PocketbookFeatureV3>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                return MainActor.assumeIsolated {
                    guard hotKeyID.signature == feature.signature,
                          hotKeyID.id == 1 else {
                        return OSStatus(eventNotHandledErr)
                    }
                    feature.toggle()
                    return noErr
                }
            },
            1,
            &type,
            pointer,
            &handler
        )

        guard status == noErr else {
            NSLog("[NotchShelf] Pocketbook V3 hotkey handler failed: %d", status)
            return
        }

        let registerStatus = registerShortcut()
        NSLog(registerStatus == noErr
            ? "[NotchShelf] Pocketbook V3 ready on \(shortcut.displayString)"
            : "[NotchShelf] Pocketbook V3 shortcut unavailable: \(shortcut.displayString)")
    }

    func stop() {
        requestedVisible = false
        pendingPresentation?.cancel()
        pendingPresentation = nil
        pendingDismissal?.cancel()
        pendingDismissal = nil
        removeKeyMonitor()
        panel?.makeFirstResponder(nil)
        panel?.orderOut(nil)
        model.presented = false

        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
        if let handler = handler { RemoveEventHandler(handler) }

        hotKey = nil
        handler = nil
        panel = nil
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        if isVisible {
            panel?.makeKeyAndOrderFront(nil)
            return
        }
        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        pendingDismissal?.cancel()
        pendingDismissal = nil
        pendingPresentation?.cancel()
        requestedVisible = true
        model.reset()

        let metrics = PocketbookV3Metrics(geometry: geometry, screen: screen)
        let frame = NSRect(
            x: screen.frame.midX - metrics.windowSize.width / 2,
            y: screen.frame.maxY - metrics.windowSize.height,
            width: metrics.windowSize.width,
            height: metrics.windowSize.height
        )

        // Retain the hosting view and field editor across open/close cycles.
        if panel?.frame != frame {
            panel?.makeFirstResponder(nil)
            panel?.orderOut(nil)
            panel = PocketbookV3Panel(
                frame: frame,
                model: model,
                geometry: geometry,
                metrics: metrics,
                onClose: { [weak self] in self?.hide() }
            )
        }
        guard let panel = panel else { return }
        installKeyMonitor()

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
        // End editing before the closing surface hides the search field.
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
        guard handler != nil else { return OSStatus(eventNotHandledErr) }

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
                if self.model.selectedID != nil {
                    self.model.selectedID = nil
                } else {
                    self.hide()
                }
                return nil
            }

            if event.keyCode == UInt16(kVK_Return), self.model.selectedID == nil {
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

private enum PocketbookV3Motion {
    // Overlapping geometry phases: shoulders 0–120 ms, bridge 80–280 ms.
    static let shoulderDuration: TimeInterval = 0.12
    static let bridgeDelay: TimeInterval = 0.08
    static let bridgeDuration: TimeInterval = 0.20
    static let contentDelay: TimeInterval = 0.16
    static let contentDuration: TimeInterval = 0.12
    static let closeContentDuration: TimeInterval = 0.10
    static let closeBridgeDelay: TimeInterval = 0.04
    static let closeBridgeDuration: TimeInterval = 0.18
    static let closeShoulderDelay: TimeInterval = 0.12
    static let closeDuration: TimeInterval = 0.26
    static let reducedDuration: TimeInterval = 0.12

    static func reveal(_ duration: TimeInterval) -> Animation {
        return .timingCurve(0.23, 1, 0.32, 1, duration: duration)
    }
}

private struct PocketbookV3Metrics {
    let wingWidth: CGFloat
    let homeDepth: CGFloat
    let detailDepth: CGFloat
    let maxDepth: CGFloat
    let contentWidth: CGFloat
    let windowSize: CGSize

    init(geometry: NotchGeometry, screen: NSScreen) {
        let availableHalfWidth = max(100, (screen.frame.width - geometry.hardwareWidth - 48) / 2)
        wingWidth = min(126, availableHalfWidth - NotchGeometry.topRadius)
        homeDepth = 228
        detailDepth = 286
        maxDepth = 294
        // Content belongs inside the straight body edges, excluding the
        // shoulder flare and transparent window envelope.
        contentWidth = geometry.hardwareWidth + 2 * wingWidth

        windowSize = CGSize(
            width: geometry.hardwareWidth
                + 2 * (wingWidth + NotchGeometry.topRadius)
                + 32,
            height: geometry.hardwareHeight + maxDepth + 4
        )
    }
}

@MainActor
private final class PocketbookV3Panel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    init(
        frame: NSRect,
        model: PocketbookV3Model,
        geometry: NotchGeometry,
        metrics: PocketbookV3Metrics,
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
        level = .mainMenu + 8
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false

        let hosting = NSHostingView(
            rootView: PocketbookV3View(
                model: model,
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

private struct PocketbookV3View: View {
    @ObservedObject var model: PocketbookV3Model
    let geometry: NotchGeometry
    let metrics: PocketbookV3Metrics
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @Namespace private var tabSelection
    @State private var shoulderExpansion: CGFloat = 0
    @State private var bridgeExpansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var pendingMotion: [DispatchWorkItem] = []
    @State private var pendingFocus: DispatchWorkItem?

    private var activeDepth: CGFloat {
        return model.selectedID == nil ? metrics.homeDepth : metrics.detailDepth
    }

    private var activeSurface: PocketbookV3Wings {
        return PocketbookV3Wings(
            geometry: geometry,
            expansion: shoulderExpansion,
            extraDepth: bridgeExpansion * activeDepth,
            wingWidth: metrics.wingWidth,
            maximumDepth: metrics.maxDepth
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            activeSurface
                .fill(Color.black)
                .overlay {
                    PocketbookV3OuterEdge(
                        geometry: geometry,
                        expansion: shoulderExpansion,
                        extraDepth: bridgeExpansion * activeDepth,
                        wingWidth: metrics.wingWidth,
                        maximumDepth: metrics.maxDepth
                    )
                    .stroke(Color.white.opacity(0.12), lineWidth: 0.75)
                }
                .shadow(
                    color: Color.black.opacity(0.34 * Double(bridgeExpansion)),
                    radius: 14,
                    y: 5
                )

            content
                .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
                .mask(activeSurface)
                .opacity(contentVisible ? 1 : 0)
                .offset(y: reduceMotion || contentVisible ? 0 : -5)
                .allowsHitTesting(model.presented && contentVisible)
                .accessibilityHidden(!model.presented || !contentVisible)
        }
        .frame(
            width: metrics.windowSize.width,
            height: metrics.windowSize.height,
            alignment: .top
        )
        .clipped()
        .opacity(reduceMotion && !model.presented ? 0 : 1)
        .animation(
            reduceMotion ? .easeOut(duration: PocketbookV3Motion.reducedDuration) : nil,
            value: model.presented
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90),
            value: activeDepth
        )
        .onChange(of: model.presented) { _, visible in
            animatePresentation(visible)
        }
        .onChange(of: reduceMotion) { _, _ in
            animatePresentation(model.presented)
        }
        .onChange(of: model.selectedID) { _, selectedID in
            searchFocused = false
            if selectedID == nil { focusSearchWhenReady() }
            else { pendingFocus?.cancel() }
        }
        .onChange(of: contentVisible) { _, visible in
            if visible { focusSearchWhenReady() }
            else {
                pendingFocus?.cancel()
                searchFocused = false
            }
        }
        .onDisappear {
            cancelMotion()
            pendingFocus?.cancel()
        }
    }

    private func cancelMotion() {
        pendingMotion.forEach { $0.cancel() }
        pendingMotion.removeAll()
    }

    private func focusSearchWhenReady() {
        pendingFocus?.cancel()
        let focus = DispatchWorkItem {
            guard model.presented, contentVisible, model.selectedID == nil else { return }
            searchFocused = true
        }
        pendingFocus = focus
        // Let the newly mounted Home field acquire its AppKit field editor.
        DispatchQueue.main.async(execute: focus)
    }

    private func scheduleMotion(after delay: TimeInterval, opening: Bool, action: @escaping () -> Void) {
        let work = DispatchWorkItem {
            guard model.presented == opening else { return }
            action()
        }
        pendingMotion.append(work)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func animatePresentation(_ opening: Bool) {
        cancelMotion()
        if !opening {
            pendingFocus?.cancel()
            searchFocused = false
        }

        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                // Keep geometry stationary; the complete surface crossfades.
                shoulderExpansion = 1
                bridgeExpansion = 1
            }
            withAnimation(.easeOut(duration: PocketbookV3Motion.reducedDuration)) {
                contentVisible = opening
            }
            return
        }

        if opening {
            withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.shoulderDuration)) {
                shoulderExpansion = 1
            }
            scheduleMotion(after: PocketbookV3Motion.bridgeDelay, opening: true) {
                withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.bridgeDuration)) {
                    bridgeExpansion = 1
                }
            }
            scheduleMotion(after: PocketbookV3Motion.contentDelay, opening: true) {
                withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.contentDuration)) {
                    contentVisible = true
                }
            }
        } else {
            withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.closeContentDuration)) {
                contentVisible = false
            }
            scheduleMotion(after: PocketbookV3Motion.closeBridgeDelay, opening: false) {
                withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.closeBridgeDuration)) {
                    bridgeExpansion = 0
                }
            }
            scheduleMotion(after: PocketbookV3Motion.closeShoulderDelay, opening: false) {
                withAnimation(PocketbookV3Motion.reveal(PocketbookV3Motion.shoulderDuration)) {
                    shoulderExpansion = 0
                }
            }
        }
    }

    private var content: some View {
        VStack(spacing: 7) {
            if model.selectedID == nil {
                homeHeader
                searchBar
                tabs
                results
            } else if let entry = model.selected {
                detail(entry)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, geometry.hardwareHeight + 8)
        .padding(.bottom, 10)
        .frame(
            width: metrics.contentWidth,
            height: geometry.hardwareHeight + activeDepth,
            alignment: .top
        )
    }

    private var homeHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 0) {
                Text("Pocketbook")
                    .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.96))
                Text("Kubernetes")
                    .font(.system(size: 9.3, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(.white.opacity(0.07)))
            }
            .buttonStyle(.plain)
        }
        .frame(height: 26)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))

            TextField("Search Kubernetes…", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            if !model.query.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        model.query = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.30))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .frame(height: 31)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(searchFocused ? 0.085 : 0.055))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(searchFocused ? 0.16 : 0.055), lineWidth: 0.7)
        }
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(PocketbookV3Kind.allCases) { kind in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.88)) {
                        model.kind = kind
                    }
                } label: {
                    ZStack {
                        if model.kind == kind {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.10))
                                .matchedGeometryEffect(id: "PocketbookV3Tab", in: tabSelection)
                        }

                        Text(kind.rawValue)
                            .font(.system(size: 9.4, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                model.kind == kind
                                    ? Color.white.opacity(0.92)
                                    : Color.white.opacity(0.40)
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 23)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.025))
        )
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.results.isEmpty {
                    Text("No reference found")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .frame(maxWidth: .infinity, minHeight: 100)
                } else {
                    ForEach(model.results) { entry in
                        resultRow(entry)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    private func resultRow(_ entry: PocketbookV3Entry) -> some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.90)) {
                model.selectedID = entry.id
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: icon(for: entry.kind))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(iconColor(for: entry.kind))
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 1.5) {
                    Text(entry.title)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.91))
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.system(size: 8.9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(entry.kind.rawValue)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.26))

                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.20))
            }
            .padding(.horizontal, 6)
            .frame(height: 34)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.white.opacity(0.05))
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func detail(_ entry: PocketbookV3Entry) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.88)) {
                        model.selectedID = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 25, height: 25)
                        .background(Circle().fill(Color.white.opacity(0.065)))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(entry.subtitle)
                        .font(.system(size: 9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.39))
                        .lineLimit(1)
                }

                Spacer()

                Text(entry.kind.rawValue)
                    .font(.system(size: 8.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(iconColor(for: entry.kind))
            }

            referenceBody(entry)

            HStack {
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.90)) {
                        model.copy(entry)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.copiedID == entry.id ? "checkmark" : "doc.on.doc")
                        Text(model.copiedID == entry.id ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        model.copiedID == entry.id
                            ? Color.green.opacity(0.95)
                            : Color.white.opacity(0.82)
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                model.copiedID == entry.id
                                    ? Color.green.opacity(0.11)
                                    : Color.white.opacity(0.055)
                            )
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                Text("⌘C")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
        .frame(maxHeight: .infinity)
        .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 6)))
    }

    private func referenceBody(_ entry: PocketbookV3Entry) -> some View {
        ScrollView([.vertical, .horizontal]) {
            if entry.code {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(entry.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                        id: \.offset
                    ) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.17))
                                .frame(width: 20, alignment: .trailing)

                            Text(String(line))
                                .font(.system(size: 10.1, design: .monospaced))
                                .foregroundStyle(codeColor(for: String(line)))
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 17)
                    }
                }
                .padding(10)
            } else {
                Text(entry.content)
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.80))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(11)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.white.opacity(0.05), lineWidth: 0.65)
        }
    }

    private func icon(for kind: PocketbookV3Kind) -> String {
        switch kind {
        case .yaml: return "doc.text.fill"
        case .kubectl: return "terminal.fill"
        case .concepts: return "book.pages.fill"
        case .all: return "book.closed.fill"
        }
    }

    private func iconColor(for kind: PocketbookV3Kind) -> Color {
        switch kind {
        case .yaml: return Color.accentColor.opacity(0.88)
        case .kubectl: return Color.green.opacity(0.80)
        case .concepts: return Color.orange.opacity(0.84)
        case .all: return Color.white.opacity(0.65)
        }
    }

    private func codeColor(for line: String) -> Color {
        let value = line.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("kubectl ") { return Color.green.opacity(0.86) }
        if value.contains("apiVersion:") || value.contains("kind:") {
            return Color.accentColor.opacity(0.90)
        }
        if value.hasPrefix("#") { return Color.white.opacity(0.34) }
        return Color.white.opacity(0.80)
    }
}

/// Same geometry strategy as the stable Drop Zone's NotchWings. The only
/// differences are a larger wing width and a larger allowed lower bridge.
private struct PocketbookV3Wings: Shape {
    let geometry: NotchGeometry
    var expansion: CGFloat
    var extraDepth: CGFloat
    var wingWidth: CGFloat
    var maximumDepth: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get {
            return AnimatablePair(
                AnimatablePair(expansion, extraDepth),
                wingWidth
            )
        }
        set {
            expansion = newValue.first.first
            extraDepth = newValue.first.second
            wingWidth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard expansion > 0 else { return Path() }

        let progress = min(max(expansion, 0), 1.08)
        let extent = wingWidth * progress
        let overlap = NotchGeometry.connectionOverlap * min(progress, 1)
        let depth = min(max(extraDepth, 0), maximumDepth)
        let renderedHeight = geometry.hardwareHeight + depth

        let leftHardwareEdge = rect.midX - geometry.hardwareWidth / 2
        let rightHardwareEdge = rect.midX + geometry.hardwareWidth / 2

        let silhouette = PocketbookV3ShelfShape(
            topRadius: NotchGeometry.topRadius,
            bottomRadius: 16
        )
        .path(in: CGRect(
            x: leftHardwareEdge - extent - NotchGeometry.topRadius,
            y: rect.minY,
            width: geometry.hardwareWidth + 2 * (extent + NotchGeometry.topRadius),
            height: renderedHeight
        ))

        let leftJoin = leftHardwareEdge + overlap
        let rightJoin = rightHardwareEdge - overlap

        var drawableRegions = Path()
        drawableRegions.addRect(CGRect(
            x: rect.minX,
            y: rect.minY,
            width: max(0, leftJoin - rect.minX),
            height: geometry.hardwareHeight
        ))
        drawableRegions.addRect(CGRect(
            x: rightJoin,
            y: rect.minY,
            width: max(0, rect.maxX - rightJoin),
            height: geometry.hardwareHeight
        ))

        if depth > 0 {
            let bridgeLeft = leftHardwareEdge - extent - NotchGeometry.topRadius
            let bridgeRight = rightHardwareEdge + extent + NotchGeometry.topRadius
            drawableRegions.addRect(CGRect(
                x: bridgeLeft,
                y: geometry.hardwareHeight - 1,
                width: bridgeRight - bridgeLeft,
                height: depth + 1
            ))
        }

        let flare = NotchGeometry.topRadius * min(progress, 1)
        let bounds = Path(CGRect(
            x: leftHardwareEdge - extent - flare,
            y: rect.minY,
            width: geometry.hardwareWidth + 2 * (extent + flare),
            height: renderedHeight
        ))

        return silhouette
            .intersection(drawableRegions)
            .intersection(bounds)
    }
}

private struct PocketbookV3ShelfShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { return AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, min(topRadius, rect.width / 2))
        let bodyHalfWidth = max(0, rect.width / 2 - top)
        let bottom = max(0, min(bottomRadius, min(bodyHalfWidth, rect.height)))

        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        let bodyRect = CGRect(
            x: rect.minX + top,
            y: rect.minY,
            width: rect.width - 2 * top,
            height: rect.height
        )

        if let corners = PocketbookV3ContinuousCorner.bottomCorners(
            bodyRect: bodyRect,
            radius: bottom
        ) {
            path.addLine(to: corners.leftEdgeReach)
            for segment in corners.left {
                path.addCurve(
                    to: segment.to,
                    control1: segment.control1,
                    control2: segment.control2
                )
            }

            path.addLine(to: corners.bottomEdgeRightReach)
            for segment in corners.right {
                path.addCurve(
                    to: segment.to,
                    control1: segment.control1,
                    control2: segment.control2
                )
            }

            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        } else {
            path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        }

        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )
        path.closeSubpath()

        return path
    }
}

private enum PocketbookV3ContinuousCorner {
    struct Segment {
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
    }

    struct BottomCorners {
        let leftEdgeReach: CGPoint
        let left: [Segment]
        let bottomEdgeRightReach: CGPoint
        let right: [Segment]
    }

    static func bottomCorners(bodyRect: CGRect, radius: CGFloat) -> BottomCorners? {
        let reference = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        )
        .path(in: bodyRect)

        var elements: [Path.Element] = []
        reference.forEach { elements.append($0) }

        guard elements.count >= 9,
              case .line(let p1) = elements[1],
              case .curve(let p2, let c2a, let c2b) = elements[2],
              case .curve(let p3, let c3a, let c3b) = elements[3],
              case .curve(let p4, let c4a, let c4b) = elements[4],
              case .line(let l5) = elements[5],
              case .curve(let p6, let c6a, let c6b) = elements[6],
              case .curve(let p7, let c7a, let c7b) = elements[7],
              case .curve(let p8, let c8a, let c8b) = elements[8] else {
            return nil
        }

        return BottomCorners(
            leftEdgeReach: p8,
            left: [
                Segment(control1: c8b, control2: c8a, to: p7),
                Segment(control1: c7b, control2: c7a, to: p6),
                Segment(control1: c6b, control2: c6a, to: l5),
            ],
            bottomEdgeRightReach: p4,
            right: [
                Segment(control1: c4b, control2: c4a, to: p3),
                Segment(control1: c3b, control2: c3a, to: p2),
                Segment(control1: c2b, control2: c2a, to: p1),
            ]
        )
    }
}

/// A subtle visible perimeter that deliberately omits any line across the
/// physical camera housing. This preserves the real notch silhouette.
private struct PocketbookV3OuterEdge: Shape {
    let geometry: NotchGeometry
    var expansion: CGFloat
    var extraDepth: CGFloat
    var wingWidth: CGFloat
    var maximumDepth: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<CGFloat, CGFloat>, CGFloat> {
        get {
            return AnimatablePair(
                AnimatablePair(expansion, extraDepth),
                wingWidth
            )
        }
        set {
            expansion = newValue.first.first
            extraDepth = newValue.first.second
            wingWidth = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        guard expansion > 0 else { return Path() }

        let progress = min(max(expansion, 0), 1.08)
        let extent = wingWidth * progress
        let depth = min(max(extraDepth, 0), maximumDepth)
        let topRadius = NotchGeometry.topRadius
        let bottomRadius = min(CGFloat(16), depth / 2)

        let leftHardwareEdge = rect.midX - geometry.hardwareWidth / 2
        let rightHardwareEdge = rect.midX + geometry.hardwareWidth / 2
        let leftBody = leftHardwareEdge - extent
        let rightBody = rightHardwareEdge + extent
        let bottomY = geometry.hardwareHeight + depth

        var path = Path()
        path.move(to: CGPoint(x: leftBody - topRadius, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: leftBody, y: topRadius),
            control: CGPoint(x: leftBody, y: 0)
        )
        path.addLine(to: CGPoint(x: leftBody, y: bottomY - bottomRadius))
        path.addQuadCurve(
            to: CGPoint(x: leftBody + bottomRadius, y: bottomY),
            control: CGPoint(x: leftBody, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rightBody - bottomRadius, y: bottomY))
        path.addQuadCurve(
            to: CGPoint(x: rightBody, y: bottomY - bottomRadius),
            control: CGPoint(x: rightBody, y: bottomY)
        )
        path.addLine(to: CGPoint(x: rightBody, y: topRadius))
        path.addQuadCurve(
            to: CGPoint(x: rightBody + topRadius, y: 0),
            control: CGPoint(x: rightBody, y: 0)
        )
        return path
    }
}

@MainActor
private final class PocketbookV3ShortcutCaptureView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Press a new shortcut")
    var captured: PocketbookV3Shortcut?

    override var acceptsFirstResponder: Bool { return true }

    init(current: PocketbookV3Shortcut) {
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
        guard let value = PocketbookV3Shortcut(event: event),
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

private enum PocketbookV3Library {
    private static func e(
        _ id: String,
        _ kind: PocketbookV3Kind,
        _ title: String,
        _ subtitle: String,
        _ keywords: String,
        _ content: String,
        code: Bool = true
    ) -> PocketbookV3Entry {
        return PocketbookV3Entry(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            content: content,
            code: code
        )
    }

    static let kubernetes: [PocketbookV3Entry] = [
        e("deployment", .yaml, "Deployment YAML", "Basic stateless workload boilerplate",
          "deployment apps replicas selector resources", """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: your-image:tag
          ports:
            - containerPort: 80
"""),
        e("service", .yaml, "Service YAML", "ClusterIP service boilerplate",
          "service clusterip targetport", """
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 80
  type: ClusterIP
"""),
        e("ingress", .yaml, "Ingress YAML", "networking.k8s.io/v1 boilerplate",
          "ingress host path backend", """
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-app
spec:
  rules:
    - host: app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
"""),
        e("configmap", .yaml, "ConfigMap YAML", "Non-secret configuration boilerplate",
          "configmap env configuration", """
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-app-config
data:
  APP_ENV: production
  LOG_LEVEL: info
"""),
        e("secret", .yaml, "Secret YAML", "Opaque Secret structure reminder",
          "secret opaque stringdata", """
apiVersion: v1
kind: Secret
metadata:
  name: my-app-secret
type: Opaque
stringData:
  username: example
  password: replace-me
"""),
        e("statefulset", .yaml, "StatefulSet YAML", "Stable identity workload skeleton",
          "statefulset serviceName identity", """
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: my-app
spec:
  serviceName: my-app
  replicas: 3
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: my-app
          image: your-image:tag
"""),
        e("daemonset", .yaml, "DaemonSet YAML", "One Pod per matching node",
          "daemonset node agent", """
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-agent
spec:
  selector:
    matchLabels:
      app: node-agent
  template:
    metadata:
      labels:
        app: node-agent
    spec:
      containers:
        - name: agent
          image: your-image:tag
"""),
        e("cronjob", .yaml, "CronJob YAML", "Scheduled Job boilerplate",
          "cronjob schedule job", """
apiVersion: batch/v1
kind: CronJob
metadata:
  name: cleanup
spec:
  schedule: "0 2 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: cleanup
              image: your-image:tag
"""),
        e("pods", .kubectl, "Pods", "Get, wide, YAML and describe",
          "pods get describe wide", """
kubectl get pods
kubectl get pods -o wide
kubectl get pod <pod> -o yaml
kubectl describe pod <pod>
kubectl get pods -A
"""),
        e("logs", .kubectl, "Logs", "Follow, previous and container logs",
          "logs follow tail previous", """
kubectl logs <pod>
kubectl logs -f <pod>
kubectl logs <pod> -c <container>
kubectl logs <pod> --previous
"""),
        e("exec", .kubectl, "Exec", "Interactive shell and one-shot command",
          "exec shell bash sh", """
kubectl exec -it <pod> -- /bin/sh
kubectl exec -it <pod> -- /bin/bash
kubectl exec <pod> -- env
"""),
        e("rollout", .kubectl, "Deployment rollout", "Status, restart, history and undo",
          "rollout restart undo history", """
kubectl rollout status deployment/<name>
kubectl rollout restart deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name>
"""),
        e("context", .kubectl, "Context & Namespace", "See and switch kubeconfig context",
          "context namespace config", """
kubectl config current-context
kubectl config get-contexts
kubectl config use-context <context>
kubectl config set-context --current --namespace=<namespace>
"""),
        e("events", .kubectl, "Events", "Inspect recent cluster events",
          "events warning troubleshoot", """
kubectl get events
kubectl get events --sort-by=.lastTimestamp
kubectl get events -A --sort-by=.lastTimestamp
kubectl get events --field-selector type=Warning
"""),
        e("port-forward", .kubectl, "Port Forward", "Expose a Pod or Service locally",
          "port forward localhost", """
kubectl port-forward pod/<pod> 8080:80
kubectl port-forward service/<service> 8080:80
kubectl port-forward service/<service> 8080:80 -n <namespace>
"""),
        e("deployment-vs-statefulset", .concepts, "Deployment vs StatefulSet",
          "Stateless vs stable identity reminder", "deployment statefulset identity storage", """
Deployment
• Default choice for stateless applications.
• Pods are interchangeable.
• Typical use: APIs, web apps, workers.

StatefulSet
• Stable Pod identity and ordered lifecycle.
• Pod names stay predictable: app-0, app-1, app-2.
• Commonly paired with persistent volumes.
""", code: false),
        e("probes", .concepts, "Probes", "Readiness, liveness and startup",
          "probe readiness liveness startup", """
readinessProbe
Controls whether a Pod receives Service traffic.

livenessProbe
Detects a stuck container and can trigger a restart.

startupProbe
Protects slow-starting apps until startup succeeds.
""", code: false),
        e("resources", .concepts, "Requests vs Limits",
          "Scheduler reservation vs runtime ceiling", "resources cpu memory limits requests", """
Requests
• Used by the scheduler when placing Pods.
• Express resources the workload expects to need.

Limits
• Set a runtime ceiling.
• CPU may be throttled.
• Exceeding memory can result in OOMKilled.
""", code: false),
        e("service-types", .concepts, "Service Types",
          "ClusterIP, NodePort and LoadBalancer", "service clusterip nodeport loadbalancer", """
ClusterIP
• Default, reachable inside the cluster.

NodePort
• Opens the Service on a port on each Node.

LoadBalancer
• Requests an external load balancer from the cloud integration.
""", code: false),
    ]
}
