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
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + keyLabel
    }

    var conflictsWithFileShelf: Bool {
        modifiers == UInt32(cmdKey)
            && (keyCode == UInt32(kVK_ANSI_X) || keyCode == UInt32(kVK_ANSI_V))
    }
}

private enum PocketbookKind: String, CaseIterable, Identifiable {
    case all = "All"
    case yaml = "YAML"
    case kubectl = "kubectl"
    case concepts = "Concepts"
    var id: String { rawValue }
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
        let base = kind == .all ? entries : entries.filter { $0.kind == kind }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            if self?.copiedID == entry.id { self?.copiedID = nil }
        }
    }
}

@MainActor
final class PocketbookFeature {
    private static let keyCodeKey = "NotchShelf.Pocketbook.keyCode"
    private static let modifiersKey = "NotchShelf.Pocketbook.modifiers"
    private static let labelKey = "NotchShelf.Pocketbook.keyLabel"
    private let signature: OSType = 0x4E535042 // NSPB

    private let model = PocketbookModel()
    private var shortcut: PocketbookShortcut
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var panel: PocketbookPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?

    var onShortcutChanged: (() -> Void)?
    var shortcutDescription: String { shortcut.displayString }
    var isVisible: Bool { panel?.isVisible == true }

    init() {
        let d = UserDefaults.standard
        if d.object(forKey: Self.keyCodeKey) != nil,
           d.object(forKey: Self.modifiersKey) != nil {
            shortcut = PocketbookShortcut(
                keyCode: UInt32(d.integer(forKey: Self.keyCodeKey)),
                modifiers: UInt32(d.integer(forKey: Self.modifiersKey)),
                keyLabel: d.string(forKey: Self.labelKey) ?? "?"
            )
        } else {
            shortcut = .defaultShortcut
        }
    }

    func start() {
        guard handler == nil else { return }
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let read = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id
                )
                guard read == noErr else { return read }
                let feature = Unmanaged<PocketbookFeature>.fromOpaque(userData).takeUnretainedValue()
                return MainActor.assumeIsolated {
                    guard id.signature == feature.signature, id.id == 1 else { return OSStatus(eventNotHandledErr) }
                    feature.toggle()
                    return noErr
                }
            },
            1, &type, pointer, &handler
        )
        guard status == noErr else {
            NSLog("[NotchShelf] Pocketbook hotkey handler failed: %d", status)
            return
        }
        let register = registerShortcut()
        NSLog(register == noErr
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

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        previousApp = NSWorkspace.shared.frontmostApplication
        model.reset()
        model.presented = false

        let width = min(max(geometry.hardwareWidth + 250, 480), screen.frame.width - 32)
        let height = geometry.hardwareHeight + 346
        let frame = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )

        panel?.orderOut(nil)
        let p = PocketbookPanel(frame: frame, model: model, geometry: geometry) { [weak self] in self?.hide() }
        panel = p
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        p.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in self?.model.presented = true }
    }

    func hide() {
        guard let panel = panel, panel.isVisible else { return }
        removeKeyMonitor()
        model.presented = false
        let restore = previousApp
        previousApp = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30) { [weak self, weak panel] in
            panel?.orderOut(nil)
            self?.panel = nil
            if let restore = restore, restore.bundleIdentifier != Bundle.main.bundleIdentifier {
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
        if let hotKey = hotKey { UnregisterEventHotKey(hotKey); self.hotKey = nil }
        shortcut = newValue
        guard registerShortcut() == noErr else {
            shortcut = old
            _ = registerShortcut()
            return false
        }
        let d = UserDefaults.standard
        d.set(Int(newValue.keyCode), forKey: Self.keyCodeKey)
        d.set(Int(newValue.modifiers), forKey: Self.modifiersKey)
        d.set(newValue.keyLabel, forKey: Self.labelKey)
        return true
    }

    private func registerShortcut() -> OSStatus {
        guard handler != nil else { return OSStatus(eventNotHandledErr) }
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: signature, id: 1)
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers, id, GetApplicationEventTarget(), OptionBits(0), &ref
        )
        if status == noErr { hotKey = ref }
        return status
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            if event.keyCode == UInt16(kVK_Escape) {
                if self.model.selectedID != nil { self.model.selectedID = nil } else { self.hide() }
                return nil
            }
            if event.keyCode == UInt16(kVK_Return), self.model.selectedID == nil {
                self.model.selectedID = self.model.results.first?.id
                return nil
            }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags.contains(.command), event.keyCode == UInt16(kVK_ANSI_C), let entry = self.model.selected {
                self.model.copy(entry)
                return nil
            }
            return event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor = keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
    }
}

