import AppKit
import Carbon.HIToolbox
import SwiftUI

struct PocketbookShortcut: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let keyLabel: String

    static let defaultShortcut = PocketbookShortcut(
        keyCode: UInt32(kVK_ANSI_K),
        modifiers: UInt32(optionKey),
        keyLabel: "K"
    )

    init?(event: NSEvent) {
        var mods: UInt32 = 0
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        guard mods != 0 else { return nil }

        let chars = event.charactersIgnoringModifiers?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let label = (chars?.isEmpty == false ? chars : nil) ?? "Key \(event.keyCode)"
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods, keyLabel: label)
    }

    init(keyCode: UInt32, modifiers: UInt32, keyLabel: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyLabel = keyLabel
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

private enum PocketbookKind: String, CaseIterable, Identifiable {
    case all = "All"
    case yaml = "YAML"
    case kubectl = "kubectl"
    case concepts = "Concepts"

    var id: String { return rawValue }
}

private struct PocketbookEntry: Identifiable, Equatable {
    let id: String
    let kind: PocketbookKind
    let title: String
    let subtitle: String
    let keywords: String
    let content: String
    let code: Bool
}

@MainActor
private final class PocketbookModel: ObservableObject {
    @Published var presented = false
    @Published var query = ""
    @Published var kind: PocketbookKind = .all
    @Published var selectedID: String?
    @Published var copiedID: String?

    let entries = PocketbookLibrary.kubernetes

    var selected: PocketbookEntry? {
        guard let selectedID = selectedID else { return nil }
        return entries.first(where: { $0.id == selectedID })
    }

    var results: [PocketbookEntry] {
        let base: [PocketbookEntry]
        if kind == .all {
            base = entries
        } else {
            base = entries.filter { $0.kind == kind }
        }

        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }

        return base.filter {
            $0.title.localizedCaseInsensitiveContains(q)
                || $0.subtitle.localizedCaseInsensitiveContains(q)
                || $0.keywords.localizedCaseInsensitiveContains(q)
                || $0.content.localizedCaseInsensitiveContains(q)
        }
    }

    func reset() {
        query = ""
        kind = .all
        selectedID = nil
        copiedID = nil
    }

    func copy(_ entry: PocketbookEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.content, forType: .string)
        copiedID = entry.id
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard self?.copiedID == entry.id else { return }
            self?.copiedID = nil
        }
    }
}

@MainActor
final class PocketbookFeature {
    private static let keyCodeKey = "NotchShelf.Pocketbook.keyCode"
    private static let modifiersKey = "NotchShelf.Pocketbook.modifiers"
    private static let labelKey = "NotchShelf.Pocketbook.keyLabel"
    private let signature: OSType = 0x4E535042

    private let model = PocketbookModel()
    private var shortcut: PocketbookShortcut
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var panel: PocketbookPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    var onShortcutChanged: (() -> Void)?
    var shortcutDescription: String { return shortcut.displayString }
    var isVisible: Bool { return panel?.isVisible == true }

