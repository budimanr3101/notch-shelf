import AppKit
import ApplicationServices

@MainActor
final class ShortcutMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    var onCut: (() -> Void)?
    var onPaste: (() -> Void)?
    var shouldCapturePaste: (() -> Bool)?
    var isFinderFrontmost: (() -> Bool)?

    static func requestAccessibilityPrompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        guard eventTap == nil else { return }

        if !AXIsProcessTrusted() {
            Self.requestAccessibilityPrompt()
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

                // This event tap is installed on the main run loop below, so bridge
                // the C callback back into the Swift main-actor world explicitly.
                return MainActor.assumeIsolated {
                    monitor.handle(type: type, event: event)
                }
            },
            userInfo: pointer
        ) else {
            NSLog("[NotchShelf] Could not create keyboard event tap. Grant Accessibility permission, then relaunch NotchShelf.")
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
