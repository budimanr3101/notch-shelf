import AppKit
import Foundation

struct FinderBridgeError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

final class FinderBridge {
    private let finderBundleID = "com.apple.finder"

    var isFinderFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == finderBundleID
    }

    func selectedFileURLs() throws -> [URL] {
        let source = #"""
        tell application "Finder"
            set selectedItems to selection
            if (count of selectedItems) is 0 then return ""
            set output to ""
            repeat with selectedItem in selectedItems
                set output to output & POSIX path of (selectedItem as alias) & linefeed
            end repeat
            return output
        end tell
        """#

        let output = try runAppleScript(source)
        let urls = output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        guard !urls.isEmpty else {
            throw FinderBridgeError(message: "Select at least one Finder item first.")
        }
        return urls
    }

    func currentDestinationURL() throws -> URL {
        let source = #"""
        tell application "Finder"
            if (count of Finder windows) > 0 then
                set destinationFolder to target of front Finder window as alias
            else
                set destinationFolder to desktop as alias
            end if
            return POSIX path of destinationFolder
        end tell
        """#

        let output = try runAppleScript(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            throw FinderBridgeError(message: "Couldn't read the current Finder folder.")
        }
        return URL(fileURLWithPath: output, isDirectory: true).standardizedFileURL
    }

    private func runAppleScript(_ source: String) throws -> String {
        guard let script = NSAppleScript(source: source) else {
            throw FinderBridgeError(message: "Couldn't create Finder automation script.")
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "Finder automation failed."
            throw FinderBridgeError(message: message)
        }

        return result.stringValue ?? ""
    }
}