    init() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.keyCodeKey) != nil,
           defaults.object(forKey: Self.modifiersKey) != nil {
            shortcut = PocketbookShortcut(
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

                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &id
                )
                guard read == noErr else { return read }

                let feature = Unmanaged<PocketbookFeature>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                return MainActor.assumeIsolated {
                    guard id.signature == feature.signature, id.id == 1 else {
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
            NSLog("[NotchShelf] Pocketbook hotkey handler failed: %d", status)
            return
        }

        let registerStatus = registerShortcut()
        NSLog(registerStatus == noErr
            ? "[NotchShelf] Pocketbook ready on \(shortcut.displayString)"
            : "[NotchShelf] Pocketbook shortcut unavailable: \(shortcut.displayString)")
    }

    func stop() {
        removeKeyMonitor()
        panel?.orderOut(nil)

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
        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        model.reset()
        model.presented = false

        let width = min(max(geometry.hardwareWidth + 340, 540), screen.frame.width - 48)
        let height = min(geometry.hardwareHeight + 356, screen.frame.height * 0.54)
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )

        panel?.orderOut(nil)
        let newPanel = PocketbookPanel(
            frame: frame,
            model: model,
            geometry: geometry,
            onClose: { [weak self] in self?.hide() }
        )
        panel = newPanel
        installKeyMonitor()

        NSApp.activate(ignoringOtherApps: true)
        newPanel.makeKeyAndOrderFront(nil)
        newPanel.contentView?.layoutSubtreeIfNeeded()
        newPanel.displayIfNeeded()

        DispatchQueue.main.async { [weak self] in
            self?.model.presented = true
        }
    }

    func hide() {
        guard let panel = panel, panel.isVisible else { return }

        removeKeyMonitor()
        model.presented = false
        let restore = previousApp
        previousApp = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.panel = nil

            if let restore = restore,
               restore.bundleIdentifier != Bundle.main.bundleIdentifier {
                restore.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    func showShortcutRecorder() {
        let alert = NSAlert()
        alert.messageText = "Pocketbook Shortcut"
        alert.informativeText = "Press a shortcut using ⌘, ⌥, ⌃, or ⇧. It works globally from any app."

        let recorder = PocketbookShortcutCaptureView(current: shortcut)
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

    private func setShortcut(_ newValue: PocketbookShortcut) -> Bool {
        guard !newValue.conflictsWithFileShelf else { return false }
        let old = shortcut

        if let hotKey = hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }

        shortcut = newValue
        guard registerShortcut() == noErr else {
            shortcut = old
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

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.modifiers,
            id,
            GetApplicationEventTarget(),
            OptionBits(0),
            &ref
        )
        if status == noErr { hotKey = ref }
        return status
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            if event.keyCode == UInt16(kVK_Escape) {
                if self.model.selectedID != nil {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                        self.model.selectedID = nil
                    }
                } else {
                    self.hide()
                }
                return nil
            }

            if event.keyCode == UInt16(kVK_Return), self.model.selectedID == nil {
                withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                    self.model.selectedID = self.model.results.first?.id
                }
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

@MainActor
private final class PocketbookPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    init(
        frame: NSRect,
        model: PocketbookModel,
        geometry: NotchGeometry,
        onClose: @escaping () -> Void
    ) {
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
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

        let host = NSHostingView(
            rootView: PocketbookView(
                model: model,
                geometry: geometry,
                onClose: onClose
            )
        )
        host.safeAreaRegions = []
        host.sizingOptions = []
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        contentView = host
    }
}

private struct PocketbookView: View {
    @ObservedObject var model: PocketbookModel
    let geometry: NotchGeometry
    let onClose: () -> Void

    @FocusState private var searchFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var tabSelection
    @State private var chromeReady = false
    @State private var contentReady = false

    private var spring: Animation? {
        if reduceMotion { return nil }
        return .spring(response: 0.42, dampingFraction: 0.82)
    }

    var body: some View {
        ZStack(alignment: .top) {
            chrome

            if model.presented {
                content
                    .opacity(contentReady ? 1 : 0)
                    .offset(y: contentReady ? 0 : -10)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            syncPresentation(model.presented)
        }
        .onChange(of: model.presented) { value in
            syncPresentation(value)
        }
        .onChange(of: model.selectedID) { value in
            if value == nil && model.presented {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                    searchFocused = true
                }
            }
        }
    }

    private var chrome: some View {
        let progress: CGFloat = chromeReady && model.presented ? 1 : 0
        let shape = PocketbookNotchSurface(
            hardwareWidth: geometry.hardwareWidth,
            hardwareHeight: geometry.hardwareHeight,
            expansion: progress
        )

        return shape
            .fill(
                LinearGradient(
                    colors: [
                        Color.black,
                        Color(red: 0.035, green: 0.042, blue: 0.055),
                        Color.black.opacity(0.985),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                shape
                    .stroke(
                        LinearGradient(
                            colors: [
                                .white.opacity(0.16),
                                .white.opacity(0.055),
                                .clear,
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 0.8
                    )
            }
            .shadow(
                color: .black.opacity(progress > 0.7 ? 0.48 : 0),
                radius: 22,
                y: 10
            )
            .animation(spring, value: progress)
    }

    private var content: some View {
        VStack(spacing: 11) {
            header
            searchBar
            tabs

            ZStack {
                if let entry = model.selected {
                    detail(entry)
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .trailing).combined(with: .opacity),
                                removal: .move(edge: .trailing).combined(with: .opacity)
                            )
                        )
                } else {
                    results
                        .transition(
                            .asymmetric(
                                insertion: .move(edge: .leading).combined(with: .opacity),
                                removal: .move(edge: .leading).combined(with: .opacity)
                            )
                        )
                }
            }
            .animation(
                reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88),
                value: model.selectedID
            )

            footerHint
        }
        .padding(.horizontal, 18)
        .padding(.top, geometry.hardwareHeight + 12)
        .padding(.bottom, 13)
    }

    private var header: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .frame(width: 28, height: 28)
                Image(systemName: "book.closed.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("Pocketbook")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.97))
                Text("Kubernetes")
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.42))
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(.white.opacity(0.065)))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 31)
    }

    private var searchBar: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.38))

            TextField("Search Kubernetes reference…", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.94))

            if !model.query.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        model.query = ""
                        model.selectedID = nil
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white.opacity(0.30))
                }
                .buttonStyle(.plain)
                .transition(.scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(searchFocused ? 0.085 : 0.060))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(
                    searchFocused ? Color.accentColor.opacity(0.42) : .white.opacity(0.06),
                    lineWidth: 0.8
                )
        }
        .animation(.easeInOut(duration: 0.18), value: searchFocused)
        .animation(.easeInOut(duration: 0.16), value: model.query)
    }

    private var tabs: some View {
        HStack(spacing: 3) {
            ForEach(PocketbookKind.allCases) { kind in
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.86)) {
                        model.kind = kind
                        model.selectedID = nil
                    }
                } label: {
                    ZStack {
                        if model.kind == kind {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color.accentColor.opacity(0.34))
                                .matchedGeometryEffect(id: "PocketbookTab", in: tabSelection)
                        }

                        Text(kind.rawValue)
                            .font(.system(size: 9.8, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                model.kind == kind
                                    ? Color.white.opacity(0.95)
                                    : Color.white.opacity(0.40)
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.040))
        )
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if model.results.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(0.22))
                        Text("No reference found")
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.38))
                    }
                    .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(Array(model.results.enumerated()), id: \.element.id) { index, entry in
                        resultRow(entry, index: index)
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: model.query)
        .animation(.easeInOut(duration: 0.18), value: model.kind)
    }

    private func resultRow(_ entry: PocketbookEntry, index: Int) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                model.selectedID = entry.id
            }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconColor(entry.kind).opacity(0.11))
                    Image(systemName: icon(entry.kind))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconColor(entry.kind))
                }
                .frame(width: 29, height: 29)

                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.system(size: 11.3, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.system(size: 9.2, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Text(entry.kind.rawValue)
                    .font(.system(size: 8.3, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28))

                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.22))
            }
            .padding(.horizontal, 9)
            .frame(height: 43)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.white.opacity(0.036))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(.white.opacity(0.035), lineWidth: 0.6)
            }
        }
        .buttonStyle(.plain)
        .opacity(contentReady ? 1 : 0)
        .offset(y: contentReady ? 0 : -5)
        .animation(
            reduceMotion
                ? nil
                : .easeOut(duration: 0.25).delay(min(Double(index) * 0.025, 0.15)),
            value: contentReady
        )
    }

    private func detail(_ entry: PocketbookEntry) -> some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                        model.selectedID = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white.opacity(0.70))
                        .frame(width: 27, height: 27)
                        .background(Circle().fill(.white.opacity(0.060)))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                    Text(entry.subtitle)
                        .font(.system(size: 9.3, design: .rounded))
                        .foregroundStyle(.white.opacity(0.40))
                        .lineLimit(1)
                }

                Spacer()

                Text(entry.kind.rawValue)
                    .font(.system(size: 8.8, weight: .semibold, design: .rounded))
                    .foregroundStyle(iconColor(entry.kind))
                    .padding(.horizontal, 8)
                    .frame(height: 21)
                    .background(
                        Capsule()
                            .fill(iconColor(entry.kind).opacity(0.10))
                    )
            }

            referenceBody(entry)

            HStack {
                Button {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.78)) {
                        model.copy(entry)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.copiedID == entry.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10, weight: .semibold))
                        Text(model.copiedID == entry.id ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10.2, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        model.copiedID == entry.id
                            ? Color.green.opacity(0.95)
                            : Color.white.opacity(0.82)
                    )
                    .padding(.horizontal, 12)
                    .frame(height: 29)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(model.copiedID == entry.id
                                ? Color.green.opacity(0.11)
                                : Color.white.opacity(0.055))
                    )
                    .scaleEffect(model.copiedID == entry.id ? 1.03 : 1)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("⌘C")
                    .font(.system(size: 8.8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.23))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func referenceBody(_ entry: PocketbookEntry) -> some View {
        ScrollView([.vertical, .horizontal]) {
            if entry.code {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(entry.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 11) {
                            Text("\(index + 1)")
                                .font(.system(size: 9.3, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.18))
                                .frame(width: 20, alignment: .trailing)

                            Text(String(line))
                                .font(.system(size: 10.4, design: .monospaced))
                                .foregroundStyle(codeColor(for: String(line)))
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 17)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 10)
            } else {
                Text(entry.content)
                    .font(.system(size: 10.8, design: .rounded))
                    .foregroundStyle(.white.opacity(0.80))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.34))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.055), lineWidth: 0.7)
        }
    }

    private var footerHint: some View {
        HStack(spacing: 7) {
            Text(model.selectedID == nil ? "↵ Open" : "Esc Back")
            Circle().fill(.white.opacity(0.18)).frame(width: 2.5, height: 2.5)
            Text(model.selectedID == nil ? "Esc Close" : "⌘C Copy")
        }
        .font(.system(size: 8.3, weight: .medium, design: .rounded))
        .foregroundStyle(.white.opacity(0.24))
        .frame(height: 9)
    }

    private func syncPresentation(_ visible: Bool) {
        if visible {
            if reduceMotion {
                chromeReady = true
                contentReady = true
                searchFocused = true
                return
            }

            chromeReady = false
            contentReady = false
            searchFocused = false

            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    chromeReady = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeOut(duration: 0.22)) {
                    contentReady = true
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                searchFocused = true
            }
        } else {
            searchFocused = false
            withAnimation(.easeOut(duration: 0.12)) {
                contentReady = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.88)) {
                    chromeReady = false
                }
            }
        }
    }

    private func icon(_ kind: PocketbookKind) -> String {
        switch kind {
        case .yaml:
            return "doc.text.fill"
        case .kubectl:
            return "terminal.fill"
        case .concepts:
            return "book.pages.fill"
        case .all:
            return "book.closed.fill"
        }
    }

    private func iconColor(_ kind: PocketbookKind) -> Color {
        switch kind {
        case .yaml:
            return Color.accentColor.opacity(0.90)
        case .kubectl:
            return Color.green.opacity(0.82)
        case .concepts:
            return Color.orange.opacity(0.86)
        case .all:
            return Color.white.opacity(0.68)
        }
    }

    private func codeColor(for line: String) -> Color {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return .white.opacity(0.34) }
        if trimmed.hasPrefix("kubectl ") { return .green.opacity(0.88) }
        if trimmed.contains("apiVersion:") || trimmed.contains("kind:") {
            return Color.accentColor.opacity(0.92)
        }
        if trimmed.hasPrefix("-") { return .white.opacity(0.72) }
        return .white.opacity(0.82)
    }
}

