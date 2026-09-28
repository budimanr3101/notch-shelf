import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let defaultOpenerDefaultsKey = "NotchShelf.defaultDropOpener"
    private static let customOpenerPathDefaultsKey = "NotchShelf.customOpenerPath"

    private let coordinator = ShelfCoordinator()
    private let pocketbook = PocketbookFeatureV3()
    private lazy var terminal = NotchTerminalFeature(
        workingDirectoryProvider: { [weak self] in
            return self?.coordinator.recentProjectURL
        },
        beforeShow: { [weak self] in
            self?.pocketbook.hide()
        }
    )

    private var statusItem: NSStatusItem?
    private var shelfStatusItem: NSMenuItem?
    private var projectStatusItem: NSMenuItem?
    private var defaultDropAppItem: NSMenuItem?
    private var openRecentItem: NSMenuItem?
    private var clearProjectItem: NSMenuItem?
    private var pocketbookShortcutItem: NSMenuItem?
    private var terminalShortcutItem: NSMenuItem?

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()

        coordinator.onShelfChanged = { [weak self] count in
            self?.updateShelfStatus(count: count)
        }
        coordinator.onProjectChanged = { [weak self] url in
            self?.updateProjectStatus(url: url)
        }
        coordinator.onDropOpenerChanged = { [weak self] in
            self?.updateDropOpenerUI()
        }
        pocketbook.onShortcutChanged = { [weak self] in
            self?.updatePocketbookUI()
        }
        terminal.onShortcutChanged = { [weak self] in
            self?.updateTerminalUI()
        }

        coordinator.start()
        pocketbook.start()
        terminal.start()
        updateProjectStatus(url: coordinator.recentProjectURL)
        updateDropOpenerUI()
        updatePocketbookUI()
        updateTerminalUI()
    }

    func applicationWillTerminate(_ notification: Notification) {
        terminal.stop()
        pocketbook.stop()
        coordinator.stop()
    }

    private func setupMenuBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "tray.full.fill",
            accessibilityDescription: "NotchShelf"
        )

        let menu = NSMenu()
        menu.delegate = self

        let shelf = NSMenuItem(title: "Shelf: Empty", action: nil, keyEquivalent: "")
        shelf.isEnabled = false
        menu.addItem(shelf)
        shelfStatusItem = shelf

        let clear = NSMenuItem(
            title: "Clear Shelf",
            action: #selector(clearShelf),
            keyEquivalent: ""
        )
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let dropHeader = NSMenuItem(title: "Developer Drop Zone", action: nil, keyEquivalent: "")
        dropHeader.isEnabled = false
        menu.addItem(dropHeader)

        let defaultApp = NSMenuItem(
            title: "Default Drop App",
            action: nil,
            keyEquivalent: ""
        )
        defaultApp.submenu = NSMenu(title: "Default Drop App")
        menu.addItem(defaultApp)
        defaultDropAppItem = defaultApp

        let project = NSMenuItem(title: "Recent: None", action: nil, keyEquivalent: "")
        project.isEnabled = false
        menu.addItem(project)
        projectStatusItem = project

        let openRecent = NSMenuItem(
            title: "Open Recent With",
            action: nil,
            keyEquivalent: ""
        )
        openRecent.submenu = NSMenu(title: "Open Recent With")
        menu.addItem(openRecent)
        openRecentItem = openRecent

        let clearProject = NSMenuItem(
            title: "Clear Recent Project",
            action: #selector(clearRecentProject),
            keyEquivalent: ""
        )
        clearProject.target = self
        menu.addItem(clearProject)
        clearProjectItem = clearProject

        menu.addItem(.separator())

        let pocketHeader = NSMenuItem(title: "Pocketbook", action: nil, keyEquivalent: "")
        pocketHeader.isEnabled = false
        menu.addItem(pocketHeader)

        let openPocketbook = NSMenuItem(
            title: "Open Pocketbook",
            action: #selector(openPocketbookAction),
            keyEquivalent: ""
        )
        openPocketbook.target = self
        menu.addItem(openPocketbook)

        let pocketbookSettings = NSMenuItem(
            title: "Pocketbook Settings…",
            action: #selector(openPocketbookSettings),
            keyEquivalent: ""
        )
        pocketbookSettings.target = self
        menu.addItem(pocketbookSettings)

        let shortcutItem = NSMenuItem(
            title: "Shortcut: \(pocketbook.shortcutDescription)…",
            action: #selector(configurePocketbookShortcut),
            keyEquivalent: ""
        )
        shortcutItem.target = self
        menu.addItem(shortcutItem)
        pocketbookShortcutItem = shortcutItem

        menu.addItem(.separator())

        let terminalHeader = NSMenuItem(title: "Notch Terminal", action: nil, keyEquivalent: "")
        terminalHeader.isEnabled = false
        menu.addItem(terminalHeader)

        let openTerminal = NSMenuItem(
            title: "Open Notch Terminal",
            action: #selector(openTerminalAction),
            keyEquivalent: ""
        )
        openTerminal.target = self
        menu.addItem(openTerminal)

        let restartTerminal = NSMenuItem(
            title: "Restart Terminal Shell",
            action: #selector(restartTerminalAction),
            keyEquivalent: ""
        )
        restartTerminal.target = self
        menu.addItem(restartTerminal)

        let terminalShortcut = NSMenuItem(
            title: "Shortcut: \(terminal.shortcutDescription)…",
            action: #selector(configureTerminalShortcut),
            keyEquivalent: ""
        )
        terminalShortcut.target = self
        menu.addItem(terminalShortcut)
        terminalShortcutItem = terminalShortcut

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit NotchShelf",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        item.menu = menu
        statusItem = item

        updateShelfStatus(count: 0)
        updateProjectStatus(url: nil)
        updateDropOpenerUI()
        updatePocketbookUI()
        updateTerminalUI()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateShelfStatus(count: coordinator.stagedCount)
        updateProjectStatus(url: coordinator.recentProjectURL)
        updateDropOpenerUI()
        updatePocketbookUI()
        updateTerminalUI()
    }

    private func updateShelfStatus(count: Int) {
        shelfStatusItem?.title = count == 0
            ? "Shelf: Empty"
            : "Shelf: \(count) item\(count == 1 ? "" : "s")"

        statusItem?.button?.image = NSImage(
            systemSymbolName: count == 0 ? "tray" : "tray.full.fill",
            accessibilityDescription: "NotchShelf"
        )
    }

    private func updateProjectStatus(url: URL?) {
        let hasProject = url != nil
        projectStatusItem?.title = url.map { "Recent: \($0.lastPathComponent)" }
            ?? "Recent: None"
        openRecentItem?.isEnabled = hasProject
        clearProjectItem?.isEnabled = hasProject
    }

    private func updateDropOpenerUI() {
        defaultDropAppItem?.title = "Default Drop App: \(coordinator.defaultDropOpenerName)"

        let availableOptions = coordinator.dropOpenerMenuOptions.filter { $0.isAvailable }

        if let submenu = defaultDropAppItem?.submenu {
            submenu.removeAllItems()

            for option in availableOptions {
                let item = NSMenuItem(
                    title: option.displayName,
                    action: #selector(selectDropOpener(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                item.state = option.isSelected ? .on : .off
                submenu.addItem(item)
            }

            submenu.addItem(.separator())

            let custom = NSMenuItem(
                title: "Choose Custom App…",
                action: #selector(chooseCustomDropApp),
                keyEquivalent: ""
            )
            custom.target = self
            submenu.addItem(custom)
        }

        if let recentMenu = openRecentItem?.submenu {
            recentMenu.removeAllItems()

            for option in availableOptions {
                let item = NSMenuItem(
                    title: option.displayName,
                    action: #selector(openRecentWithOpener(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.id
                recentMenu.addItem(item)
            }

            recentMenu.addItem(.separator())

            let chooseOther = NSMenuItem(
                title: "Choose Other App…",
                action: #selector(chooseOtherAppForRecent),
                keyEquivalent: ""
            )
            chooseOther.target = self
            recentMenu.addItem(chooseOther)
        }
    }

    private func updatePocketbookUI() {
        pocketbookShortcutItem?.title = "Shortcut: \(pocketbook.shortcutDescription)…"
    }

    private func updateTerminalUI() {
        terminalShortcutItem?.title = "Shortcut: \(terminal.shortcutDescription)…"
    }

    @objc private func clearShelf() {
        coordinator.clearShelf()
    }

    @objc private func selectDropOpener(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        coordinator.setDefaultDropOpener(id: id)
    }

    @objc private func chooseCustomDropApp() {
        coordinator.chooseCustomDropApp()
    }

    @objc private func openRecentWithOpener(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        performRecentOpen(usingTemporaryOpenerID: id)
    }

    @objc private func chooseOtherAppForRecent() {
        let picker = NSOpenPanel()
        picker.title = "Open Recent With"
        picker.message = "Choose an application for this open only. Your default Drop Zone app will not change."
        picker.prompt = "Open"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [.application]
        picker.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        NSApp.activate(ignoringOtherApps: true)
        guard picker.runModal() == .OK, let appURL = picker.url else { return }

        let defaults = UserDefaults.standard
        let previousDefault = defaults.string(forKey: Self.defaultOpenerDefaultsKey)
        let previousCustomPath = defaults.string(forKey: Self.customOpenerPathDefaultsKey)

        defaults.set(appURL.path, forKey: Self.customOpenerPathDefaultsKey)
        defaults.set("custom", forKey: Self.defaultOpenerDefaultsKey)

        coordinator.openRecentWithDefaultApp()

        restoreDefaults(
            previousDefault: previousDefault,
            previousCustomPath: previousCustomPath
        )
        updateDropOpenerUI()
    }

    private func performRecentOpen(usingTemporaryOpenerID id: String) {
        let defaults = UserDefaults.standard
        let previousDefault = defaults.string(forKey: Self.defaultOpenerDefaultsKey)

        defaults.set(id, forKey: Self.defaultOpenerDefaultsKey)
        coordinator.openRecentWithDefaultApp()

        if let previousDefault = previousDefault {
            defaults.set(previousDefault, forKey: Self.defaultOpenerDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultOpenerDefaultsKey)
        }

        updateDropOpenerUI()
    }

    private func restoreDefaults(previousDefault: String?, previousCustomPath: String?) {
        let defaults = UserDefaults.standard

        if let previousDefault = previousDefault {
            defaults.set(previousDefault, forKey: Self.defaultOpenerDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultOpenerDefaultsKey)
        }

        if let previousCustomPath = previousCustomPath {
            defaults.set(previousCustomPath, forKey: Self.customOpenerPathDefaultsKey)
        } else {
            defaults.removeObject(forKey: Self.customOpenerPathDefaultsKey)
        }
    }

    @objc private func clearRecentProject() {
        coordinator.clearRecentProject()
    }

    @objc private func openPocketbookAction() {
        terminal.hide()
        pocketbook.toggle()
    }

    @objc private func openPocketbookSettings() {
        terminal.hide()
        pocketbook.showSettings()
    }

    @objc private func configurePocketbookShortcut() {
        pocketbook.showShortcutRecorder()
        updatePocketbookUI()
    }

    @objc private func openTerminalAction() {
        terminal.toggle()
    }

    @objc private func restartTerminalAction() {
        terminal.restartShell()
    }

    @objc private func configureTerminalShortcut() {
        terminal.showShortcutRecorder()
        updateTerminalUI()
    }
}

// MARK: - Native Notch Terminal

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

        // Shift-only global shortcuts steal normal capital-letter typing. Require at
        // least one non-Shift modifier; Shift is still valid as an extra modifier.
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
        return modifiers == UInt32(cmdKey)
            && (keyCode == UInt32(kVK_ANSI_X) || keyCode == UInt32(kVK_ANSI_V))
    }
}