@MainActor
private final class PocketbookPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(frame: NSRect, model: PocketbookModel, geometry: NotchGeometry, onClose: @escaping () -> Void) {
        super.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = .mainMenu + 8
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        hidesOnDeactivate = false
        let host = NSHostingView(rootView: PocketbookView(model: model, geometry: geometry, onClose: onClose))
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

    var body: some View {
        ZStack(alignment: .top) {
            PocketbookSurface(hardwareWidth: geometry.hardwareWidth, hardwareHeight: geometry.hardwareHeight)
                .fill(Color.black.opacity(0.97))
                .overlay {
                    PocketbookSurface(hardwareWidth: geometry.hardwareWidth, hardwareHeight: geometry.hardwareHeight)
                        .stroke(.white.opacity(0.10), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.42), radius: 18, y: 8)

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "book.closed.fill").foregroundStyle(Color.accentColor)
                    Text("Pocketbook").font(.system(size: 15, weight: .semibold, design: .rounded))
                    Text("Kubernetes MVP")
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.52))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.08)))
                    Spacer()
                    Button(action: onClose) {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                            .frame(width: 23, height: 23).background(Circle().fill(.white.opacity(0.08)))
                    }.buttonStyle(.plain)
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                    TextField("Search deployment, rollout, port-forward…", text: $model.query)
                        .textFieldStyle(.plain).focused($searchFocused)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                    if !model.query.isEmpty {
                        Button { model.query = ""; model.selectedID = nil } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.35))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11).frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.075)))

                HStack(spacing: 4) {
                    ForEach(PocketbookKind.allCases) { kind in
                        Button {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                                model.kind = kind; model.selectedID = nil
                            }
                        } label: {
                            Text(kind.rawValue).font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(model.kind == kind ? .white : .white.opacity(0.45))
                                .frame(maxWidth: .infinity).frame(height: 27)
                                .background(RoundedRectangle(cornerRadius: 8).fill(
                                    model.kind == kind ? Color.accentColor.opacity(0.62) : .clear
                                ))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(3).background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.055)))

                Group {
                    if let entry = model.selected { detail(entry) } else { results }
                }
                .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86), value: model.selectedID)

                Text(model.selectedID == nil ? "↵ Open first result   •   Esc Close" : "Esc Back   •   ⌘C Copy")
                    .font(.system(size: 8.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.28)).frame(height: 10)
            }
            .padding(.horizontal, 16)
            .padding(.top, geometry.hardwareHeight + 10)
            .padding(.bottom, 11)
        }
        .scaleEffect(model.presented ? 1 : 0.965, anchor: .top)
        .opacity(model.presented ? 1 : 0)
        .animation(reduceMotion ? nil : .spring(response: 0.40, dampingFraction: 0.84), value: model.presented)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { searchFocused = true } }
        .onChange(of: model.selectedID) { value in
            if value == nil { DispatchQueue.main.async { searchFocused = true } }
        }
    }

    private var results: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                if model.results.isEmpty {
                    Text("No reference found").foregroundStyle(.white.opacity(0.45))
                        .frame(maxWidth: .infinity, minHeight: 150)
                } else {
                    ForEach(model.results) { entry in
                        Button { model.selectedID = entry.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: icon(entry.kind)).frame(width: 22)
                                    .foregroundStyle(iconColor(entry.kind))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.title).font(.system(size: 11.5, weight: .semibold, design: .rounded))
                                    Text(entry.subtitle).font(.system(size: 9.5, design: .rounded))
                                        .foregroundStyle(.white.opacity(0.45)).lineLimit(1)
                                }
                                Spacer()
                                Text(entry.kind.rawValue).font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.36))
                                Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.25))
                            }
                            .padding(.horizontal, 10).frame(height: 43)
                            .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.045)))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .scrollIndicators(.never).frame(maxHeight: .infinity)
    }

    private func detail(_ entry: PocketbookEntry) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { model.selectedID = nil } label: {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24).background(Circle().fill(.white.opacity(0.07)))
                }.buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.title).font(.system(size: 13, weight: .semibold, design: .rounded))
                    Text(entry.subtitle).font(.system(size: 9.3, design: .rounded))
                        .foregroundStyle(.white.opacity(0.46)).lineLimit(1)
                }
                Spacer()
                Text(entry.kind.rawValue).font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.accentColor)
            }

            ScrollView([.vertical, .horizontal]) {
                Text(entry.content)
                    .font(entry.code
                        ? .system(size: 10.8, design: .monospaced)
                        : .system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading).padding(11)
            }
            .background(RoundedRectangle(cornerRadius: 11).fill(.white.opacity(0.045)))

            HStack {
                Button { model.copy(entry) } label: {
                    HStack(spacing: 6) {
                        Image(systemName: model.copiedID == entry.id ? "checkmark" : "doc.on.doc")
                        Text(model.copiedID == entry.id ? "Copied" : "Copy")
                    }
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.copiedID == entry.id ? .green : .white.opacity(0.88))
                    .padding(.horizontal, 12).frame(height: 29)
                    .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.08)))
                }.buttonStyle(.plain)
                Spacer()
                Text("⌘C").font(.system(size: 9, design: .rounded)).foregroundStyle(.white.opacity(0.28))
            }
        }.frame(maxHeight: .infinity)
    }

    private func icon(_ kind: PocketbookKind) -> String {
        switch kind {
        case .yaml: return "doc.text.fill"
        case .kubectl: return "terminal.fill"
        case .concepts: return "book.pages.fill"
        case .all: return "book.closed.fill"
        }
    }

    private func iconColor(_ kind: PocketbookKind) -> Color {
        switch kind {
        case .yaml: return Color.accentColor.opacity(0.9)
        case .kubectl: return .green.opacity(0.85)
        case .concepts: return .orange.opacity(0.88)
        case .all: return .white.opacity(0.7)
        }
    }
}

