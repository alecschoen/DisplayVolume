import Foundation

/// UserDefaults-backed settings. Injectable defaults suite for tests.
public final class Preferences {
    public enum Key {
        public static let deviceUID = "selectedDeviceUID"
        public static let volume = "volume"
        public static let muted = "muted"
        public static let startAtLogin = "startAtLogin"
        public static let keyboardControlEnabled = "keyboardControlEnabled"
        public static let matchSystemOutput = "matchSystemOutput"
        public static let volumeFeedbackEnabled = "volumeFeedbackEnabled"
        public static let volumeByDevice = "volumeByDevice"
        public static let mutedByDevice = "mutedByDevice"
        public static let onboardingCompleted = "onboardingCompleted"
        public static let processingWasActive = "processingWasActive"
    }

    public static let defaultVolume: Float = 0.5

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Persistent Core Audio device UID of the selected output (never the
    /// transient AudioObjectID).
    public var selectedDeviceUID: String? {
        get { defaults.string(forKey: Key.deviceUID) }
        set { defaults.set(newValue, forKey: Key.deviceUID) }
    }

    /// Saved volume in 0.0–1.0. Defaults to 50% — the app must never start
    /// unexpectedly at 100%. Values are sanitized on both read and write.
    public var volume: Float {
        get {
            guard defaults.object(forKey: Key.volume) != nil else {
                return Self.defaultVolume
            }
            let raw = defaults.float(forKey: Key.volume)
            guard raw.isFinite else { return Self.defaultVolume }
            return min(max(raw, 0), 1)
        }
        set {
            guard newValue.isFinite else { return }
            defaults.set(min(max(newValue, 0), 1), forKey: Key.volume)
        }
    }

    public var muted: Bool {
        get { defaults.bool(forKey: Key.muted) }
        set { defaults.set(newValue, forKey: Key.muted) }
    }

    public var startAtLogin: Bool {
        get { defaults.bool(forKey: Key.startAtLogin) }
        set { defaults.set(newValue, forKey: Key.startAtLogin) }
    }

    public var keyboardControlEnabled: Bool {
        get { defaults.bool(forKey: Key.keyboardControlEnabled) }
        set { defaults.set(newValue, forKey: Key.keyboardControlEnabled) }
    }

    /// Play the system "pop" feedback sound when the volume keys change the
    /// volume (both control modes). Defaults to true, matching macOS.
    public var volumeFeedbackEnabled: Bool {
        get {
            guard defaults.object(forKey: Key.volumeFeedbackEnabled) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.volumeFeedbackEnabled)
        }
        set { defaults.set(newValue, forKey: Key.volumeFeedbackEnabled) }
    }

    // MARK: - Per-device software volume/mute

    /// Saved software volume for a specific device UID. Devices never seen
    /// before fall back to the legacy single `volume` value (which itself
    /// defaults to 50%), so behavior is continuous across upgrades and the
    /// app still never starts at 100%.
    public func volume(forDevice uid: String?) -> Float {
        guard let uid,
              let dict = defaults.dictionary(forKey: Key.volumeByDevice),
              let raw = dict[uid] as? Double else {
            return volume
        }
        let value = Float(raw)
        guard value.isFinite else { return Self.defaultVolume }
        return min(max(value, 0), 1)
    }

    /// Persists the software volume for `uid` (and mirrors it into the
    /// legacy key, which doubles as the fallback for new devices).
    public func setVolume(_ newValue: Float, forDevice uid: String?) {
        guard newValue.isFinite else { return }
        let clamped = min(max(newValue, 0), 1)
        volume = clamped
        guard let uid else { return }
        var dict = defaults.dictionary(forKey: Key.volumeByDevice) ?? [:]
        dict[uid] = Double(clamped)
        defaults.set(dict, forKey: Key.volumeByDevice)
    }

    /// Saved software mute state for a specific device UID; falls back to
    /// the legacy single `muted` value for devices never seen before.
    public func muted(forDevice uid: String?) -> Bool {
        guard let uid,
              let dict = defaults.dictionary(forKey: Key.mutedByDevice),
              let value = dict[uid] as? Bool else {
            return muted
        }
        return value
    }

    public func setMuted(_ newValue: Bool, forDevice uid: String?) {
        muted = newValue
        guard let uid else { return }
        var dict = defaults.dictionary(forKey: Key.mutedByDevice) ?? [:]
        dict[uid] = newValue
        defaults.set(dict, forKey: Key.mutedByDevice)
    }

    /// Keep the app's selected device in sync with the macOS default output
    /// (both directions). Defaults to true: the tap only captures audio
    /// destined for the selected device, so a mismatch means silence.
    public var matchSystemOutput: Bool {
        get {
            guard defaults.object(forKey: Key.matchSystemOutput) != nil else {
                return true
            }
            return defaults.bool(forKey: Key.matchSystemOutput)
        }
        set { defaults.set(newValue, forKey: Key.matchSystemOutput) }
    }

    public var onboardingCompleted: Bool {
        get { defaults.bool(forKey: Key.onboardingCompleted) }
        set { defaults.set(newValue, forKey: Key.onboardingCompleted) }
    }

    /// Whether processing was active at last quit, so the app can resume
    /// (permission was already granted in that case; no surprise prompts).
    public var processingWasActive: Bool {
        get { defaults.bool(forKey: Key.processingWasActive) }
        set { defaults.set(newValue, forKey: Key.processingWasActive) }
    }
}