// Streaming line renderer: control sequences may span PTY reads.
private final class NotchTerminalSanitizer {
    var onCompletion: ((String, Int32) -> Void)?
    private var state = 0
    private var sequence = ""
    private var lines: [[NSAttributedString]] = [[]]
    private var column = 0
    private var foreground = NSColor.white.withAlphaComponent(0.86)
    private var bold = false
    private var dim = false
    private var underline = false

    func reset() {
        state = 0; sequence = ""; lines = [[]]; column = 0
        foreground = NSColor.white.withAlphaComponent(0.86)
        bold = false; dim = false; underline = false
    }

    func clearScreen() {
        lines = [[]]
        column = 0
    }

    var rendered: NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for (index, line) in lines.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            for cell in line { result.append(cell) }
        }
        return result
    }

    func consume(_ value: String) {
        for scalar in value.unicodeScalars {
            switch state {
            case 1:
                sequence = ""
                state = scalar.value == 91 ? 2 : (scalar.value == 93 ? 3 : 0)
            case 2:
                if (64...126).contains(scalar.value) {
                    csi(String(scalar)); state = 0
                } else { sequence.unicodeScalars.append(scalar) }
            case 3:
                if scalar.value == 7 { osc(); state = 0 }
                else if scalar.value == 27 { state = 4 }
                else { sequence.unicodeScalars.append(scalar) }
            case 4:
                if scalar.value == 92 { osc(); state = 0 } else { state = 3 }
            default:
                switch scalar.value {
                case 27: state = 1
                case 13: column = 0
                case 8: column = max(0, column - 1)
                case 10:
                    lines.append([]); column = 0
                    if lines.count > 2000 { lines.removeFirst(lines.count - 2000) }
                case 9:
                    for _ in 0..<(8 - column % 8) { write(" ") }
                case 0...31, 127: break
                default: write(String(scalar))
                }
            }
        }
    }

    private func write(_ text: String) {
        var attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: dim ? foreground.withAlphaComponent(0.5) : foreground,
            .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: bold ? .bold : .regular)
        ]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        let cell = NSAttributedString(string: text, attributes: attributes)
        let row = lines.count - 1
        while lines[row].count < column { lines[row].append(NSAttributedString(string: " ")) }
        if column < lines[row].count { lines[row][column] = cell } else { lines[row].append(cell) }
        column += 1
    }

    private func osc() {
        let pieces = sequence.split(separator: ";")
        if pieces.count == 4, pieces[0] == "777", pieces[1] == "notchshelf",
           let status = Int32(pieces[3]) { onCompletion?(String(pieces[2]), status) }
    }

    private func csi(_ final: String) {
        let values = sequence.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        let first = values.first ?? 0
        switch final {
        case "D": column = max(0, column - max(1, first))
        case "C": column = min(10000, column + max(1, first))
        case "G": column = max(0, min(10000, first - 1))
        case "J":
            if first == 2 || first == 3 { lines = [[]]; column = 0 }
        case "K":
            let row = lines.count - 1
            if first == 2 { lines[row] = [] }
            else if first == 1 {
                for index in 0..<min(column + 1, lines[row].count) { lines[row][index] = NSAttributedString(string: " ") }
            } else if column < lines[row].count { lines[row].removeSubrange(column...) }
        case "m":
            var i = 0
            while i < values.count {
                let v = values[i]
                switch v {
                case 0: foreground = NSColor.white.withAlphaComponent(0.86); bold = false; dim = false; underline = false
                case 1: bold = true
                case 2: dim = true
                case 4: underline = true
                case 22: bold = false; dim = false
                case 24: underline = false
                case 39: foreground = NSColor.white.withAlphaComponent(0.86)
                case 30...37: foreground = color(v - 30)
                case 90...97: foreground = color(v - 90 + 8)
                case 38:
                    if i + 2 < values.count, values[i + 1] == 5 { foreground = color(values[i + 2]); i += 2 }
                    else if i + 4 < values.count, values[i + 1] == 2 {
                        foreground = NSColor(srgbRed: CGFloat(max(0, min(255, values[i + 2]))) / 255,
                            green: CGFloat(max(0, min(255, values[i + 3]))) / 255,
                            blue: CGFloat(max(0, min(255, values[i + 4]))) / 255, alpha: 1); i += 4
                    }
                default: break
                }
                i += 1
            }
        default: break
        }
    }

    private func color(_ index: Int) -> NSColor {
        let palette: [UInt32] = [0x202020,0xcd3131,0x0dbc79,0xe5e510,0x2472c8,0xbc3fbc,0x11a8cd,0xe5e5e5,
            0x666666,0xf14c4c,0x23d18b,0xf5f543,0x3b8eea,0xd670d6,0x29b8db,0xffffff]
        let rgb: UInt32
        if index < 16 { rgb = palette[max(0, index)] }
        else if index < 232 {
            let n = index - 16; let levels: [UInt32] = [0,95,135,175,215,255]
            rgb = levels[n / 36] << 16 | levels[n / 6 % 6] << 8 | levels[n % 6]
        } else { let level = UInt32(min(255, 8 + max(0, index - 232) * 10)); rgb = level << 16 | level << 8 | level }
        return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255,
            blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

private final class NotchTerminalShell {
    var onOutput: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?

    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var configurationDirectory: URL?

    var isRunning: Bool {
        return process?.isRunning == true
    }

    func start(at directory: URL) throws {
        stop()

        let process = Process()
        let input = Pipe()
        let output = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        process.arguments = [
            "-q",
            "/dev/null",
            "/bin/sh",
            "-c",
            "stty rows 30 cols 100 -echo; exec /bin/zsh -l"
        ]
        process.currentDirectoryURL = directory

        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LINES"] = "30"
        environment["COLUMNS"] = "100"
        // This app already owns the PTY and input bar; Kiro must not replace it.
        environment["PROCESS_LAUNCHED_BY_Q"] = "1"
        environment["LC_CTYPE"] = environment["LC_CTYPE"] ?? "UTF-8"
        // Source the user's startup files, then install our hook before the first read.
        // A per-session ZDOTDIR keeps the user's configuration untouched.
        let original = environment["ZDOTDIR"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        let configuration = FileManager.default.temporaryDirectory.appendingPathComponent("notchshelf-zsh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: configuration, withIntermediateDirectories: true)
        configurationDirectory = configuration
        func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }
        for file in [".zshenv", ".zprofile", ".zshrc", ".zlogin"] {
            let source = URL(fileURLWithPath: original).appendingPathComponent(file).path
            var contents = "[[ -f " + quote(source) + " ]] && source " + quote(source) + "\n"
            contents += "export ZDOTDIR=" + quote(configuration.path) + "\n"
            if file == ".zlogin" {
                contents += """
                unsetopt zle
                stty rows 30 cols 100 -echo
                autoload -Uz add-zsh-hook
                function _notchshelf_done() {
                    local result=$?
                    if [[ -n ${_notchshelf_id-} ]]; then
                        printf '\\e]777;notchshelf;%s;%s\\a' "$_notchshelf_id" "$result"
                        unset _notchshelf_id
                    fi
                    return $result
                }
                add-zsh-hook precmd _notchshelf_done
                printf '\\e]777;notchshelf;ready;0\\a'
                """
            }
            try contents.write(to: configuration.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        environment["ZDOTDIR"] = configuration.path
        process.environment = environment

        process.standardInput = input
        process.standardOutput = output
        process.standardError = output

        let outputCallback = onOutput
        let exitCallback = onExit
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            outputCallback?(String(decoding: data, as: UTF8.self))
        }

        process.terminationHandler = { process in
            output.fileHandleForReading.readabilityHandler = nil
            exitCallback?(process.terminationStatus)
        }

        try process.run()
        self.process = process
        inputPipe = input
        outputPipe = output
    }

    func sendLine(_ value: String) {
        guard isRunning,
              let data = (value + "\n").data(using: .utf8) else { return }
        inputPipe?.fileHandleForWriting.write(data)
    }

    func interrupt() {
        guard isRunning else { return }
        inputPipe?.fileHandleForWriting.write(Data([0x03]))
    }

    func stop() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        if let process = process, process.isRunning {
            if let data = "exit\n".data(using: .utf8) {
                inputPipe?.fileHandleForWriting.write(data)
            }
            process.terminate()
        }
        process = nil
        inputPipe = nil
        outputPipe = nil
        if let directory = configurationDirectory { try? FileManager.default.removeItem(at: directory) }
        configurationDirectory = nil
    }
}

@MainActor
final class NotchTerminalModel: ObservableObject {
    @Published var transcript = ""
    @Published var styledTranscript = AttributedString("")
    @Published var command = ""
    @Published var sessionAlive = false
    @Published var presented = false
    @Published var directoryLabel = "~"

    private let shell = NotchTerminalShell()
    private let sanitizer = NotchTerminalSanitizer()
    private let workingDirectoryProvider: () -> URL?
    private var sessionID = UUID()
    private var shellReady = false
    private var pendingInput: [String] = []
    private var history: [String] = []
    private var historyIndex: Int?

    init(workingDirectoryProvider: @escaping () -> URL?) {
        self.workingDirectoryProvider = workingDirectoryProvider
        sanitizer.onCompletion = { [weak self] id, status in
            guard let self = self else { return }
            if id == "ready" {
                self.shellReady = true
                let input = self.pendingInput
                self.pendingInput.removeAll()
                for line in input { self.shell.sendLine(line) }
            } else {
                NotchTerminalActivityController.shared.finish(id: id, status: status)
            }
        }
    }

    private func connectSession(id: UUID) {
        shell.onOutput = { [weak self] value in
            DispatchQueue.main.async {
                guard let self = self, self.sessionID == id else { return }
                self.appendOutput(value)
            }
        }
        shell.onExit = { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self, self.sessionID == id else { return }
                self.sessionAlive = false
                self.shellReady = false
                self.pendingInput.removeAll()
                NotchTerminalActivityController.shared.finishSession(status: status)
                self.appendPlain("\n[session ended: \(status)]\n")
            }
        }
    }

    func ensureSession() {
        guard !shell.isRunning else {
            sessionAlive = true
            return
        }

        sessionID = UUID()
        shellReady = false
        pendingInput.removeAll()
        connectSession(id: sessionID)
        let directory = initialDirectory()
        directoryLabel = displayDirectory(directory)
        sanitizer.reset()

        do {
            try shell.start(at: directory)
            sessionAlive = true
            appendPlain("Notch Terminal • zsh\n")
        } catch {
            sessionAlive = false
            appendPlain("Unable to start zsh: \(error.localizedDescription)\n")
        }
    }

    func restart() {
        shell.stop()
        sanitizer.reset()
        transcript = ""
        styledTranscript = AttributedString("")
        NotchTerminalActivityController.shared.finishSession(status: 130)
        sessionAlive = false
        historyIndex = nil
        ensureSession()
    }

    func stop() {
        sessionID = UUID()
        shellReady = false
        pendingInput.removeAll()
        shell.stop()
        sessionAlive = false
    }

    func submit() {
        let value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        historyIndex = nil
        command = ""

        // Input entered while a command is already running may be a password or an
        // interactive prompt response. Send it to the PTY, but never persist it in history.
        if NotchTerminalActivityController.shared.isRunning {
            sendInput(value)
            return
        }

        if history.last != value {
            history.append(value)
            if history.count > 200 { history.removeFirst(history.count - 200) }
        }

        ensureSession()
        guard sessionAlive else { return }
        let id = UUID().uuidString
        NotchTerminalActivityController.shared.begin(id: id, command: value)
        // Single-quote shell data, never interpolate command text as shell syntax.
        let quoted = "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        appendPlain("\n› " + value + "\n")
        sendInput("_notchshelf_id='" + id + "'; eval -- " + quoted + "; _notchshelf_done")
    }

    private func sendInput(_ line: String) {
        if shellReady { shell.sendLine(line) }
        else { pendingInput.append(line) }
    }

    func interrupt() {
        if !shellReady, !pendingInput.isEmpty {
            pendingInput.removeAll()
            NotchTerminalActivityController.shared.finishSession(status: 130)
            return
        }
        shell.interrupt()
    }

    func clear() {
        sanitizer.clearScreen()
        transcript = ""
        styledTranscript = AttributedString("")
    }

    func historyPrevious() {
        guard !history.isEmpty else { return }
        let next: Int
        if let historyIndex = historyIndex {
            next = max(0, historyIndex - 1)
        } else {
            next = history.count - 1
        }
        historyIndex = next
        command = history[next]
    }

    func historyNext() {
        guard let historyIndex = historyIndex else { return }
        let next = historyIndex + 1
        if next >= history.count {
            self.historyIndex = nil
            command = ""
        } else {
            self.historyIndex = next
            command = history[next]
        }
    }

    private func appendOutput(_ raw: String) {
        sanitizer.consume(raw)
        publishTranscript()
    }

    private func appendPlain(_ value: String) {
        sanitizer.consume(value)
        publishTranscript()
    }

    private func publishTranscript() {
        let rendered = sanitizer.rendered
        transcript = rendered.string
        styledTranscript = AttributedString(rendered)
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
}

private struct NotchTerminalMetrics {
    let wingWidth: CGFloat
    let depth: CGFloat
    let maxDepth: CGFloat
    let contentWidth: CGFloat
    let windowSize: CGSize

    init(geometry: NotchGeometry, screen: NSScreen) {
        let availableHalfWidth = max(160, (screen.frame.width - geometry.hardwareWidth - 48) / 2)
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
final class NotchTerminalFeature {
    private static let keyCodeKey = "NotchShelf.Terminal.keyCode"
    private static let modifiersKey = "NotchShelf.Terminal.modifiers"
    private static let labelKey = "NotchShelf.Terminal.keyLabel"
    private let signature: OSType = 0x4E535454 // NSTT

    private let model: NotchTerminalModel
    private let beforeShow: () -> Void
    private var shortcut: NotchTerminalShortcut
    private var hotKey: EventHotKeyRef?
    private var panel: NotchTerminalPanel?
    private var keyMonitor: Any?
    private var started = false
    private var requestedVisible = false
    private var pendingDismissal: DispatchWorkItem?

    var onShortcutChanged: (() -> Void)?
    var shortcutDescription: String { return shortcut.displayString }
    var isVisible: Bool { return requestedVisible && panel?.isVisible == true }

    init(
        workingDirectoryProvider: @escaping () -> URL?,
        beforeShow: @escaping () -> Void = {}
    ) {
        model = NotchTerminalModel(workingDirectoryProvider: workingDirectoryProvider)
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
        let handlerStatus = CarbonHotKeyCenter.shared.setHandler(signature: signature, id: 1) { [weak self] in
            guard let self = self else { return OSStatus(eventNotHandledErr) }
            self.toggle()
            return noErr
        }
        guard handlerStatus == noErr else {
            NSLog("[NotchShelf] Terminal hotkey handler failed: %d", handlerStatus)
            return
        }

        started = true
        let registerStatus = registerShortcut()
        if registerStatus != noErr {
            CarbonHotKeyCenter.shared.removeHandler(signature: signature, id: 1)
            started = false
        }

        NSLog(registerStatus == noErr
            ? "[NotchShelf] Notch Terminal ready on \(shortcut.displayString)"
            : "[NotchShelf] Terminal shortcut unavailable: \(shortcut.displayString)")
    }

    func stop() {
        requestedVisible = false
        pendingDismissal?.cancel()
        pendingDismissal = nil
        removeKeyMonitor()
        model.presented = false
        model.stop()
        panel?.orderOut(nil)
        panel = nil

        if let hotKey = hotKey { UnregisterEventHotKey(hotKey) }
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
            return
        }

        guard let screen = NSScreen.screens.first(where: { NotchGeometry.measure($0) != nil }),
              let geometry = NotchGeometry.measure(screen) else {
            NSSound.beep()
            return
        }

        beforeShow()
        model.ensureSession()
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
                model: model,
                geometry: geometry,
                metrics: metrics,
                onClose: { [weak self] in self?.hide() }
            )
        }

        installKeyMonitor()
        panel?.ignoresMouseEvents = false
        panel?.makeKeyAndOrderFront(nil)
        panel?.contentView?.layoutSubtreeIfNeeded()
        panel?.displayIfNeeded()
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.requestedVisible else { return }
            self.model.presented = true
        }
    }

    func hide() {
        guard requestedVisible, let panel = panel, panel.isVisible else { return }
        requestedVisible = false
        removeKeyMonitor()
        panel.ignoresMouseEvents = true
        panel.makeFirstResponder(nil)
        panel.resignKey()
        model.presented = false
        pendingDismissal?.cancel()

        let work = DispatchWorkItem { [weak self, weak panel] in
            guard let self = self, !self.requestedVisible, self.panel === panel else { return }
            panel?.orderOut(nil)
            self.pendingDismissal = nil
        }
        pendingDismissal = work
        let delay = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.26
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func restartShell() {
        model.restart()
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

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self, self.isVisible else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if event.keyCode == UInt16(kVK_Escape) {
                self.hide()
                return nil
            }
            if flags.contains(.control), event.keyCode == UInt16(kVK_ANSI_C) {
                self.model.interrupt()
                return nil
            }
            if flags.contains(.command), event.keyCode == UInt16(kVK_ANSI_K) {
                self.model.clear()
                return nil
            }
            if event.keyCode == UInt16(kVK_UpArrow) {
                self.model.historyPrevious()
                return nil
            }
            if event.keyCode == UInt16(kVK_DownArrow) {
                self.model.historyNext()
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
private final class NotchTerminalPanel: NSPanel {
    override var canBecomeKey: Bool { return true }
    override var canBecomeMain: Bool { return false }

    init(
        frame: NSRect,
        model: NotchTerminalModel,
        geometry: NotchGeometry,
        metrics: NotchTerminalMetrics,
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

private struct NotchTerminalView: View {
    @ObservedObject var model: NotchTerminalModel
    let geometry: NotchGeometry
    let metrics: NotchTerminalMetrics
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var inputFocused: Bool
    @State private var shoulderExpansion: CGFloat = 0
    @State private var bridgeExpansion: CGFloat = 0
    @State private var contentVisible = false
    @State private var pendingMotion: [DispatchWorkItem] = []

    private var surface: PocketbookV3Wings {
        return PocketbookV3Wings(
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
                .allowsHitTesting(model.presented && contentVisible)
        }
        .frame(width: metrics.windowSize.width, height: metrics.windowSize.height, alignment: .top)
        .clipped()
        .opacity(reduceMotion && !model.presented ? 0 : 1)
        .onChange(of: model.presented) { visible in
            animatePresentation(visible)
        }
        .onChange(of: contentVisible) { visible in
            guard visible else {
                inputFocused = false
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                inputFocused = true
            }
        }
        .onDisappear {
            cancelMotion()
        }
    }

    private var content: some View {
        VStack(spacing: 8) {
            header
            transcript
            commandBar
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
                Text(model.directoryLabel)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Circle()
                .fill(model.sessionAlive ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.sessionAlive ? "zsh" : "offline")
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

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if model.transcript.isEmpty {
                        Text("Starting zsh…")
                            .foregroundStyle(Color.white.opacity(0.42))
                    } else {
                        Text(model.styledTranscript)
                            .textSelection(.enabled)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("terminal-bottom")
                }
                .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.transcript) { _ in
                withAnimation(.easeOut(duration: 0.08)) {
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(height: 0.5)
        }
    }

    private var commandBar: some View {
        HStack(spacing: 8) {
            Text("❯")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.green)

            TextField("", text: $model.command, prompt: Text("Type a command…"))
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.94))
                .focused($inputFocused)
                .onSubmit {
                    model.submit()
                    inputFocused = true
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(inputFocused ? 0.15 : 0.075), lineWidth: 0.75)
        )
    }

    private var footer: some View {
        HStack(spacing: 9) {
            Text("↑↓ History")
            Text("•")
            Text("⌃C Interrupt")
            Text("•")
            Text("⌘K Clear")
            Spacer()
            Text("Esc Close")
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
private final class NotchTerminalShortcutCaptureView: NSView {
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let hint = NSTextField(labelWithString: "Press a new shortcut")
    var captured: NotchTerminalShortcut?

    override var acceptsFirstResponder: Bool { return true }

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

    required init?(coder: NSCoder) { return nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
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