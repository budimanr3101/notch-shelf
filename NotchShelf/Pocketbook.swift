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

        let queryText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !queryText.isEmpty else { return base }

        return base.filter {
            $0.title.localizedCaseInsensitiveContains(queryText)
                || $0.subtitle.localizedCaseInsensitiveContains(queryText)
                || $0.keywords.localizedCaseInsensitiveContains(queryText)
                || $0.content.localizedCaseInsensitiveContains(queryText)
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

private enum PocketbookLayout {
    static let homeWingWidth: CGFloat = 96
    static let detailWingWidth: CGFloat = 138
    static let homeDepth: CGFloat = 188
    static let detailDepth: CGFloat = 300
    static let bottomSlack: CGFloat = 8

    static func windowSize(for geometry: NotchGeometry) -> CGSize {
        let width = geometry.hardwareWidth
            + 2 * (detailWingWidth + NotchGeometry.topRadius)
            + 24
        let height = geometry.hardwareHeight + detailDepth + bottomSlack
        return CGSize(width: width, height: height)
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

        let size = PocketbookLayout.windowSize(for: geometry)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height,
            width: size.width,
            height: size.height
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

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.43) { [weak self, weak panel] in
            panel?.orderOut(nil)
            guard self?.panel === panel else { return }
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
    @State private var surfaceOpen = false
    @State private var contentVisible = false

    private var isDetail: Bool {
        return model.selectedID != nil
    }

    private var activeDepth: CGFloat {
        return isDetail ? PocketbookLayout.detailDepth : PocketbookLayout.homeDepth
    }

    private var activeWingWidth: CGFloat {
        return isDetail ? PocketbookLayout.detailWingWidth : PocketbookLayout.homeWingWidth
    }

    private var surface: PocketbookNotchWings {
        return PocketbookNotchWings(
            geometry: geometry,
            expansion: surfaceOpen ? 1 : 0,
            extraDepth: surfaceOpen ? activeDepth : 0,
            wingWidth: surfaceOpen ? activeWingWidth : 0
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            surface
                .fill(.black)
                .shadow(
                    color: surfaceOpen ? Color.black.opacity(0.34) : .clear,
                    radius: 14,
                    y: 5
                )

            content
                .opacity(contentVisible ? 1 : 0)
                .offset(y: reduceMotion || contentVisible ? 0 : -5)
                .mask(surface)
                .allowsHitTesting(contentVisible && model.presented)
        }
        .frame(
            width: PocketbookLayout.windowSize(for: geometry).width,
            height: PocketbookLayout.windowSize(for: geometry).height,
            alignment: .top
        )
        .clipped()
        .ignoresSafeArea()
        .animation(
            reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.84),
            value: surfaceOpen
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.86),
            value: isDetail
        )
        .onAppear {
            syncPresentation(model.presented)
        }
        .onChange(of: model.presented) { visible in
            syncPresentation(visible)
        }
        .onChange(of: model.selectedID) { selectedID in
            if selectedID != nil {
                searchFocused = false
            } else if model.presented {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                    searchFocused = true
                }
            }
        }
    }

    private var content: some View {
        Group {
            if let entry = model.selected {
                detail(entry)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        )
                    )
            } else {
                home
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        )
                    )
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, geometry.hardwareHeight + 5)
        .frame(
            width: PocketbookLayout.windowSize(for: geometry).width,
            height: geometry.hardwareHeight + activeDepth,
            alignment: .top
        )
        .animation(
            reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.88),
            value: model.selectedID
        )
    }

    private var home: some View {
        VStack(spacing: 5) {
            header
            searchBar
            tabs
            results
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "book.closed.fill")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.82))

            Text("Pocketbook")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))

            Text("Kubernetes")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.46))
                    .frame(width: 21, height: 21)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .frame(height: 21)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.34))

            TextField("Search Kubernetes…", text: $model.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))

            if !model.query.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        model.query = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.26))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(.white.opacity(searchFocused ? 0.075 : 0.048))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(.white.opacity(searchFocused ? 0.12 : 0.045), lineWidth: 0.7)
        }
        .animation(.easeInOut(duration: 0.16), value: searchFocused)
    }

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(PocketbookKind.allCases) { kind in
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        model.kind = kind
                    }
                } label: {
                    ZStack {
                        if model.kind == kind {
                            Capsule()
                                .fill(.white.opacity(0.095))
                                .matchedGeometryEffect(id: "PocketbookTab", in: tabSelection)
                        }

                        Text(kind.rawValue)
                            .font(.system(size: 9.1, weight: .semibold, design: .rounded))
                            .foregroundStyle(
                                model.kind == kind
                                    ? Color.white.opacity(0.91)
                                    : Color.white.opacity(0.38)
                            )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 20)
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.results.isEmpty {
                    Text("No reference found")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .frame(maxWidth: .infinity, minHeight: 90)
                } else {
                    ForEach(model.results) { entry in
                        resultRow(entry)
                    }
                }
            }
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.16), value: model.query)
        .animation(.easeInOut(duration: 0.16), value: model.kind)
    }

    private func resultRow(_ entry: PocketbookEntry) -> some View {
        Button {
            withAnimation(.spring(response: 0.31, dampingFraction: 0.88)) {
                model.selectedID = entry.id
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(entry.kind))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(iconColor(entry.kind))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 10.8, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.91))
                        .lineLimit(1)
                    Text(entry.subtitle)
                        .font(.system(size: 8.8, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                Image(systemName: "chevron.right")
                    .font(.system(size: 7.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.18))
            }
            .padding(.horizontal, 4)
            .frame(height: 31)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(.white.opacity(0.045))
                    .frame(height: 0.5)
            }
        }
        .buttonStyle(.plain)
    }

    private func detail(_ entry: PocketbookEntry) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Button {
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.88)) {
                        model.selectedID = nil
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.72))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.96))
                    Text(entry.subtitle)
                        .font(.system(size: 8.9, design: .rounded))
                        .foregroundStyle(.white.opacity(0.38))
                        .lineLimit(1)
                }

                Spacer()

                Text(entry.kind.rawValue)
                    .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(iconColor(entry.kind))
            }
            .frame(height: 28)

            referenceBody(entry)

            HStack {
                Button {
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                        model.copy(entry)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: model.copiedID == entry.id ? "checkmark" : "doc.on.doc")
                        Text(model.copiedID == entry.id ? "Copied" : "Copy")
                    }
                    .font(.system(size: 9.8, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        model.copiedID == entry.id
                            ? Color.green.opacity(0.94)
                            : Color.white.opacity(0.78)
                    )
                    .padding(.horizontal, 11)
                    .frame(height: 27)
                    .background(
                        Capsule()
                            .fill(model.copiedID == entry.id
                                ? Color.green.opacity(0.10)
                                : Color.white.opacity(0.055))
                    )
                    .scaleEffect(model.copiedID == entry.id ? 1.03 : 1)
                }
                .buttonStyle(.plain)

                Spacer()

                Text("Esc Back   ·   ⌘C Copy")
                    .font(.system(size: 8.1, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.22))
            }
        }
    }

    private func referenceBody(_ entry: PocketbookEntry) -> some View {
        ScrollView([.vertical, .horizontal]) {
            if entry.code {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(
                        Array(entry.content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()),
                        id: \.offset
                    ) { index, line in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.system(size: 8.8, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.17))
                                .frame(width: 20, alignment: .trailing)

                            Text(String(line))
                                .font(.system(size: 10.1, design: .monospaced))
                                .foregroundStyle(codeColor(for: String(line)))
                                .textSelection(.enabled)
                        }
                        .frame(minHeight: 16)
                    }
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 8)
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
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(0.035))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.04), lineWidth: 0.6)
        }
    }

    private func syncPresentation(_ visible: Bool) {
        if visible {
            if reduceMotion {
                surfaceOpen = true
                contentVisible = true
                searchFocused = true
                return
            }

            surfaceOpen = false
            contentVisible = false
            searchFocused = false

            DispatchQueue.main.async {
                withAnimation(.spring(response: 0.36, dampingFraction: 0.84)) {
                    surfaceOpen = true
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.13) {
                guard model.presented else { return }
                withAnimation(.easeOut(duration: 0.16)) {
                    contentVisible = true
                }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                guard model.presented else { return }
                searchFocused = true
            }
        } else {
            searchFocused = false
            withAnimation(.easeOut(duration: reduceMotion ? 0.08 : 0.10)) {
                contentVisible = false
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0.06 : 0.07)) {
                withAnimation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.88)) {
                    surfaceOpen = false
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
            return Color.accentColor.opacity(0.84)
        case .kubectl:
            return Color.green.opacity(0.78)
        case .concepts:
            return Color.orange.opacity(0.80)
        case .all:
            return Color.white.opacity(0.64)
        }
    }

    private func codeColor(for line: String) -> Color {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("#") { return .white.opacity(0.34) }
        if trimmed.hasPrefix("kubectl ") { return .green.opacity(0.86) }
        if trimmed.contains("apiVersion:") || trimmed.contains("kind:") {
            return Color.accentColor.opacity(0.88)
        }
        if trimmed.hasPrefix("-") { return .white.opacity(0.70) }
        return .white.opacity(0.81)
    }
}

