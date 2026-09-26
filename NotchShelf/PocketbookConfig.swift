import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Custom JSON

struct PocketbookJSONRoot: Decodable {
    let books: [PocketbookJSONBook]?
    let extensions: [String: [PocketbookJSONEntry]]?
}

struct PocketbookJSONBook: Decodable {
    let id: String
    let title: String
    let icon: String?
    let entries: [PocketbookJSONEntry]
}

struct PocketbookJSONEntry: Decodable {
    let id: String
    let title: String?
    let subtitle: String?
    let category: String?
    let tags: [String]?
    let type: String?
    let language: String?
    let content: String?
    let disabled: Bool?
}

@MainActor
final class PocketbookV3Configuration: ObservableObject {
    static let shared = PocketbookV3Configuration()

    private static let enabledKey = "NotchShelf.Pocketbook.enabledBooks"
    private static let defaultKey = "NotchShelf.Pocketbook.defaultBook"

    @Published private(set) var enabledBookIDs: Set<String>
    @Published private(set) var customBooks: [PocketbookV3Book] = []
    @Published private(set) var customError: String?
    @Published private(set) var customFileExists = false
    @Published private(set) var defaultBookID: String?

    private var customEntriesByBook: [String: [PocketbookV3Entry]] = [:]
    private var builtinExtensions: [String: [PocketbookJSONEntry]] = [:]

    private init() {
        let defaults = UserDefaults.standard
        let saved = defaults.stringArray(forKey: Self.enabledKey) ?? []
        enabledBookIDs = Set(saved)
        defaultBookID = defaults.string(forKey: Self.defaultKey)
        reloadCustom()
        normalizeDefault()
    }

    var configURL: URL {
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("notchshelf", isDirectory: true)
            .appendingPathComponent("pocketbook.json", isDirectory: false)
    }

    var builtinBooks: [PocketbookV3Book] {
        return PocketbookV3BuiltinLibrary.books
    }

    var allBooks: [PocketbookV3Book] {
        return builtinBooks + customBooks
    }

    var enabledBooks: [PocketbookV3Book] {
        return allBooks.filter { enabledBookIDs.contains($0.id) }
    }

    var resolvedDefaultBook: PocketbookV3Book? {
        let enabled = enabledBooks
        guard !enabled.isEmpty else { return nil }
        if let id = defaultBookID,
           let match = enabled.first(where: { $0.id == id }) {
            return match
        }
        return enabled.first
    }

    func isEnabled(_ id: String) -> Bool {
        return enabledBookIDs.contains(id)
    }

    func setEnabled(_ id: String, enabled: Bool) {
        if enabled {
            enabledBookIDs.insert(id)
        } else {
            enabledBookIDs.remove(id)
        }
        persistEnabled()
        normalizeDefault()
        objectWillChange.send()
    }

    func setDefaultBook(_ id: String?) {
        guard let id = id else {
            defaultBookID = nil
            UserDefaults.standard.removeObject(forKey: Self.defaultKey)
            objectWillChange.send()
            return
        }
        guard enabledBookIDs.contains(id) else { return }
        defaultBookID = id
        UserDefaults.standard.set(id, forKey: Self.defaultKey)
        objectWillChange.send()
    }

    func entries(for bookID: String) -> [PocketbookV3Entry] {
        if let custom = customEntriesByBook[bookID] {
            return custom
        }

        var entries = PocketbookV3BuiltinLibrary.entries(for: bookID)
        guard let overlays = builtinExtensions[bookID], !overlays.isEmpty else {
            return entries
        }

        var order = entries.map { $0.id }
        var byID: [String: PocketbookV3Entry] = [:]
        for entry in entries { byID[entry.id] = entry }

        for payload in overlays {
            if payload.disabled == true {
                byID.removeValue(forKey: payload.id)
                order.removeAll(where: { $0 == payload.id })
                continue
            }

            let previous = byID[payload.id]
            guard let mapped = map(
                payload,
                bookID: bookID,
                fallback: previous
            ) else { continue }

            if previous == nil { order.append(mapped.id) }
            byID[mapped.id] = mapped
        }

        return order.compactMap { byID[$0] }
    }