private struct PocketbookNotchSurface: Shape {
    let hardwareWidth: CGFloat
    let hardwareHeight: CGFloat
    var expansion: CGFloat

    var animatableData: CGFloat {
        get { return expansion }
        set { expansion = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let progress = min(max(expansion, 0), 1)
        let collapsedWidth = min(rect.width - 12, hardwareWidth + 54)
        let expandedWidth = rect.width - 10
        let width = collapsedWidth + (expandedWidth - collapsedWidth) * progress

        let collapsedHeight = hardwareHeight + 9
        let expandedHeight = rect.height - 5
        let height = collapsedHeight + (expandedHeight - collapsedHeight) * progress

        let frame = CGRect(
            x: rect.midX - width / 2,
            y: 0,
            width: width,
            height: height
        )

        let radius = 14 + 10 * progress
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: frame)
    }
}

@MainActor
private final class PocketbookShortcutCaptureView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Press a new shortcut")
    var captured: PocketbookShortcut?

    override var acceptsFirstResponder: Bool { return true }

    init(current: PocketbookShortcut) {
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
        guard let value = PocketbookShortcut(event: event),
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

private enum PocketbookLibrary {
    private static func e(
        _ id: String,
        _ kind: PocketbookKind,
        _ title: String,
        _ subtitle: String,
        _ keywords: String,
        _ content: String,
        code: Bool = true
    ) -> PocketbookEntry {
        return PocketbookEntry(
            id: id,
            kind: kind,
            title: title,
            subtitle: subtitle,
            keywords: keywords,
            content: content,
            code: code
        )
    }

    static let kubernetes: [PocketbookEntry] = [
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
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
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
    - name: http
      port: 80
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
          "statefulset serviceName volumeClaimTemplates", """
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
          "daemonset node daemon agent", """
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
          "cronjob schedule job restartPolicy", """
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
        e("pdb-yaml", .yaml, "PodDisruptionBudget YAML", "Protect voluntary availability",
          "pdb minavailable drain", """
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: my-app
"""),
        e("hpa", .yaml, "HPA YAML", "CPU-based autoscaling boilerplate",
          "hpa autoscaling cpu", """
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: my-app
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
"""),
        e("pods", .kubectl, "Pods: inspect quickly", "Get, wide, YAML and describe",
          "pods get describe wide", """
kubectl get pods
kubectl get pods -o wide
kubectl get pod <pod> -o yaml
kubectl describe pod <pod>
kubectl get pods -A
"""),
        e("logs", .kubectl, "Logs", "Follow, previous container and timestamps",
          "logs follow tail previous", """
kubectl logs <pod>
kubectl logs -f <pod>
kubectl logs <pod> -c <container>
kubectl logs <pod> --previous
kubectl logs <pod> --since=10m --timestamps
"""),
        e("exec", .kubectl, "Exec into a Pod", "Interactive shell and one-shot command",
          "exec shell bash sh command", """
kubectl exec -it <pod> -- /bin/sh
kubectl exec -it <pod> -- /bin/bash
kubectl exec <pod> -- env
kubectl exec -it <pod> -c <container> -- /bin/sh
"""),
        e("rollout", .kubectl, "Deployment rollout", "Status, restart, history and undo",
          "rollout restart undo history", """
kubectl rollout status deployment/<name>
kubectl rollout restart deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name>
"""),
        e("scale", .kubectl, "Scale workload", "Change Deployment or StatefulSet replicas",
          "scale replicas deployment statefulset", """
kubectl scale deployment/<name> --replicas=3
kubectl scale statefulset/<name> --replicas=3
"""),
        e("context", .kubectl, "Context & Namespace", "See and switch kubeconfig context",
          "context namespace config", """
kubectl config current-context
kubectl config get-contexts
kubectl config use-context <context>
kubectl config set-context --current --namespace=<namespace>
kubectl config view --minify
"""),
        e("events", .kubectl, "Events", "First stop for many workload failures",
          "events warning troubleshoot", """
kubectl get events
kubectl get events --sort-by=.lastTimestamp
kubectl get events -A --sort-by=.lastTimestamp
kubectl get events --field-selector type=Warning
"""),
        e("port-forward", .kubectl, "Port Forward", "Expose a Pod or Service locally",
          "port forward localhost tunnel", """
kubectl port-forward pod/<pod> 8080:80
kubectl port-forward service/<service> 8080:80
kubectl port-forward service/<service> 8080:80 -n <namespace>
"""),
        e("deploy-vs-stateful", .concepts, "Deployment vs StatefulSet", "Quick workload selection reminder",
          "deployment statefulset identity storage", """
Deployment
• Default choice for stateless applications.
• Pods are interchangeable.
• Typical use: APIs, web apps, workers.

StatefulSet
• Use when Pods need stable identity or ordered lifecycle.
• Pod names stay predictable: app-0, app-1, app-2.
• Commonly paired with persistent volumes.
""", code: false),
        e("probes", .concepts, "Probes", "Readiness, liveness and startup",
          "probe health readiness liveness", """
readinessProbe
Controls whether a Pod receives Service traffic.

livenessProbe
Detects a stuck container and can trigger a restart.

startupProbe
Protects slow-starting apps from liveness checks until startup succeeds.
""", code: false),
        e("resources", .concepts, "Requests vs Limits", "Scheduler reservation vs runtime ceiling",
          "cpu memory requests limits oom", """
Requests
• Used by the scheduler when placing Pods.
• Express resources the workload expects to need.

Limits
• Set a runtime ceiling.
• CPU may be throttled at its limit.
• Exceeding a memory limit can result in OOMKilled.
""", code: false),
        e("service-types", .concepts, "Service Types", "ClusterIP, NodePort and LoadBalancer",
          "service clusterip nodeport loadbalancer", """
ClusterIP
• Default Service type; reachable inside the cluster.

NodePort
• Opens the Service on a port on each Node.

LoadBalancer
• Requests an external load balancer from supported cloud integrations.
""", code: false),
        e("pdb-concept", .concepts, "PodDisruptionBudget", "Voluntary disruption guardrail",
          "pdb disruption drain eviction", """
PodDisruptionBudget limits how many replicas may be unavailable during voluntary disruptions.

Common examples:
• Node drain
• Cluster maintenance
• Voluntary eviction

Use either minAvailable or maxUnavailable for the selected Pods.
""", code: false),
    ]
}
