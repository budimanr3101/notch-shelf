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
        NotchAppLauncher.shared.start()

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
        NotchAppLauncher.shared.stop()
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

// MARK: - Notch App Launcher MVP

private struct NotchLauncherApplication: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleIdentifier: String?

    var id: String { url.path }
}

@MainActor
private final class NotchLauncherModel: ObservableObject {
    @Published var query = "" {
        didSet { selectedIndex = 0 }
    }
    @Published var selectedIndex = 0
    @Published var applications: [NotchLauncherApplication] = []
    @Published var presented = false

    private static let recentKey = "NotchShelf.Launcher.recentApplications"
    private var loaded = false

    var results: [NotchLauncherApplication] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let recent = recentApplications
        let recentRank = Dictionary(
            uniqueKeysWithValues: recent.enumerated().map { ($0.element, $0.offset) }
        )

        if trimmed.isEmpty {
            return applications.sorted { lhs, rhs in
                let leftRank = recentRank[lhs.url.path] ?? Int.max
                let rightRank = recentRank[rhs.url.path] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
        }

        let needle = normalize(trimmed)
        return applications.compactMap { app -> (NotchLauncherApplication, Int, Int)? in
            guard let score = matchScore(app, needle: needle) else { return nil }
            return (app, score, recentRank[app.url.path] ?? Int.max)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
            return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        .map { $0.0 }
    }

    var selectedApplication: NotchLauncherApplication? {
        let visible = results
        guard !visible.isEmpty else { return nil }
        return visible[min(max(0, selectedIndex), visible.count - 1)]
    }

    func loadApplicationsIfNeeded() {
        guard !loaded else { return }
        loaded = true
        applications = Self.scanApplications()
        NSLog("[NotchShelf] Launcher indexed %d application(s)", applications.count)
    }

    func refreshApplications() {
        applications = Self.scanApplications()
        selectedIndex = 0
        NSLog("[NotchShelf] Launcher refreshed %d application(s)", applications.count)
    }

    func moveSelection(_ delta: Int) {
        let count = results.count
        guard count > 0 else {
            selectedIndex = 0
            return
        }
        selectedIndex = min(max(0, selectedIndex + delta), count - 1)
    }

    func recordLaunch(_ app: NotchLauncherApplication) {
        var recent = recentApplications.filter { $0 != app.url.path }
        recent.insert(app.url.path, at: 0)
        if recent.count > 20 {
            recent.removeLast(recent.count - 20)
        }
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }

    private var recentApplications: [String] {
        UserDefaults.standard.stringArray(forKey: Self.recentKey) ?? []
    }

    private func matchScore(_ app: NotchLauncherApplication, needle: String) -> Int? {
        let name = normalize(app.name)
        let bundle = normalize(app.bundleIdentifier ?? "")

        if name == needle { return 1000 }
        if name.hasPrefix(needle) { return 900 }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(needle) }) { return 820 }
        if name.contains(needle) { return 740 }
        if bundle.contains(needle) { return 580 }
        if fuzzyMatch(needle, in: name) { return 420 }
        return nil
    }

    private func normalize(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        .lowercased()
    }

    private func fuzzyMatch(_ needle: String, in haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var index = needle.startIndex
        for character in haystack {
            if character == needle[index] {
                index = needle.index(after: index)
                if index == needle.endIndex { return true }
            }
        }
        return false
    }

    private static func scanApplications() -> [NotchLauncherApplication] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            home.appendingPathComponent("Applications", isDirectory: true),
        ]

        var seen = Set<String>()
        var apps: [NotchLauncherApplication] = []

        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles],
                errorHandler: nil
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.lowercased() == "app" else { continue }
                enumerator.skipDescendants()

                let canonical = url.resolvingSymlinksInPath().path
                guard seen.insert(canonical).inserted else { continue }

                let bundle = Bundle(url: url)
                let bundleID = bundle?.bundleIdentifier
                if bundleID == "com.budiman.notchshelf" { continue }

                let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent

                guard !displayName.isEmpty else { continue }
                apps.append(
                    NotchLauncherApplication(
                        url: url,
                        name: displayName,
                        bundleIdentifier: bundleID
                    )
                )
            }
        }

        return apps.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }
}

private struct NotchLauncherMetrics {
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
private final class NotchAppLauncher {
    static let shared = NotchAppLauncher()

    private let signature: OSType = 0x4E534C41 // NSLA
    private let model = NotchLauncherModel()
    private var hotKey: EventHotKeyRef?
    private var panel: NotchLauncherPanel?
    private var keyMonitor: Any?
    private var pendingDismissal: DispatchWorkItem?
    private var started = false
    private var requestedVisible = false