private struct PocketbookNotchWings: Shape {
    let geometry: NotchGeometry
    var expansion: CGFloat
    var extraDepth: CGFloat
    var wingWidth: CGFloat

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
        let extent = max(0, wingWidth) * progress
        let overlap = NotchGeometry.connectionOverlap * min(progress, 1)
        let maximumDepth = max(0, rect.height - geometry.hardwareHeight)
        let depth = min(max(extraDepth, 0), maximumDepth)
        let renderedHeight = geometry.hardwareHeight + depth

        let leftHardwareEdge = rect.midX - geometry.hardwareWidth / 2
        let rightHardwareEdge = rect.midX + geometry.hardwareWidth / 2

        let silhouette = PocketbookShelfShape(
            topRadius: NotchGeometry.topRadius,
            bottomRadius: NotchGeometry.bottomRadius
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

private struct PocketbookShelfShape: Shape {
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

        if let corners = PocketbookContinuousCorner.bottomCorners(
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

private enum PocketbookContinuousCorner {
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
        e("deployment", .yaml, "Deployment YAML", "Stateless workload boilerplate",
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
        e("configmap", .yaml, "ConfigMap YAML", "Non-secret configuration",
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
        e("pods", .kubectl, "Pods", "Get, wide, YAML and describe",
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
        e("scale", .kubectl, "Scale workload", "Deployment or StatefulSet replicas",
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
        e("events", .kubectl, "Events", "Useful first stop for workload failures",
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
