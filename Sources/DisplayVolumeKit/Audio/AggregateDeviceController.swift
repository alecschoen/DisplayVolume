import CoreAudio
import Foundation

/// Creates and destroys the private aggregate device that hosts the process
/// tap, following Apple's "Capturing system audio with Core Audio taps"
/// sample: the aggregate contains the target output device as its (main)
/// sub-device and the tap in its tap list, with drift compensation and
/// automatic tap start enabled.
///
/// The aggregate is marked private, so it never appears in Audio MIDI Setup,
/// Sound settings, or other applications, and it is destroyed automatically
/// by the HAL if this process dies. We still destroy it explicitly on stop
/// and sweep for stale instances (matching our UID prefix) on startup as
/// defense in depth against interrupted launches.
public final class AggregateDeviceController {

    public private(set) var aggregateID = AudioObjectID(kAudioObjectUnknown)
    public private(set) var aggregateUID: String = ""

    public var isActive: Bool { aggregateID != kAudioObjectUnknown }

    public init() {}

    deinit { destroy() }

    public func create(targetDeviceUID: String, tapUID: String) throws {
        precondition(!isActive, "aggregate already exists")

        // Unique per pipeline instance, stable prefix for identification.
        let uid = "\(AudioDeviceManager.aggregateUIDPrefix).\(ProcessInfo.processInfo.processIdentifier).\(UUID().uuidString)"

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DisplayVolume Capture",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceMainSubDeviceKey: targetDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: targetDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true,
                ]
            ],
        ]

        var newID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newID)
        guard status == noErr, newID != kAudioObjectUnknown else {
            throw DisplayVolumeError.aggregateCreationFailed(status: status)
        }
        aggregateID = newID
        aggregateUID = uid
        AppLog.audio.info("Aggregate device created (id \(newID))")
    }

    public func destroy() {
        guard aggregateID != kAudioObjectUnknown else { return }
        let status = AudioHardwareDestroyAggregateDevice(aggregateID)
        if status != noErr {
            AppLog.audio.error("AudioHardwareDestroyAggregateDevice failed: \(status)")
        }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        aggregateUID = ""
    }

    /// Destroys any aggregate created by an earlier, interrupted instance of
    /// this app. Private aggregates normally die with their process, but a
    /// sweep at startup guarantees no stale devices survive.
    public static func destroyStaleAggregates() {
        let (status, ids): (OSStatus, [AudioObjectID]) =
            CA.readArray(CA.systemObject, kAudioHardwarePropertyDevices)
        guard status == noErr else { return }
        for id in ids {
            guard let uid = CA.deviceUID(id),
                  uid.hasPrefix(AudioDeviceManager.aggregateUIDPrefix) else { continue }
            AppLog.audio.warning("Destroying stale aggregate \(uid, privacy: .public)")
            AudioHardwareDestroyAggregateDevice(id)
        }
    }
}
