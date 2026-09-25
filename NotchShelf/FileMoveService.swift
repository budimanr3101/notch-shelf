import Foundation

struct FileMoveBatchResult {
    let moved: [URL]
    let remaining: [URL]
    let errorMessage: String?
}

final class FileMoveService {
    func move(
        _ items: [URL],
        to destinationFolder: URL,
        completion: @escaping @MainActor (FileMoveBatchResult) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = FileManager.default

            // Preflight all destination conflicts before moving anything.
            for source in items {
                let target = destinationFolder.appendingPathComponent(source.lastPathComponent)
                if source.standardizedFileURL == target.standardizedFileURL {
                    let result = FileMoveBatchResult(
                        moved: [],
                        remaining: items,
                        errorMessage: "\(source.lastPathComponent) is already in this folder."
                    )
                    DispatchQueue.main.async { completion(result) }
                    return
                }
                if manager.fileExists(atPath: target.path) {
                    let result = FileMoveBatchResult(
                        moved: [],
                        remaining: items,
                        errorMessage: "\(source.lastPathComponent) already exists in the destination."
                    )
                    DispatchQueue.main.async { completion(result) }
                    return
                }
            }

            var moved: [URL] = []
            var remaining = items

            for source in items {
                let target = destinationFolder.appendingPathComponent(source.lastPathComponent)
                do {
                    try self.moveOne(source, to: target, fileManager: manager)
                    moved.append(source)
                    remaining.removeAll { $0.standardizedFileURL == source.standardizedFileURL }
                } catch {
                    let result = FileMoveBatchResult(
                        moved: moved,
                        remaining: remaining,
                        errorMessage: error.localizedDescription
                    )
                    DispatchQueue.main.async { completion(result) }
                    return
                }
            }

            let result = FileMoveBatchResult(moved: moved, remaining: [], errorMessage: nil)
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func moveOne(_ source: URL, to target: URL, fileManager: FileManager) throws {
        do {
            try fileManager.moveItem(at: source, to: target)
        } catch {
            // Cross-volume moves can fail as a rename. Copy first, then delete source only after copy succeeds.
            do {
                try fileManager.copyItem(at: source, to: target)
            } catch {
                // copyItem can leave a partial destination for folders; clean it before returning failure.
                try? fileManager.removeItem(at: target)
                throw error
            }

            do {
                try fileManager.removeItem(at: source)
            } catch {
                // Don't leave an accidental duplicate if deleting the source failed.
                try? fileManager.removeItem(at: target)
                throw error
            }
        }
    }
}
