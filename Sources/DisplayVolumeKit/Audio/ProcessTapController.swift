import CoreAudio
import Foundation

/// Creates and destroys the Core Audio process tap.
///
/// The tap is configured to capture ALL processes whose audio is destined
/// for the selected output device EXCEPT this application's own process.
/// Excluding ourselves is essential: the app renders the processed audio to
/// the same device, and capturing our own output would create a feedback
/// loop.
///
/// Mute behavior is `.mutedWhenTapped`: while the tap is being read, the
/// original direct audio to the device is muted (so the user does not hear
/// the dry and processed signals doubled); if this app stops reading,
/// crashes, or exits, Core Audio automatically unmutes the original audio.
/// The system is never left permanently silent.
public final class ProcessTapController {

    public private(set) var tapID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var tapUID: String = ""
    public private(set) var tapFormat = AudioStreamBasicDescription()

    public var isActive: Bool { tapID != kAudioObjectUnknown }

    public init() {}

    deinit { destroy() }

    /// Creates a private, stereo-mixdown tap bound to `deviceUID`, stream 0.
    public func create(deviceUID: String) throws {
        precondition(!isActive, "tap already exists")

        // 1. Resolve our own Core Audio process object from our Unix PID.
        //    (A PID is not an AudioObjectID; translation is mandatory.)
        let pid = ProcessInfo.processInfo.processIdentifier
        let (status, processObjectID) = CA.processObjectID(forPID: pid_t(pid))
        guard status == noErr, processObjectID != kAudioObjectUnknown else {
            // Refuse to continue: a tap that includes our own output would
            // feed back. Failing closed is the safe option.
            AppLog.audio.error("PID→process-object translation failed (status \(status))")
            throw DisplayVolumeError.processObjectResolutionFailed(status: status)
        }

        // 2. Describe the tap: everything destined for the device except us.
        //    (initExcludingProcesses:andDeviceUID:withStream: is
        //    NS_REFINED_FOR_SWIFT; this SDK exposes only the raw __ import.)
        let description = CATapDescription(
            __excludingProcesses: [NSNumber(value: processObjectID)],
            andDeviceUID: deviceUID,
            withStream: 0)
        description.name = "DisplayVolume Tap (\(deviceUID))"
        description.isPrivate = true                 // invisible to other apps
        description.isExclusive = true               // "all except listed"
        description.muteBehavior = .mutedWhenTapped  // fail-safe unmute

        // 3. Create it.
        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let createStatus = AudioHardwareCreateProcessTap(description, &newTapID)
        guard createStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw DisplayVolumeError.tapCreationFailed(status: createStatus)
        }
        tapID = newTapID

        // 4. Read back the tap's UID (needed for the aggregate's tap list)
        //    and its stream format (must be validated, never assumed).
        guard let uid = CA.readString(tapID, kAudioTapPropertyUID) else {
            let fallback = description.uuid.uuidString
            AppLog.audio.warning("kAudioTapPropertyUID unreadable; falling back to description UUID")
            tapUID = fallback
            try readFormat()
            return
        }
        tapUID = uid
        try readFormat()
    }

    private func readFormat() throws {
        let (status, format) = CA.read(tapID, kAudioTapPropertyFormat,
                                       defaultValue: AudioStreamBasicDescription())
        guard status == noErr, format.mSampleRate > 0 else {
            destroy()
            throw DisplayVolumeError.tapFormatUnreadable(status: status)
        }
        tapFormat = format
        AppLog.audio.info("Tap created: \(AudioFormatUtilities.describe(format), privacy: .public)")
    }

    public func destroy() {
        guard tapID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyProcessTap(tapID)
        if status != noErr {
            AppLog.audio.error("AudioHardwareDestroyProcessTap failed: \(status)")
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
        tapUID = ""
        tapFormat = AudioStreamBasicDescription()
    }
}
