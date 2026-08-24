import AppKit
import ApplicationServices
import Foundation

/// Accessibility permission, needed only for the global media-key event tap.
/// The system prompt is triggered exclusively from `request()`, which the
/// app calls only when the user turns on "Control with keyboard volume
/// keys" — never at launch, and never repeatedly.
public enum AccessibilityPermission {

    public static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    public static var state: PermissionState {
        isGranted ? .granted : .denied
    }

    /// Shows the system consent prompt (at most once per TCC state; the OS
    /// deduplicates). Returns the current trust state.
    @discardableResult
    public static func request() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// Deep link to Privacy & Security → Accessibility.
    public static func openSystemSettings() {
        if let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
