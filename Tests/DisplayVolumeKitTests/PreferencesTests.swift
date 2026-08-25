import Foundation
import Testing
@testable import DisplayVolumeKit

@Suite("Preferences persistence")
struct PreferencesTests {

    /// Runs `body` with a throwaway UserDefaults suite that is removed
    /// afterwards, so tests never touch real app preferences.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "PreferencesTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    @Test("default volume is 50%, never 100%")
    func defaultVolume() {
        withDefaults { defaults in
            #expect(Preferences(defaults: defaults).volume == 0.5)
        }
    }

    @Test("volume persists and restores")
    func volumeRoundTrip() {
        withDefaults { defaults in
            Preferences(defaults: defaults).volume = 0.73
            #expect(abs(Preferences(defaults: defaults).volume - 0.73) < 1e-6)
        }
    }

    @Test("volume clamps on write")
    func volumeClamps() {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.volume = 3.5
            #expect(prefs.volume == 1.0)
            prefs.volume = -2
            #expect(prefs.volume == 0.0)
        }
    }

    @Test("invalid volume writes are ignored")
    func invalidVolumeIgnored() {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.volume = 0.6
            prefs.volume = .nan
            #expect(abs(prefs.volume - 0.6) < 1e-6)
            prefs.volume = .infinity
            #expect(abs(prefs.volume - 0.6) < 1e-6)
        }
    }

    @Test("corrupt stored volume reads back safely")
    func corruptStoredVolume() {
        withDefaults { defaults in
            defaults.set(Float.nan, forKey: Preferences.Key.volume)
            let v = Preferences(defaults: defaults).volume
            #expect(v.isFinite)
            #expect((0...1).contains(v))
        }
    }

    @Test("mute state persists")
    func mutePersists() {
        withDefaults { defaults in
            #expect(Preferences(defaults: defaults).muted == false)
            Preferences(defaults: defaults).muted = true
            #expect(Preferences(defaults: defaults).muted == true)
        }
    }

    @Test("device UID persists (identity by UID, not by name or object ID)")
    func deviceUIDPersists() {
        withDefaults { defaults in
            #expect(Preferences(defaults: defaults).selectedDeviceUID == nil)
            let uid = "AppleUSBAudioEngine:TCL:32X3A:ABC123:1"
            Preferences(defaults: defaults).selectedDeviceUID = uid
            #expect(Preferences(defaults: defaults).selectedDeviceUID == uid)
        }
    }

    @Test("per-device volume persists independently for each device")
    func perDeviceVolume() {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.setVolume(0.3, forDevice: "monitor-A")
            prefs.setVolume(0.9, forDevice: "monitor-B")
            let reloaded = Preferences(defaults: defaults)
            #expect(abs(reloaded.volume(forDevice: "monitor-A") - 0.3) < 1e-6)
            #expect(abs(reloaded.volume(forDevice: "monitor-B") - 0.9) < 1e-6)
        }
    }

    @Test("unknown device falls back to the legacy volume, then 50%")
    func perDeviceVolumeFallback() {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            // Nothing saved at all → 50% default.
            #expect(prefs.volume(forDevice: "never-seen") == 0.5)
            // Legacy value present → new devices inherit it.
            prefs.volume = 0.7
            #expect(abs(prefs.volume(forDevice: "never-seen") - 0.7) < 1e-6)
        }
    }

    @Test("per-device volume writes are sanitized and clamped")
    func perDeviceVolumeSanitized() {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.setVolume(0.4, forDevice: "dev")
            prefs.setVolume(.nan, forDevice: "dev")
            #expect(abs(prefs.volume(forDevice: "dev") - 0.4) < 1e-6)
            prefs.setVolume(7, forDevice: "dev")
            #expect(prefs.volume(forDevice: "dev") == 1.0)
        }
    }

    @Test("per-device mute persists independently and falls back to legacy")
    func perDeviceMute() {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.setMuted(true, forDevice: "monitor-A")
            #expect(prefs.muted(forDevice: "monitor-A") == true)
            #expect(prefs.muted(forDevice: "monitor-B") == prefs.muted,
                    "unseen device falls back to the legacy mute value")
            prefs.setMuted(false, forDevice: "monitor-A")
            #expect(Preferences(defaults: defaults).muted(forDevice: "monitor-A") == false)
        }
    }

    @Test("audio-capture verdict is tri-state: unknown, granted, denied")
    func audioCaptureVerdict() {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            #expect(prefs.audioCaptureGranted == nil, "starts undetermined")
            prefs.audioCaptureGranted = true
            #expect(Preferences(defaults: defaults).audioCaptureGranted == true)
            prefs.audioCaptureGranted = false
            #expect(Preferences(defaults: defaults).audioCaptureGranted == false)
            prefs.audioCaptureGranted = nil
            #expect(Preferences(defaults: defaults).audioCaptureGranted == nil)
        }
    }

    @Test("volume-key feedback defaults to on and persists when turned off")
    func volumeFeedbackDefaultsOn() {
        withDefaults { defaults in
            #expect(Preferences(defaults: defaults).volumeFeedbackEnabled == true)
            Preferences(defaults: defaults).volumeFeedbackEnabled = false
            #expect(Preferences(defaults: defaults).volumeFeedbackEnabled == false)
        }
    }

    @Test("match-system-output defaults to on and persists when turned off")
    func matchSystemOutputDefaultsOn() {
        withDefaults { defaults in
            #expect(Preferences(defaults: defaults).matchSystemOutput == true)
            Preferences(defaults: defaults).matchSystemOutput = false
            #expect(Preferences(defaults: defaults).matchSystemOutput == false)
        }
    }

    @Test("start-at-login, keyboard, onboarding, and resume flags persist")
    func togglesPersist() {
        withDefaults { defaults in
            let prefs = Preferences(defaults: defaults)
            prefs.startAtLogin = true
            prefs.keyboardControlEnabled = true
            prefs.onboardingCompleted = true
            prefs.processingWasActive = true
            let reloaded = Preferences(defaults: defaults)
            #expect(reloaded.startAtLogin)
            #expect(reloaded.keyboardControlEnabled)
            #expect(reloaded.onboardingCompleted)
            #expect(reloaded.processingWasActive)
        }
    }
}
