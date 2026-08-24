import AppKit
import Foundation

public enum PermissionState: String {
    case unknown = "Unknown"
    case granted = "Granted"
    case denied = "Denied / not granted"
}

/// System Audio Recording (TCC "Screen & System Audio Recording") state.
///
/// macOS offers no public preflight API for this permission. The system
/// shows its consent prompt the first time the app creates a process tap
/// (which only happens when the user explicitly starts processing). State
/// is therefore inferred:
///  - `.granted` once the tap delivers any non-silent audio.
///  - `.denied` when tap creation fails, or audio stays completely silent
///    while callbacks are running for an extended period AND the user
///    reports no audio (surfaced as guidance, never as a repeated prompt).
///
/// The app never re-triggers the system prompt on its own; the "Open System
/// Settings" button takes the user to the right pane instead.
public final class AudioCapturePermission {
    public private(set) var state: PermissionState = .unknown

    public init() {}

    public func noteTapCreationSucceeded() {
        if state == .denied { state = .unknown }
    }

    public func noteNonSilentAudioObserved() {
        state = .granted
    }

    public func noteTapCreationFailed() {
        // Tap creation failing on a healthy device is the observable
        // signature of a TCC denial.
        if state != .granted { state = .denied }
    }

    /// Deep link to Privacy & Security → Screen & System Audio Recording.
    public static func openSystemSettings() {
        let candidates = [
            // macOS 15+/26 pane for audio capture:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
