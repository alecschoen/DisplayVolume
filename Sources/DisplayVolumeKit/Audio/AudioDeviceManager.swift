import CoreAudio
import Foundation

/// What kind of output a device is — drives the menu-bar glyph so it's
/// always clear what you're listening on (like the system volume icon).
public enum OutputDeviceKind: Equatable {
    case builtinSpeaker
    case headphones
    case airPods
    case airPodsPro
    case airPodsMax
    case display
    case bluetoothSpeaker
    case airPlay
    case genericSpeaker

    /// SF Symbol for the menu bar. `active` only affects the speaker
    /// variants (glyph-only symbols have no fill variant).
    public func menuBarSymbol(active: Bool) -> String {
        switch self {
        case .builtinSpeaker, .genericSpeaker:
            return active ? "speaker.wave.2.fill" : "speaker.wave.2"
        case .headphones: return "headphones"
        case .airPods: return "airpods"
        case .airPodsPro: return "airpodspro"
        case .airPodsMax: return "airpodsmax"
        case .display: return "display"
        case .bluetoothSpeaker: return "hifispeaker"
        case .airPlay: return "airplayaudio"
        }
    }
}

/// A selectable physical output device.
public struct AudioOutputDevice: Identifiable, Hashable {
    public let id: AudioObjectID     // Transient! Only the UID is persistent.
    public let uid: String
    public let name: String
    public let sampleRate: Double
    public let outputChannelCount: Int
    public let transportType: UInt32
    public let kind: OutputDeviceKind

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
        case volumeChanged
        case muteChanged
        case dataSourceChanged
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

