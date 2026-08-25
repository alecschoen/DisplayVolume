import AppKit
import Foundation

/// Plays the macOS volume-key feedback "pop".
///
/// Because this app's own audio is excluded from the process tap (feedback-
/// loop protection), the pop reaches the device directly. On fixed-volume
/// displays it must therefore be attenuated in the player itself to match
/// the current software volume — which is exactly how macOS scales its own
/// feedback sound. On native-volume devices the hardware volume applies, so
/// full player volume is correct there.
public final class VolumeFeedbackPlayer {

    private let sound: NSSound?

    public init() {
        // The genuine system feedback sound, with a similar-sounding
        // built-in alert as fallback should Apple move it.
        let candidates = [
            "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff",
            "/System/Library/Sounds/Pop.aiff",
        ]
        var loaded: NSSound?
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            if let s = NSSound(contentsOfFile: path, byReference: true) {
                loaded = s
                break
            }
        }
        sound = loaded
        if sound == nil {
            AppLog.app.warning("Volume feedback sound not found; feedback disabled")
        }
    }

    /// Plays the pop at the given loudness (0–1). Safe to call rapidly
    /// (key repeat): a still-playing pop is restarted.
    public func play(atVolume volume: Float) {
        guard let sound else { return }
        guard volume.isFinite, volume > 0 else { return }
        if sound.isPlaying {
            sound.stop()
        }
        sound.volume = min(max(volume, 0), 1)
        sound.currentTime = 0
        sound.play()
    }
}
