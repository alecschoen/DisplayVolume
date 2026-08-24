import AppKit
import Foundation

/// Collects the non-sensitive technical state shown in the diagnostics
/// section and copied by "Copy Diagnostics". Never contains audio samples
/// or unrelated personal information, and is never transmitted anywhere —
/// copying to the clipboard is the only export.
public struct DiagnosticsReport {
    public var appVersion: String
    public var macOSVersion: String
    public var architecture: String
    public var status: String
    public var deviceName: String
    public var deviceUID: String
    public var sampleRate: Double
    public var channelCount: Int
    public var tapFormat: String
    public var outputFormat: String
    public var estimatedLatencyMs: Double
    public var underruns: UInt64
    public var overruns: UInt64
    public var inputCallbacks: UInt64
    public var outputCallbacks: UInt64
    public var nonSilentInputSeen: Bool
    public var audioPermission: String
    public var accessibilityPermission: String
    public var lastError: String

    public init() {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        appVersion = "\(short) (\(build))"
        macOSVersion = ProcessInfo.processInfo.operatingSystemVersionString
        #if arch(arm64)
        architecture = "arm64 (Apple Silicon)"
        #elseif arch(x86_64)
        architecture = "x86_64 (Intel)"
        #else
        architecture = "unknown"
        #endif
        status = ""
        deviceName = "—"
        deviceUID = "—"
        sampleRate = 0
        channelCount = 0
        tapFormat = "—"
        outputFormat = "—"
        estimatedLatencyMs = 0
        underruns = 0
        overruns = 0
        inputCallbacks = 0
        outputCallbacks = 0
        nonSilentInputSeen = false
        audioPermission = PermissionState.unknown.rawValue
        accessibilityPermission = PermissionState.unknown.rawValue
        lastError = "none"
    }

    public var clipboardText: String {
        """
        DisplayVolume Diagnostics
        =========================
        App version:        \(appVersion)
        macOS:              \(macOSVersion)
        Architecture:       \(architecture)
        State:              \(status)

        Selected device:    \(deviceName)
        Device UID:         \(deviceUID)
        Sample rate:        \(sampleRate > 0 ? String(format: "%.0f Hz", sampleRate) : "—")
        Channels:           \(channelCount > 0 ? String(channelCount) : "—")
        Tap format:         \(tapFormat)
        Output format:      \(outputFormat)
        Est. added latency: \(String(format: "%.1f ms", estimatedLatencyMs))

        Input callbacks:    \(inputCallbacks)
        Output callbacks:   \(outputCallbacks)
        Underruns:          \(underruns)
        Overruns:           \(overruns)
        Audio observed:     \(nonSilentInputSeen ? "yes" : "not yet")

        System Audio Recording permission: \(audioPermission)
        Accessibility permission:          \(accessibilityPermission)

        Last error:         \(lastError)
        """
    }

    public func copyToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(clipboardText, forType: .string)
    }
}