private struct PocketbookSurface: Shape {
    let hardwareWidth: CGFloat
    let hardwareHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top = max(0, hardwareHeight - 2)
        p.addRoundedRect(in: CGRect(x: 5, y: top, width: rect.width - 10, height: rect.height - top - 5),
                         cornerSize: CGSize(width: 20, height: 20))
        let left = rect.midX - hardwareWidth / 2
        let right = rect.midX + hardwareWidth / 2
        p.addRect(CGRect(x: left - 64, y: 0, width: 76, height: hardwareHeight + 12))
        p.addRect(CGRect(x: right - 12, y: 0, width: 76, height: hardwareHeight + 12))
        return p
    }
}

@MainActor
private final class PocketbookShortcutCaptureView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Press a new shortcut")
    var captured: PocketbookShortcut?
    override var acceptsFirstResponder: Bool { true }

    init(current: PocketbookShortcut) {
        captured = current
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 74))
        shortcutLabel.stringValue = current.displayString
        shortcutLabel.font = .systemFont(ofSize: 24, weight: .semibold)
        shortcutLabel.alignment = .center
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        [shortcutLabel, hint].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; addSubview($0) }
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
        guard let value = PocketbookShortcut(event: event), !value.conflictsWithFileShelf else {
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
    private static func e(_ id: String, _ kind: PocketbookKind, _ title: String, _ subtitle: String,
                          _ keywords: String, _ content: String, code: Bool = true) -> PocketbookEntry {
        PocketbookEntry(id: id, kind: kind, title: title, subtitle: subtitle,
                        keywords: keywords, content: content, code: code)
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
        e("service", .yaml, "Service YAML", "ClusterIP service boilerplate", "service clusterip targetport", """
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
        e("ingress", .yaml, "Ingress YAML", "networking.k8s.io/v1 boilerplate", "ingress host path backend", """
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
        e("pdb-yaml", .yaml, "PodDisruptionBudget YAML", "Protect voluntary availability", "pdb minavailable drain", """
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
        e("hpa", .yaml, "HPA YAML", "CPU-based autoscaling boilerplate", "hpa autoscaling cpu", """
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
        e("pods", .kubectl, "Pods: inspect quickly", "Get, wide, YAML and describe", "pods get describe wide", """
kubectl get pods
kubectl get pods -o wide
kubectl get pod <pod> -o yaml
kubectl describe pod <pod>
kubectl get pods -A
"""),
        e("logs", .kubectl, "Logs", "Follow, previous container and timestamps", "logs follow tail previous", """
kubectl logs <pod>
kubectl logs -f <pod>
kubectl logs <pod> -c <container>
kubectl logs <pod> --previous
kubectl logs <pod> --since=10m --timestamps
"""),
        e("rollout", .kubectl, "Deployment rollout", "Status, restart, history and undo", "rollout restart undo history", """
kubectl rollout status deployment/<name>
kubectl rollout restart deployment/<name>
kubectl rollout history deployment/<name>
kubectl rollout undo deployment/<name>
"""),
        e("context", .kubectl, "Context & Namespace", "See and switch kubeconfig context", "context namespace config", """
kubectl config current-context
kubectl config get-contexts
kubectl config use-context <context>
kubectl config set-context --current --namespace=<namespace>
kubectl config view --minify
"""),
        e("events", .kubectl, "Events", "First stop for many workload failures", "events warning troubleshoot", """
kubectl get events
kubectl get events --sort-by=.lastTimestamp
kubectl get events -A --sort-by=.lastTimestamp
kubectl get events --field-selector type=Warning
"""),
        e("port-forward", .kubectl, "Port Forward", "Expose a Pod or Service locally", "port forward localhost tunnel", """
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
        e("probes", .concepts, "Probes", "Readiness, liveness and startup", "probe health readiness liveness", """
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
    ]
}
