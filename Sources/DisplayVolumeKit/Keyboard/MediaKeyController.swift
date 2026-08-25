import AppKit
import CoreGraphics
import Foundation

/// Narrowly scoped media-key handler.
///
/// A CGEvent tap is created for exactly one event type: NSSystemDefined
/// (type 14, `NX_SYSDEFINED`), and within it only the AUX-control subtype
/// for the three sound keys (mute / volume-down / volume-up) is examined
/// and consumed. Regular keyboard input is never observed, logged, or
/// stored — other event types are not even delivered to the tap, and
/// non-sound system events are passed through untouched.
///
/// Requires Accessibility permission; `start()` throws if it is missing so
/// the caller can guide the user (the menu-bar slider keeps working
/// regardless).
public final class MediaKeyController {

    public enum Key {
        case volumeUp
        case volumeDown
        case mute
    }

    /// Called on the main queue. `fine` is true when Option+Shift is held
    /// (1-point steps instead of 5).
    public var onKey: ((Key, _ fine: Bool, _ isRepeat: Bool) -> Void)?

    public private(set) var isRunning = false

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Re-enable throttling: if the system keeps disabling the tap (e.g.
    // while Accessibility is being revoked), give up instead of fighting
    // the WindowServer — a tug-of-war over a session event tap can wedge
    // event delivery for the whole login session.
    private var lastReenable = Date.distantPast
    private var reenableStrikes = 0

    // NX constants (IOKit/hidsystem/ev_keymap.h)
    private static let nxSysdefinedType: UInt32 = 14 // NX_SYSDEFINED
    private static let auxControlSubtype: Int16 = 8  // NX_SUBTYPE_AUX_CONTROL_BUTTONS
    private static let keySoundUp: Int32 = 0         // NX_KEYTYPE_SOUND_UP
    private static let keySoundDown: Int32 = 1       // NX_KEYTYPE_SOUND_DOWN
    private static let keyMute: Int32 = 7            // NX_KEYTYPE_MUTE

    public init() {}

    deinit { stop() }

    public func start() throws {
        guard !isRunning else { return }
        guard AccessibilityPermission.isGranted else {
            throw DisplayVolumeError.accessibilityPermissionMissing
        }

        let mask = CGEventMask(1) << CGEventMask(Self.nxSysdefinedType)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let controller = Unmanaged<MediaKeyController>
                    .fromOpaque(refcon).takeUnretainedValue()
                return controller.handle(type: type, event: event)
            },
            userInfo: userInfo
        ) else {
            AppLog.keys.error("CGEvent.tapCreate failed (accessibility revoked?)")
            throw DisplayVolumeError.accessibilityPermissionMissing
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        isRunning = true
        AppLog.keys.info("Media-key tap started")
    }

    public func stop() {
        guard isRunning || eventTap != nil else { return }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            // Fully sever the WindowServer connection, not just disable it,
            // so no half-dead tap lingers across permission changes.
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        isRunning = false
        reenableStrikes = 0
        AppLog.keys.info("Media-key tap stopped")
    }

    // MARK: - Event handling (event-tap thread / main run loop)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // The OS disabled the tap. Re-enable ONLY when it is safe:
            //  - never while Accessibility is revoked (the disable is the
            //    system telling us to go away — fighting it can hang the
            //    session's event delivery), and
            //  - never more than a few times in quick succession.
            guard AccessibilityPermission.isGranted else {
                AppLog.keys.warning("Tap disabled and Accessibility revoked; tearing down")
                DispatchQueue.main.async { [weak self] in self?.stop() }
                return Unmanaged.passUnretained(event)
            }
            let now = Date()
            if now.timeIntervalSince(lastReenable) > 2.0 {
                reenableStrikes = 0
            }
            reenableStrikes += 1
            lastReenable = now
            if reenableStrikes > 4 {
                AppLog.keys.error("Tap keeps getting disabled; giving up instead of fighting the system")
                DispatchQueue.main.async { [weak self] in self?.stop() }
            } else if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type.rawValue == Self.nxSysdefinedType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.auxControlSubtype else {
            return Unmanaged.passUnretained(event)
        }

        let data1 = nsEvent.data1
        let keyCode = Int32((data1 & 0xFFFF_0000) >> 16)
        let keyFlags = data1 & 0x0000_FFFF
        let isKeyDown = ((keyFlags & 0xFF00) >> 8) == 0x0A
        let isRepeat = (keyFlags & 0x1) == 1

        let key: Key
        switch keyCode {
        case Self.keySoundUp: key = .volumeUp
        case Self.keySoundDown: key = .volumeDown
        case Self.keyMute: key = .mute
        default:
            // Not a sound key (brightness, play/pause, …): pass through.
            return Unmanaged.passUnretained(event)
        }

        if isKeyDown {
            let modifiers = nsEvent.modifierFlags
            let fine = modifiers.contains(.option) && modifiers.contains(.shift)
            DispatchQueue.main.async { [weak self] in
                self?.onKey?(key, fine, isRepeat)
            }
        }
        // Consume both key-down and key-up of the sound keys so the system
        // does not also show its own (ineffective) volume bezel.
        return nil
    }
}