    func reloadCustom() {
        let url = configURL
        customFileExists = FileManager.default.fileExists(atPath: url.path)
        customBooks = []
        customEntriesByBook = [:]
        builtinExtensions = [:]
        customError = nil

        guard customFileExists else {
            pruneMissingCustomBookSettings()
            return
        }

        do {
            let data = try Data(contentsOf: url)
            let root = try JSONDecoder().decode(PocketbookJSONRoot.self, from: data)

            builtinExtensions = root.extensions ?? [:]
            let reserved = Set(PocketbookV3BuiltinLibrary.books.map { $0.id })
            var seen: Set<String> = []

            for payload in root.books ?? [] {
                let id = payload.id.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, !reserved.contains(id), !seen.contains(id) else { continue }
                seen.insert(id)

                let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let book = PocketbookV3Book(
                    id: id,
                    title: title.isEmpty ? id : title,
                    icon: payload.icon?.isEmpty == false ? payload.icon! : "note.text",
                    searchPlaceholder: "Search \(title.isEmpty ? id : title)…",
                    isBuiltin: false
                )
                customBooks.append(book)
                customEntriesByBook[id] = payload.entries.compactMap {
                    map($0, bookID: id, fallback: nil)
                }
            }

            pruneMissingCustomBookSettings()
            normalizeDefault()
            NSLog("[NotchShelf] Pocketbook custom config loaded: %d custom book(s)", customBooks.count)
        } catch {
            customError = error.localizedDescription
            NSLog("[NotchShelf] Pocketbook custom config error: %@", error.localizedDescription)
            pruneMissingCustomBookSettings()
            normalizeDefault()
        }
    }

    @discardableResult
    func ensureExampleConfig() -> Bool {
        if FileManager.default.fileExists(atPath: configURL.path) {
            customFileExists = true
            return true
        }

        let directory = configURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )
            try Self.exampleJSON.write(
                to: configURL,
                atomically: true,
                encoding: .utf8
            )
            reloadCustom()
            return true
        } catch {
            customError = error.localizedDescription
            NSSound.beep()
            return false
        }
    }

    func openConfig() {
        guard ensureExampleConfig() else { return }
        if !NSWorkspace.shared.open(configURL) {
            NSSound.beep()
        }
    }

    private func persistEnabled() {
        let order = allBooks.map { $0.id }
        let known = order.filter { enabledBookIDs.contains($0) }
        let unknown = enabledBookIDs.subtracting(Set(order)).sorted()
        UserDefaults.standard.set(known + unknown, forKey: Self.enabledKey)
    }

    private func normalizeDefault() {
        let enabled = enabledBooks
        if let id = defaultBookID, enabled.contains(where: { $0.id == id }) {
            return
        }

        defaultBookID = enabled.first?.id
        if let id = defaultBookID {
            UserDefaults.standard.set(id, forKey: Self.defaultKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.defaultKey)
        }
    }

    private func pruneMissingCustomBookSettings() {
        let builtin = Set(PocketbookV3BuiltinLibrary.books.map { $0.id })
        let custom = Set(customBooks.map { $0.id })
        let valid = builtin.union(custom)
        enabledBookIDs = enabledBookIDs.intersection(valid)
        persistEnabled()
    }

    private func map(
        _ payload: PocketbookJSONEntry,
        bookID: String,
        fallback: PocketbookV3Entry?
    ) -> PocketbookV3Entry? {
        let id = payload.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        if payload.disabled == true { return nil }

        let title = payload.title ?? fallback?.title
        let content = payload.content ?? fallback?.content
        guard let resolvedTitle = title, !resolvedTitle.isEmpty,
              let resolvedContent = content else { return nil }

        let rawType = payload.type ?? fallback?.type.rawValue ?? "code"
        let type = PocketbookV3ContentType(rawValue: rawType) ?? .code
        let tags = payload.tags?.joined(separator: " ") ?? fallback?.keywords ?? ""

        return PocketbookV3Entry(
            id: id,
            bookID: bookID,
            category: payload.category ?? fallback?.category ?? "Notes",
            title: resolvedTitle,
            subtitle: payload.subtitle ?? fallback?.subtitle ?? "",
            keywords: tags,
            content: resolvedContent,
            type: type,
            language: payload.language ?? fallback?.language
        )
    }

    private static let exampleJSON = """
{
  "books": [
    {
      "id": "my-notes",
      "title": "My Notes",
      "icon": "note.text",
      "entries": [
        {
          "id": "prod-checklist",
          "title": "Production Checklist",
          "subtitle": "Before touching production",
          "category": "Checklist",
          "tags": ["prod", "change", "checklist"],
          "type": "checklist",
          "content": "1. Verify account and context\\n2. Confirm namespace / region\\n3. Confirm change window\\n4. Keep a rollback command ready"
        },
        {
          "id": "my-eks-login",
          "title": "My EKS Login",
          "subtitle": "Personal kubeconfig template",
          "category": "AWS",
          "tags": ["eks", "kubeconfig"],
          "type": "code",
          "language": "bash",
          "content": "aws eks update-kubeconfig --name <cluster> --region <region> --profile <profile>"
        }
      ]
    }
  ],
  "extensions": {
    "kubernetes": [
      {
        "id": "deployment",
        "subtitle": "Override any built-in entry by reusing its id",
        "tags": ["deployment", "my-template"]
      }
    ],
    "aws": [
      {
        "id": "my-account-check",
        "title": "My Account Check",
        "subtitle": "Custom entry added to the AWS book",
        "category": "CLI",
        "tags": ["account", "sts"],
        "type": "code",
        "language": "bash",
        "content": "aws sts get-caller-identity --profile <profile>"
      }
    ]
  }
}
"""
}

