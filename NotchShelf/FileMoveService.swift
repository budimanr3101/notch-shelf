import Darwin
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
            let destination = destinationFolder.resolvingSymlinksInPath().standardizedFileURL

            // Preflight the entire batch before moving anything. A failure here must leave
            // every source untouched.
            var targetNames = Set<String>()
            for source in items {
                let normalizedSource = source.resolvingSymlinksInPath().standardizedFileURL
                let target = destination.appendingPathComponent(source.lastPathComponent)
                    .standardizedFileURL
                let collisionKey = source.lastPathComponent.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                )

                guard targetNames.insert(collisionKey).inserted else {
                    self.complete(
                        moved: [],
                        remaining: items,
                        errorMessage: "Two staged items would create the same destination name: \(source.lastPathComponent).",
                        completion: completion
                    )
                    return
                }

                if normalizedSource == target.resolvingSymlinksInPath().standardizedFileURL {
                    self.complete(
                        moved: [],
                        remaining: items,
                        errorMessage: "\(source.lastPathComponent) is already in this folder.",
                        completion: completion
                    )
                    return
                }

                var isDirectory: ObjCBool = false
                if manager.fileExists(atPath: normalizedSource.path, isDirectory: &isDirectory),
                   isDirectory.boolValue,
                   self.isDescendant(destination, of: normalizedSource) {
                    self.complete(
                        moved: [],
                        remaining: items,
                        errorMessage: "A folder cannot be moved into one of its own subfolders: \(source.lastPathComponent).",
                        completion: completion
                    )
                    return
                }

                if manager.fileExists(atPath: target.path) {
                    self.complete(
                        moved: [],
                        remaining: items,
                        errorMessage: "\(source.lastPathComponent) already exists in the destination.",
                        completion: completion
                    )
                    return
                }
            }

            var moved: [URL] = []
            var remaining = items

            for source in items {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                    .standardizedFileURL
                do {
                    try self.moveOne(source, to: target, fileManager: manager)
                    moved.append(source)
                    remaining.removeAll {
                        $0.resolvingSymlinksInPath().standardizedFileURL
                            == source.resolvingSymlinksInPath().standardizedFileURL
                    }
                } catch {
                    self.complete(
                        moved: moved,
                        remaining: remaining,
                        errorMessage: error.localizedDescription,
                        completion: completion
                    )
                    return
                }
            }

            self.complete(moved: moved, remaining: [], errorMessage: nil, completion: completion)
        }
    }

    private func moveOne(_ source: URL, to target: URL, fileManager: FileManager) throws {
        do {
            try fileManager.moveItem(at: source, to: target)
            return
        } catch {
            guard isCrossDeviceError(error) else {
                throw error
            }
        }

        // Cross-volume fallback: copy to a unique temporary sibling first. Never copy
        // directly to the final target and never delete a path we did not create.
        let temporaryTarget = target.deletingLastPathComponent().appendingPathComponent(
            ".notchshelf-move-\(UUID().uuidString)-\(target.lastPathComponent)"
        )

        do {
            try fileManager.copyItem(at: source, to: temporaryTarget)
        } catch {
            try? fileManager.removeItem(at: temporaryTarget)
            throw error
        }

        do {
            guard !fileManager.fileExists(atPath: target.path) else {
                throw FileMoveSafetyError.destinationAppeared(target.lastPathComponent)
            }
            try fileManager.moveItem(at: temporaryTarget, to: target)
        } catch {
            try? fileManager.removeItem(at: temporaryTarget)
            throw error
        }

        do {
            try fileManager.removeItem(at: source)
        } catch {
            // Keep the verified destination copy. Duplication is safer than deleting the
            // only good copy if source cleanup fails or is only partially successful.
            throw FileMoveSafetyError.sourceCleanupFailed(
                source.lastPathComponent,
                underlying: error
            )
        }
    }

    private func isCrossDeviceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(EXDEV) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isCrossDeviceError(underlying)
        }
        return false
    }

    private func isDescendant(_ candidate: URL, of ancestor: URL) -> Bool {
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        let ancestorPath = ancestor.resolvingSymlinksInPath().standardizedFileURL.path
        return candidatePath.hasPrefix(ancestorPath + "/")
    }

    private func complete(
        moved: [URL],
        remaining: [URL],
        errorMessage: String?,
        completion: @escaping @MainActor (FileMoveBatchResult) -> Void
    ) {
        let result = FileMoveBatchResult(
            moved: moved,
            remaining: remaining,
            errorMessage: errorMessage
        )
        DispatchQueue.main.async { completion(result) }
    }
}

private enum FileMoveSafetyError: LocalizedError {
    case destinationAppeared(String)
    case sourceCleanupFailed(String, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .destinationAppeared(let name):
            return "\(name) appeared in the destination while the move was in progress. No existing destination file was removed."
        case .sourceCleanupFailed(let name, let underlying):
            return "\(name) was copied to the destination, but the original could not be removed. The destination copy was kept for safety. \(underlying.localizedDescription)"
        }
    }
}