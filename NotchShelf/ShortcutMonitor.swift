import AppKit
import ApplicationServices
import CoreGraphics

@MainActor
final class ShortcutMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var shouldCapturePaste: (() -> Bool)?
    var isFinderFrontmost: (() -> Bool)?

    static func requestPermissions() {
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }

        if !CGPreflightListenEventAccess() {
            _ = CGRequestListenEventAccess()
        }
    }

    static func logPermissionStatus(prefix: String = "[NotchShelf]") {
        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        NSLog("\(prefix) Permission status — Accessibility: \(accessibility ? "granted" : "missing"), Input Monitoring: \(inputMonitoring ? "granted" : "missing")")
    }

    func start() {
        guard eventTap == nil else { return }

        Self.requestPermissions()

        let accessibility = AXIsProcessTrusted()
        let inputMonitoring = CGPreflightListenEventAccess()
        Self.logPermissionStatus()

        guard accessibility, inputMonitoring else {
            NSLog("[NotchShelf] Keyboard monitor not started. Grant both Accessibility and Input Monitoring to this NotchShelf build, quit the app completely, then launch it again.")
            return
        }

        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ShortcutMonitor>.fromOpaque(userInfo).takeUnretainedValue()

                return MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
            },
            userInfo: pointer
        ) else {
            NSLog("[NotchShelf] CGEventTap creation failed even though permissions preflight as granted. This usually means macOS TCC still trusts a different/older NotchShelf build. Reset the app's Accessibility and Input Monitoring entries, then grant the current build again.")
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[NotchShelf] Shortcut monitor started")
    }

    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard isFinderFrontmost?() == true else { return Unmanaged.passUnretained(event) }

        let flags = event.flags
        guard flags.contains(.maskCommand) else { return Unmanaged.passUnretained(event) }
        guard !flags.contains(.maskAlternate), !flags.contains(.maskControl), !flags.contains(.maskShift) else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // ANSI keyboard keycodes: X = 7, V = 9.
        if keyCode == 7 {
            onCut?()
            return nil
        }

        if keyCode == 9, shouldCapturePaste?() == true {
            onPaste?()
            return nil
        }

        return Unmanaged.passUnretained(event)
    }
}