// MARK: - Pocketbook model

@MainActor
final class PocketbookV3Model: ObservableObject {
    @Published var presented = false
    @Published var books: [PocketbookV3Book] = []
    @Published var bookID: String?
    @Published var query = ""
    @Published var category = "All"
    @Published var selectedID: String?
    @Published var copiedID: String?

    private let configuration: PocketbookV3Configuration

    init(configuration: PocketbookV3Configuration) {
        self.configuration = configuration
        reloadConfiguration(preferDefault: true)
    }

    var currentBook: PocketbookV3Book? {
        guard let bookID = bookID else { return nil }
        return books.first(where: { $0.id == bookID })
    }

    var entries: [PocketbookV3Entry] {
        guard let bookID = bookID else { return [] }
        return configuration.entries(for: bookID)
    }

    var categories: [String] {
        var result = ["All"]
        for entry in entries where !entry.category.isEmpty {
            if !result.contains(entry.category) { result.append(entry.category) }
        }
        return result
    }

    var selected: PocketbookV3Entry? {
        guard let selectedID = selectedID else { return nil }
        return entries.first(where: { $0.id == selectedID })
    }

    var results: [PocketbookV3Entry] {
        let source = category == "All"
            ? entries
            : entries.filter { $0.category == category }

        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return source }

        return source.filter {
            $0.title.localizedCaseInsensitiveContains(value)
                || $0.subtitle.localizedCaseInsensitiveContains(value)
                || $0.keywords.localizedCaseInsensitiveContains(value)
                || $0.category.localizedCaseInsensitiveContains(value)
                || $0.content.localizedCaseInsensitiveContains(value)
        }
    }

    func reloadConfiguration(preferDefault: Bool) {
        let previous = bookID
        books = configuration.enabledBooks

        let next: String?
        if preferDefault {
            next = configuration.resolvedDefaultBook?.id
        } else if let previous = previous,
                  books.contains(where: { $0.id == previous }) {
            next = previous
        } else {
            next = configuration.resolvedDefaultBook?.id
        }

        bookID = next
        query = ""
        category = "All"
        selectedID = nil
        copiedID = nil
    }

    func resetForPresentation() {
        reloadConfiguration(preferDefault: true)
    }

    func switchBook(to id: String) {
        guard id != bookID,
              books.contains(where: { $0.id == id }) else { return }
        bookID = id
        query = ""
        category = "All"
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
