import CoreAudio
import Foundation

/// A selectable physical output device.
public struct AudioOutputDevice: Identifiable, Hashable {
    public let id: AudioObjectID     // Transient! Only the UID is persistent.
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let outputChannelCount: Int
    public let transportType: UInt32

    public var transportName: String {
        switch transportType {
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeDisplayPort: return "DisplayPort"
        case kAudioDeviceTransportTypeHDMI: return "HDMI"
        case kAudioDeviceTransportTypeThunderbolt: return "Thunderbolt"
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth: return "Bluetooth"
        case kAudioDeviceTransportTypeAirPlay: return "AirPlay"
        case kAudioDeviceTransportTypeAggregate: return "Aggregate"
        case kAudioDeviceTransportTypeVirtual: return "Virtual"
        default: return "Other"
        }
    }
}

/// Enumerates real output devices and watches for hardware changes.
/// All callbacks are delivered on the main queue.
public final class AudioDeviceManager {

    /// UID prefix for aggregates created by this app, so they are always
    /// excluded from the selectable list (and cleaned up if ever stale).
    public static let aggregateUIDPrefix = "com.bnewable.DisplayVolume.aggregate"

    /// Fired when the device list may have changed (add/remove).
    public var onDevicesChanged: (() -> Void)?
    /// Fired when the system default output device changes.
    public var onDefaultOutputChanged: (() -> Void)?
    /// Fired when a watched device dies, or nil deviceID events.
    public var onWatchedDeviceEvent: ((WatchedDeviceEvent) -> Void)?

    public enum WatchedDeviceEvent {
        case aliveChanged(isAlive: Bool)
        case sampleRateChanged(newRate: Double)
        case streamConfigurationChanged
    }

    private var systemListenerBlock: AudioObjectPropertyListenerBlock?
    private var systemListenerAddresses: [AudioObjectPropertyAddress] = []

    private var watchedDeviceID: AudioObjectID = AudioObjectID(kAudioObjectUnknown)
    private var watchedListenerBlock: AudioObjectPropertyListenerBlock?
    private var watchedAddresses: [AudioObjectPropertyAddress] = []

    public init() {}

    deinit {
        stopWatchingSystem()
        stopWatchingSelectedDevice()
    }

    // MARK: - Enumeration

