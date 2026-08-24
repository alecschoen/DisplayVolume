import CoreAudio
import Foundation

/// Thin, non-real-time helpers for AudioObject property access.
/// Never call these from an audio IOProc.
public enum CA {
    public static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    // MARK: - Generic reads

    public static func read<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        defaultValue: T
    ) -> (status: OSStatus, value: T) {
        var addr = address(selector, scope: scope)
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        return (status, value)
    }

    public static func readArray<T>(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> (status: OSStatus, values: [T]) {
        var addr = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard status == noErr, size > 0 else { return (status, []) }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return (noErr, []) }
        var values = [T](unsafeUninitializedCapacity: count) { _, initialized in
            initialized = count
        }
        status = values.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, buffer.baseAddress!)
        }
        if status != noErr { return (status, []) }
        let actual = Int(size) / MemoryLayout<T>.stride
        if actual < count { values.removeLast(count - actual) }
        return (noErr, values)
    }

    public static func readString(
        _ objectID: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var addr = address(selector, scope: scope)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let cf = value else { return nil }
        return cf as String
    }

    // MARK: - Common device properties

    public static func deviceUID(_ deviceID: AudioObjectID) -> String? {
        readString(deviceID, kAudioDevicePropertyDeviceUID)
    }

    public static func objectName(_ objectID: AudioObjectID) -> String? {
        readString(objectID, kAudioObjectPropertyName)
    }

    public static func nominalSampleRate(_ deviceID: AudioObjectID) -> Double {
        read(deviceID, kAudioDevicePropertyNominalSampleRate, defaultValue: Double(0)).value
    }

    public static func isAlive(_ deviceID: AudioObjectID) -> Bool {
        let (status, alive) = read(deviceID, kAudioDevicePropertyDeviceIsAlive,
                                   defaultValue: UInt32(0))
        return status == noErr && alive != 0
    }

    public static func transportType(_ deviceID: AudioObjectID) -> UInt32 {
        read(deviceID, kAudioDevicePropertyTransportType, defaultValue: UInt32(0)).value
    }

    /// Total output channel count from the device's output stream configuration.
    public static func outputChannelCount(_ deviceID: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration,
                           scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let ablPtr = raw.assumingMemoryBound(to: AudioBufferList.self)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ablPtr) == noErr else {
            return 0
        }
        let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// IDs of the device's output streams (element order preserved).
    public static func outputStreamIDs(_ deviceID: AudioObjectID) -> [AudioObjectID] {
        readArray(deviceID, kAudioDevicePropertyStreams,
                  scope: kAudioObjectPropertyScopeOutput).values
    }

    /// The virtual (client-side) format of a stream — the format IOProc buffers use.
    public static func streamVirtualFormat(_ streamID: AudioObjectID)
        -> (status: OSStatus, format: AudioStreamBasicDescription) {
        let result = read(streamID, kAudioStreamPropertyVirtualFormat,
                          defaultValue: AudioStreamBasicDescription())
        return (result.status, result.value)
    }

    // MARK: - Translations

    /// Resolve a persistent device UID to the current AudioObjectID.
    /// Returns nil when no such device is present (e.g. monitor unplugged).
    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cf = uid as CFString
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cf) { qualifier in
            AudioObjectGetPropertyData(systemObject, &addr,
                                       UInt32(MemoryLayout<CFString>.size), qualifier,
                                       &size, &deviceID)
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Resolve a Unix PID to its Core Audio process AudioObjectID.
    /// A PID is NOT an AudioObjectID; this translation is required before a
    /// process can be excluded from a tap.
    public static func processObjectID(forPID pid: pid_t)
        -> (status: OSStatus, objectID: AudioObjectID) {
        var addr = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var pidValue = pid
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &pidValue) { qualifier in
            AudioObjectGetPropertyData(systemObject, &addr,
                                       UInt32(MemoryLayout<pid_t>.size), qualifier,
                                       &size, &objectID)
        }
        return (status, objectID)
    }
}
