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