    /// All devices that can actually render audio, excluding our own
    /// aggregates, input-only/capture-only devices, and dead devices.
    public func outputDevices() -> [AudioOutputDevice] {
        let (status, ids): (OSStatus, [AudioObjectID]) =
            CA.readArray(CA.systemObject, kAudioHardwarePropertyDevices)
        guard status == noErr else {
            AppLog.devices.error("Device enumeration failed: \(status)")
            return []
        }

        var result: [AudioOutputDevice] = []
        for deviceID in ids {
            guard let uid = CA.deviceUID(deviceID) else { continue }
            // Never list aggregates created by this app.
            if uid.hasPrefix(Self.aggregateUIDPrefix) { continue }
            // No output channels → capture-only/virtual input; cannot render.
            let channels = CA.outputChannelCount(deviceID)
            guard channels > 0 else { continue }
            guard CA.isAlive(deviceID) else { continue }

            result.append(AudioOutputDevice(
                id: deviceID,
                uid: uid,
                name: CA.objectName(deviceID) ?? uid,
                sampleRate: CA.nominalSampleRate(deviceID),
                outputChannelCount: channels,
                transportType: CA.transportType(deviceID)
            ))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func device(forUID uid: String) -> AudioOutputDevice? {
        outputDevices().first { $0.uid == uid }
    }

    // MARK: - System default output

    /// UID of the current system default output device (System Settings →
    /// Sound → Output), or nil if it cannot be determined.
    public func defaultOutputDeviceUID() -> String? {
        let (status, deviceID) = CA.read(CA.systemObject,
                                         kAudioHardwarePropertyDefaultOutputDevice,
                                         defaultValue: AudioObjectID(kAudioObjectUnknown))
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return CA.deviceUID(deviceID)
    }

    /// Makes the device with `uid` the system default output, so the app's
    /// selection and the macOS Sound output stay in step.
    @discardableResult
    public func setDefaultOutputDevice(uid: String) -> Bool {
        guard let deviceID = CA.deviceID(forUID: uid) else {
            AppLog.devices.warning("Cannot set default output: no device for UID")
            return false
        }
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        var value = deviceID
        let status = AudioObjectSetPropertyData(CA.systemObject, &addr, 0, nil,
                                                UInt32(MemoryLayout<AudioObjectID>.size),
                                                &value)
        if status != noErr {
            AppLog.devices.error("Setting default output failed: \(status)")
        }
        return status == noErr
    }

    // MARK: - System-level listeners

    public func startWatchingSystem() {
        guard systemListenerBlock == nil else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self else { return }
            for i in 0..<Int(count) {
                switch addresses[i].mSelector {
                case kAudioHardwarePropertyDefaultOutputDevice:
                    self.onDefaultOutputChanged?()
                default:
                    self.onDevicesChanged?()
                }
            }
        }
        let selectors: [AudioObjectPropertySelector] = [
            kAudioHardwarePropertyDevices,
            kAudioHardwarePropertyDefaultOutputDevice,
        ]
        var addresses: [AudioObjectPropertyAddress] = []
        for selector in selectors {
            var addr = CA.address(selector)
            let status = AudioObjectAddPropertyListenerBlock(
                CA.systemObject, &addr, .main, block)
            if status == noErr { addresses.append(addr) }
        }
        systemListenerBlock = block
        systemListenerAddresses = addresses
    }

    public func stopWatchingSystem() {
        guard let block = systemListenerBlock else { return }
        for var addr in systemListenerAddresses {
            AudioObjectRemovePropertyListenerBlock(CA.systemObject, &addr, .main, block)
        }
        systemListenerBlock = nil
        systemListenerAddresses = []
    }

    // MARK: - Per-device listeners (alive / sample rate / stream format)

    public func watchSelectedDevice(_ deviceID: AudioObjectID) {
        stopWatchingSelectedDevice()
        guard deviceID != kAudioObjectUnknown else { return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] count, addresses in
            guard let self else { return }
            let watched = self.watchedDeviceID
            guard watched != kAudioObjectUnknown else { return }
            for i in 0..<Int(count) {
                let selector = addresses[i].mSelector
                switch selector {
                case kAudioDevicePropertyDeviceIsAlive:
                    let alive = CA.isAlive(watched)
                    self.onWatchedDeviceEvent?(.aliveChanged(isAlive: alive))
                case kAudioDevicePropertyNominalSampleRate:
                    let rate = CA.nominalSampleRate(watched)
                    self.onWatchedDeviceEvent?(.sampleRateChanged(newRate: rate))
                case kAudioDevicePropertyStreamConfiguration,
                     kAudioStreamPropertyVirtualFormat:
                    self.onWatchedDeviceEvent?(.streamConfigurationChanged)
                default:
                    break
                }
            }
        }

        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput),
        ]
        var registered: [AudioObjectPropertyAddress] = []
        for (selector, scope) in selectors {
            var addr = CA.address(selector, scope: scope)
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &addr, .main, block)
            if status == noErr { registered.append(addr) }
        }
        watchedDeviceID = deviceID
        watchedListenerBlock = block
        watchedAddresses = registered
    }

    public func stopWatchingSelectedDevice() {
        guard let block = watchedListenerBlock,
              watchedDeviceID != kAudioObjectUnknown else {
            watchedListenerBlock = nil
            watchedAddresses = []
            watchedDeviceID = AudioObjectID(kAudioObjectUnknown)
            return
        }
        for var addr in watchedAddresses {
            AudioObjectRemovePropertyListenerBlock(watchedDeviceID, &addr, .main, block)
        }
        watchedListenerBlock = nil
        watchedAddresses = []
        watchedDeviceID = AudioObjectID(kAudioObjectUnknown)
    }
}