            let name = CA.objectName(deviceID) ?? uid
            let transport = CA.transportType(deviceID)
            result.append(AudioOutputDevice(
                id: deviceID,
                uid: uid,
                name: name,
                sampleRate: CA.nominalSampleRate(deviceID),
                outputChannelCount: channels,
                transportType: transport,
                kind: Self.classify(deviceID: deviceID, name: name, transport: transport)
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

    // MARK: - Device-kind classification

    /// 'hdpn' — the built-in codec's data source when headphones are
    /// plugged into the jack.
    private static let headphoneDataSource: UInt32 = 0x6864_706E

    /// Best-effort classification from data source, name, and transport.
    static func classify(deviceID: AudioObjectID, name: String,
                         transport: UInt32) -> OutputDeviceKind {
        let lower = name.lowercased()

        // AirPods variants get their own glyphs, like the system icon.
        if lower.contains("airpods max") { return .airPodsMax }
        if lower.contains("airpods pro") { return .airPodsPro }
        if lower.contains("airpods") { return .airPods }

        // Headphone jack on the built-in codec, or headphone-ish names
        // on any transport (USB headsets, Bluetooth buds, …).
        if CA.outputDataSource(deviceID) == headphoneDataSource {
            return .headphones
        }
        for token in ["headphone", "headset", "earbud", "buds", "earphone"]
        where lower.contains(token) {
            return .headphones
        }

        switch transport {
        case kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI:
            return .display
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtinSpeaker
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothSpeaker
        case kAudioDeviceTransportTypeAirPlay:
            return .airPlay
        default:
            return .genericSpeaker
        }
    }

    // MARK: - Native (hardware) volume control

    /// True when the device exposes a settable output volume — i.e. macOS
    /// can control it natively and no software processing is needed.
    /// Fixed-volume displays (the whole reason this app exists) return false.
    public func hasSettableVolume(_ deviceID: AudioObjectID) -> Bool {
        !settableElements(deviceID, selector: kAudioDevicePropertyVolumeScalar).isEmpty
    }

    /// Elements (main, or per-channel 1/2) on which `selector` is settable.
    private func settableElements(_ deviceID: AudioObjectID,
                                  selector: AudioObjectPropertySelector)
        -> [AudioObjectPropertyElement] {
        var result: [AudioObjectPropertyElement] = []
        for element in [kAudioObjectPropertyElementMain,
                        AudioObjectPropertyElement(1),
                        AudioObjectPropertyElement(2)] {
            var addr = CA.address(selector, scope: kAudioObjectPropertyScopeOutput,
                                  element: element)
            guard AudioObjectHasProperty(deviceID, &addr) else { continue }
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(deviceID, &addr, &settable) == noErr,
                  settable.boolValue else { continue }
            if element == kAudioObjectPropertyElementMain { return [element] }
            result.append(element)
        }
        return result
    }

    /// Current hardware output volume (0–1), averaged over channels when the
    /// device has no main-element control. Nil when unsupported.
    public func deviceVolume(_ deviceID: AudioObjectID) -> Float? {
        let elements = settableElements(deviceID, selector: kAudioDevicePropertyVolumeScalar)
        guard !elements.isEmpty else { return nil }
        var sum: Float = 0
        var count = 0
        for element in elements {
            var addr = CA.address(kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioObjectPropertyScopeOutput, element: element)
            var value = Float32(0)
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr {
                sum += value
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return min(max(sum / Float(count), 0), 1)
    }

    /// Sets the hardware output volume (0–1). This is the same control the
    /// system volume UI uses, so the two stay identical.
    @discardableResult
    public func setDeviceVolume(_ deviceID: AudioObjectID, _ volume: Float) -> Bool {
        guard volume.isFinite else { return false }
        let clamped = min(max(volume, 0), 1)
        var ok = false
        for element in settableElements(deviceID, selector: kAudioDevicePropertyVolumeScalar) {
            var addr = CA.address(kAudioDevicePropertyVolumeScalar,
                                  scope: kAudioObjectPropertyScopeOutput, element: element)
            var value = Float32(clamped)
            if AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                          UInt32(MemoryLayout<Float32>.size), &value) == noErr {
                ok = true
            }
        }
        return ok
    }

    /// Hardware mute state; nil when the device has no mute control.
    public func deviceMute(_ deviceID: AudioObjectID) -> Bool? {
        let elements = settableElements(deviceID, selector: kAudioDevicePropertyMute)
        guard let element = elements.first else { return nil }
        var addr = CA.address(kAudioDevicePropertyMute,
                              scope: kAudioObjectPropertyScopeOutput, element: element)
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    /// Sets hardware mute. Returns false when the device has no mute control
    /// (the caller falls back to volume-based muting).
    @discardableResult
    public func setDeviceMute(_ deviceID: AudioObjectID, _ muted: Bool) -> Bool {
        let elements = settableElements(deviceID, selector: kAudioDevicePropertyMute)
        guard !elements.isEmpty else { return false }
        var ok = false
        for element in elements {
            var addr = CA.address(kAudioDevicePropertyMute,
                                  scope: kAudioObjectPropertyScopeOutput, element: element)
            var value: UInt32 = muted ? 1 : 0
            if AudioObjectSetPropertyData(deviceID, &addr, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                ok = true
            }
        }
        return ok
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
                case kAudioDevicePropertyVolumeScalar:
                    self.onWatchedDeviceEvent?(.volumeChanged)
                case kAudioDevicePropertyMute:
                    self.onWatchedDeviceEvent?(.muteChanged)
                case kAudioDevicePropertyDataSource:
                    self.onWatchedDeviceEvent?(.dataSourceChanged)
                default:
                    break
                }
            }
        }

        let selectors: [(AudioObjectPropertySelector, AudioObjectPropertyScope,
                         AudioObjectPropertyElement)] = [
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal,
             kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
             kAudioObjectPropertyElementMain),
            (kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeOutput,
             kAudioObjectPropertyElementMain),
            // Wildcard element: hardware volume/mute may live on the main
            // element or on channels 1/2 depending on the device.
            (kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput,
             kAudioObjectPropertyElementWildcard),
            (kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput,
             kAudioObjectPropertyElementWildcard),
            // Headphone jack plug/unplug on the built-in codec.
            (kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeOutput,
             kAudioObjectPropertyElementMain),
        ]
        var registered: [AudioObjectPropertyAddress] = []
        for (selector, scope, element) in selectors {
            var addr = CA.address(selector, scope: scope, element: element)
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
