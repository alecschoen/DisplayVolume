import Foundation

/// Typed errors for every failure mode the audio engine can hit.
/// `errorDescription` is the short user-facing message; `technicalDetails`
/// is retained for the diagnostics panel.
public enum DisplayVolumeError: Error, Equatable {
    case systemAudioPermissionMissing
    case accessibilityPermissionMissing
    case deviceUnavailable(uid: String)
    case noStereoOutput(deviceName: String)
    case unsupportedFormat(details: String)
    case formatMismatch(details: String)
    case processObjectResolutionFailed(status: Int32)
    case tapCreationFailed(status: Int32)
    case tapFormatUnreadable(status: Int32)
    case aggregateCreationFailed(status: Int32)
    case inputCallbackFailure(status: Int32)
    case outputCallbackFailure(status: Int32)
    case deviceStartFailed(status: Int32)
    case ringBufferUnderrun
    case ringBufferOverrun
}

extension DisplayVolumeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .systemAudioPermissionMissing:
            return "System Audio Recording permission is required."
        case .accessibilityPermissionMissing:
            return "Accessibility permission is required for volume keys."
        case .deviceUnavailable:
            return "The selected output device is not available."
        case .noStereoOutput(let name):
            return "\(name) has no stereo output stream."
        case .unsupportedFormat:
            return "The device uses an unsupported audio format."
        case .formatMismatch:
            return "Tap and output formats do not match."
        case .processObjectResolutionFailed:
            return "Could not identify this app to Core Audio (feedback-loop protection)."
        case .tapCreationFailed:
            return "Could not create the system audio tap."
        case .tapFormatUnreadable:
            return "Could not read the audio tap format."
        case .aggregateCreationFailed:
            return "Could not create the internal capture device."
        case .inputCallbackFailure:
            return "Audio capture stopped unexpectedly."
        case .outputCallbackFailure:
            return "Audio output stopped unexpectedly."
        case .deviceStartFailed:
            return "Could not start audio processing."
        case .ringBufferUnderrun:
            return "Audio buffer underrun."
        case .ringBufferOverrun:
            return "Audio buffer overrun."
        }
    }

    /// Full technical description for the diagnostics panel and logs.
    public var technicalDetails: String {
        switch self {
        case .systemAudioPermissionMissing:
            return "TCC System Audio Recording (NSAudioCaptureUsageDescription) not granted"
        case .accessibilityPermissionMissing:
            return "AXIsProcessTrusted() == false; CGEventTap unavailable"
        case .deviceUnavailable(let uid):
            return "No alive AudioObject found for UID \(uid)"
        case .noStereoOutput(let name):
            return "Device \(name): fewer than 2 output channels in kAudioDevicePropertyStreamConfiguration"
        case .unsupportedFormat(let details):
            return "Unsupported format: \(details)"
        case .formatMismatch(let details):
            return "Format mismatch: \(details)"
        case .processObjectResolutionFailed(let status):
            return "kAudioHardwarePropertyTranslatePIDToProcessObject failed: \(fourCC(status))"
        case .tapCreationFailed(let status):
            return "AudioHardwareCreateProcessTap failed: \(fourCC(status))"
        case .tapFormatUnreadable(let status):
            return "kAudioTapPropertyFormat read failed: \(fourCC(status))"
        case .aggregateCreationFailed(let status):
            return "AudioHardwareCreateAggregateDevice failed: \(fourCC(status))"
        case .inputCallbackFailure(let status):
            return "Aggregate/tap IOProc failure: \(fourCC(status))"
        case .outputCallbackFailure(let status):
            return "Physical output IOProc failure: \(fourCC(status))"
        case .deviceStartFailed(let status):
            return "AudioDeviceStart failed: \(fourCC(status))"
        case .ringBufferUnderrun:
            return "Ring buffer underrun (output read faster than tap produced)"
        case .ringBufferOverrun:
            return "Ring buffer overrun (tap produced faster than output consumed)"
        }
    }

    private func fourCC(_ status: Int32) -> String {
        let u = UInt32(bitPattern: status)
        let bytes = [UInt8((u >> 24) & 0xFF), UInt8((u >> 16) & 0xFF),
                     UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
        if bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }),
           let s = String(bytes: bytes, encoding: .ascii) {
            return "\(status) ('\(s)')"
        }
        return "\(status)"
    }
}
