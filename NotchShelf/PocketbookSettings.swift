import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Settings

@MainActor
final class PocketbookV3SettingsWindowController: NSObject, NSWindowDelegate {
    private let configuration: PocketbookV3Configuration
    private let shortcutDescription: () -> String
    private let configureShortcut: () -> Void
    private let onChanged: () -> Void
    private var window: NSWindow?

    init(
        configuration: PocketbookV3Configuration,
        shortcutDescription: @escaping () -> String,
        configureShortcut: @escaping () -> Void,
        onChanged: @escaping () -> Void
    ) {
        self.configuration = configuration
        self.shortcutDescription = shortcutDescription
        self.configureShortcut = configureShortcut
        self.onChanged = onChanged
    }

    func show() {
        configuration.reloadCustom()

        if window == nil {
            let frame = NSRect(x: 0, y: 0, width: 520, height: 520)
            let window = NSWindow(
                contentRect: frame,
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "NotchShelf Settings"
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            window.contentView = NSHostingView(
                rootView: PocketbookV3SettingsView(
                    configuration: configuration,
                    shortcutDescription: shortcutDescription,
                    configureShortcut: configureShortcut,
                    onChanged: onChanged
                )
            )
            self.window = window
        }

        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PocketbookV3SettingsView: View {
    @ObservedObject var configuration: PocketbookV3Configuration
    let shortcutDescription: () -> String
    let configureShortcut: () -> Void
    let onChanged: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pocketbook")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Choose exactly which books appear when the notch Pocketbook opens.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                settingsCard(title: "Built-in Books") {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(configuration.builtinBooks) { book in
                            bookToggle(book)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                settingsCard(title: "Custom JSON") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(configuration.configURL.path)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)

                        if let error = configuration.customError {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.orange)
                        }

                        if configuration.customBooks.isEmpty {
                            Text(configuration.customFileExists
                                ? "No custom books found in the JSON file."
                                : "No custom config yet. Create one to add personal books or override built-in entries.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(configuration.customBooks) { book in
                                bookToggle(book)
                            }
                        }

                        HStack {
                            Button(configuration.customFileExists ? "Open Config" : "Create Config") {
                                configuration.openConfig()
                                onChanged()
                            }
                            Button("Reload") {
                                configuration.reloadCustom()
                                onChanged()
                            }
                        }
                    }
                }

                settingsCard(title: "Default Book") {
                    if configuration.enabledBooks.isEmpty {
                        Text("Enable at least one book. Until then Pocketbook opens with an empty state.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    } else {
                        Picker(
                            "Open on",
                            selection: Binding(
                                get: { configuration.resolvedDefaultBook?.id ?? "" },
                                set: {
                                    configuration.setDefaultBook($0)
                                    onChanged()
                                }
                            )
                        ) {
                            ForEach(configuration.enabledBooks) { book in
                                Text(book.title).tag(book.id)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                settingsCard(title: "Shortcut") {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Global Pocketbook Shortcut")
                                .font(.system(size: 12, weight: .medium))
                            Text(shortcutDescription())
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                        }
                        Spacer()
                        Button("Change…", action: configureShortcut)
                    }
                }
            }
            .padding(24)
        }
        .frame(minWidth: 500, minHeight: 500)
    }

    @ViewBuilder
    private func settingsCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private func bookToggle(_ book: PocketbookV3Book) -> some View {
        HStack(spacing: 10) {
            Image(systemName: book.icon)
                .frame(width: 24, alignment: .center)

            VStack(alignment: .leading, spacing: 1) {
                Text(book.title)
                    .font(.system(size: 12, weight: .medium))
                Text(book.isBuiltin ? "Built in" : "Custom JSON")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 16)

            Toggle(
                "",
                isOn: Binding(
                    get: { configuration.isEnabled(book.id) },
                    set: {
                        configuration.setEnabled(book.id, enabled: $0)
                        onChanged()
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
    }
}

// MARK: - Shortcut recorder

@MainActor
final class PocketbookV3ShortcutCaptureView: NSView {
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