    private init() {}

    private var isVisible: Bool {
        requestedVisible && panel?.isVisible == true
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
            NSLog("[NotchShelf] Launcher hotkey handler failed: %d", handlerStatus)
            return
        }

        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            identifier,
            GetApplicationEventTarget(),
            OptionBits(0),
            &reference
        )

        guard status == noErr else {
            CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
            NSLog("[NotchShelf] Launcher shortcut unavailable on ⌥Space (OSStatus %d)", status)
            return
        }

        hotKey = reference
        started = true
        model.loadApplicationsIfNeeded()
        NSLog("[NotchShelf] Notch Launcher ready on ⌥Space")
    }

    func stop() {
        requestedVisible = false
        pendingDismissal?.cancel()
        pendingDismissal = nil
        removeKeyMonitor()
        model.presented = false
        panel?.orderOut(nil)
        panel = nil

        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        self.hotKey = nil
        CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
        started = false
    }

    private func toggle() {
        if isVisible { hide() }
        else { show() }
    }

    private func show() {
        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        model.loadApplicationsIfNeeded()
        model.query = ""
        model.selectedIndex = 0
        pendingDismissal?.cancel()
        pendingDismissal = nil
        requestedVisible = true

        let metrics = NotchLauncherMetrics(geometry: geometry, screen: screen)
        let frame = NSRect(
            x: screen.frame.midX - metrics.windowSize.width / 2,
            y: screen.frame.maxY - metrics.windowSize.height,
            width: metrics.windowSize.width,
            height: metrics.windowSize.height
        )

        if panel == nil || panel?.frame != frame {
            panel?.orderOut(nil)
            panel = NotchLauncherPanel(
                frame: frame,
                model: model,
                geometry: geometry,
                metrics: metrics,
                onClose: { [weak self] in self?.hide() },
                onLaunch: { [weak self] app in self?.launch(app) }
            )
        }

        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel?.ignoresMouseEvents = false
        panel?.makeKeyAndOrderFront(nil)
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.requestedVisible else { return }
            self.model.presented = true
        }
    }

    private func hide() {
        guard requestedVisible else { return }
        requestedVisible = false
        removeKeyMonitor()
        model.presented = false
        panel?.ignoresMouseEvents = true
        panel?.makeFirstResponder(nil)
        panel?.resignKey()
        pendingDismissal?.cancel()

        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self,
                  !self.requestedVisible,
                  self.panel === panel else { return }
            panel?.orderOut(nil)
            self.pendingDismissal = nil
        }
        pendingDismissal = work
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.10 : 0.24
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func launch(_ app: NotchLauncherApplication) {
        model.recordLaunch(app)
        let opened = NSWorkspace.shared.open(app.url)
        NSLog(
            opened
                ? "[NotchShelf] Launcher opened %@"
                : "[NotchShelf] Launcher failed to open %@",
            app.name
        )
        hide()
    }

    private func launchSelected() {
        guard let app = model.selectedApplication else {
            NSSound.beep()
            return
        }
        launch(app)
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible else { return event }

            switch Int(event.keyCode) {
            case kVK_Escape:
                self.hide()
                return nil
            case kVK_UpArrow:
                self.model.moveSelection(-1)
                return nil
            case kVK_DownArrow:
                self.model.moveSelection(1)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                self.launchSelected()
                return nil
            default:
                if event.modifierFlags.contains(.command),
                   event.keyCode == UInt16(kVK_ANSI_R) {
                    self.model.refreshApplications()
                    return nil
                }
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }
}

@MainActor
private final class NotchLauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(
        frame: NSRect,
        model: NotchLauncherModel,
        geometry: NotchGeometry,
        metrics: NotchLauncherMetrics,
        onClose: @escaping () -> Void,
        onLaunch: @escaping (NotchLauncherApplication) -> Void
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
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false

        let hosting = NSHostingView(
            rootView: NotchLauncherView(
                model: model,
                geometry: geometry,
                metrics: metrics,
                onClose: onClose,
                onLaunch: onLaunch
            )
        )
        hosting.safeAreaRegions = []
        hosting.sizingOptions = []
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]
        contentView = hosting
    }
}

