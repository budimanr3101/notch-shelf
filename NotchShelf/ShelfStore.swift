import Foundation

final class ShelfStore {
    private(set) var items: [URL] = []

    var isEmpty: Bool { items.isEmpty }
    var count: Int { items.count }

    func stage(_ urls: [URL]) {
        items = urls
    }

    func clear() {
        items.removeAll()
    }

    func replace(with urls: [URL]) {
        items = urls
    }
}
