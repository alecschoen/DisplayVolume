import CAtomics
import Foundation

/// Maps UI volume (0.0–1.0) to linear amplitude gain.
///
/// A quadratic curve (gain = v²) is used: it is close to perceptually even
/// for program material, guarantees gain(v) ≤ v ≤ 1 (never amplifies), maps
/// 0 → exact silence and 1 → exact unity.
public enum VolumeCurve {
    /// Sanitizes any input: non-finite values become 0, everything is
    /// clamped to [0, 1], so the result can never be NaN, infinite,
    /// negative, or above unity.
    public static func gain(forVolume volume: Float) -> Float {
        guard volume.isFinite else { return 0 }
        let v = min(max(volume, 0), 1)
        return v * v
    }
}

/// Real-time-safe gain smoother/applier.
///
/// Threading model:
///  - `setTarget(volume:muted:)` may be called from any thread (UI, media-key
///    handler). It only performs an atomic store.
///  - `prepare(sampleRate:)` must be called before audio starts, never during.
///  - `processInterleaved` is called from the real-time audio callback. It
///    performs no allocation, locking, or ObjC/Swift runtime calls that block.
///
/// The applied gain slews linearly toward the target at a bounded rate so a
/// full 0→1 swing takes `rampMilliseconds` (default 15 ms). This removes
/// clicks on volume moves, mute/unmute, and gives the required silence→saved
/// volume ramp at pipeline startup (the smoothed gain always starts at 0).
public final class GainProcessor {
    private let target: UnsafeMutablePointer<DVAtomicF32>

    // Owned exclusively by the audio thread between prepare() and stop.
    private var currentGain: Float = 0
    private var slewPerFrame: Float = 0.001

    public let rampMilliseconds: Double

    public init(rampMilliseconds: Double = 15) {
        self.rampMilliseconds = min(max(rampMilliseconds, 1), 100)
        target = .allocate(capacity: 1)
        target.initialize(to: DVAtomicF32(_value: 0))
    }

    deinit {
        target.deinitialize(count: 1)
        target.deallocate()
    }

    // MARK: - Control side (any thread)

    /// Atomically publishes a new target gain from volume + mute state.
    /// Invalid (non-finite) volumes are ignored, keeping the previous target.
    public func setTarget(volume: Float, muted: Bool) {
        guard volume.isFinite else { return }
        let gain = muted ? 0 : VolumeCurve.gain(forVolume: volume)
        dv_f32_store(target, gain)
    }

    public var targetGain: Float { dv_f32_load(target) }

    // MARK: - Audio-thread side

    /// Call once before starting IO (not from the RT thread while running).
    /// Resets the smoothed gain to 0 so startup ramps from silence.
    public func prepare(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 1000 ? sampleRate : 48_000
        slewPerFrame = Float(1.0 / (rate * rampMilliseconds / 1000.0))
        currentGain = 0
    }

    /// The gain most recently applied (diagnostics only; racy by design).
    public var smoothedGain: Float { currentGain }

    /// Applies gain in place to interleaved Float32 samples.
    /// REAL-TIME SAFE: no allocation, no locks, no logging.
    public func processInterleaved(_ samples: UnsafeMutablePointer<Float>,
                                   frameCount: Int,
                                   channelCount: Int) {
        guard frameCount > 0, channelCount > 0 else { return }
        var t = dv_f32_load(target)
        // Defensive: never let a corrupt target produce NaN/inf or amplify.
        if !t.isFinite { t = 0 }
        t = min(max(t, 0), 1)

        var g = currentGain
        let slew = slewPerFrame

        if g == t {
            // Steady state: fast paths.
            if t >= 1 { return }                      // unity: bit-exact passthrough
            let count = frameCount * channelCount
            if t <= 0 {
                memset(samples, 0, count * MemoryLayout<Float>.size)
            } else {
                for i in 0..<count { samples[i] *= t }
            }
            return
        }

        // Ramping: per-frame bounded step toward the target.
        var index = 0
        for _ in 0..<frameCount {
            if g < t {
                g += slew
                if g > t { g = t }
            } else {
                g -= slew
                if g < t { g = t }
            }
            for _ in 0..<channelCount {
                samples[index] *= g
                index += 1
            }
        }
        currentGain = g
    }
}