private struct NotchLauncherView: View {
    @ObservedObject var model: NotchLauncherModel
    let geometry: NotchGeometry
    let metrics: NotchLauncherMetrics
    let onClose: () -> Void
    let onLaunch: (NotchLauncherApplication) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
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
                    .stroke(Color.white.opacity(0.11), lineWidth: 0.75)
                }
                .shadow(
                    color: Color.black.opacity(0.38 * Double(bridgeExpansion)),
                    radius: 18,
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
                .offset(y: reduceMotion || contentVisible ? 0 : -6)
                .allowsHitTesting(model.presented && contentVisible)
        }
        .frame(
            width: metrics.windowSize.width,
            height: metrics.windowSize.height,
            alignment: .top
        )
        .clipped()
        .onChange(of: model.presented) { visible in
            animatePresentation(visible)
        }
        .onChange(of: contentVisible) { visible in
            if visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    searchFocused = true
                }
            } else {
                searchFocused = false
            }
        }
        .onDisappear {
            cancelMotion()
        }
    }

    private var content: some View {
        VStack(spacing: 10) {
            searchBar
            results
            footer
        }
        .padding(.horizontal, 17)
        .padding(.top, geometry.hardwareHeight + 11)
        .padding(.bottom, 11)
        .frame(
            width: metrics.contentWidth,
            height: geometry.hardwareHeight + metrics.depth,
            alignment: .top
        )
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.48))

            TextField("Search applications…", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 16, weight: .medium, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.96))
                .focused($searchFocused)

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.white.opacity(0.28))
                }
                .buttonStyle(.plain)
            }

            Text("⌥Space")
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .foregroundStyle(Color.white.opacity(0.34))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.055))
                )
        }
        .padding(.horizontal, 13)
        .frame(height: 48)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.065))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    Color.white.opacity(searchFocused ? 0.15 : 0.08),
                    lineWidth: 0.8
                )
        }
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                let visible = model.results

                if visible.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "app.dashed")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.22))
                        Text(
                            model.query.isEmpty
                                ? "No applications indexed"
                                : "No application found"
                        )
                        .font(.system(size: 12.5, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.42))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 72)
                } else {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(visible.enumerated()), id: \.element.id) { index, app in
                            resultRow(app, index: index)
                                .id(app.id)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.selectedIndex) { index in
                let visible = model.results
                guard visible.indices.contains(index) else { return }
                let app = visible[index]
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(app.id, anchor: .center)
                }
            }
            .onChange(of: model.query) { _ in
                let visible = model.results
                guard let first = visible.first else { return }
                DispatchQueue.main.async {
                    proxy.scrollTo(first.id, anchor: .top)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultRow(_ app: NotchLauncherApplication, index: Int) -> some View {
        let selected = index == model.selectedIndex
        return Button {
            model.selectedIndex = index
            onLaunch(app)
        } label: {
            HStack(spacing: 11) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 34, height: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 13.2, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.94))
                        .lineLimit(1)

                    Text(app.bundleIdentifier ?? "Application")
                        .font(.system(size: 9.2, weight: .regular, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.36))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                if selected {
                    HStack(spacing: 5) {
                        Text("Open")
                        Text("↵")
                    }
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.48))
                }
            }
            .padding(.horizontal, 11)
            .frame(height: 46)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(selected ? 0.095 : 0.001))
            )
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text("↑↓ Navigate")
            Text("•")
            Text("↵ Open")
            Text("•")
            Text("⌘R Refresh")
            Spacer()
            Text("Esc Close")
        }
        .font(.system(size: 8.5, weight: .medium, design: .rounded))
        .foregroundStyle(Color.white.opacity(0.34))
        .frame(height: 12)
    }

    private func animatePresentation(_ visible: Bool) {
        cancelMotion()

        if reduceMotion {
            shoulderExpansion = visible ? 1 : 0
            bridgeExpansion = visible ? 1 : 0
            contentVisible = visible
            return
        }

        if visible {
            withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)) {
                shoulderExpansion = 1
            }
            schedule(after: 0.055) {
                withAnimation(.timingCurve(0.23, 1, 0.32, 1, duration: 0.22)) {
                    bridgeExpansion = 1
                }
            }
            schedule(after: 0.14) {
                withAnimation(.easeOut(duration: 0.11)) {
                    contentVisible = true
                }
            }
        } else {
            withAnimation(.easeOut(duration: 0.08)) {
                contentVisible = false
            }
            schedule(after: 0.035) {
                withAnimation(.timingCurve(0.55, 0, 0.85, 0.40, duration: 0.16)) {
                    bridgeExpansion = 0
                }
            }
            schedule(after: 0.11) {
                withAnimation(.timingCurve(0.55, 0, 0.85, 0.40, duration: 0.13)) {
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
